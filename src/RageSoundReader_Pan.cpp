#include "RageSoundReader_Pan.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <string>

#include "RageSoundReader.h"
#include "RageSoundReader_Filter.h"
#include "RageSoundUtil.h"

RageSoundReader_Pan::RageSoundReader_Pan(RageSoundReader* pSource)
    : RageSoundReader_Filter(pSource) {
  m_fPan = 0;
}

int RageSoundReader_Pan::Read(float* pBuf, int iFrames) {
  if (iFrames == 0) {
    m_sError.clear();
    return 0;
  }
  if (pBuf == nullptr) {
    SetError("RageSoundReader_Pan::Read called with a null output buffer");
    return RageSoundReader::ERROR;
  }
  if (iFrames < 0) {
    SetError("RageSoundReader_Pan::Read called with a negative frame count");
    return RageSoundReader::ERROR;
  }
  if (m_pSource.isNull()) {
    SetError("RageSoundReader_Pan::Read has no source reader");
    return RageSoundReader::ERROR;
  }
  m_sError.clear();

  const int iRequestedFrames = iFrames;
  iFrames = m_pSource->Read(pBuf, iFrames);
  if (iFrames < 0) {
    return iFrames;
  }

  const unsigned sourceChannels = m_pSource->GetNumChannels();
  if (sourceChannels == 0) {
    SetError("RageSoundReader_Pan source reports zero channels");
    return RageSoundReader::ERROR;
  }
  if (static_cast<size_t>(iFrames) >
      std::numeric_limits<int>::max() / sourceChannels) {
    SetError("RageSoundReader_Pan sample count overflow");
    return RageSoundReader::ERROR;
  }

  if (sourceChannels == 1) {
    const size_t stereoCapacity =
        static_cast<size_t>(iRequestedFrames) * GetNumChannels();
    if (!RageSoundUtil::ConvertMonoToStereoInPlace(
            pBuf, static_cast<size_t>(iFrames), stereoCapacity)) {
      SetError("pan reader mono to stereo expansion "
               "failed");
      return RageSoundReader::ERROR;
    }
  }

  /* This block goes from iStreamFrame to iStreamFrame+iGotFrames. */
  if (GetNumChannels() == 2 && m_fPan != 0.0) {
    if (!RageSoundUtil::Pan(
            pBuf, static_cast<size_t>(iFrames), GetNumChannels(), m_fPan)) {
      SetError("pan reader refused non-stereo pan");
      return RageSoundReader::ERROR;
    }
  }

  return iFrames;
}

unsigned RageSoundReader_Pan::GetNumChannels() const {
  const unsigned sourceChannels = RageSoundReader_Filter::GetNumChannels();
  if (sourceChannels == 0) {
    return 0;
  }
  return std::max(2u, sourceChannels);
}

bool RageSoundReader_Pan::SetProperty(
    const std::string& sProperty, float fValue) {
  if (sProperty == "Pan") {
    if (!std::isfinite(fValue)) {
      SetError("RageSoundReader_Pan rejected a non-finite pan value");
      return false;
    }
    m_fPan = std::clamp(fValue, -1.0f, 1.0f);
    m_sError.clear();
    return true;
  }

  return RageSoundReader_Filter::SetProperty(sProperty, fValue);
}

std::string RageSoundReader_Pan::GetError() const {
  if (!m_sError.empty()) {
    return m_sError;
  }
  return RageSoundReader_Filter::GetError();
}

void RageSoundReader_Pan::SetError(const std::string& sError) {
  // keep filter-owned failures diagnosable instead
  // of reporting an unrelated source-reader error.
  m_sError = sError;
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
