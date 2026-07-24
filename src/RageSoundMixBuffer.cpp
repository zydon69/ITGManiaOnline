#include "RageSoundMixBuffer.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <new>
#include <string>
#include <vector>

RageSoundMixBuffer::RageSoundMixBuffer() : m_iOffset(0) {}
RageSoundMixBuffer::~RageSoundMixBuffer() {}

/* write() will start mixing iOffset samples into the buffer.  Be careful; this
 * is measured in samples, not frames, so if the data is stereo, multiply by
 * two. */
bool RageSoundMixBuffer::SetWriteOffset(int iOffset) {
  if (iOffset < 0) {
    return SetError("negative mix write offset");
  }

  m_iOffset = static_cast<size_t>(iOffset);
  m_sError.clear();
  return true;
}

bool RageSoundMixBuffer::Extend(size_t iSamples) {
  if (iSamples > std::numeric_limits<size_t>::max() - m_iOffset) {
    return SetError("mix buffer size overflow");
  }

  const size_t realsize = iSamples + m_iOffset;
  if (m_pMixbuf.size() >= realsize) {
    m_sError.clear();
    return true;
  }

  try {
    m_pMixbuf.resize(realsize, 0.0f);
  } catch (const std::bad_alloc&) {
    return SetError("mix buffer allocation failed");
  }

  m_sError.clear();
  return true;
}

bool RageSoundMixBuffer::write(
    const float* pBuf, size_t iSize, int iSourceStride, int iDestStride) {
  if (iSize == 0) {
    m_sError.clear();
    return true;
  }
  if (pBuf == nullptr) {
    return SetError("null mix source buffer");
  }
  if (iSourceStride <= 0 || iDestStride <= 0) {
    return SetError("invalid mix buffer stride");
  }

  // iSize = 3, iDestStride = 2 uses 4 frames.  Don't allocate the stride of the
  // last sample.
  const size_t destStride = static_cast<size_t>(iDestStride);
  if (iSize - 1 > (std::numeric_limits<size_t>::max() - 1) / destStride) {
    return SetError("mix write span overflow");
  }
  const size_t writeSpan = (iSize - 1) * destStride + 1;
  if (!Extend(writeSpan)) {
    return false;
  }
  if (m_iOffset >= m_pMixbuf.size()) {
    return SetError("mix write offset out of range");
  }

  // Load the audio at m_iOffset into the buffer.
  float* pDestBuf = &m_pMixbuf[m_iOffset];

  while (iSize) {
    *pDestBuf += *pBuf;
    pBuf += iSourceStride;
    pDestBuf += iDestStride;
    --iSize;
  }
  m_sError.clear();
  return true;
}

bool RageSoundMixBuffer::read(int16_t* pBuf) {
  if (pBuf == nullptr && !m_pMixbuf.empty()) {
    return SetError("null int16 mix output buffer");
  }
  for (size_t iPos = 0; iPos < m_pMixbuf.size(); ++iPos) {
    // do the read
    float iOut = m_pMixbuf[iPos];
    // ensure volume is within expected levels to prevent clipping
    iOut = std::clamp(iOut, -1.0f, +1.0f);
    // round rather than truncate to minimize distortion
    pBuf[iPos] = static_cast<int16_t>(std::round(iOut * INT16_MAX));
  }
  Clear();
  return true;
}

bool RageSoundMixBuffer::read(float* pBuf) {
  if (pBuf == nullptr && !m_pMixbuf.empty()) {
    return SetError("null float mix output buffer");
  }
  // ensure volume is within expected levels to prevent clipping
  std::transform(m_pMixbuf.begin(), m_pMixbuf.end(), pBuf, [](float s) {
    return std::clamp(s, -1.0f, +1.0f);
  });
  Clear();
  return true;
}

bool RageSoundMixBuffer::read_deinterlace(float** pBufs, int channels) {
  if (channels <= 0) {
    return SetError("invalid deinterlace channel count");
  }
  if (pBufs == nullptr && !m_pMixbuf.empty()) {
    return SetError("null deinterlace output buffers");
  }
  if (m_pMixbuf.size() % static_cast<size_t>(channels) != 0) {
    return SetError("deinterlace buffer is unaligned");
  }

  const size_t frames = m_pMixbuf.size() / static_cast<size_t>(channels);
  for (int ch = 0; ch < channels; ++ch) {
    if (pBufs[ch] == nullptr && frames > 0) {
      return SetError("null deinterlace output plane");
    }
  }

  for (size_t i = 0; i < frames; ++i) {
    for (int ch = 0; ch < channels; ++ch) {
      pBufs[ch][i] = m_pMixbuf[channels * i + ch];
    }
  }
  Clear();
  return true;
}

void RageSoundMixBuffer::Clear() {
  m_pMixbuf.clear();
  m_iOffset = 0;
  m_sError.clear();
}

bool RageSoundMixBuffer::SetError(const std::string& sError) {
  m_sError = sError;
  return false;
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
