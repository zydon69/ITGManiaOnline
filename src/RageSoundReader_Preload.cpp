/* This reader simply precaches all of the data from another reader. This
 * reduces CPU usage for sounds that are played several times at once. */

#include "RageSoundReader_Preload.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
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

#define samplesize (m_bBufferIs16Bit ? sizeof(int16_t) : sizeof(float))
#define framesize (samplesize * m_iChannels)

bool RageSoundReader_Preload::PreloadSound(RageSoundReader*& pSound) {
  if (pSound == nullptr) {
    return false;
  }
  RageSoundReader_Preload* pPreload = new RageSoundReader_Preload;
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
      m_fRate(0.0f) {
  m_bBufferIs16Bit = g_bSoundPreload16bit.Get();
}

int RageSoundReader_Preload::GetTotalFrames() const {
  if (m_iChannels == 0 || framesize == 0) {
    return 0;
  }
  return m_Buffer->size() / framesize;
}

bool RageSoundReader_Preload::Open(RageSoundReader* pSource) {
  if (pSource == nullptr || pSource->GetSampleRate() <= 0 ||
      pSource->GetNumChannels() == 0 ||
      pSource->GetNumChannels() >
          static_cast<unsigned>(std::numeric_limits<int>::max())) {
    return false;
  }
  m_iSampleRate = pSource->GetSampleRate();
  m_iChannels = static_cast<int>(pSource->GetNumChannels());
  m_fRate = pSource->GetStreamToSourceRatio();
  if (!std::isfinite(m_fRate) || m_fRate <= 0.0f || m_iChannels > 1024) {
    return false;
  }

  int iMaxSamples = g_iSoundPreloadMaxSamples.Get();
  if (iMaxSamples <= 0) {
    return false;
  }

  /* Check the length, and see if we think it'll fit in the buffer. */
  int iLen = pSource->GetLength_Fast();
  if (iLen != -1) {
    if (iLen < 0) {
      return false;
    }
    float fSecs = iLen / 1000.f;

    const double framesDouble =
        static_cast<double>(fSecs) * static_cast<double>(m_iSampleRate);
    if (!std::isfinite(framesDouble) || framesDouble < 0.0 ||
        framesDouble > static_cast<double>(std::numeric_limits<int>::max())) {
      return false;
    }
    int iFrames = static_cast<int>(framesDouble + 0.5); /* seconds -> frames */
    if (static_cast<unsigned>(iFrames) >
        static_cast<unsigned>(std::numeric_limits<int>::max()) / m_iChannels) {
      return false;
    }
    int iSamples = iFrames * m_iChannels; /* frames -> samples */
    if (iSamples > iMaxSamples) {
      return false; /* Don't bother trying to preload it. */
    }

    if (static_cast<size_t>(iSamples) >
        std::numeric_limits<size_t>::max() / samplesize) {
      return false;
    }
    size_t iBytes = static_cast<size_t>(iSamples) * samplesize;
    m_Buffer.Get()->reserve(iBytes);
  }

  for (;;) {
    /* If the rate changes, we won't preload it. */
    if (pSource->GetStreamToSourceRatio() != m_fRate) {
      return false; /* Don't bother trying to preload it. */
    }
    float buffer[1024];
    if (m_iChannels == 0 || m_iChannels > ARRAYLEN(buffer)) {
      return false;
    }
    int iCnt = pSource->Read(buffer, ARRAYLEN(buffer) / m_iChannels);

    if (iCnt == END_OF_FILE) {
      break;
    }
    if (iCnt < 0) {
      return false;
    }
    if (iCnt == 0) {
      return false;
    }
    if (static_cast<unsigned>(iCnt) > ARRAYLEN(buffer) / m_iChannels ||
        static_cast<unsigned>(iCnt) >
            static_cast<unsigned>(std::numeric_limits<int>::max()) /
                m_iChannels) {
      return false;
    }
    /* Add the buffer. */
    if (m_bBufferIs16Bit) {
      int16_t buffer16[1024];
      RageSoundUtil::ConvertFloatToNativeInt16(
          buffer, buffer16, iCnt * m_iChannels);
      m_Buffer.Get()->append(
          (char*)buffer16, (char*)(buffer16 + iCnt * m_iChannels));
    } else {
      m_Buffer.Get()->append(
          (char*)buffer, (char*)(buffer + iCnt * m_iChannels));
    }

    if (static_cast<size_t>(iMaxSamples) >
            std::numeric_limits<size_t>::max() / samplesize ||
        m_Buffer.Get()->size() >
            static_cast<size_t>(iMaxSamples) * samplesize) {
      return false; /* too big */
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
  return int(float(GetTotalFrames()) * 1000.f / m_iSampleRate);
}

int RageSoundReader_Preload::GetLength_Fast() const { return GetLength(); }

int RageSoundReader_Preload::SetPosition(int iFrame) {
  if (!std::isfinite(m_fRate) || m_fRate <= 0.0f) {
    return ERROR;
  }
  m_iPosition = std::max(0, iFrame);
  m_iPosition = static_cast<int>((m_iPosition / m_fRate) + 0.5);

  if (m_iPosition >= int(m_Buffer->size() / framesize)) {
    m_iPosition = m_Buffer->size() / framesize;
    return 0;
  }

  return 1;
}

int RageSoundReader_Preload::GetNextSourceFrame() const {
  if (!std::isfinite(m_fRate) || m_fRate <= 0.0f) {
    return 0;
  }
  return static_cast<int>((m_iPosition * m_fRate) + 0.5);
}

int RageSoundReader_Preload::Read(float* pBuffer, int iFrames) {
  if (iFrames == 0) {
    return 0;
  }
  if (pBuffer == nullptr || iFrames < 0 || m_iChannels == 0 || framesize == 0) {
    return ERROR;
  }
  const int iSizeFrames = m_Buffer->size() / framesize;
  const int iFramesAvail = iSizeFrames - m_iPosition;

  iFrames = std::min(iFrames, iFramesAvail);
  if (iFrames < 0 ||
      static_cast<unsigned>(iFrames) >
          static_cast<unsigned>(std::numeric_limits<int>::max()) /
              m_iChannels) {
    return ERROR;
  }
  if (iFrames == 0) {
    return END_OF_FILE;
  }
  const int samples = iFrames * m_iChannels;
  if (m_bBufferIs16Bit) {
    const int16_t* pIn =
        (const int16_t*)(m_Buffer->data() + (m_iPosition * framesize));
    RageSoundUtil::ConvertNativeInt16ToFloat(
        pIn, pBuffer, samples);
  } else {
    if (static_cast<size_t>(iFrames) >
        std::numeric_limits<size_t>::max() / framesize) {
      return ERROR;
    }
    memcpy(
        pBuffer, m_Buffer->data() + (m_iPosition * framesize),
        static_cast<size_t>(iFrames) * framesize);
  }
  m_iPosition += iFrames;

  return iFrames;
}

RageSoundReader_Preload* RageSoundReader_Preload::Copy() const {
  return new RageSoundReader_Preload(*this);
}

int RageSoundReader_Preload::GetReferenceCount() const {
  return m_Buffer.GetReferenceCount();
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
