#include "RageSoundReader_ThreadedBuffer.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <limits>
#include <list>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <thread>

#include "PerfDiagnostics.h"
#include "RageSoundReader.h"
#include "RageSoundReader_Filter.h"
#include "RageTimer.h"
#include "global.h"

/* Implement threaded read-ahead buffering.
 *
 * If a buffer is low on data, keep filling until it has a g_iMinFillFrames.
 * Once beyond that, fill at a rate relative to realtime.
 *
 * This allows a stream to have a large buffer, for higher reliability, without
 * causing major CPU bursts when the stream starts or underruns. Filling 32k
 * takes more CPU than filling 4k frames, and may cause a skip. */

// The amount of data to read at once:
static const unsigned g_iReadBlockSizeFrames = 4096;  // 4K frames

// The maximum number of frames to buffer:
static const int g_iStreamingBufferFrames = 1024 * 128;  // 128K frames

/* When a sound has fewer than g_iMinFillFrames buffered, buffer at maximum
 * speed. Once beyond that, fill at a limited rate. */
static const int g_iMinFillFrames = 1024 * 16;  // 16K frames
static const float g_fBufferWaitTimeoutSeconds = 30.0f;
static const unsigned MAX_THREADED_BUFFER_CHANNELS = 64;

namespace {

int ClampInt64ToInt(std::int64_t value) {
  if (value > std::numeric_limits<int>::max()) {
    return std::numeric_limits<int>::max();
  }
  if (value < std::numeric_limits<int>::min()) {
    return std::numeric_limits<int>::min();
  }
  return static_cast<int>(value);
}

bool CheckedAddFrames(std::int64_t base, int frames, std::int64_t* result) {
  if (result == nullptr || frames < 0 ||
      base > std::numeric_limits<std::int64_t>::max() - frames) {
    return false;
  }
  *result = base + frames;
  return true;
}

class RestoreThreadedBufferState {
 public:
  RestoreThreadedBufferState(const RageSoundReader_ThreadedBuffer& reader,
                             bool shouldRestore)
      : m_reader(reader), m_shouldRestore(shouldRestore) {}

  ~RestoreThreadedBufferState() {
    if (m_shouldRestore) {
      m_reader.EnableBuffering();
    }
  }

  RestoreThreadedBufferState(const RestoreThreadedBufferState&) = delete;
  RestoreThreadedBufferState& operator=(const RestoreThreadedBufferState&) =
      delete;

 private:
  const RageSoundReader_ThreadedBuffer& m_reader;
  bool m_shouldRestore;
};

}  // namespace

RageSoundReader_ThreadedBuffer::RageSoundReader_ThreadedBuffer(
    RageSoundReader* pSource)
    : RageSoundReader_Filter(pSource), m_Event("ThreadedBuffer") {
  m_iSampleRate = pSource == nullptr ? 0 : pSource->GetSampleRate();
  const unsigned iSourceChannels =
      pSource == nullptr ? 0 : pSource->GetNumChannels();
  m_iChannels = iSourceChannels > static_cast<unsigned>(
                                      std::numeric_limits<int>::max())
                    ? 0
                    : static_cast<int>(iSourceChannels);

  m_bEOF = true;
  m_bShutdownThread = false;
  m_bEnabled = false;
  m_bFilling = false;
  m_bThreadStarted = false;

  if (pSource == nullptr || m_iSampleRate <= 0 || iSourceChannels == 0 ||
      iSourceChannels > MAX_THREADED_BUFFER_CHANNELS ||
      m_iChannels <= 0) {
    SetError("SRC_AUDIT_FIX SRC-2860: invalid threaded-buffer source "
             "topology");
    return;
  }

  if (g_iStreamingBufferFrames >
      std::numeric_limits<unsigned>::max() / iSourceChannels) {
    SetError("SRC_AUDIT_FIX SRC-2852: threaded-buffer capacity overflow");
    return;
  }
  const unsigned iSampleCapacity =
      static_cast<unsigned>(g_iStreamingBufferFrames) * iSourceChannels;
  if (iSampleCapacity > std::numeric_limits<unsigned>::max() - iSourceChannels) {
    SetError("SRC_AUDIT_FIX SRC-2852: threaded-buffer reserve overflow");
    return;
  }

  try {
    m_DataBuffer.reserve(static_cast<unsigned>(iSampleCapacity), m_iChannels);
    m_StreamPosition.push_back(Mapping());
  } catch (const std::bad_alloc&) {
    SetError("SRC_AUDIT_FIX SRC-2858: failed to allocate threaded audio "
             "buffer");
    return;
  }
  m_bEOF = false;

  m_StreamPosition.back().iPositionOfFirstFrame =
      pSource->GetNextSourceFrame64();
  m_StreamPosition.back().fRate = pSource->GetStreamToSourceRatio();

  m_Thread.SetName("Sound buffering");
  m_Thread.Create(StartBufferingThread, this);
  m_bThreadStarted = true;
}

RageSoundReader_ThreadedBuffer::RageSoundReader_ThreadedBuffer(
    const RageSoundReader_ThreadedBuffer& cpy)
    : RageSoundReader_Filter(
          nullptr),  // don't touch m_pSource before DisableBuffering
      m_Event("ThreadedBuffer") {
  m_iSampleRate = 0;
  m_iChannels = 0;
  m_bEOF = true;
  m_bShutdownThread = false;
  m_bEnabled = false;
  m_bFilling = false;
  m_bThreadStarted = false;

  bool bWasEnabled = false;
  if (!const_cast<RageSoundReader_ThreadedBuffer&>(cpy)
           .DisableBufferingForSourceAccess(&bWasEnabled)) {
    SetError("SRC_AUDIT_FIX SRC-2855: source was still busy while copying "
             "threaded buffer");
    return;
  }
  RestoreThreadedBufferState restoreOriginal(cpy, bWasEnabled);

  try {
    m_pSource = cpy.m_pSource.isNull() ? nullptr : cpy.m_pSource->Copy();
    m_iSampleRate = cpy.m_iSampleRate;
    m_iChannels = cpy.m_iChannels;
    m_DataBuffer = cpy.m_DataBuffer;
    m_StreamPosition = cpy.m_StreamPosition;
    m_bEOF = cpy.m_bEOF;
  } catch (const std::bad_alloc&) {
    m_pSource = nullptr;
    m_iSampleRate = 0;
    m_iChannels = 0;
    m_StreamPosition.clear();
    m_bEOF = true;
    SetError("SRC_AUDIT_FIX SRC-2855: failed to allocate threaded-buffer "
             "copy");
    return;
  }

  if (!IsTopologyUsable()) {
    m_pSource = nullptr;
    m_bEOF = true;
    SetError("SRC_AUDIT_FIX SRC-2855: copied threaded buffer has no usable "
             "source");
    return;
  }

  if (!m_bEOF) {
    m_Thread.SetName("Sound buffering");
    m_Thread.Create(StartBufferingThread, this);
    m_bThreadStarted = true;
    if (bWasEnabled) {
      EnableBuffering();
    }
  }
}

RageSoundReader_ThreadedBuffer* RageSoundReader_ThreadedBuffer::Copy() const {
  std::unique_ptr<RageSoundReader_ThreadedBuffer> copy;
  try {
    copy.reset(new RageSoundReader_ThreadedBuffer(*this));
  } catch (const std::bad_alloc&) {
    return nullptr;
  }
  if (!copy->IsTopologyUsable()) {
    return nullptr;
  }
  return copy.release();
}

RageSoundReader_ThreadedBuffer::~RageSoundReader_ThreadedBuffer() {
  m_Event.Lock();
  m_bEnabled = false;
  m_bShutdownThread = true;
  m_Event.Broadcast();
  m_Event.Unlock();

  bool bWasEnabled = false;
  if (!DisableBufferingForSourceAccess(&bWasEnabled)) {
    SetError("SRC_AUDIT_FIX SRC-2854: threaded-buffer source did not become "
             "idle before destruction");
  }

  if (m_bThreadStarted) {
    m_Thread.Wait();
    m_bThreadStarted = false;
  }
}

void RageSoundReader_ThreadedBuffer::EnableBuffering() {
  m_Event.Lock();
  if (!m_bThreadStarted || m_pSource.isNull() || m_bShutdownThread || m_bEOF) {
    m_Event.Unlock();
    return;
  }
  m_bEnabled = true;
  m_Event.Broadcast();
  m_Event.Unlock();
}

bool RageSoundReader_ThreadedBuffer::DisableBuffering() {
  bool bWasEnabled = false;
  DisableBufferingForSourceAccess(&bWasEnabled);
  return bWasEnabled;
}

bool RageSoundReader_ThreadedBuffer::DisableBufferingForSourceAccess(
    bool* pWasEnabled) {
  m_Event.Lock();
  const bool bWasEnabled = m_bEnabled;
  m_bEnabled = false;
  m_Event.Broadcast();

  RageTimer timeout;
  timeout.Touch();
  timeout += g_fBufferWaitTimeoutSeconds;
  RageTimer waitStarted;
  while (m_bFilling) {
    bool waitCompleted = true;
    if (m_Event.WaitTimeoutSupported()) {
      waitCompleted = m_Event.Wait(&timeout);
    } else {
      m_Event.Unlock();
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
      m_Event.Lock();
      waitCompleted = waitStarted.Ago() < g_fBufferWaitTimeoutSeconds;
    }
    if (!waitCompleted) {
      if (pWasEnabled != nullptr) {
        *pWasEnabled = bWasEnabled;
      }
      m_Event.Unlock();
      SetError("SRC_AUDIT_FIX SRC-2853: timed out waiting for threaded "
               "audio source access");
      return false;
    }
  }

  m_Event.Unlock();

  if (pWasEnabled != nullptr) {
    *pWasEnabled = bWasEnabled;
  }
  return true;
}

int RageSoundReader_ThreadedBuffer::SetPosition(int iFrame) {
  if (m_pSource.isNull()) {
    return RageSoundReader::ERROR;
  }
  bool bWasEnabled = false;
  if (!DisableBufferingForSourceAccess(&bWasEnabled)) {
    return RageSoundReader::ERROR;
  }
  RestoreThreadedBufferState restoreBuffering(*this, bWasEnabled);

  int iRet = RageSoundReader::ERROR;
  {
    LockMutex lock(m_Event);

    m_DataBuffer.clear();

    if (iFrame < 0) {
      LogReviewSrcDiagnostics(
          "SRC_AUDIT_FIX SRC-2859: ThreadedBuffer accepted lead-in "
          "SetPosition frame=%d",
          iFrame);
    }
    iRet = RageSoundReader_Filter::SetPosition(iFrame);

    m_StreamPosition.clear();
    try {
      m_StreamPosition.push_back(Mapping());
    } catch (const std::bad_alloc&) {
      m_bEOF = true;
      SetError("SRC_AUDIT_FIX SRC-2858: failed to rebuild threaded-buffer "
               "position map");
      return RageSoundReader::ERROR;
    }
    m_StreamPosition.back().iPositionOfFirstFrame = iFrame;
    m_StreamPosition.back().fRate = m_pSource->GetStreamToSourceRatio();

    m_bEOF = iRet == 0;
  }

  return iRet;
}

int RageSoundReader_ThreadedBuffer::GetEmptyFrames() const {
  int iSamplesPerFrame = this->GetNumChannels();
  if (iSamplesPerFrame <= 0) {
    return 0;
  }
  if (g_iReadBlockSizeFrames * iSamplesPerFrame > m_DataBuffer.num_writable()) {
    return 0;
  }
  return m_DataBuffer.num_writable() / iSamplesPerFrame;
}

int RageSoundReader_ThreadedBuffer::GetFilledFrames() const {
  int iSamplesPerFrame = this->GetNumChannels();
  if (iSamplesPerFrame <= 0) {
    return 0;
  }
  return m_DataBuffer.num_readable() / iSamplesPerFrame;
}

int RageSoundReader_ThreadedBuffer::GetNextSourceFrame() const {
  m_Event.Lock();
  int iRet = m_StreamPosition.empty()
                 ? 0
                 : ClampInt64ToInt(
                       m_StreamPosition.front().iPositionOfFirstFrame);
  m_Event.Unlock();
  return iRet;
}

std::int64_t RageSoundReader_ThreadedBuffer::GetNextSourceFrame64() const {
  m_Event.Lock();
  const std::int64_t iRet =
      m_StreamPosition.empty() ? 0 : m_StreamPosition.front().iPositionOfFirstFrame;
  m_Event.Unlock();
  return iRet;
}

float RageSoundReader_ThreadedBuffer::GetStreamToSourceRatio() const {
  m_Event.Lock();
  float fRet = m_StreamPosition.empty() ? 1.0f : m_StreamPosition.front().fRate;
  m_Event.Unlock();
  return fRet;
}

int RageSoundReader_ThreadedBuffer::GetLength() const {
  bool bWasEnabled = false;
  if (!const_cast<RageSoundReader_ThreadedBuffer*>(this)
           ->DisableBufferingForSourceAccess(&bWasEnabled)) {
    return 0;
  }
  RestoreThreadedBufferState restoreBuffering(*this, bWasEnabled);
  int iRet = m_pSource.isNull() ? 0 : m_pSource->GetLength();
  return iRet;
}
int RageSoundReader_ThreadedBuffer::GetLength_Fast() const {
  bool bWasEnabled = false;
  if (!const_cast<RageSoundReader_ThreadedBuffer*>(this)
           ->DisableBufferingForSourceAccess(&bWasEnabled)) {
    return 0;
  }
  RestoreThreadedBufferState restoreBuffering(*this, bWasEnabled);
  int iRet = m_pSource.isNull() ? 0 : m_pSource->GetLength_Fast();
  return iRet;
}

bool RageSoundReader_ThreadedBuffer::SetProperty(
    const std::string& sProperty, float fValue) {
  if (m_pSource.isNull()) {
    return false;
  }

  bool bWasEnabled = false;
  if (!DisableBufferingForSourceAccess(&bWasEnabled)) {
    return false;
  }
  RestoreThreadedBufferState restoreBuffering(*this, bWasEnabled);
  const bool bRet = m_pSource->SetProperty(sProperty, fValue);
  return bRet;
}

void RageSoundReader_ThreadedBuffer::BufferingThread() {
  m_Event.Lock();
  while (!m_bShutdownThread) {
    if (!m_bEnabled) {
      m_Event.Wait();
      continue;
    }

    // Fill some data.
    m_bFilling = true;

    int iFramesToFill = g_iReadBlockSizeFrames;
    if (GetFilledFrames() < g_iMinFillFrames) {
      iFramesToFill =
          std::max(iFramesToFill, g_iMinFillFrames - GetFilledFrames());
    }

    int iRet = FillFrames(iFramesToFill);

    // Release m_bFilling, and signal the event to wake anyone waiting for it.
    m_bFilling = false;
    m_Event.Broadcast();

    // WOULD_BLOCK only means that the decoder made no progress during this
    // pass.  Keep the buffer enabled so the next timed pass can resume it.
    // Errors and EOF remain terminal for this source.
    if (iRet < 0 && iRet != RageSoundReader::WOULD_BLOCK) {
      m_bEnabled = false;
      continue;
    }

    /* Sleep proportionately to the amount of data we buffered, so we
     * fill at a reasonable pace. */
    const float fTimeToSleep =
        m_iSampleRate <= 0
            ? 0.0f
            : static_cast<float>(g_iReadBlockSizeFrames) /
                  (m_iSampleRate * 2.0f);
    if (!std::isfinite(fTimeToSleep) || fTimeToSleep <= 0.0f) {
      continue;
    }

    if (m_Event.WaitTimeoutSupported()) {
      RageTimer time;
      time.Touch();
      time += fTimeToSleep;
      m_Event.Wait(&time);
    } else {
      m_Event.Unlock();
      const auto sleep_duration_us =
          std::chrono::duration_cast<std::chrono::microseconds>(
              std::chrono::duration<float>(fTimeToSleep));
      std::this_thread::sleep_for(sleep_duration_us);
      m_Event.Lock();
    }
  }
  m_Event.Unlock();
}

int RageSoundReader_ThreadedBuffer::FillFrames(int iFrames) {
  if (iFrames <= 0) {
    return 0;
  }
  int iFramesFilled = 0;
  while (iFramesFilled < iFrames) {
    int iRet = FillBlock();

    if (iRet == 0) {
      break;
    }
    // On error or end of file, stop buffering the sound.
    if (iRet < 0) {
      return iRet;
    }

    iFramesFilled += iRet;
  }
  return iFramesFilled;
}

int RageSoundReader_ThreadedBuffer::FillBlock() {
  if (m_pSource.isNull() || m_StreamPosition.empty() || GetEmptyFrames() == 0) {
    return 0;
  }

  int iSamplesPerFrame = this->GetNumChannels();
  if (iSamplesPerFrame <= 0 || static_cast<unsigned>(iSamplesPerFrame) >
                                  MAX_THREADED_BUFFER_CHANNELS ||
      g_iReadBlockSizeFrames >
          std::numeric_limits<unsigned>::max() /
              static_cast<unsigned>(iSamplesPerFrame) ||
      g_iReadBlockSizeFrames * static_cast<unsigned>(iSamplesPerFrame) >
          m_DataBuffer.num_writable()) {
    SetError("SRC_AUDIT_FIX SRC-2858: invalid threaded-buffer write state");
    return RageSoundReader::ERROR;
  }

  int iGotFrames;
  std::int64_t iNextSourceFrame = 0;
  float fRate = 0;

  m_Event.Unlock();

  {
    // We own m_pSource, even after unlocking, because m_bFilling is true.
    unsigned iBufSize;
    float* pBuf = m_DataBuffer.get_write_pointer(&iBufSize);
    if (pBuf == nullptr || (iBufSize % iSamplesPerFrame) != 0) {
      iGotFrames = RageSoundReader::ERROR;
    } else {
      iGotFrames = m_pSource->RetriedRead(
          pBuf, std::min(g_iReadBlockSizeFrames, iBufSize / iSamplesPerFrame),
          &iNextSourceFrame, &fRate);
    }
  }

  m_Event.Lock();

  if (iGotFrames > 0) {
    if (iGotFrames > GetEmptyFrames()) {
      SetError("SRC_AUDIT_FIX SRC-2858: source returned more audio than the "
               "threaded buffer can store");
      return RageSoundReader::ERROR;
    }

    const Mapping& currentMapping = m_StreamPosition.back();
    std::int64_t iExpectedNextSourceFrame = 0;
    if (!CheckedAddFrames(currentMapping.iPositionOfFirstFrame,
                          currentMapping.iFramesBuffered,
                          &iExpectedNextSourceFrame)) {
      SetError("SRC_AUDIT_FIX SRC-3323: threaded-buffer source mapping "
               "overflow");
      return RageSoundReader::ERROR;
    }
    if (static_cast<std::int64_t>(iNextSourceFrame) != iExpectedNextSourceFrame ||
        fRate != m_StreamPosition.back().fRate) {
      try {
        m_StreamPosition.push_back(Mapping());
      } catch (const std::bad_alloc&) {
        SetError("SRC_AUDIT_FIX SRC-2858: failed to extend threaded-buffer "
                 "position map");
        return RageSoundReader::ERROR;
      }
      m_StreamPosition.back().iPositionOfFirstFrame = iNextSourceFrame;
      m_StreamPosition.back().fRate = fRate;
    }

    if (m_StreamPosition.back().iFramesBuffered >
        std::numeric_limits<int>::max() - iGotFrames) {
      SetError("SRC_AUDIT_FIX SRC-2859: threaded-buffer mapping overflow");
      return RageSoundReader::ERROR;
    }

    // Add the data only after the source-to-stream mapping is known-good.
    m_DataBuffer.advance_write_pointer(iGotFrames * iSamplesPerFrame);
    m_StreamPosition.back().iFramesBuffered += iGotFrames;
    ClearError();
  }

  m_bEOF = (iGotFrames == END_OF_FILE);

  return iGotFrames;
}

int RageSoundReader_ThreadedBuffer::Read(float* pBuffer, int iFrames) {
  if (iFrames == 0) {
    return 0;
  }
  if (pBuffer == nullptr || iFrames < 0 || m_iChannels <= 0) {
    return RageSoundReader::ERROR;
  }
  EnableBuffering();

  m_Event.Lock();
  if (m_StreamPosition.empty()) {
    m_Event.Unlock();
    return RageSoundReader::ERROR;
  }

  {
    /* Collapse all consumed mappings at once, but keep the final mapping so
     * the current source position and rate remain available.  Returning once
     * still tells RetriedRead that the mapping changed without making it burn
     * one retry per historical mapping. */
    size_t collapsedMappings = 0;
    while (m_StreamPosition.size() > 1 &&
           m_StreamPosition.front().iFramesBuffered == 0) {
      m_StreamPosition.pop_front();
      ++collapsedMappings;
    }
    if (collapsedMappings != 0) {
      if (collapsedMappings > 1) {
        LogReviewSrcDiagnostics(
            "SRC_AUDIT_FIX SRC-2933: collapsed %zu consumed threaded audio "
            "mappings source=%s remaining=%zu",
            collapsedMappings, GetSourcePath().c_str(),
            m_StreamPosition.size());
      }
      m_Event.Unlock();
      return 0;
    }
  }

  int iRet;
  if (m_StreamPosition.front().iFramesBuffered) {
    Mapping& pos = m_StreamPosition.front();
    int iFramesToRead = std::min(iFrames, pos.iFramesBuffered);
    int iSamplesPerFrame = this->GetNumChannels();
    if (iSamplesPerFrame <= 0 ||
        iFramesToRead > std::numeric_limits<int>::max() / iSamplesPerFrame ||
        !m_DataBuffer.read(pBuffer, iFramesToRead * iSamplesPerFrame)) {
      m_Event.Unlock();
      return RageSoundReader::ERROR;
    }
    std::int64_t iNewSourceFrame = 0;
    if (!CheckedAddFrames(
            pos.iPositionOfFirstFrame, iFramesToRead, &iNewSourceFrame)) {
      m_Event.Unlock();
      SetError("SRC_AUDIT_FIX SRC-3323: threaded-buffer read position "
               "overflow");
      return RageSoundReader::ERROR;
    }
    pos.iPositionOfFirstFrame = iNewSourceFrame;
    pos.iFramesBuffered -= iFramesToRead;
    iRet = iFramesToRead;
  } else if (m_bEOF) {
    iRet = END_OF_FILE;
  } else {
    iRet = WOULD_BLOCK;
  }
  m_Event.Unlock();

  if (iRet != RageSoundReader::ERROR) {
    ClearError();
  }
  return iRet;
}

bool RageSoundReader_ThreadedBuffer::IsTopologyUsable() const {
  return !m_pSource.isNull() && m_iSampleRate > 0 && m_iChannels > 0 &&
         static_cast<unsigned>(m_iChannels) <= MAX_THREADED_BUFFER_CHANNELS &&
         !m_StreamPosition.empty();
}

void RageSoundReader_ThreadedBuffer::ClearError() const {
  std::lock_guard<std::mutex> lock(m_ErrorMutex);
  m_sError.clear();
}

void RageSoundReader_ThreadedBuffer::SetError(const std::string& sError) const {
  if (sError.find("SRC_AUDIT_FIX SRC-28") != std::string::npos) {
    LogReviewSrcDiagnostics("%s", sError.c_str());
  }
  std::lock_guard<std::mutex> lock(m_ErrorMutex);
  m_sError = sError;
}

std::string RageSoundReader_ThreadedBuffer::GetError() const {
  {
    std::lock_guard<std::mutex> lock(m_ErrorMutex);
    if (!m_sError.empty()) {
      return m_sError;
    }
  }
  return RageSoundReader_Filter::GetError();
}

/*
 * Copyright (c) 2006 Glenn Maynard
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
