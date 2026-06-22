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
    return 0;
  }
  if (pBuf == nullptr || iFrames < 0 || m_pSource.isNull()) {
    return RageSoundReader::ERROR;
  }
  iFrames = m_pSource->Read(pBuf, iFrames);
  if (iFrames < 0) {
    return iFrames;
  }

  const unsigned sourceChannels = m_pSource->GetNumChannels();
  if (sourceChannels == 0 ||
      static_cast<size_t>(iFrames) >
          std::numeric_limits<int>::max() / sourceChannels) {
    return RageSoundReader::ERROR;
  }
  int iSamples = iFrames * sourceChannels;

  if (sourceChannels == 1) {
    RageSoundUtil::ConvertMonoToStereoInPlace(pBuf, iSamples);
    iSamples *= 2;
  }

  /* This block goes from iStreamFrame to iStreamFrame+iGotFrames. */
  if (GetNumChannels() == 2 && m_fPan != 0.0) {
    RageSoundUtil::Pan(pBuf, iFrames, m_fPan);
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
      return false;
    }
    m_fPan = std::clamp(fValue, -1.0f, 1.0f);
    return true;
  }

  return RageSoundReader_Filter::SetProperty(sProperty, fValue);
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
