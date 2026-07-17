/*
 * When streaming files in gameplay, we need to be able to access files without
 * blocking. If we read data and it's not currently in the OS's read-ahead
 * cache, we'll block while it reads, which will usually take 10-20ms and cause
 * a frame skip.
 *
 * One common case of this is playing a background movie.  We'll open the file
 * when the screen loads, but it may not be played for over a minute, during
 * which time we'll be streaming from other movies.  When we come back, the file
 * may not have any read-ahead waiting for us.
 *
 * Linux provides two calls that can help here:
 *
 * posix_readahead; this hints the OS that we're streaming a file, so it doesn't
 * need to preserve cache behind where we've read.  This reduces the chance of
 * pushing other files out of cache.  However, this can also cause new skips; if
 * we need to rewind a movie and start it over, the beginning will be out of the
 * cache.
 *
 * readahead: this explicitly triggers a specific file read-ahead.  This blocks,
 * so if we use this we need to do it in a thread.
 *
 * We work like this:
 *
 * - Persistantly cache the first N bytes of the file.
 * - Open a worker thread for read-ahead, which is idle most of the time.
 * - When we read from the first 128k of the file, take it directly out of our
 * cache, and seek the file past our cache.
 * - When any data is read from the cached part of the file and readahead hasn't
 * been performed, trigger readahead() to be done in the worker thread, so data
 * past our cache is ready when we get there.
 * - When any data is read outside of the cached part of the file, reset our
 * state so we know to do the readahead again the next time we're back at the
 * start of the file.
 *
 * This means that reading should always be nonblocking, given these
 * constraints:
 * - We must consistently stream a file starting at the beginning, and don't
 * seek to random points in the file.
 * - We read the file slowly enough that we don't overtake the read-ahead cache,
 * which for most streaming files shouldn't be a problem.
 */

#include "RageFileDriverReadAhead.h"

#include <algorithm>
#include <cstring>
#include <limits>
#include <memory>
#include <stdexcept>

#include "RageFileBasic.h"
#include "RageFileManager_ReadAhead.h"
#include "RageUtil.h"

#if defined(HAVE_FCNTL_H)
#include <fcntl.h>
#endif
#include <cerrno>
#include <cstddef>
#if defined(WIN32)
#include <io.h>
#endif

/* If GetFD() isn't supported on the underlying file, this filter won't do
 * anything. */
bool RageFileDriverReadAhead::FileSupported(RageFileBasic* pFile) {
  return pFile != nullptr && pFile->GetFD() != -1;
}

/* iReadAheadBytes is the number of bytes to cache at the start of the file, to
 * serve data while the readahead is taking place.  iPostBufferReadAhead is the
 * number of bytes to actually read ahead. */
RageFileDriverReadAhead::RageFileDriverReadAhead(
    RageFileBasic* pFile, int iCacheBytes, int iPostBufferReadAhead) {
  if (iPostBufferReadAhead == -1) {
    iPostBufferReadAhead = iCacheBytes;
  }

  m_pFile = pFile;
  m_iFilePos = 0;
  m_bFileOwned = false;
  m_iPostBufferReadAhead = iPostBufferReadAhead;
  m_bValid = false;

  if (m_pFile == nullptr || iCacheBytes < 0 || iPostBufferReadAhead < 0 ||
      iPostBufferReadAhead > std::numeric_limits<int>::max() - 1024 * 32) {
    SetError("Invalid read-ahead file or buffer size");
    return;
  }
  m_iFilePos = m_pFile->Tell();
  if (m_iFilePos < 0) {
    SetError("Could not determine read-ahead source position");
    return;
  }
  const int initialPos = m_iFilePos;
  m_bValid = FillBuffer(iCacheBytes);
  if (m_bValid && RageFileObj::Seek(initialPos) != initialPos) {
    m_bValid = false;
    SetError("Could not synchronize read-ahead file position");
  }
}

RageFileDriverReadAhead::RageFileDriverReadAhead(
    const RageFileDriverReadAhead& cpy)
    : RageFileObj(cpy) {
  m_pFile = nullptr;
  m_iFilePos = cpy.m_iFilePos;
  m_bFileOwned = true;
  m_iPostBufferReadAhead = cpy.m_iPostBufferReadAhead;
  m_bValid = false;

  std::unique_ptr<RageFileBasic> sourceCopy(
      cpy.m_pFile == nullptr ? nullptr : cpy.m_pFile->Copy());
  m_sBuffer = cpy.m_sBuffer;
  m_pFile = sourceCopy.release();
  m_bValid = cpy.m_bValid && m_pFile != nullptr;

  if (m_bValid) {
    RageFileManagerReadAhead::CacheHintStreaming(m_pFile);
  } else if (GetError().empty()) {
    SetError("Could not copy read-ahead source");
  }
}

RageFileDriverReadAhead::~RageFileDriverReadAhead() {
  if (m_bFileOwned) {
    delete m_pFile;
  }
}

RageFileDriverReadAhead* RageFileDriverReadAhead::Copy() const {
  try {
    return new RageFileDriverReadAhead(*this);
  } catch (const std::exception&) {
    return nullptr;
  }
}

std::string RageFileDriverReadAhead::GetError() const {
  const std::string localError = RageFileObj::GetError();
  if (!localError.empty()) {
    return localError;
  }
  return m_pFile == nullptr ? "Read-ahead source is unavailable"
                            : m_pFile->GetError();
}

void RageFileDriverReadAhead::ClearError() {
  RageFileObj::ClearError();
  if (m_pFile != nullptr) {
    m_pFile->ClearError();
  }
}

bool RageFileDriverReadAhead::FillBuffer(int iBytes) {
  const int iOldPos = m_pFile->Tell();
  if (iOldPos < 0 || m_pFile->Seek(0) != 0) {
    SetError("Could not seek read-ahead source to its beginning");
    return false;
  }

  m_sBuffer.clear();
  int buffered = -1;
  try {
    buffered = m_pFile->Read(m_sBuffer, iBytes);
  } catch (const std::exception& error) {
    SetError(std::string("Could not allocate read-ahead buffer: ") + error.what());
    m_pFile->Seek(iOldPos);
    return false;
  }
  if (buffered < 0) {
    SetError(m_pFile->GetError().empty() ? "Could not fill read-ahead buffer"
                                         : m_pFile->GetError());
    m_pFile->Seek(iOldPos);
    return false;
  }

  /* Seek back to where we were.  If we're going back to the cached region, seek
   * past it, like SeekInternal does. */
  const int restorePos = std::max(iOldPos, static_cast<int>(m_sBuffer.size()));
  if (m_pFile->Seek(restorePos) != restorePos) {
    SetError("Could not restore read-ahead source position");
    return false;
  }

  /* Now that we're done moving the file pointer around, set the file's
   * read-ahead hint, if supported. */
  RageFileManagerReadAhead::CacheHintStreaming(m_pFile);
  return true;
}

int RageFileDriverReadAhead::ReadInternal(void* pBuffer, size_t iBytes) {
  if (!m_bValid || m_pFile == nullptr) {
    SetError("Read-ahead source is invalid");
    return -1;
  }
  int iRet = -1;
  if (m_iFilePos >= 0 &&
      m_iFilePos < static_cast<int>(m_sBuffer.size())) {
    // If we can serve data out of the buffer, use it.
    const size_t bufferedBytes = std::min(
        iBytes, m_sBuffer.size() - static_cast<size_t>(m_iFilePos));
    memcpy(pBuffer, m_sBuffer.data() + m_iFilePos, bufferedBytes);
    iRet = static_cast<int>(bufferedBytes);
  } else {
    // Read out of the underlying file.
    iRet = m_pFile->Read(pBuffer, iBytes);
  }

  if (iRet >= 0) {
    m_iFilePos += iRet;
    RageFileManagerReadAhead::ReadAhead(m_pFile, m_iPostBufferReadAhead);

  /*
   * We're streaming the file, so we don't need data that we've already read in
   * cache. Hint the OS to discard it, so it doesn't push more useful data out
   * of cache.
   *
   * Keep the previous 32k of data in cache.  This prevents an issue in Linux:
   * if we're at the end of the file, flush the cache, then try to read
   * (resulting in 0 bytes), it'll hit the disk if we've flushed.
   */
    RageFileManagerReadAhead::DiscardCache(
        m_pFile, -m_iPostBufferReadAhead - 1024 * 32,
        m_iPostBufferReadAhead);
  }

  return iRet;
}

int RageFileDriverReadAhead::WriteInternal(
    const void* /* pBuffer */, size_t /* iBytes */) {
  SetError("Read-ahead wrapper is read-only");
  return -1;
}

int RageFileDriverReadAhead::SeekInternal(int iOffset) {
  if (!m_bValid || m_pFile == nullptr || iOffset < 0) {
    SetError(iOffset < 0 ? "Read-ahead seek is negative"
                         : "Read-ahead source is invalid");
    return -1;
  }
  if (iOffset < static_cast<int>(m_sBuffer.size())) {
    /* This assumes that seeking the file won't block.  This seems to be true in
     * Linux, at least. Seek the actual file to just past our buffer, so the
     * RageFileManagerReadAhead::ReadAhead call will read ahead from the correct
     * position. */
    const int sourcePos = static_cast<int>(m_sBuffer.size());
    if (m_pFile->Seek(sourcePos) != sourcePos) {
      SetError(m_pFile->GetError().empty()
                   ? "Could not position read-ahead source"
                   : m_pFile->GetError());
      return -1;
    }
    m_iFilePos = iOffset;
    return iOffset;
  }

  m_iFilePos = m_pFile->Seek(iOffset);
  if (m_iFilePos < 0) {
    SetError(m_pFile->GetError().empty() ? "Could not seek read-ahead source"
                                         : m_pFile->GetError());
  }
  return m_iFilePos;
}

int RageFileDriverReadAhead::GetFileSize() const {
  return m_pFile == nullptr ? -1 : m_pFile->GetFileSize();
}

int RageFileDriverReadAhead::GetFD() {
  return m_pFile == nullptr ? -1 : m_pFile->GetFD();
}

/*
 * Copyright (c) 2010 Glenn Maynard
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
