#include "RageSoundReader_Merge.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <iterator>
#include <limits>
#include <memory>
#include <new>
#include <string>
#include <utility>
#include <vector>

#include "RageLog.h"
#include "RageSoundConstants.h"
#include "RageSoundMixBuffer.h"
#include "RageSoundReader.h"
#include "RageSoundReader_Pan.h"
#include "RageSoundReader_Resample_Good.h"
#include "RageUtil.h"
#include "global.h"

namespace {
static const unsigned MAX_MERGE_CHANNELS = 64;

bool IsUsableRatio(float ratio) {
  return std::isfinite(ratio) && ratio > 0.0f;
}

int ClampInt64ToInt(std::int64_t value) {
  if (value > std::numeric_limits<int>::max()) {
    return std::numeric_limits<int>::max();
  }
  if (value < std::numeric_limits<int>::min()) {
    return std::numeric_limits<int>::min();
  }
  return static_cast<int>(value);
}

bool AdvanceSourceFrame(
    std::int64_t* sourceFrame, int streamFrames, float ratio) {
  if (sourceFrame == nullptr) {
    return false;
  }
  if (streamFrames <= 0 || !IsUsableRatio(ratio)) {
    return true;
  }
  const double delta = static_cast<double>(streamFrames) * ratio;
  if (!std::isfinite(delta) ||
      delta > static_cast<double>(std::numeric_limits<std::int64_t>::max())) {
    return false;
  }
  const std::int64_t rounded = static_cast<std::int64_t>(std::llround(delta));
  if (rounded < 0 ||
      *sourceFrame > std::numeric_limits<std::int64_t>::max() - rounded) {
    return false;
  }
  *sourceFrame += rounded;
  return true;
}
}  // namespace

RageSoundReader_Merge::RageSoundReader_Merge() = default;
RageSoundReader_Merge::~RageSoundReader_Merge() = default;

RageSoundReader_Merge* RageSoundReader_Merge::Copy() const {
  try {
    std::unique_ptr<RageSoundReader_Merge> copy(new RageSoundReader_Merge());
    copy->m_iSampleRate = m_iSampleRate;
    copy->m_iChannels = m_iChannels;
    copy->m_bFinished = m_bFinished;
    copy->m_iNextSourceFrame = m_iNextSourceFrame;
    copy->m_fCurrentStreamToSourceRatio = m_fCurrentStreamToSourceRatio;

    copy->m_aSounds.reserve(m_aSounds.size());
    for (const auto& sound : m_aSounds) {
      if (sound == nullptr) {
        continue;
      }
      std::unique_ptr<RageSoundReader> soundCopy(sound->Copy());
      if (soundCopy == nullptr) {
        SetError("SRC_AUDIT_FIX SRC-2876: failed to copy merge source reader");
        return nullptr;
      }
      copy->m_aSounds.push_back(std::move(soundCopy));
    }
    return copy.release();
  } catch (const std::bad_alloc&) {
    SetError("SRC_AUDIT_FIX SRC-2876: failed to allocate merge copy");
    return nullptr;
  }
}

void RageSoundReader_Merge::AddSound(RageSoundReader* pSound) {
  std::unique_ptr<RageSoundReader> soundOwner(pSound);
  if (pSound == nullptr) {
    if (LOG != nullptr) {
      LOG->Warn("RageSoundReader_Merge::AddSound: null sound reader");
    }
    return;
  }
  if (m_bFinished) {
    SetError("SRC_AUDIT_FIX SRC-2877: attempted to add merge source after "
             "Finish");
    if (LOG != nullptr) {
      LOG->Warn("RageSoundReader_Merge::AddSound: ignored sound added after "
                "Finish");
    }
    return;
  }
  try {
    m_aSounds.push_back(std::move(soundOwner));
  } catch (const std::bad_alloc&) {
    SetError("SRC_AUDIT_FIX SRC-2877: failed to store merge source reader");
  }
}

/* If every sound has the same sample rate, return it.  Otherwise, return -1. */
int RageSoundReader_Merge::GetSampleRateInternal() const {
  if (m_aSounds.empty()) {
    return FALLBACK_SAMPLE_RATE;
  }

  int iRate = -1;
  for (const auto& sound : m_aSounds) {
    const RageSoundReader* it = sound.get();
    if (it == nullptr) {
      continue;
    }
    if (it->GetSampleRate() <= 0) {
      return -1;
    }
    if (iRate == -1) {
      iRate = it->GetSampleRate();
    } else if (iRate != it->GetSampleRate()) {
      return -1;
    }
  }
  return iRate;
}

void RageSoundReader_Merge::Finish(int iPreferredSampleRate) {
  if (m_bFinished) {
    SetError("SRC_AUDIT_FIX SRC-2877: attempted to finish merge twice");
    return;
  }
  ClearError();
  if (iPreferredSampleRate <= 0) {
    iPreferredSampleRate = FALLBACK_SAMPLE_RATE;
  }
  /* Figure out how many channels we have.  All sounds must either have 1 or 2
   * channels, which will be converted as needed, or have the same number of
   * channels. */
  m_iChannels = 1;
  for (auto& sound : m_aSounds) {
    if (sound == nullptr) {
      continue;
    }
    if (!IsSoundTopologyUsable(sound.get())) {
      SetError("SRC_AUDIT_FIX SRC-2879: discarded invalid merge source "
               "topology");
      sound.reset();
      continue;
    }
    m_iChannels = std::max(m_iChannels, sound->GetNumChannels());
  }
  EraseNullSounds();

  if (m_iChannels > 2) {
    for (auto& sound : m_aSounds) {
      if (sound != nullptr && sound->GetNumChannels() != m_iChannels) {
        if (LOG != nullptr) {
          LOG->Warn(
              "Discarded sound with %i channels, not %i", sound->GetNumChannels(),
              m_iChannels);
        }
        SetError("SRC_AUDIT_FIX SRC-2879: discarded merge source with "
                 "incompatible channel count");
        sound.reset();
      }
    }
    EraseNullSounds();
  }

  /*
   * We might get different sample rates from our sources.  If they're all the
   * same sample rate, just leave it alone, so the whole sound can be resampled
   * as a group. If not, resample eveything to the preferred rate.  (Using the
   * preferred rate should avoid redundant resampling later.)
   */
  m_iSampleRate = GetSampleRateInternal();
  if (m_iSampleRate == -1) {
    for (auto& sound : m_aSounds) {
      if (sound == nullptr) {
        continue;
      }
      try {
        std::unique_ptr<RageSoundReader> original(std::move(sound));
        RageSoundReader* pRawOriginal = original.release();
        std::unique_ptr<RageSoundReader> pResample;
        try {
          pResample.reset(new RageSoundReader_Resample_Good(
              pRawOriginal, iPreferredSampleRate));
          pRawOriginal = nullptr;
        } catch (...) {
          original.reset(pRawOriginal);
          sound = std::move(original);
          throw;
        }

        if (!IsSoundTopologyUsable(pResample.get())) {
          SetError("SRC_AUDIT_FIX SRC-2878: discarded invalid merge resample "
                   "wrapper");
          sound.reset();
          continue;
        }
        sound = std::move(pResample);
      } catch (const std::bad_alloc&) {
        SetError("SRC_AUDIT_FIX SRC-2878: failed to allocate merge resampler");
        sound.reset();
      }
    }

    m_iSampleRate = iPreferredSampleRate;
    EraseNullSounds();
  }

  /* If we have two channels, and any sounds have only one, convert them by
   * adding a Pan filter. */
  for (auto& sound : m_aSounds) {
    if (sound != nullptr && sound->GetNumChannels() != this->GetNumChannels()) {
      try {
        RageSoundReader* pRawSound = sound.release();
        std::unique_ptr<RageSoundReader> pPan;
        try {
          pPan.reset(new RageSoundReader_Pan(pRawSound));
          pRawSound = nullptr;
        } catch (...) {
          sound.reset(pRawSound);
          throw;
        }
        if (!IsSoundTopologyUsable(pPan.get()) ||
            pPan->GetNumChannels() != this->GetNumChannels()) {
          SetError("SRC_AUDIT_FIX SRC-2878: discarded invalid merge pan "
                   "wrapper");
          sound.reset();
          continue;
        }
        sound = std::move(pPan);
      } catch (const std::bad_alloc&) {
        SetError("SRC_AUDIT_FIX SRC-2878: failed to allocate merge pan filter");
        sound.reset();
      }
    }
  }
  EraseNullSounds();

  if (m_aSounds.empty()) {
    m_iChannels = 1;
  }
  if (m_iSampleRate <= 0) {
    m_iSampleRate = iPreferredSampleRate;
  }
  m_bFinished = true;
}

int RageSoundReader_Merge::SetPosition(int iFrame) {
  int iRet = 0;
  std::vector<RageSoundReader*> seeked;
  try {
    seeked.reserve(m_aSounds.size());
  } catch (const std::bad_alloc&) {
    SetError("SRC_AUDIT_FIX SRC-2882: failed to track merge seek rollback");
    return ERROR;
  }

  for (auto& sound : m_aSounds) {
    RageSoundReader* pSound = sound.get();
    if (pSound == nullptr) {
      continue;
    }
    int iThisRet = pSound->SetPosition(iFrame);
    if (iThisRet == -1) {
      for (RageSoundReader* seekedSound : seeked) {
        seekedSound->SetPosition(ClampInt64ToInt(m_iNextSourceFrame));
      }
      SetError("SRC_AUDIT_FIX SRC-2882: merge source seek failed");
      return ERROR;
    }
    seeked.push_back(pSound);
    if (iThisRet > 0) {
      iRet = 1;
    }
  }

  m_iNextSourceFrame = iFrame;
  ClearError();
  return iRet;
}

bool RageSoundReader_Merge::SetProperty(
    const std::string& sProperty, float fValue) {
  bool bAnyAccepted = false;
  bool bAnyRejected = false;
  for (auto& sound : m_aSounds) {
    if (sound == nullptr) {
      continue;
    }
    if (sound->SetProperty(sProperty, fValue)) {
      bAnyAccepted = true;
    } else {
      bAnyRejected = true;
    }
  }

  if (bAnyAccepted && bAnyRejected) {
    SetError("SRC_AUDIT_FIX SRC-2883: merge property was only partially "
             "accepted");
    return false;
  }
  if (!bAnyAccepted) {
    SetError("SRC_AUDIT_FIX SRC-2883: merge property was rejected by all "
             "sources");
    return false;
  }
  ClearError();
  return true;
}

static float Difference(float a, float b) { return std::abs(a - b); }
static uint64_t Difference(std::int64_t a, std::int64_t b) {
  if (a >= b) {
    return static_cast<uint64_t>(a) - static_cast<uint64_t>(b);
  }
  return static_cast<uint64_t>(b) - static_cast<uint64_t>(a);
}

/*
 * If the audio position drifts apart further than ERROR_CORRECTION_THRESHOLD
 * frames, attempt to resync it.
 *
 * Frames are expressed as whole numbers, and the ratio between source and
 * stream frames is floating point.  We can't read a specific number of source
 * frames, only stream frames.  If a stream is early by 15 source frames, we'll
 * convert that to stream frames for reading; this rounds back to an integer, so
 * it isn't exact.  (The amount of error should be no more than the ratio; if we
 * have a ratio of 10, then reading 10 stream frames should advance the stream
 * by 100-110 frames.  The ratio is normally less than 5.)
 *
 * ERROR_CORRECTION_THRESHOLD should be greater than the maximum rate in use, so
 * we can always resync the stream back to within the tolerance of the
 * threshold.
 *
 * In the pathological case, if this is too low we may never resync properly,
 * each attempt to resync leapfrogging past the previous.
 */

static const int ERROR_CORRECTION_THRESHOLD = 16;

/* As we iterate through the sound tree, we'll find that we need data from
 * different sounds; a sound may be needed by more than one other sound. */
int RageSoundReader_Merge::Read(float* pBuffer, int iFrames) {
  if (pBuffer == nullptr || iFrames < 0 || m_iChannels == 0 ||
      m_iChannels > MAX_MERGE_CHANNELS || m_iSampleRate <= 0 ||
      !m_bFinished || !IsUsableRatio(m_fCurrentStreamToSourceRatio)) {
    SetError("SRC_AUDIT_FIX SRC-2884: invalid merge read state");
    return ERROR;
  }
  if (iFrames == 0) {
    return 0;
  }
  if (m_aSounds.empty()) {
    return END_OF_FILE;
  }

  /*
   * All sounds which are active should stay aligned; each GetNextSourceFrame
   * should not come out of sync.  Accomodate small rounding errors.  A larger
   * inconsistency happens may be a bug, such as sounds at different speeds.
   */
  std::vector<std::int64_t> aNextSourceFrames;
  std::vector<float> aRatios;
  try {
    aNextSourceFrames.resize(m_aSounds.size());
    aRatios.resize(m_aSounds.size());
  } catch (const std::bad_alloc&) {
    SetError("SRC_AUDIT_FIX SRC-2885: failed to allocate merge read state");
    return ERROR;
  }

  for (size_t i = 0; i < m_aSounds.size(); ++i) {
    if (m_aSounds[i] == nullptr) {
      SetError("SRC_AUDIT_FIX SRC-2884: merge source reader is null");
      return ERROR;
    }
    aNextSourceFrames[i] = m_aSounds[i]->GetNextSourceFrame();
    aRatios[i] = m_aSounds[i]->GetStreamToSourceRatio();
    if (!IsUsableRatio(aRatios[i])) {
      SetError("SRC_AUDIT_FIX SRC-2884: merge source has invalid stream "
               "ratio");
      return ERROR;
    }
  }

  /* GetNextSourceFrame for each active sound should be the same.  If any
   * differ, delay the later sounds until the earlier ones catch back up to put
   * them back in sync. */
  int iEarliestSound = std::distance(
      aNextSourceFrames.begin(),
      std::min_element(aNextSourceFrames.begin(), aNextSourceFrames.end()));

  /* Normally, m_iNextSourceFrame should already be aligned with the
   * GetNextSourceFrame of our sounds.  If it's not, adjust it and return. */
  if (m_iNextSourceFrame != aNextSourceFrames[iEarliestSound] ||
      m_fCurrentStreamToSourceRatio != aRatios[iEarliestSound]) {
    m_iNextSourceFrame = aNextSourceFrames[iEarliestSound];
    m_fCurrentStreamToSourceRatio = aRatios[iEarliestSound];
    return 0;
  }

  const std::int64_t iMinPosition = aNextSourceFrames[iEarliestSound];
  for (size_t i = 0; i < m_aSounds.size(); ++i) {
    if (Difference(aNextSourceFrames[i], iMinPosition) >
        ERROR_CORRECTION_THRESHOLD) {
      /* A sound is being delayed to resync it; clamp the number of frames we
       * read now, so we don't advance past it. */
      const std::int64_t iMaxSourceFramesToRead =
          aNextSourceFrames[i] - iMinPosition;
      if (iMaxSourceFramesToRead <= 0) {
        continue;
      }
      const double iMaxStreamFrames =
          (static_cast<double>(iMaxSourceFramesToRead) /
           m_fCurrentStreamToSourceRatio) +
          0.5;
      if (!std::isfinite(iMaxStreamFrames)) {
        SetError("SRC_AUDIT_FIX SRC-2886: merge resync frame calculation "
                 "overflow");
        return ERROR;
      }
      int iMaxStreamFramesToRead =
          iMaxStreamFrames > std::numeric_limits<int>::max()
              ? std::numeric_limits<int>::max()
              : std::max(1, static_cast<int>(iMaxStreamFrames));
      iFrames = std::min(iFrames, iMaxStreamFramesToRead);
      //			LOG->Warn( "RageSoundReader_Merge: sound
      // positions moving at different rates" );
    }
  }

  // Read directly if there's only one sound
  if (m_aSounds.size() == 1) {
    RageSoundReader* pSound = m_aSounds.front().get();
    if (pSound == nullptr || pSound->GetNumChannels() != m_iChannels) {
      SetError("SRC_AUDIT_FIX SRC-2880: merge source channel mismatch");
      return ERROR;
    }
    iFrames = pSound->Read(pBuffer, iFrames);
    if (iFrames > 0) {
      if (!AdvanceSourceFrame(
              &m_iNextSourceFrame, iFrames, m_fCurrentStreamToSourceRatio)) {
        SetError("SRC_AUDIT_FIX SRC-2887: merge source frame overflow");
        return ERROR;
      }
      ClearError();
    }
    return iFrames;
  }

  RageSoundMixBuffer mix;
  float Buffer[2048];
  iFrames = std::min(iFrames, static_cast<int>(ARRAYLEN(Buffer) / m_iChannels));
  if (iFrames <= 0) {
    return ERROR;
  }

  /* Read iFrames from each sound. */
  for (size_t i = 0; i < m_aSounds.size(); ++i) {
    RageSoundReader* pSound = m_aSounds[i].get();
    if (pSound == nullptr || pSound->GetNumChannels() != m_iChannels) {
      SetError("SRC_AUDIT_FIX SRC-2880: merge source channel mismatch");
      return ERROR;
    }

    int iFramesRead = 0;
    while (iFramesRead < iFrames) {
      //			if( i == 0 )
      // LOG->Trace( "*** %i", Difference(aNextSourceFrames[i],
      // m_iNextSourceFrame + std::lrint(iFramesRead * aRatios[i])) );

      // if( Difference(aNextSourceFrames[i], m_iNextSourceFrame +
      // static_cast<int>((iFramesRead * aRatios[i]) + 0.5)) >
      // ERROR_CORRECTION_THRESHOLD )
      // {
      // LOG->Trace("Sound positions moving at different rates");
      // break;
      // }

      int iGotFrames = pSound->Read(Buffer, iFrames - iFramesRead);
      aNextSourceFrames[i] = m_aSounds[i]->GetNextSourceFrame();
      aRatios[i] = m_aSounds[i]->GetStreamToSourceRatio();
      //	LOG->Trace( "read %i from %i; %i -> %i", iGotFrames, i, oldf,
      // aNextSourceFrames[i] );
      if (iGotFrames < 0) {
        if (i == 0) {
          return iGotFrames;
        }
        break;
      }
      if (iGotFrames == 0) {
        break;
      }
      if (!IsUsableRatio(aRatios[i])) {
        SetError("SRC_AUDIT_FIX SRC-2884: merge source ratio became invalid");
        return ERROR;
      }

      const unsigned soundChannels = pSound->GetNumChannels();
      if (soundChannels == 0 ||
          static_cast<size_t>(iFramesRead) >
              static_cast<size_t>(std::numeric_limits<int>::max()) /
                  soundChannels ||
          static_cast<size_t>(iGotFrames) >
              std::numeric_limits<size_t>::max() / soundChannels ||
          !mix.SetWriteOffset(
              static_cast<int>(iFramesRead * soundChannels)) ||
          !mix.write(
              Buffer, static_cast<size_t>(iGotFrames) * soundChannels)) {
        SetError("SRC_AUDIT_FIX SRC-2881: merge mix buffer write failed");
        if (LOG != nullptr) {
          LOG->Warn(
              "RageSoundReader_Merge: mix buffer write failed: %s",
              mix.GetError().c_str());
        }
        return ERROR;
      }
      iFramesRead += iGotFrames;

      if (Difference(aRatios[i], m_fCurrentStreamToSourceRatio) > 0.001f) {
        break;
      }
    }
  }

  /* Read mixed frames into the output buffer. */
  int iMaxFramesRead = mix.size() / m_iChannels;
  if (iMaxFramesRead <= 0) {
    return 0;
  }
  if (!mix.read(pBuffer)) {
    SetError("SRC_AUDIT_FIX SRC-2884: merge mix buffer read failed");
    if (LOG != nullptr) {
      LOG->Warn(
          "RageSoundReader_Merge: mix buffer read failed: %s",
          mix.GetError().c_str());
    }
    return ERROR;
  }

  if (!AdvanceSourceFrame(
          &m_iNextSourceFrame, iMaxFramesRead,
          m_fCurrentStreamToSourceRatio)) {
    SetError("SRC_AUDIT_FIX SRC-2887: merge source frame overflow");
    return ERROR;
  }

  ClearError();
  return iMaxFramesRead;
}

int RageSoundReader_Merge::GetLength() const {
  int iLength = 0;
  for (const auto& sound : m_aSounds) {
    if (sound != nullptr) {
      iLength = std::max(iLength, sound->GetLength());
    }
  }
  return iLength;
}

int RageSoundReader_Merge::GetLength_Fast() const {
  int iLength = 0;
  for (const auto& sound : m_aSounds) {
    if (sound != nullptr) {
      iLength = std::max(iLength, sound->GetLength_Fast());
    }
  }
  return iLength;
}

int RageSoundReader_Merge::GetNextSourceFrame() const {
  return ClampInt64ToInt(m_iNextSourceFrame);
}

std::int64_t RageSoundReader_Merge::GetNextSourceFrame64() const {
  return m_iNextSourceFrame;
}

std::string RageSoundReader_Merge::GetError() const {
  if (!m_sError.empty()) {
    return m_sError;
  }
  for (const auto& sound : m_aSounds) {
    if (sound == nullptr) {
      continue;
    }
    const std::string sourceError = sound->GetError();
    if (!sourceError.empty()) {
      return sourceError;
    }
  }
  return std::string();
}

void RageSoundReader_Merge::ClearError() const {
  m_sError.clear();
}

void RageSoundReader_Merge::SetError(const std::string& sError) const {
  m_sError = sError;
}

bool RageSoundReader_Merge::IsSoundTopologyUsable(
    const RageSoundReader* pSound) const {
  if (pSound == nullptr) {
    return false;
  }
  const unsigned channels = pSound->GetNumChannels();
  return pSound->GetSampleRate() > 0 && channels > 0 &&
         channels <= MAX_MERGE_CHANNELS;
}

void RageSoundReader_Merge::EraseNullSounds() {
  m_aSounds.erase(
      std::remove_if(
          m_aSounds.begin(), m_aSounds.end(),
          [](const std::unique_ptr<RageSoundReader>& sound) {
            return sound == nullptr;
          }),
      m_aSounds.end());
}

/*
 * Copyright (c) 2004-2006 Glenn Maynard
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
