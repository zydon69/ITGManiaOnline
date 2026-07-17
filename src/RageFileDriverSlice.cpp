#include "RageFileDriverSlice.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>

#include "RageFileBasic.h"
#include "global.h"

RageFileDriverSlice::RageFileDriverSlice(
    RageFileBasic* pFile, int iOffset, int iFileSize) {
  m_pFile = pFile;
  m_iOffset = iOffset;
  m_iFileSize = iFileSize;
  m_iFilePos = 0;
  m_bFileOwned = false;
  m_bValid = false;

  if (m_pFile == nullptr || iOffset < 0 || iFileSize < 0) {
    SetError("Invalid file slice bounds");
    return;
  }
  const int sourceSize = m_pFile->GetFileSize();
  const int64_t sliceEnd = static_cast<int64_t>(iOffset) + iFileSize;
  if (sourceSize < 0 || sliceEnd > sourceSize ||
      sliceEnd > std::numeric_limits<int>::max()) {
    SetError("File slice exceeds its source bounds");
    return;
  }
  m_bValid = true;
}

RageFileDriverSlice::RageFileDriverSlice(const RageFileDriverSlice& cpy)
    : RageFileObj(cpy) {
  m_pFile = cpy.m_pFile == nullptr ? nullptr : cpy.m_pFile->Copy();
  m_iOffset = cpy.m_iOffset;
  m_iFileSize = cpy.m_iFileSize;
  m_iFilePos = cpy.m_iFilePos;
  m_bFileOwned = true;
  m_bValid = cpy.m_bValid && m_pFile != nullptr;
  if (!m_bValid && GetError().empty()) {
    SetError("Could not copy file slice source");
  }
}

RageFileDriverSlice::~RageFileDriverSlice() {
  if (m_bFileOwned) {
    delete m_pFile;
  }
}

RageFileDriverSlice* RageFileDriverSlice::Copy() const {
  RageFileDriverSlice* pRet = new RageFileDriverSlice(*this);
  return pRet;
}

int RageFileDriverSlice::ReadInternal(void* buf, size_t bytes) {
  if (!m_bValid || m_pFile == nullptr) {
    SetError("File slice is invalid");
    return -1;
  }
  /* Make sure we're reading from the right place.  We might have been
   * constructed with a file not pointing to iOffset. */
  const int target = m_iFilePos + m_iOffset;
  if (m_pFile->Seek(target) != target) {
    SetError(m_pFile->GetError().empty() ? "Could not seek file slice source"
                                         : m_pFile->GetError());
    return -1;
  }

  const int bytes_left = m_iFileSize - this->m_iFilePos;
  if (bytes_left <= 0) {
    return 0;
  }
  const size_t requested =
      std::min(bytes, static_cast<size_t>(bytes_left));
  const int got = m_pFile->Read(buf, requested);
  if (got == -1) {
    SetError(m_pFile->GetError());
    return -1;
  }

  m_iFilePos += got;

  return got;
}

int RageFileDriverSlice::SeekInternal(int offset) {
  if (!m_bValid || m_pFile == nullptr || offset < 0) {
    SetError(offset < 0 ? "File slice seek is negative" : "File slice is invalid");
    return -1;
  }
  offset = std::min(offset, m_iFileSize);

  const int target = m_iOffset + offset;
  const int ret = m_pFile->Seek(target);
  if (ret != target) {
    SetError(m_pFile->GetError().empty() ? "Could not seek file slice source"
                                         : m_pFile->GetError());
    return -1;
  }
  m_iFilePos = offset;

  return offset;
}

/*
 * Copyright (c) 2003-2004 Glenn Maynard
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
