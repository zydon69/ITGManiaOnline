/* RageFileObjInflate - decompress streams compressed with "deflate"
 * compression. */

#ifndef RAGE_FILE_DRIVER_DEFLATE_H
#define RAGE_FILE_DRIVER_DEFLATE_H

#include <cstddef>
#include <cstdint>
#include <string>

#include "RageFileBasic.h"

typedef struct z_stream_s z_stream;

class RageFileObjInflate : public RageFileObj {
 public:
  /* By default, pFile will not be freed.  To implement GetFileSize(), the
   * container format must store the file size. */
  explicit RageFileObjInflate(RageFileBasic* pFile, int iUncompressedSize);
  RageFileObjInflate(const RageFileObjInflate& cpy);
  ~RageFileObjInflate() override;
  int ReadInternal(void* pBuffer, size_t iBytes) override;
  int WriteInternal(
      const void* /* pBuffer */, size_t /* iBytes */) override {
    SetError("Not implemented");
    return -1;
  }
  int SeekInternal(int iOffset) override;
  int GetFileSize() const override { return m_iUncompressedSize; }
  int GetFD() override { return m_pFile == nullptr ? -1 : m_pFile->GetFD(); }
  RageFileObjInflate* Copy() const override;

  bool IsValid() const { return m_bInflateInitialized && m_pFile != nullptr; }

  void DeleteFileWhenFinished() { m_bFileOwned = true; }

 private:
  bool ValidateStreamEnd();

  int m_iUncompressedSize{ 0 };
  RageFileBasic* m_pFile{ nullptr };
  int m_iFilePos{ 0 };
  bool m_bFileOwned{ false };
  bool m_bInflateInitialized{ false };
  bool m_bStreamEnded{ false };

  z_stream* m_pInflate{ nullptr };
  enum { INBUFSIZE = 1024 * 4 };
  char decomp_buf[INBUFSIZE]{};
  char* decomp_buf_ptr{ decomp_buf };
  int decomp_buf_avail{ 0 };

  RageFileObjInflate& operator=(const RageFileObjInflate&) = delete;
};

class RageFileObjDeflate : public RageFileObj {
 public:
  /* By default, pFile will not be freed. */
  explicit RageFileObjDeflate(RageFileBasic* pOutput);
  ~RageFileObjDeflate() override;

  int GetFileSize() const override {
    return m_pFile == nullptr ? -1 : m_pFile->GetFileSize();
  }
  int GetFD() override { return m_pFile == nullptr ? -1 : m_pFile->GetFD(); }
  void DeleteFileWhenFinished() { m_bFileOwned = true; }

 protected:
  int ReadInternal(void* /* pBuffer */, size_t /* iBytes */) override {
    SetError("Not implemented");
    return -1;
  }
  int WriteInternal(const void* pBuffer, size_t iBytes) override;
  int FlushInternal() override;
  int SeekInternal(int /* iOffset */) override {
    SetError("Compressed output streams cannot be seeked");
    return -1;
  }

  bool IsDeflateValid() const {
    return m_bDeflateInitialized && m_pFile != nullptr;
  }

  RageFileBasic* m_pFile{ nullptr };
  z_stream* m_pDeflate{ nullptr };
  bool m_bFileOwned{ false };
  bool m_bDeflateInitialized{ false };
  bool m_bDeflateFinished{ false };

 private:
  RageFileObjDeflate(const RageFileObjDeflate&) = delete;
  RageFileObjDeflate& operator=(const RageFileObjDeflate&) = delete;
};

class RageFileObjGzip : public RageFileObjDeflate {
 public:
  explicit RageFileObjGzip(RageFileBasic* pFile);
  int Start();
  int Finish();

 private:
  int m_iDataStartOffset{ -1 };
  bool m_bStarted{ false };
  bool m_bFinished{ false };
};

RageFileObjInflate* GunzipFile(
    RageFileBasic* pFile, std::string& sError, uint32_t* iCRC32);

/* Quick helpers: */
bool GzipString(
    const std::string& sIn, std::string& sOut,
    std::string* pError = nullptr);
bool GunzipString(
    const std::string& sIn, std::string& sOut,
    std::string& sError);  // returns false on CRC, etc. error
bool GunzipStringBounded(
    const std::string& sIn, std::string& sOut, std::string& sError,
    std::size_t maxOutputBytes);

#endif

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
