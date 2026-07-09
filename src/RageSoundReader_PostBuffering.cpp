#include "RageSoundReader_PostBuffering.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <limits>
#include <mutex>
#include <new>
#include <string>

#include "PerfDiagnostics.h"
#include "RageSoundReader.h"
#include "RageSoundReader_Filter.h"
#include "RageSoundUtil.h"
#include "global.h"

/*
 * This filter is normally inserted after extended buffering, implementing
 * properties that do not seek the sound, allowing these properties to be
 * changed with low latency.
 */
namespace {
std::atomic<float> g_fMasterVolume{1.0f};

float SanitizeVolume(float fVolume) {
  if (!std::isfinite(fVolume)) {
    return 1.0f;
  }
  return std::clamp(fVolume, 0.0f, 1.0f);
}
}

RageSoundReader_PostBuffering::RageSoundReader_PostBuffering(
    RageSoundReader* pSource) : RageSoundReader_Filter(pSource) {
}

void RageSoundReader_PostBuffering::SetMasterVolume(float fVolume) {
  g_fMasterVolume.store(SanitizeVolume(fVolume), std::memory_order_relaxed);
}

RageSoundReader_PostBuffering* RageSoundReader_PostBuffering::Copy() const {
  if (m_pSource.isNull()) {
    return nullptr;
  }

  RageSoundReader* pSourceCopy = nullptr;
  try {
    pSourceCopy = m_pSource->Copy();
  } catch (const std::bad_alloc&) {
    return nullptr;
  }
  if (pSourceCopy == nullptr) {
    return nullptr;
  }

  RageSoundReader_PostBuffering* pCopy = nullptr;
  try {
    pCopy = new RageSoundReader_PostBuffering(pSourceCopy);
  } catch (const std::bad_alloc&) {
    delete pSourceCopy;
    return nullptr;
  }

  pCopy->m_fVolume.store(
      m_fVolume.load(std::memory_order_relaxed), std::memory_order_relaxed);
  return pCopy;
}

int RageSoundReader_PostBuffering::Read(float* pBuf, int iFrames) {
  if (iFrames == 0) {
    ClearError();
    return 0;
  }
  if (pBuf == nullptr) {
    SetError("RageSoundReader_PostBuffering::Read called with a null buffer");
    return RageSoundReader::ERROR;
  }
  if (iFrames < 0) {
    SetError(
        "RageSoundReader_PostBuffering::Read called with a negative frame count");
    return RageSoundReader::ERROR;
  }
  if (m_pSource.isNull()) {
    SetError("RageSoundReader_PostBuffering::Read has no source reader");
    return RageSoundReader::ERROR;
  }
  ClearError();

  iFrames = m_pSource->Read(pBuf, iFrames);
  if (iFrames < 0) {
    return iFrames;
  }

  // Combine the sound's volume with master volume.
  // Square the master so lower volumes are more sensitive.
  // This lines up better with perceived volume.
  const float fMasterVolume =
      g_fMasterVolume.load(std::memory_order_relaxed);
  float fVolume =
      m_fVolume.load(std::memory_order_relaxed) * fMasterVolume * fMasterVolume;
  fVolume = SanitizeVolume(fVolume);

  if (fVolume != 1.0f) {
    const unsigned channels = this->GetNumChannels();
    if (channels == 0 ||
        static_cast<size_t>(iFrames) >
            std::numeric_limits<size_t>::max() /
                static_cast<size_t>(channels)) {
      SetError(
          "SRC_AUDIT_FIX SRC-2821: PostBuffering sample count overflow");
      return RageSoundReader::ERROR;
    }
    const size_t iSamples = static_cast<size_t>(iFrames) * channels;
    if (!RageSoundUtil::Attenuate(pBuf, iSamples, fVolume)) {
      SetError("SRC_AUDIT_FIX SRC-2913: PostBuffering attenuation failed");
      return RageSoundReader::ERROR;
    }
  }

  return iFrames;
}

bool RageSoundReader_PostBuffering::SetProperty(
    const std::string& sProperty, float fValue) {
  if (sProperty == "Volume") {
    if (!std::isfinite(fValue)) {
      SetError("RageSoundReader_PostBuffering rejected a non-finite volume");
      return false;
    }
    m_fVolume.store(SanitizeVolume(fValue), std::memory_order_relaxed);
    ClearError();
    return true;
  }

  return RageSoundReader_Filter::SetProperty(sProperty, fValue);
}

std::string RageSoundReader_PostBuffering::GetError() const {
  {
    std::lock_guard<std::mutex> lock(m_ErrorMutex);
    if (!m_sError.empty()) {
      return m_sError;
    }
  }
  return RageSoundReader_Filter::GetError();
}

void RageSoundReader_PostBuffering::ClearError() const {
  std::lock_guard<std::mutex> lock(m_ErrorMutex);
  m_sError.clear();
}

void RageSoundReader_PostBuffering::SetError(const std::string& sError) const {
  if (sError.find("SRC_AUDIT_FIX SRC-28") != std::string::npos) {
    LogReviewSrcDiagnostics("%s", sError.c_str());
  }
  std::lock_guard<std::mutex> lock(m_ErrorMutex);
  m_sError = sError;
}

/*
 * Copyright (c) 2007 Glenn Maynard
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
