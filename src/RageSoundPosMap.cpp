#include "RageSoundPosMap.h"

#include <algorithm>
#include <cinttypes>
#include <cmath>
#include <cstdint>
#include <deque>
#include <limits>
#include <mutex>
#include <new>
#include <string>
#include <utility>

#include "PerfDiagnostics.h"
#include "RageLog.h"
#include "RageTimer.h"

// NOTE(sukibaby): The number of frames we should keep pos_map data for.
// This maps hardware frames back to decoded stream/source frames. It is not
// an audio output buffer, so increasing it does not add playback latency; it
// keeps more timing history available when CoreAudio scheduling or device
// latency gets uneven mid-gameplay.
static constexpr int kPosMapBacklogFrames = 480000;
// CoreAudio and other backends can report a hardware cursor that is a small
// buffer quantum ahead/behind the newest committed position while a sound is
// starting or flushing. Treat that as timing jitter, not a real map failure.
// Keep the tolerance in time, then convert to frames for the rate being mapped
// so 44.1k, 48k, and high-rate devices behave consistently.
static constexpr double kMinorPositionDriftToleranceMs = 46.0;
static constexpr float kMinorPositionDriftTraceSeconds = 60.0f;
static constexpr int kSustainedMinorPositionDriftSearches = 120;
static constexpr size_t kMaxPosMapEntries = 4096;
static constexpr double kRatioMergeEpsilon = 0.000000001;

static bool MinorPositionDriftFramesForRate(
    int iFrameRate, int64_t& outFrames) {
  if (iFrameRate <= 0) {
    return false;
  }
  const double frames =
      static_cast<double>(iFrameRate) * kMinorPositionDriftToleranceMs /
      1000.0;
  if (!std::isfinite(frames) ||
      frames > static_cast<double>(std::numeric_limits<int64_t>::max())) {
    return false;
  }
  outFrames = static_cast<int64_t>(frames + 0.5);
  return true;
}

static bool AddInt64(int64_t lhs, int64_t rhs, int64_t& out) {
  if ((rhs > 0 && lhs > std::numeric_limits<int64_t>::max() - rhs) ||
      (rhs < 0 && lhs < std::numeric_limits<int64_t>::min() - rhs)) {
    return false;
  }
  out = lhs + rhs;
  return true;
}

static uint64_t AbsDistance(int64_t lhs, int64_t rhs) {
  if (lhs >= rhs) {
    return static_cast<uint64_t>(lhs) - static_cast<uint64_t>(rhs);
  }
  return static_cast<uint64_t>(rhs) - static_cast<uint64_t>(lhs);
}

static bool ScaleFramesToDestDelta(
    int64_t frames, double ratio, int64_t& out) {
  if (frames < 0 || !std::isfinite(ratio) || ratio <= 0.0) {
    return false;
  }
  const long double scaled =
      static_cast<long double>(frames) * static_cast<long double>(ratio);
  if (!std::isfinite(static_cast<double>(scaled)) ||
      scaled > static_cast<long double>(std::numeric_limits<int64_t>::max()) ||
      scaled < 0.0L) {
    return false;
  }
  out = static_cast<int64_t>(scaled + 0.5L);
  return true;
}

static bool RatiosEquivalent(double lhs, double rhs) {
  return std::abs(lhs - rhs) <=
         kRatioMergeEpsilon * std::max({1.0, std::abs(lhs), std::abs(rhs)});
}

struct pos_map_t {
  int64_t m_iSourceFrame;
  int64_t m_iDestFrame;
  int64_t m_iFrames;
  double m_fSourceToDestRatio;

  pos_map_t() {
    m_iSourceFrame = 0;
    m_iDestFrame = 0;
    m_iFrames = 0;
    m_fSourceToDestRatio = 1.0;
  }
};

struct pos_map_impl {
  std::deque<pos_map_t> m_Queue;
  mutable std::mutex m_Mutex;
  mutable int m_iConsecutiveMinorDrifts = 0;
  mutable RageTimer m_LastMinorDriftLog;
  mutable RageTimer m_LastSustainedMinorDriftLog;
  mutable RageTimer m_LastMismatchLog;
  mutable std::string m_sError;

  pos_map_impl() = default;
  pos_map_impl(const pos_map_impl& rhs) {
    std::lock_guard<std::mutex> lock(rhs.m_Mutex);
    m_Queue = rhs.m_Queue;
    m_iConsecutiveMinorDrifts = rhs.m_iConsecutiveMinorDrifts;
    m_sError = rhs.m_sError;
  }

  pos_map_impl& operator=(const pos_map_impl&) = delete;

  void ClearErrorLocked() const { m_sError.clear(); }

  bool SetErrorLocked(const std::string& error) const {
    m_sError = error;
    LogReviewSrcDiagnostics("%s", error.c_str());
    return false;
  }

  void CleanupLocked();
};

pos_map_queue::pos_map_queue() : m_pImpl(new pos_map_impl) {}

pos_map_queue::~pos_map_queue() = default;

pos_map_queue::pos_map_queue(const pos_map_queue& cpy) {
  m_pImpl.reset(new pos_map_impl(*cpy.m_pImpl));
}

pos_map_queue& pos_map_queue::operator=(const pos_map_queue& rhs) {
  if (this != &rhs) {
    pos_map_queue temp(rhs);
    std::swap(m_pImpl, temp.m_pImpl);
  }
  return *this;
}

pos_map_queue::pos_map_queue(pos_map_queue&&) noexcept = default;

pos_map_queue& pos_map_queue::operator=(pos_map_queue&&) noexcept = default;

bool pos_map_queue::Insert(
    int64_t iSourceFrame, int64_t iFrames, int64_t iDestFrame,
    double fSourceToDestRatio) {
  std::lock_guard<std::mutex> lock(m_pImpl->m_Mutex);
  m_pImpl->ClearErrorLocked();
  if (iFrames <= 0 || !std::isfinite(fSourceToDestRatio) ||
      fSourceToDestRatio <= 0.0) {
    return m_pImpl->SetErrorLocked(
        "SRC_AUDIT_FIX SRC-2916: PosMap rejected invalid insert arguments");
  }
  if (iSourceFrame < 0 || iDestFrame < 0) {
    LogReviewSrcDiagnostics(
        "SRC_AUDIT_FIX SRC-2918: PosMap accepted intentional negative frame "
        "mapping source=%lld dest=%lld frames=%lld ratio=%.9f",
        static_cast<long long>(iSourceFrame),
        static_cast<long long>(iDestFrame), static_cast<long long>(iFrames),
        fSourceToDestRatio);
  }
  int64_t sourceEnd = 0;
  int64_t destDelta = 0;
  int64_t destEnd = 0;
  if (!AddInt64(iSourceFrame, iFrames, sourceEnd) ||
      !ScaleFramesToDestDelta(iFrames, fSourceToDestRatio, destDelta) ||
      !AddInt64(iDestFrame, destDelta, destEnd)) {
    return m_pImpl->SetErrorLocked(
        "SRC_AUDIT_FIX SRC-2916: PosMap rejected overflowed insert mapping");
  }

  bool merged = false;
  if (!m_pImpl->m_Queue.empty()) {
    // Check if the last entry can be merged with the new entry
    pos_map_t& last = m_pImpl->m_Queue.back();
    int64_t lastSourceEnd = 0;
    int64_t lastDestDelta = 0;
    int64_t lastDestEnd = 0;
    if (AddInt64(last.m_iSourceFrame, last.m_iFrames, lastSourceEnd) &&
        ScaleFramesToDestDelta(
            last.m_iFrames, last.m_fSourceToDestRatio, lastDestDelta) &&
        AddInt64(last.m_iDestFrame, lastDestDelta, lastDestEnd) &&
        lastSourceEnd == iSourceFrame &&
        RatiosEquivalent(last.m_fSourceToDestRatio, fSourceToDestRatio) &&
        lastDestEnd == iDestFrame) {
      // Merge the frames and set the merged flag to true.
      int64_t mergedFrames = 0;
      if (AddInt64(last.m_iFrames, iFrames, mergedFrames)) {
        last.m_iFrames = mergedFrames;
        merged = true;
      }
    }
  }

  if (!merged) {
    try {
      m_pImpl->m_Queue.emplace_back();
    } catch (const std::bad_alloc&) {
      return m_pImpl->SetErrorLocked(
          "SRC_AUDIT_FIX SRC-2917: PosMap insert allocation failed");
    }
    pos_map_t& m = m_pImpl->m_Queue.back();
    m.m_iSourceFrame = iSourceFrame;
    m.m_iDestFrame = iDestFrame;
    m.m_iFrames = iFrames;
    m.m_fSourceToDestRatio = fSourceToDestRatio;
  }

  m_pImpl->CleanupLocked();
  return true;
}

void pos_map_impl::CleanupLocked() {
  auto it = m_Queue.end();
  int64_t iTotalFrames = 0;
  // Scan backwards until we have at least pos_map_backlog_frames.
  while (iTotalFrames < kPosMapBacklogFrames) {
    if (it == m_Queue.begin()) {
      break;
    }
    --it;
    if (!AddInt64(iTotalFrames, it->m_iFrames, iTotalFrames)) {
      iTotalFrames = std::numeric_limits<int64_t>::max();
      SetErrorLocked(
          "SRC_AUDIT_FIX SRC-2919: PosMap cleanup frame accumulator overflow");
      break;
    }
  }

  m_Queue.erase(m_Queue.begin(), it);
  while (m_Queue.size() > kMaxPosMapEntries) {
    m_Queue.pop_front();
  }
}

pos_map_search_result pos_map_queue::SearchResult(
    int64_t iSourceFrame, int iFrameRate) const {
  std::lock_guard<std::mutex> lock(m_pImpl->m_Mutex);
  m_pImpl->ClearErrorLocked();

  pos_map_search_result result;
  if (m_pImpl->m_Queue.empty()) {
    result.status = pos_map_search_result::Status::Empty;
    return result;
  }
  int64_t minorPositionDriftFrames = 0;
  if (!MinorPositionDriftFramesForRate(iFrameRate, minorPositionDriftFrames)) {
    m_pImpl->SetErrorLocked(
        "SRC_AUDIT_FIX SRC-2925: PosMap search rejected invalid frame rate");
    result.status = pos_map_search_result::Status::InvalidInput;
    return result;
  }

  // iSourceFrame is probably in pos_map.  Search to figure out what position it
  // maps to.
  int64_t iClosestPosition = 0;
  uint64_t iClosestPositionDist = std::numeric_limits<uint64_t>::max();
  size_t skippedCorruptEntries = 0;
  for (const pos_map_t& pm : m_pImpl->m_Queue) {
    int64_t sourceEnd = 0;
    int64_t destDelta = 0;
    int64_t destEnd = 0;
    if (!AddInt64(pm.m_iSourceFrame, pm.m_iFrames, sourceEnd) ||
        !ScaleFramesToDestDelta(
            pm.m_iFrames, pm.m_fSourceToDestRatio, destDelta) ||
        !AddInt64(pm.m_iDestFrame, destDelta, destEnd)) {
      ++skippedCorruptEntries;
      continue;
    }

    // Loop over the queue until we know generally where iSourceFrame is
    if (iSourceFrame >= pm.m_iSourceFrame &&
        iSourceFrame < sourceEnd) {
      m_pImpl->m_iConsecutiveMinorDrifts = 0;
      // If we are in the correct block, calculate its current position
      int64_t iDiff = static_cast<int64_t>(iSourceFrame - pm.m_iSourceFrame);
      if (!ScaleFramesToDestDelta(iDiff, pm.m_fSourceToDestRatio, iDiff)) {
        result.frame = pm.m_iDestFrame;
        result.status = pos_map_search_result::Status::Approximate;
        return result;
      }
      int64_t mappedFrame = 0;
      if (!AddInt64(pm.m_iDestFrame, iDiff, mappedFrame)) {
        result.frame = pm.m_iDestFrame;
        result.status = pos_map_search_result::Status::Approximate;
        return result;
      }
      result.frame = mappedFrame;
      result.status = pos_map_search_result::Status::Exact;
      return result;
    }

    // See if the current position is close to the beginning of this block.
    uint64_t dist = AbsDistance(pm.m_iSourceFrame, iSourceFrame);
    if (dist < iClosestPositionDist) {
      iClosestPositionDist = dist;
      iClosestPosition = pm.m_iDestFrame;
    }

    // See if the current position is close to the end of this block.
    dist = AbsDistance(sourceEnd, iSourceFrame);
    if (dist < iClosestPositionDist) {
      iClosestPositionDist = dist;
      iClosestPosition = destEnd;
    }
  }

  if (iClosestPositionDist == std::numeric_limits<uint64_t>::max()) {
    if (skippedCorruptEntries > 0) {
      m_pImpl->SetErrorLocked(
          "SRC_AUDIT_FIX SRC-2921: PosMap search skipped only corrupt entries");
      result.status = pos_map_search_result::Status::CorruptMap;
    }
    return result;
  }

  if (skippedCorruptEntries > 0) {
    LogReviewSrcDiagnostics(
        "SRC_AUDIT_FIX SRC-2921: PosMap search skipped %zu corrupt entries",
        skippedCorruptEntries);
  }

  /*
   * The frame is out of the range of data we've actually sent.
   * Return the closest position.
   *
   * There are three cases when this happens:
   * 1. Before the first CommitPlayingPosition call.
   * 2. After GetDataToPlay returns EOF and the sound has flushed, but before
   *    SoundStopped has been called.
   * 3. Underflow; we'll be given a larger frame number than we know about.
   */
  const pos_map_t& first = m_pImpl->m_Queue.front();
  const pos_map_t& lastEntry = m_pImpl->m_Queue.back();
  const int64_t firstStart = first.m_iSourceFrame;
  int64_t firstEnd = firstStart;
  AddInt64(first.m_iSourceFrame, first.m_iFrames, firstEnd);
  const int64_t lastStart = lastEntry.m_iSourceFrame;
  int64_t lastEnd = lastStart;
  AddInt64(lastEntry.m_iSourceFrame, lastEntry.m_iFrames, lastEnd);
  const char* relation =
      iSourceFrame < firstStart ? "before" :
      iSourceFrame >= lastEnd ? "after" : "gap";

  const uint64_t minorPositionDriftDistance =
      static_cast<uint64_t>(minorPositionDriftFrames);
  if (iClosestPositionDist <= minorPositionDriftDistance) {
    ++m_pImpl->m_iConsecutiveMinorDrifts;
    const bool sustainedDrift =
        m_pImpl->m_iConsecutiveMinorDrifts >
        kSustainedMinorPositionDriftSearches;
    if (sustainedDrift) {
      if (LOG != nullptr && PerfDiagnosticsEnabled() &&
          m_pImpl->m_LastSustainedMinorDriftLog.Ago() >= 10.0f) {
        m_pImpl->m_LastSustainedMinorDriftLog.Touch();
        LOG->Trace(
            "Audio position mismatch: sustained minor drift frame %" PRId64
            " outside buffered range relation=%s closest_dist=%" PRIu64
            " tolerance=%" PRIu64 " tolerance_ms=%.3f frame_rate=%d "
            "consecutive_searches=%d entries=%zu "
            "first=[%" PRId64 ",%" PRId64 ") last=[%" PRId64 ",%" PRId64
            ")",
            iSourceFrame, relation, iClosestPositionDist,
            minorPositionDriftDistance, kMinorPositionDriftToleranceMs,
            iFrameRate, m_pImpl->m_iConsecutiveMinorDrifts,
            m_pImpl->m_Queue.size(), firstStart, firstEnd, lastStart, lastEnd);
      }
      result.frame = iClosestPosition;
      result.status = pos_map_search_result::Status::Approximate;
      return result;
    }

    if (LOG != nullptr && PerfDiagnosticsEnabled() &&
        m_pImpl->m_LastMinorDriftLog.Ago() >=
            kMinorPositionDriftTraceSeconds) {
      m_pImpl->m_LastMinorDriftLog.Touch();
      LOG->Trace(
          "Audio position map minor drift: frame %" PRId64
          " outside buffered range relation=%s closest_dist=%" PRIu64
          " tolerance=%" PRIu64 " tolerance_ms=%.3f frame_rate=%d "
          "consecutive_searches=%d entries=%zu "
          "first=[%" PRId64 ",%" PRId64 ") last=[%" PRId64 ",%" PRId64 ")",
          iSourceFrame, relation, iClosestPositionDist,
          minorPositionDriftDistance, kMinorPositionDriftToleranceMs,
          iFrameRate, m_pImpl->m_iConsecutiveMinorDrifts,
          m_pImpl->m_Queue.size(), firstStart, firstEnd, lastStart, lastEnd);
    }
    result.frame = iClosestPosition;
    result.status = pos_map_search_result::Status::Approximate;
    return result;
  }

  m_pImpl->m_iConsecutiveMinorDrifts = 0;
  if (LOG != nullptr && PerfDiagnosticsEnabled() &&
      m_pImpl->m_LastMismatchLog.Ago() >= 10.0f) {
    m_pImpl->m_LastMismatchLog.Touch();
    LOG->Trace(
        "Audio position mismatch: frame %" PRId64
        " outside buffered range relation=%s closest_dist=%" PRIu64
        " tolerance=%" PRIu64 " tolerance_ms=%.3f frame_rate=%d entries=%zu "
        "first=[%" PRId64 ",%" PRId64 ") last=[%" PRId64 ",%" PRId64 ")",
        iSourceFrame, relation, iClosestPositionDist,
        minorPositionDriftDistance, kMinorPositionDriftToleranceMs,
        iFrameRate, m_pImpl->m_Queue.size(), firstStart, firstEnd, lastStart,
        lastEnd);
  }

  result.frame = iClosestPosition;
  result.status = pos_map_search_result::Status::Approximate;
  return result;
}

int64_t pos_map_queue::Search(int64_t iSourceFrame, int iFrameRate) const {
  return SearchResult(iSourceFrame, iFrameRate).frame;
}

void pos_map_queue::Clear() {
  std::lock_guard<std::mutex> lock(m_pImpl->m_Mutex);
  m_pImpl->m_Queue.clear();
  m_pImpl->m_iConsecutiveMinorDrifts = 0;
  m_pImpl->ClearErrorLocked();
}

bool pos_map_queue::IsEmpty() const {
  std::lock_guard<std::mutex> lock(m_pImpl->m_Mutex);
  return m_pImpl->m_Queue.empty();
}

std::string pos_map_queue::GetError() const {
  std::lock_guard<std::mutex> lock(m_pImpl->m_Mutex);
  return m_pImpl->m_sError;
}

/*
 * Copyright (c) 2002-2004 Glenn Maynard
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the
 * "Software"), to deal in the Software without restriction, including
 * without limitation the rights to use, copy, modify, merge, publish,
 * distribute, and/or sell copies of the Software, and to permit persons to
 * whom the Software is furnished to do so, provided that the above
 * copyright notice(s) and this permission notice appear in all copies of
 * the Software and that both the above copyright notice(s) and this
 * permission notice appear in supporting documentation.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 * OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
 * THIRD PARTY RIGHTS. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS
 * INCLUDED IN THIS NOTICE BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT
 * OR CONSEQUENTIAL DAMAGES, OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
 * OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
 * OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
 * PERFORMANCE OF THIS SOFTWARE.
 */
