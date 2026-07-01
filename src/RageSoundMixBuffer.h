#ifndef RAGESOUNDMIXBUFFER_H
#define RAGESOUNDMIXBUFFER_H

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

class RageSoundMixBuffer {
 public:
  RageSoundMixBuffer();
  ~RageSoundMixBuffer();

  bool SetWriteOffset(int iOffset);
  bool Extend(size_t iSamples);
  bool write(
      const float* pBuf, size_t iSize, int iSourceStride = 1,
      int iDestStride = 1);
  bool read(int16_t* pBuf);
  bool read(float* pBuf);
  bool read_deinterlace(float** pBufs, int channels);
  void Clear();
  const std::string& GetError() const { return m_sError; }
  inline size_t size() const { return m_pMixbuf.size(); }

 private:
  bool SetError(const std::string& sError);

  std::vector<float> m_pMixbuf;
  std::string m_sError;
  size_t m_iOffset;
};

#endif  // RAGESOUNDMIXBUFFER_H

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
