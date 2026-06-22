#include "RageSoundReader_ThreadedBuffer.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>
#include <list>
#include <string>
#include <thread>

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

RageSoundReader_ThreadedBuffer::RageSoundReader_ThreadedBuffer(
    RageSoundReader* pSource)
    : RageSoundReader_Filter(pSource), m_Event("ThreadedBuffer") {
  m_iSampleRate = pSource == nullptr ? 0 : pSource->GetSampleRate();
  m_iChannels =
      pSource == nullptr ? 0 : static_cast<int>(pSource->GetNumChannels());

  m_bEOF = true;
  m_bShutdownThread = false;
  m_bEnabled = false;
  m_bFilling = false;
  m_bThreadStarted = false;

  if (pSource == nullptr || m_iSampleRate <= 0 || m_iChannels <= 0 ||
      m_iChannels >
          std::numeric_limits<int>::max() / static_cast<int>(sizeof(float))) {
    return;
  }

  const int iFrameSize = sizeof(float) * m_iChannels;
  if (g_iStreamingBufferFrames >
      std::numeric_limits<int>::max() / iFrameSize) {
    return;
  }
  m_DataBuffer.reserve(g_iStreamingBufferFrames * iFrameSize, iFrameSize);
  m_bEOF = false;

  m_StreamPosition.push_back(Mapping());
  m_StreamPosition.back().iPositionOfFirstFrame = pSource->GetNextSourceFrame();
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
  bool bWasEnabled = cpy.DisableBuffering();

  m_pSource = cpy.m_pSource.isNull() ? nullptr : cpy.m_pSource->Copy();
  m_iSampleRate = cpy.m_iSampleRate;
  m_iChannels = cpy.m_iChannels;
  m_DataBuffer = cpy.m_DataBuffer;
  m_bEOF = cpy.m_bEOF;
  m_bShutdownThread = cpy.m_bShutdownThread;
  m_bEnabled = cpy.m_bEnabled;
  m_bFilling = cpy.m_bFilling;
  m_bThreadStarted = false;

  m_StreamPosition = cpy.m_StreamPosition;

  if (!m_pSource.isNull() && m_iSampleRate > 0 && m_iChannels > 0) {
    m_Thread.Create(StartBufferingThread, this);
    m_bThreadStarted = true;
  } else {
    m_bEnabled = false;
    m_bFilling = false;
    m_bEOF = true;
  }

  if (bWasEnabled) {
    cpy.EnableBuffering();
    EnableBuffering();
  }
}

RageSoundReader_ThreadedBuffer::~RageSoundReader_ThreadedBuffer() {
  DisableBuffering();
  m_Event.Lock();
  m_bShutdownThread = true;
  m_Event.Broadcast();
  m_Event.Unlock();

  if (m_bThreadStarted) {
    m_Thread.Wait();
    m_bThreadStarted = false;
  }
}

void RageSoundReader_ThreadedBuffer::EnableBuffering() {
  if (!m_bThreadStarted || m_pSource.isNull()) {
    return;
  }
  m_Event.Lock();
  m_bEnabled = true;
  m_Event.Broadcast();
  m_Event.Unlock();
}

bool RageSoundReader_ThreadedBuffer::DisableBuffering() {
  m_Event.Lock();
  bool bRet = m_bEnabled;
  m_bEnabled = false;
  m_Event.Broadcast();

  while (m_bFilling) {
    if (m_Event.WaitTimeoutSupported()) {
      RageTimer timeout;
      timeout.Touch();
      timeout += g_fBufferWaitTimeoutSeconds;
      if (!m_Event.Wait(&timeout)) {
        break;
      }
    } else {
      m_Event.Wait();
    }
  }

  m_Event.Unlock();

  return bRet;
}

void RageSoundReader_ThreadedBuffer::WaitUntilFrames(int iWaitUntilFrames) {
  if (iWaitUntilFrames <= 0) {
    return;
  }
  m_Event.Lock();
  while (m_bEnabled && !m_bEOF && GetFilledFrames() < iWaitUntilFrames) {
    if (m_Event.WaitTimeoutSupported()) {
      RageTimer timeout;
      timeout.Touch();
      timeout += g_fBufferWaitTimeoutSeconds;
      if (!m_Event.Wait(&timeout)) {
        break;
      }
    } else {
      m_Event.Wait();
    }
  }
  m_Event.Unlock();
}

int RageSoundReader_ThreadedBuffer::SetPosition(int iFrame) {
  if (m_pSource.isNull()) {
    return RageSoundReader::ERROR;
  }
  bool bWasEnabled = DisableBuffering();

  m_DataBuffer.clear();

  int iRet = RageSoundReader_Filter::SetPosition(iFrame);

  m_StreamPosition.clear();
  m_StreamPosition.push_back(Mapping());
  m_StreamPosition.back().iPositionOfFirstFrame = iFrame;
  m_StreamPosition.back().fRate = m_pSource->GetStreamToSourceRatio();

  m_bEOF = iRet == 0;

  if (bWasEnabled) {
    EnableBuffering();
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
  int iRet =
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
  bool bWasEnabled = DisableBuffering();
  int iRet = m_pSource.isNull() ? 0 : m_pSource->GetLength();
  if (bWasEnabled) {
    EnableBuffering();
  }
  return iRet;
}
int RageSoundReader_ThreadedBuffer::GetLength_Fast() const {
  bool bWasEnabled = DisableBuffering();
  int iRet = m_pSource.isNull() ? 0 : m_pSource->GetLength_Fast();
  if (bWasEnabled) {
    EnableBuffering();
  }
  return iRet;
}

bool RageSoundReader_ThreadedBuffer::SetProperty(
    const std::string& sProperty, float fValue) {
  if (m_pSource.isNull()) {
    return false;
  }
  return m_pSource->SetProperty(sProperty, fValue);
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

    // On error or end of file, stop buffering the sound.
    if (iRet < 0) {
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
  if (m_pSource.isNull() || GetEmptyFrames() == 0) {
    return 0;
  }

  int iSamplesPerFrame = this->GetNumChannels();
  if (iSamplesPerFrame <= 0 ||
      g_iReadBlockSizeFrames * iSamplesPerFrame > m_DataBuffer.num_writable()) {
    return RageSoundReader::ERROR;
  }

  int iGotFrames;
  int iNextSourceFrame = 0;
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
      return RageSoundReader::ERROR;
    }
    // Add the data to the buffer.
    m_DataBuffer.advance_write_pointer(iGotFrames * iSamplesPerFrame);
    if (iNextSourceFrame != m_StreamPosition.back().iPositionOfFirstFrame +
                                m_StreamPosition.back().iFramesBuffered ||
        fRate != m_StreamPosition.back().fRate) {
      m_StreamPosition.push_back(Mapping());
      m_StreamPosition.back().iPositionOfFirstFrame = iNextSourceFrame;
      m_StreamPosition.back().fRate = fRate;
    }

    m_StreamPosition.back().iFramesBuffered += iGotFrames;
  }

  m_bEOF = (iGotFrames == END_OF_FILE);

  return iGotFrames;
}

int RageSoundReader_ThreadedBuffer::Read(float* pBuffer, int iFrames) {
  if (iFrames == 0) {
    return 0;
  }
  if (pBuffer == nullptr || iFrames < 0 || m_iChannels <= 0 ||
      m_StreamPosition.empty()) {
    return RageSoundReader::ERROR;
  }
  if (!m_bEOF) {
    EnableBuffering();
  }

  m_Event.Lock();

  {
    /* Delete any empty mappings from the beginning, but don't empty the list,
     * so we always have the current position and rate. If we delete an item,
     * the rate or position has probably changed, so return. */
    std::list<Mapping>::iterator it = m_StreamPosition.begin();
    if (it != m_StreamPosition.end()) {
      ++it;
    }
    if (it != m_StreamPosition.end() &&
        !m_StreamPosition.front().iFramesBuffered) {
      ++it;
      m_StreamPosition.pop_front();
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
    pos.iPositionOfFirstFrame += iFramesToRead;
    pos.iFramesBuffered -= iFramesToRead;
    iRet = iFramesToRead;
  } else if (m_bEOF) {
    iRet = END_OF_FILE;
  } else {
    iRet = WOULD_BLOCK;
  }
  m_Event.Unlock();

  return iRet;
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
