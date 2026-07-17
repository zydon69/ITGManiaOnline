#include "RageFileDriverDeflate.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <new>
#include <string>

#include "RageFile.h"
#include "RageFileBasic.h"
#include "RageFileDriverSlice.h"
#include "RageUtil.h"
#include "RageUtil/Endian.h"
#include "global.h"
#include "zconf.h"

#if defined(_WIN32)
#include "zlib.h"
#if defined(_MSC_VER)
#if defined(BINARY_ZDL)
#pragma comment(lib, "zdll.lib")
// #else
// #pragma comment(lib, "zlib.lib")
#endif
#endif
#elif defined(MACOSX)
#include "zlib.h"
#else
#include <zlib.h>
#endif

RageFileObjInflate::RageFileObjInflate(
    RageFileBasic* pFile, int iUncompressedSize) {
  m_pFile = pFile;
  m_iUncompressedSize = iUncompressedSize;
  if (m_pFile == nullptr || m_iUncompressedSize < 0) {
    SetError("Invalid compressed input stream");
    return;
  }

  m_pInflate = new (std::nothrow) z_stream;
  if (m_pInflate == nullptr) {
    SetError("Could not allocate inflate state");
    return;
  }
  memset(m_pInflate, 0, sizeof(z_stream));

  const int err = inflateInit2(m_pInflate, -MAX_WBITS);
  if (err != Z_OK) {
    SetError(ssprintf("Could not initialize inflate stream: %i", err));
    return;
  }
  m_bInflateInitialized = true;
}

RageFileObjInflate::RageFileObjInflate(const RageFileObjInflate& cpy)
    : RageFileObj(cpy) {
  m_iUncompressedSize = cpy.m_iUncompressedSize;
  m_iFilePos = cpy.m_iFilePos;
  m_bStreamEnded = cpy.m_bStreamEnded;
  m_bFileOwned = true;
  if (!cpy.IsValid()) {
    SetError(cpy.GetError().empty() ? "Cannot copy an invalid inflate stream"
                                    : cpy.GetError());
    return;
  }

  m_pFile = cpy.m_pFile->Copy();
  if (m_pFile == nullptr) {
    SetError("Could not copy compressed input stream");
    return;
  }
  m_pInflate = new (std::nothrow) z_stream;
  if (m_pInflate == nullptr) {
    SetError("Could not allocate copied inflate state");
    return;
  }
  memset(m_pInflate, 0, sizeof(z_stream));
  const int err =
      inflateCopy(m_pInflate, const_cast<z_stream*>(cpy.m_pInflate));
  if (err != Z_OK) {
    SetError(ssprintf("Could not copy inflate state: %i", err));
    return;
  }
  m_bInflateInitialized = true;

  const ptrdiff_t inputOffset = cpy.decomp_buf_ptr - cpy.decomp_buf;
  if (inputOffset < 0 || inputOffset > INBUFSIZE ||
      cpy.decomp_buf_avail < 0 ||
      cpy.decomp_buf_avail > INBUFSIZE - inputOffset) {
    inflateEnd(m_pInflate);
    m_bInflateInitialized = false;
    SetError("Copied inflate input buffer is invalid");
    return;
  }
  memcpy(decomp_buf, cpy.decomp_buf, sizeof(decomp_buf));
  decomp_buf_ptr = decomp_buf + inputOffset;
  decomp_buf_avail = cpy.decomp_buf_avail;
}

RageFileObjInflate* RageFileObjInflate::Copy() const {
  try {
    std::unique_ptr<RageFileObjInflate> copy(new RageFileObjInflate(*this));
    if (!copy->IsValid()) {
      return nullptr;
    }
    return copy.release();
  } catch (const std::bad_alloc&) {
    return nullptr;
  } catch (...) {
    return nullptr;
  }
}

RageFileObjInflate::~RageFileObjInflate() {
  if (m_bFileOwned) {
    delete m_pFile;
  }

  if (m_bInflateInitialized) {
    const int err = inflateEnd(m_pInflate);
    if (err != Z_OK) {
      WARN(ssprintf("inflateEnd failed: %i", err));
    }
  }

  delete m_pInflate;
}

bool RageFileObjInflate::ValidateStreamEnd() {
  while (!m_bStreamEnded) {
    if (decomp_buf_avail == 0) {
      decomp_buf_ptr = decomp_buf;
      const int got = m_pFile->Read(decomp_buf, sizeof(decomp_buf));
      if (got == -1) {
        SetError(m_pFile->GetError());
        return false;
      }
      if (got <= 0 || got > static_cast<int>(sizeof(decomp_buf))) {
        SetError(got == 0 ? "Compressed stream is truncated"
                          : "Compressed source returned an invalid byte count");
        return false;
      }
      decomp_buf_avail = got;
    }

    unsigned char extraOutput = 0;
    m_pInflate->next_in = reinterpret_cast<Bytef*>(decomp_buf_ptr);
    m_pInflate->avail_in = static_cast<uInt>(decomp_buf_avail);
    m_pInflate->next_out = &extraOutput;
    m_pInflate->avail_out = 1;
    const uInt inputBefore = m_pInflate->avail_in;
    const int err = inflate(m_pInflate, Z_NO_FLUSH);

    const int used = static_cast<int>(inputBefore - m_pInflate->avail_in);
    decomp_buf_ptr += used;
    decomp_buf_avail -= used;

    if (m_pInflate->avail_out == 0) {
      SetError("Compressed stream exceeds its declared size");
      return false;
    }
    if (err == Z_STREAM_END) {
      m_bStreamEnded = true;
      return true;
    }
    if (err == Z_DATA_ERROR) {
      SetError("Data error");
      return false;
    }
    if (err == Z_MEM_ERROR) {
      SetError("out of memory");
      return false;
    }
    if (err == Z_NEED_DICT) {
      SetError("Compressed stream requires a preset dictionary");
      return false;
    }
    if (err != Z_OK || inputBefore == m_pInflate->avail_in) {
      SetError(err == Z_BUF_ERROR ? "Compressed stream is truncated"
                                  : "Inflate stream made no progress");
      return false;
    }
  }
  return true;
}

int RageFileObjInflate::ReadInternal(void* buf, size_t bytes) {
  /* Don't read more than m_iUncompressedSize of data.  If we don't do this,
   * it's possible for a .gz to contain a header claiming 500k of data, but to
   * actually contain much more deflated data. */
  if (!IsValid() || m_iFilePos < 0 ||
      m_iFilePos > m_iUncompressedSize) {
    SetError("Inflate stream is invalid");
    return -1;
  }
  bytes = std::min(bytes, size_t(m_iUncompressedSize - m_iFilePos));
  if (bytes == 0) {
    return ValidateStreamEnd() ? 0 : -1;
  }
  if (m_bStreamEnded) {
    SetError("Compressed stream ended before its declared size");
    return -1;
  }

  bool done = false;
  int ret = 0;
  while (bytes && !done) {
    if (!decomp_buf_avail) {
      decomp_buf_ptr = decomp_buf;
      decomp_buf_avail = 0;
      int got = m_pFile->Read(decomp_buf, sizeof(decomp_buf));
      if (got == -1) {
        SetError(m_pFile->GetError());
        return -1;
      }

      if (got < 0 || got > static_cast<int>(sizeof(decomp_buf))) {
        SetError("Compressed source returned an invalid byte count");
        return -1;
      }
      decomp_buf_avail = got;
    }

    m_pInflate->next_in = (Bytef*)decomp_buf_ptr;
    m_pInflate->avail_in = decomp_buf_avail;
    m_pInflate->next_out = (Bytef*)buf;
    m_pInflate->avail_out = bytes;

    const uInt inputBefore = m_pInflate->avail_in;
    const uInt outputBefore = m_pInflate->avail_out;
    const int err = inflate(m_pInflate, Z_NO_FLUSH);
    switch (err) {
      case Z_DATA_ERROR:
        SetError("Data error");
        return -1;
      case Z_MEM_ERROR:
        SetError("out of memory");
        return -1;
      case Z_BUF_ERROR:
        SetError("file truncated");
        return -1;
      case Z_STREAM_END:
        done = true;
        m_bStreamEnded = true;
        break;
      case Z_OK:
        break;
      case Z_NEED_DICT:
        SetError("Compressed stream requires a preset dictionary");
        return -1;
      default:
        SetError(ssprintf("Inflate failed: %i", err));
        return -1;
    }

    const int used = (char*)m_pInflate->next_in - decomp_buf_ptr;
    decomp_buf_ptr += used;
    decomp_buf_avail -= used;

    const int got = (char*)m_pInflate->next_out - (char*)buf;
    m_iFilePos += got;
    ret += got;
    buf = (char*)buf + got;
    bytes -= got;

    if (inputBefore == m_pInflate->avail_in &&
        outputBefore == m_pInflate->avail_out && !done) {
      SetError("Inflate stream made no progress");
      return -1;
    }
  }

  if (m_bStreamEnded && m_iFilePos != m_iUncompressedSize) {
    SetError("Compressed stream ended before its declared size");
    return -1;
  }
  if (m_iFilePos == m_iUncompressedSize && !ValidateStreamEnd()) {
    return -1;
  }

  return ret;
}

int RageFileObjInflate::SeekInternal(int iPos) {
  if (!IsValid() || iPos < 0) {
    SetError(iPos < 0 ? "Inflate seek is negative" : "Inflate stream is invalid");
    return -1;
  }
  /* Optimization: if offset is the end of the file, it's a lseek(0,SEEK_END).
   * Don't decode anything. */
  if (iPos >= m_iUncompressedSize) {
    m_iFilePos = m_iUncompressedSize;
    const int sourceSize = m_pFile->GetFileSize();
    if (sourceSize < 0 || m_pFile->Seek(sourceSize) != sourceSize) {
      SetError(m_pFile->GetError().empty() ? "Could not seek compressed source"
                                           : m_pFile->GetError());
      return -1;
    }
    decomp_buf_ptr = decomp_buf;
    decomp_buf_avail = 0;
    const int err = inflateReset(m_pInflate);
    if (err != Z_OK) {
      SetError(ssprintf("Could not reset inflate stream: %i", err));
      return -1;
    }
    m_bStreamEnded = true;
    return m_iUncompressedSize;
  }

  if (iPos < m_iFilePos) {
    const int err = inflateReset(m_pInflate);
    if (err != Z_OK) {
      SetError(ssprintf("Could not reset inflate stream: %i", err));
      return -1;
    }
    decomp_buf_ptr = decomp_buf;
    decomp_buf_avail = 0;

    if (m_pFile->Seek(0) != 0) {
      SetError(m_pFile->GetError().empty() ? "Could not rewind compressed source"
                                           : m_pFile->GetError());
      return -1;
    }
    m_iFilePos = 0;
    m_bStreamEnded = false;
  }

  int iOffset = iPos - m_iFilePos;

  /* Can this be optimized? */
  char buf[1024 * 4];
  while (iOffset) {
    int got = ReadInternal(buf, std::min((int)sizeof(buf), iOffset));
    if (got == -1) {
      return -1;
    }

    if (got == 0) {
      break;
    }
    iOffset -= got;
  }

  return m_iFilePos;
}

RageFileObjDeflate::RageFileObjDeflate(RageFileBasic* pFile) {
  m_pFile = pFile;
  if (m_pFile == nullptr) {
    SetError("Invalid compressed output stream");
    return;
  }

  m_pDeflate = new (std::nothrow) z_stream;
  if (m_pDeflate == nullptr) {
    SetError("Could not allocate deflate state");
    return;
  }
  memset(m_pDeflate, 0, sizeof(z_stream));

  int err = deflateInit2(
      m_pDeflate, 3, Z_DEFLATED,
      -15,  // windowBits
      8,    // memLevel
      Z_DEFAULT_STRATEGY);

  if (err != Z_OK) {
    SetError(ssprintf("Could not initialize deflate stream: %i", err));
    return;
  }
  m_bDeflateInitialized = true;
}

RageFileObjDeflate::~RageFileObjDeflate() {
  if (m_bDeflateInitialized && !m_bDeflateFinished) {
    FlushInternal();
  }

  if (m_bFileOwned) {
    delete m_pFile;
  }

  if (m_bDeflateInitialized) {
    const int err = deflateEnd(m_pDeflate);
    if (err != Z_OK) {
      WARN(ssprintf("deflateEnd failed: %i", err));
    }
  }

  delete m_pDeflate;
}

int RageFileObjDeflate::WriteInternal(const void* pBuffer, size_t iBytes) {
  if (iBytes == 0) {
    return 0;
  }
  if (!IsDeflateValid()) {
    SetError("Deflate stream is invalid");
    return -1;
  }
  if (m_bDeflateFinished) {
    SetError("Deflate stream is already finished");
    return -1;
  }
  m_pDeflate->next_in = (Bytef*)pBuffer;
  m_pDeflate->avail_in = static_cast<uInt>(iBytes);

  for (;;) {
    char buf[1024 * 4];
    m_pDeflate->next_out = (Bytef*)buf;
    m_pDeflate->avail_out = sizeof(buf);

    const uInt inputBefore = m_pDeflate->avail_in;
    const uInt outputBefore = m_pDeflate->avail_out;
    const int err = deflate(m_pDeflate, Z_NO_FLUSH);

    if (err != Z_OK) {
      SetError(ssprintf("Deflate failed: %i", err));
      return -1;
    }
    if (m_pDeflate->avail_out < sizeof(buf)) {
      int lBytes = sizeof(buf) - m_pDeflate->avail_out;
      int iRet = m_pFile->Write(buf, lBytes);
      if (iRet == -1) {
        SetError(m_pFile->GetError());
        return -1;
      }
      if (iRet < lBytes) {
        SetError("Partial write");
        return -1;
      }
    }

    if (m_pDeflate->avail_in == 0 && m_pDeflate->avail_out != 0) {
      break;
    }
    if (inputBefore == m_pDeflate->avail_in &&
        outputBefore == m_pDeflate->avail_out) {
      SetError("Deflate stream made no progress");
      return -1;
    }
  }
  return static_cast<int>(iBytes);
}

/* Note that flushing clears compression state, so (unlike most Flush() calls)
 * calling this *does* change the result of the output if you continue writing
 * data. */
int RageFileObjDeflate::FlushInternal() {
  if (!IsDeflateValid()) {
    SetError("Deflate stream is invalid");
    return -1;
  }
  if (m_bDeflateFinished) {
    return m_pFile->Flush();
  }
  m_pDeflate->avail_in = 0;

  for (;;) {
    char buf[1024 * 4];
    m_pDeflate->next_out = (Bytef*)buf;
    m_pDeflate->avail_out = sizeof(buf);

    const uLong outputBefore = m_pDeflate->total_out;
    const int err = deflate(m_pDeflate, Z_FINISH);
    if (err != Z_OK && err != Z_STREAM_END) {
      SetError(ssprintf("Could not finish deflate stream: %i", err));
      return -1;
    }
    if (m_pDeflate->avail_out < sizeof(buf)) {
      int iBytes = sizeof(buf) - m_pDeflate->avail_out;
      int iRet = m_pFile->Write(buf, iBytes);
      if (iRet == -1) {
        SetError(m_pFile->GetError());
        return -1;
      }
      if (iRet < iBytes) {
        SetError("Partial write");
        return -1;
      }
    }

    if (err == Z_STREAM_END && m_pDeflate->avail_out != 0) {
      m_bDeflateFinished = true;
      return m_pFile->Flush();
    }
    if (m_pDeflate->total_out == outputBefore) {
      SetError("Deflate finalization made no progress");
      return -1;
    }
  }
}

/*
 * Parse a .gz file, check the header CRC16 if present, and return the data
 * CRC32 and a decompressor.  pFile will be deleted.
 */
RageFileObjInflate* GunzipFile(
    RageFileBasic* pFile_, std::string& sError, uint32_t* iCRC32) {
  std::unique_ptr<RageFileBasic> pFile(pFile_);

  sError = "";
  if (iCRC32 != nullptr) {
    *iCRC32 = 0;
  }
  if (pFile == nullptr) {
    sError = "Missing gzip input stream";
    return nullptr;
  }

  const int fileSize = pFile->GetFileSize();
  constexpr int kMinimumGzipSize = 10 + 8;
  if (fileSize < kMinimumGzipSize) {
    sError = "Gzip file is too short";
    return nullptr;
  }
  const int iFooterPos = fileSize - 8;

  if (pFile->Seek(0) != 0) {
    sError = pFile->GetError().empty() ? "Could not rewind gzip input"
                                       : pFile->GetError();
    return nullptr;
  }
  pFile->EnableCRC32(true);

  {
    char magic[2];
    FileReading::ReadBytes(*pFile, magic, 2, sError);
    if (sError != "") {
      return nullptr;
    }

    if (magic[0] != '\x1f' || magic[1] != '\x8b') {
      sError = "Not a gzipped file";
      return nullptr;
    }
  }

  uint8_t iCompressionMethod = FileReading::read_8(*pFile, sError);
  uint8_t iFlags = FileReading::read_8(*pFile, sError);
  FileReading::read_32_le(*pFile, sError); /* time */
  FileReading::read_8(*pFile, sError);     /* xfl */
  FileReading::read_8(*pFile, sError);     /* os */
  if (sError != "") {
    return nullptr;
  }

  constexpr uint8_t FHCRC = 1 << 1;
  constexpr uint8_t FEXTRA = 1 << 2;
  constexpr uint8_t FNAME = 1 << 3;
  constexpr uint8_t FCOMMENT = 1 << 4;
  constexpr uint8_t UNSUPPORTED_MASK = 0xE0;
  if (iCompressionMethod != 8) {
    sError = ssprintf("Unsupported compression: %i", iCompressionMethod);
    return nullptr;
  }

  /* Warning: flags other than FNAME are untested, since gzip doesn't
   * actually output them. */
  if (iFlags & UNSUPPORTED_MASK) {
    sError = ssprintf("Unsupported flags: %x", iFlags);
    return nullptr;
  }

  if (iFlags & FEXTRA) {
    const uint16_t iSize = FileReading::read_u16_le(*pFile, sError);
    FileReading::SkipBytes(*pFile, iSize, sError);
    if (sError != "" || pFile->Tell() > iFooterPos) {
      sError = sError.empty() ? "Gzip extra field overlaps the footer" : sError;
      return nullptr;
    }
  }

  if (iFlags & FNAME) {
    bool terminated = false;
    while (sError == "" && pFile->Tell() < iFooterPos) {
      if (FileReading::read_8(*pFile, sError) == 0) {
        terminated = true;
        break;
      }
    }
    if (!terminated && sError.empty()) {
      sError = "Unterminated gzip file name";
    }
  }
  if (iFlags & FCOMMENT) {
    bool terminated = false;
    while (sError == "" && pFile->Tell() < iFooterPos) {
      if (FileReading::read_8(*pFile, sError) == 0) {
        terminated = true;
        break;
      }
    }
    if (!terminated && sError.empty()) {
      sError = "Unterminated gzip comment";
    }
  }
  if (sError != "") {
    return nullptr;
  }

  if (iFlags & FHCRC) {
    /* Get the CRC of the data read so far.  Be sure to do this before
     * reading iExpectedCRC16. */
    uint32_t iActualCRC32;
    const bool bOK = pFile->GetCRC32(&iActualCRC32);
    if (!bOK) {
      sError = "Could not calculate gzip header CRC";
      return nullptr;
    }

    uint16_t iExpectedCRC16 = FileReading::read_u16_le(*pFile, sError);
    uint16_t iActualCRC16 = int16_t(iActualCRC32 & 0xFFFF);
    if (sError != "") {
      return nullptr;
    }

    if (iActualCRC16 != iExpectedCRC16) {
      sError = "Header CRC error";
      return nullptr;
    }
  }

  /* We only need CRC checking on the raw data for the header, so disable
   * it. */
  pFile->EnableCRC32(false);

  if (sError != "") {
    return nullptr;
  }

  int iDataPos = pFile->Tell();
  if (iDataPos < 0 || iDataPos > iFooterPos) {
    sError = "Gzip header overlaps the footer";
    return nullptr;
  }

  /* Seek to the end, and grab the uncompressed flie size and CRC. */
  FileReading::Seek(*pFile, iFooterPos, sError);

  uint32_t iExpectedCRC32 = FileReading::read_u32_le(*pFile, sError);
  uint32_t iUncompressedSize = FileReading::read_u32_le(*pFile, sError);
  if (iCRC32 != nullptr) {
    *iCRC32 = iExpectedCRC32;
  }

  FileReading::Seek(*pFile, iDataPos, sError);

  if (sError != "") {
    return nullptr;
  }
  if (iUncompressedSize >
      static_cast<uint32_t>(std::numeric_limits<int>::max())) {
    sError = "Uncompressed size exceeds supported range";
    return nullptr;
  }

  try {
    std::unique_ptr<RageFileDriverSlice> pSliceFile(
        new RageFileDriverSlice(
            pFile.get(), iDataPos, iFooterPos - iDataPos));
    if (!pSliceFile->GetError().empty()) {
      sError = pSliceFile->GetError();
      return nullptr;
    }
    pFile.release();
    pSliceFile->DeleteFileWhenFinished();

    std::unique_ptr<RageFileObjInflate> pInflateFile(
        new RageFileObjInflate(
            pSliceFile.get(), static_cast<int>(iUncompressedSize)));
    if (!pInflateFile->IsValid()) {
      sError = pInflateFile->GetError().empty()
                   ? "Could not initialize gzip decompressor"
                   : pInflateFile->GetError();
      return nullptr;
    }
    pSliceFile.release();
    pInflateFile->DeleteFileWhenFinished();

    /* Enable CRC calculation only if the caller is interested. */
    if (iCRC32 != nullptr) {
      pInflateFile->EnableCRC32();
    }

    return pInflateFile.release();
  } catch (const std::bad_alloc&) {
    sError = "Out of memory while opening gzip stream";
    return nullptr;
  }
}

/*
 * Usage:
 *
 * RageFile output;
 * output.Open( "hello.gz", RageFile::WRITE );
 *
 * RageFileObjGzip gzip( &output );
 * gzip.Start();
 * gzip.Write( "data" );
 * gzip.Finish();
 */
RageFileObjGzip::RageFileObjGzip(RageFileBasic* pFile)
    : RageFileObjDeflate(pFile) {}

/* Write the gzip header. */
int RageFileObjGzip::Start() {
  if (!IsDeflateValid()) {
    SetError("Gzip output stream is invalid");
    return -1;
  }
  if (m_bStarted) {
    SetError("Gzip stream has already been started");
    return -1;
  }
  if (Tell() != 0 || m_pFile->Tell() != 0) {
    SetError("Gzip output stream must start at offset zero");
    return -1;
  }

  static const char header[] = {
      '\x1f', '\x8b',        // magic
      8,                     // method: deflate
      0,                     // no flags
      0,      0,      0, 0,  // no time
      0,                     // no extra flags
      '\xFF'                 // unknown os
  };

  const int written = m_pFile->Write(header, sizeof(header));
  if (written != static_cast<int>(sizeof(header))) {
    SetError(written == -1 && !m_pFile->GetError().empty()
                 ? m_pFile->GetError()
                 : "Could not write complete gzip header");
    return -1;
  }

  m_iDataStartOffset = Tell();

  /* Enable and reset the CRC32 for the uncompressed data about to be
   * written to this file. */
  this->EnableCRC32(true);
  m_bStarted = true;

  return 0;
}

/* Write the gzip footer. */
int RageFileObjGzip::Finish() {
  if (!m_bStarted) {
    SetError("Gzip stream has not been started");
    return -1;
  }
  if (m_bFinished) {
    return m_pFile->Flush();
  }
  /* We're about to write to the underlying file (so the footer isn't
   * compressed).  Flush the compressed data first. */
  if (this->Flush() == -1) {
    return -1;
  }

  /* Read the CRC of the data that's been written. */
  uint32_t iCRC;
  if (!this->GetCRC32(&iCRC)) {
    SetError("Could not calculate gzip data CRC");
    return -1;
  }

  /* Figure out the size of the data. */
  if (Tell() < m_iDataStartOffset) {
    SetError("Invalid gzip input size");
    return -1;
  }
  uint32_t iSize = static_cast<uint32_t>(Tell() - m_iDataStartOffset);

  /* Write the CRC and size directly to the file, so they don't get compressed.
   */
  iCRC = Swap32LE(iCRC);
  const int crcWritten = m_pFile->Write(&iCRC, sizeof(iCRC));
  if (crcWritten != static_cast<int>(sizeof(iCRC))) {
    SetError(crcWritten == -1 && !m_pFile->GetError().empty()
                 ? m_pFile->GetError()
                 : "Could not write complete gzip CRC");
    return -1;
  }

  /* Write the size. */
  iSize = Swap32LE(iSize);
  const int sizeWritten = m_pFile->Write(&iSize, sizeof(iSize));
  if (sizeWritten != static_cast<int>(sizeof(iSize))) {
    SetError(sizeWritten == -1 && !m_pFile->GetError().empty()
                 ? m_pFile->GetError()
                 : "Could not write complete gzip size");
    return -1;
  }

  /* Flush the CRC and wize that we just wrote directly to the file. */
  m_bFinished = true;
  const int result = m_pFile->Flush();
  if (result != 0 && GetError().empty()) {
    SetError(m_pFile->GetError().empty() ? "Could not flush gzip footer"
                                         : m_pFile->GetError());
  }
  return result;
}

#include "RageFileDriverMemory.h"

bool GzipString(
    const std::string& sIn, std::string& sOut, std::string* pError) {
  sOut.clear();
  if (sIn.size() > static_cast<size_t>(std::numeric_limits<int>::max())) {
    if (pError != nullptr) {
      *pError = "Gzip input exceeds the supported size";
    }
    return false;
  }
  /* Gzip it. */
  RageFileObjMem mem;
  RageFileObjGzip gzip(&mem);
  if (gzip.Start() == -1 || gzip.Write(sIn) != static_cast<int>(sIn.size()) ||
      gzip.Finish() == -1) {
    if (pError != nullptr) {
      *pError = gzip.GetError().empty() ? "Could not gzip string"
                                        : gzip.GetError();
    }
    return false;
  }

  sOut = mem.GetString();
  if (pError != nullptr) {
    pError->clear();
  }
  return true;
}

bool GunzipString(
    const std::string& sIn, std::string& sOut, std::string& sError) {
  return GunzipStringBounded(
      sIn, sOut, sError,
      static_cast<std::size_t>(std::numeric_limits<int>::max()));
}

bool GunzipStringBounded(
    const std::string& sIn, std::string& sOut, std::string& sError,
    std::size_t maxOutputBytes) {
  sOut.clear();
  sError.clear();
  std::unique_ptr<RageFileObjMem> mem;
  try {
    mem.reset(new RageFileObjMem);
  } catch (const std::bad_alloc&) {
    sError = "Out of memory while preparing gzip input";
    return false;
  }
  if (!mem->PutString(sIn)) {
    sError = mem->GetError().empty() ? "Could not prepare gzip input"
                                     : mem->GetError();
    return false;
  }

  uint32_t iCRC32;
  std::unique_ptr<RageFileBasic> file(
      GunzipFile(mem.release(), sError, &iCRC32));
  if (file == nullptr) {
    return false;
  }

  const int uncompressedSize = file->GetFileSize();
  if (uncompressedSize < 0 ||
      static_cast<std::size_t>(uncompressedSize) > maxOutputBytes) {
    sError = "Uncompressed data exceeds maximum allowed size";
    return false;
  }

  const int bytesRead = file->Read(sOut, uncompressedSize);
  if (bytesRead != uncompressedSize) {
    sError = file->GetError().empty() ? "Unexpected end of compressed data"
                                      : file->GetError();
    sOut.clear();
    return false;
  }
  char trailingByte = 0;
  const int trailingRead = file->Read(&trailingByte, 1);
  if (trailingRead != 0) {
    sError = trailingRead == -1 && !file->GetError().empty()
                 ? file->GetError()
                 : "Compressed stream contains undeclared output";
    sOut.clear();
    return false;
  }

  /* Check the CRC. */
  unsigned iRet;
  if (!file->GetCRC32(&iRet)) {
    sError = "Could not calculate uncompressed CRC";
    sOut.clear();
    return false;
  }

  if (iRet != iCRC32) {
    sError = "CRC error";
    sOut.clear();
    return false;
  }

  return true;
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
