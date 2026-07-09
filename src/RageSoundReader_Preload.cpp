/* This reader simply precaches all of the data from another reader. This
 * reduces CPU usage for sounds that are played several times at once. */

#include "RageSoundReader_Preload.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>
#include <string>

#include "Preference.h"
#include "RageSoundReader.h"
#include "RageSoundUtil.h"
#include "RageUtil.h"
#include "global.h"

/* If true, preloaded sounds are stored in 16-bit instead of floats.  Most
 * processing happens after preloading, and it's usually a waste to store high-
 * resolution data for sound effects. */
Preference<bool> g_bSoundPreload16bit("SoundPreload16bit", true);

/* If a sound is smaller than this, we'll load it entirely into memory. */
Preference<int> g_iSoundPreloadMaxSamples(
    "SoundPreloadMaxSamples", 1024 * 1024);

bool RageSoundReader_Preload::PreloadSound(RageSoundReader*& pSound) {
  if (pSound == nullptr) {
    return false;
  }
  RageSoundReader_Preload* pPreload = nullptr;
  try {
    pPreload = new RageSoundReader_Preload;
  } catch (const std::bad_alloc&) {
    return false;
  }
  if (!pPreload->Open(pSound)) {
    /* Preload failed.  It read some data, so we need to rewind the reader. */
    if (pSound != nullptr) {
      pSound->SetPosition(0);
    }
    delete pPreload;
    return false;
  }

  pSound = pPreload;
  return true;
}

RageSoundReader_Preload::RageSoundReader_Preload()
    : m_Buffer(new std::string),
      m_bBufferIs16Bit(false),
      m_iPosition(0),
      m_iSampleRate(0),
      m_iChannels(0),
      m_fRate(0.0f),
      m_sError() {
  m_bBufferIs16Bit = g_bSoundPreload16bit.Get();
}

int RageSoundReader_Preload::GetTotalFrames() const {
  const size_t frames = GetTotalFramesSize();
  if (frames > static_cast<size_t>(std::numeric_limits<int>::max())) {
    return std::numeric_limits<int>::max();
  }
  return static_cast<int>(frames);
}

bool RageSoundReader_Preload::Open(RageSoundReader* pSource) {
  m_sError.clear();
  m_Buffer.Get()->clear();
  m_iPosition = 0;
  m_iSampleRate = 0;
  m_iChannels = 0;
  m_fRate = 0.0f;

  if (pSource == nullptr || pSource->GetSampleRate() <= 0 ||
      pSource->GetNumChannels() == 0 ||
      pSource->GetNumChannels() >
          static_cast<unsigned>(std::numeric_limits<int>::max())) {
    return SetError("SRC_AUDIT_FIX SRC-2790: invalid preload source format");
  }
  m_iSampleRate = pSource->GetSampleRate();
  m_iChannels = static_cast<int>(pSource->GetNumChannels());
  m_fRate = pSource->GetStreamToSourceRatio();
  if (!std::isfinite(m_fRate) || m_fRate <= 0.0f || m_iChannels > 1024) {
    return SetError("SRC_AUDIT_FIX SRC-2790: invalid preload stream ratio");
  }

  int iMaxSamples = g_iSoundPreloadMaxSamples.Get();
  if (iMaxSamples <= 0) {
    return SetError("SRC_AUDIT_FIX SRC-2790: invalid preload sample limit");
  }

  /* Check the length, and see if we think it'll fit in the buffer. */
  int iLen = pSource->GetLength_Fast();
  if (iLen != -1) {
    if (iLen < 0) {
      return SetError("SRC_AUDIT_FIX SRC-2790: invalid preload length");
    }
    float fSecs = iLen / 1000.f;

    const double framesDouble =
        static_cast<double>(fSecs) * static_cast<double>(m_iSampleRate);
    if (!std::isfinite(framesDouble) || framesDouble < 0.0 ||
        framesDouble > static_cast<double>(std::numeric_limits<int>::max())) {
      return SetError("SRC_AUDIT_FIX SRC-2790: preload length overflow");
    }
    int iFrames = static_cast<int>(framesDouble + 0.5); /* seconds -> frames */
    if (static_cast<unsigned>(iFrames) >
        static_cast<unsigned>(std::numeric_limits<int>::max()) / m_iChannels) {
      return SetError("SRC_AUDIT_FIX SRC-2790: preload sample count overflow");
    }
    int iSamples = iFrames * m_iChannels; /* frames -> samples */
    if (iSamples > iMaxSamples) {
      return SetError("SRC_AUDIT_FIX SRC-2790: preload exceeds sample limit");
    }

    const size_t sampleSize = GetSampleSizeBytes();
    if (static_cast<size_t>(iSamples) >
        std::numeric_limits<size_t>::max() / sampleSize) {
      return SetError("SRC_AUDIT_FIX SRC-2790: preload byte count overflow");
    }
    size_t iBytes = static_cast<size_t>(iSamples) * sampleSize;
    try {
      m_Buffer.Get()->reserve(iBytes);
    } catch (const std::bad_alloc&) {
      return SetError("SRC_AUDIT_FIX SRC-2790: preload reserve failed");
    }
  }

  const size_t sampleSize = GetSampleSizeBytes();
  if (static_cast<size_t>(iMaxSamples) >
      std::numeric_limits<size_t>::max() / sampleSize) {
    return SetError("SRC_AUDIT_FIX SRC-2790: preload max byte count overflow");
  }
  const size_t maxBytes = static_cast<size_t>(iMaxSamples) * sampleSize;

  for (;;) {
    /* If the rate changes, we won't preload it. */
    if (pSource->GetStreamToSourceRatio() != m_fRate) {
      return SetError("SRC_AUDIT_FIX SRC-2790: preload stream ratio changed");
    }
    float buffer[1024];
    if (m_iChannels == 0 || m_iChannels > ARRAYLEN(buffer)) {
      return SetError("SRC_AUDIT_FIX SRC-2790: invalid preload channel count");
    }
    int iCnt = pSource->Read(buffer, ARRAYLEN(buffer) / m_iChannels);

    if (iCnt == END_OF_FILE) {
      break;
    }
    if (iCnt < 0) {
      m_sError = pSource->GetError();
      if (m_sError.empty()) {
        m_sError = "SRC_AUDIT_FIX SRC-2790: preload source read failed";
      }
      return false;
    }
    if (iCnt == 0) {
      return SetError("SRC_AUDIT_FIX SRC-2790: preload source returned zero frames");
    }
    if (static_cast<unsigned>(iCnt) > ARRAYLEN(buffer) / m_iChannels ||
        static_cast<unsigned>(iCnt) >
            static_cast<unsigned>(std::numeric_limits<int>::max()) /
                m_iChannels) {
      return SetError("SRC_AUDIT_FIX SRC-2790: preload read count overflow");
    }
    const size_t chunkSamples = static_cast<size_t>(iCnt) * m_iChannels;
    if (chunkSamples > std::numeric_limits<size_t>::max() / sampleSize) {
      return SetError("SRC_AUDIT_FIX SRC-2790: preload chunk byte overflow");
    }
    const size_t chunkBytes = chunkSamples * sampleSize;
    if (m_Buffer->size() > maxBytes || chunkBytes > maxBytes - m_Buffer->size()) {
      return SetError("SRC_AUDIT_FIX SRC-2790: preload exceeds sample limit");
    }

    /* Add the buffer. */
    try {
      if (m_bBufferIs16Bit) {
        int16_t buffer16[1024];
        RageSoundUtil::ConvertFloatToNativeInt16(
            buffer, buffer16, static_cast<int>(chunkSamples));
        m_Buffer.Get()->append(
            reinterpret_cast<const char*>(buffer16),
            reinterpret_cast<const char*>(buffer16 + chunkSamples));
      } else {
        m_Buffer.Get()->append(
            reinterpret_cast<const char*>(buffer),
            reinterpret_cast<const char*>(buffer + chunkSamples));
      }
    } catch (const std::bad_alloc&) {
      return SetError("SRC_AUDIT_FIX SRC-2790: preload append failed");
    }
  }

  m_iPosition = 0;
  delete pSource;
  return true;
}

int RageSoundReader_Preload::GetLength() const {
  if (m_iSampleRate <= 0) {
    return 0;
  }
  const double lengthMs =
      static_cast<double>(GetTotalFramesSize()) * 1000.0 /
      static_cast<double>(m_iSampleRate);
  if (!std::isfinite(lengthMs) || lengthMs < 0.0) {
    return 0;
  }
  if (lengthMs > static_cast<double>(std::numeric_limits<int>::max())) {
    return std::numeric_limits<int>::max();
  }
  return static_cast<int>(lengthMs);
}

int RageSoundReader_Preload::GetLength_Fast() const { return GetLength(); }

int RageSoundReader_Preload::SetPosition(int iFrame) {
  const size_t frameSize = GetFrameSizeBytes();
  if (!std::isfinite(m_fRate) || m_fRate <= 0.0f || frameSize == 0) {
    SetError("SRC_AUDIT_FIX SRC-2791: invalid preload seek state");
    return ERROR;
  }
  const size_t totalFrames = GetTotalFramesSize();
  const double targetFrame =
      (static_cast<double>(std::max(0, iFrame)) / m_fRate) + 0.5;
  if (!std::isfinite(targetFrame) || targetFrame < 0.0) {
    SetError("SRC_AUDIT_FIX SRC-2791: preload seek position overflow");
    return ERROR;
  }
  if (targetFrame >= static_cast<double>(totalFrames)) {
    m_iPosition =
        totalFrames > static_cast<size_t>(std::numeric_limits<int>::max())
            ? std::numeric_limits<int>::max()
            : static_cast<int>(totalFrames);
    return 0;
  }
  if (targetFrame > static_cast<double>(std::numeric_limits<int>::max())) {
    SetError("SRC_AUDIT_FIX SRC-2791: preload seek position exceeds int range");
    return ERROR;
  }
  m_iPosition = static_cast<int>(targetFrame);

  if (static_cast<size_t>(m_iPosition) >= totalFrames) {
    m_iPosition =
        totalFrames > static_cast<size_t>(std::numeric_limits<int>::max())
            ? std::numeric_limits<int>::max()
            : static_cast<int>(totalFrames);
    return 0;
  }

  return 1;
}

int RageSoundReader_Preload::GetNextSourceFrame() const {
  return ClampSourceFrameToInt(GetNextSourceFrame64());
}

std::int64_t RageSoundReader_Preload::GetNextSourceFrame64() const {
  if (!std::isfinite(m_fRate) || m_fRate <= 0.0f) {
    return 0;
  }
  const double sourceFrame =
      (static_cast<double>(m_iPosition) * static_cast<double>(m_fRate)) + 0.5;
  if (!std::isfinite(sourceFrame) || sourceFrame <= 0.0) {
    return 0;
  }
  if (sourceFrame > static_cast<double>(std::numeric_limits<std::int64_t>::max())) {
    return std::numeric_limits<std::int64_t>::max();
  }
  return static_cast<std::int64_t>(sourceFrame);
}

int RageSoundReader_Preload::Read(float* pBuffer, int iFrames) {
  if (iFrames == 0) {
    return 0;
  }
  const size_t frameSize = GetFrameSizeBytes();
  if (pBuffer == nullptr || iFrames < 0 || m_iChannels == 0 || frameSize == 0) {
    SetError("SRC_AUDIT_FIX SRC-2791: invalid preload read arguments");
    return ERROR;
  }
  const size_t sizeFrames = GetTotalFramesSize();
  if (m_iPosition < 0 || static_cast<size_t>(m_iPosition) > sizeFrames) {
    SetError("SRC_AUDIT_FIX SRC-2791: invalid preload read position");
    return ERROR;
  }
  const size_t framesAvail = sizeFrames - static_cast<size_t>(m_iPosition);

  const size_t framesToRead =
      std::min(static_cast<size_t>(iFrames), framesAvail);
  if (framesToRead >
      static_cast<size_t>(std::numeric_limits<int>::max()) / m_iChannels) {
    SetError("SRC_AUDIT_FIX SRC-2791: preload read sample count overflow");
    return ERROR;
  }
  if (framesToRead == 0) {
    return END_OF_FILE;
  }
  const size_t samples = framesToRead * m_iChannels;
  if (samples > static_cast<size_t>(std::numeric_limits<int>::max())) {
    SetError("SRC_AUDIT_FIX SRC-2791: preload read sample count overflow");
    return ERROR;
  }
  const size_t byteOffset = static_cast<size_t>(m_iPosition) * frameSize;
  const size_t byteCount = framesToRead * frameSize;
  if (byteOffset > m_Buffer->size() || byteCount > m_Buffer->size() - byteOffset) {
    SetError("SRC_AUDIT_FIX SRC-2791: preload read byte range overflow");
    return ERROR;
  }
  if (m_bBufferIs16Bit) {
    const int16_t* pIn =
        reinterpret_cast<const int16_t*>(m_Buffer->data() + byteOffset);
    RageSoundUtil::ConvertNativeInt16ToFloat(
        pIn, pBuffer, static_cast<int>(samples));
  } else {
    memcpy(pBuffer, m_Buffer->data() + byteOffset, byteCount);
  }
  m_iPosition += static_cast<int>(framesToRead);

  return static_cast<int>(framesToRead);
}

RageSoundReader_Preload* RageSoundReader_Preload::Copy() const {
  return new RageSoundReader_Preload(*this);
}

int RageSoundReader_Preload::GetReferenceCount() const {
  return m_Buffer.GetReferenceCount();
}

size_t RageSoundReader_Preload::GetSampleSizeBytes() const {
  return m_bBufferIs16Bit ? sizeof(int16_t) : sizeof(float);
}

size_t RageSoundReader_Preload::GetFrameSizeBytes() const {
  if (m_iChannels == 0) {
    return 0;
  }
  const size_t sampleSize = GetSampleSizeBytes();
  if (static_cast<size_t>(m_iChannels) >
      std::numeric_limits<size_t>::max() / sampleSize) {
    return 0;
  }
  return sampleSize * static_cast<size_t>(m_iChannels);
}

size_t RageSoundReader_Preload::GetTotalFramesSize() const {
  const size_t frameSize = GetFrameSizeBytes();
  if (frameSize == 0) {
    return 0;
  }
  return m_Buffer->size() / frameSize;
}

bool RageSoundReader_Preload::SetError(const std::string& sError) {
  m_sError = sError;
  return false;
}

/*
 * Copyright (c) 2003 Glenn Maynard
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
