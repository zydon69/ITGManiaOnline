/*
 * Ref: http://www.info-zip.org/pub/infozip/doc/appnote-981119-iz.zip
 */

#include "RageFileDriverZip.h"

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <limits>
#include <memory>
#include <new>
#include <string>

#include "RageFile.h"
#include "RageFileDriver.h"
#include "RageFileDriverDeflate.h"
#include "RageFileDriverSlice.h"
#include "RageUtil.h"
#include "RageUtil_FileDB.h"
#include "global.h"

static struct FileDriverEntry_ZIP : public FileDriverEntry {
  FileDriverEntry_ZIP() : FileDriverEntry("ZIP") {}
  RageFileDriver* Create(const std::string& sRoot) const override {
    return new RageFileDriverZip(sRoot);
  }
} const g_RegisterDriver;

namespace {
bool IsSafeZipPath(const std::string& path) {
  if (path.empty() || path.front() == '/' || path.front() == '\\' ||
      path.find('\0') != std::string::npos ||
      path.find('\\') != std::string::npos ||
      path.find("//") != std::string::npos) {
    return false;
  }
  std::vector<std::string> parts;
  split(path, "/", parts, false);
  for (const std::string& part : parts) {
    if (part.empty() || part == "." || part == "..") {
      return false;
    }
  }
  return true;
}

class RageFileObjZipCRC final : public RageFileObj {
 public:
  RageFileObjZipCRC(
      RageFileBasic* source, int uncompressedSize, uint32_t expectedCRC)
      : m_pSource(source),
        m_iUncompressedSize(uncompressedSize),
        m_iExpectedCRC(expectedCRC) {
    if (m_pSource == nullptr || m_iUncompressedSize < 0 ||
        m_pSource->GetFileSize() != m_iUncompressedSize ||
        m_pSource->Seek(0) != 0) {
      SetError("Invalid ZIP entry stream");
      return;
    }
    m_bValid = true;
  }

  RageFileObjZipCRC(const RageFileObjZipCRC& other) : RageFileObj(other) {
    m_iUncompressedSize = other.m_iUncompressedSize;
    m_iFilePos = other.m_iFilePos;
    m_iExpectedCRC = other.m_iExpectedCRC;
    m_iActualCRC = other.m_iActualCRC;
    m_bCRCValidationPossible = other.m_bCRCValidationPossible;
    m_bCRCValidated = other.m_bCRCValidated;
    m_pSource = other.m_pSource == nullptr ? nullptr : other.m_pSource->Copy();
    m_bValid = other.m_bValid && m_pSource != nullptr;
    if (!m_bValid) {
      SetError("Could not copy ZIP entry stream");
    }
  }

  ~RageFileObjZipCRC() override { delete m_pSource; }

  int ReadInternal(void* buffer, size_t bytes) override {
    if (!m_bValid || m_pSource == nullptr) {
      SetError("ZIP entry stream is invalid");
      return -1;
    }
    const int remaining = m_iUncompressedSize - m_iFilePos;
    if (remaining < 0) {
      SetError("ZIP entry position is invalid");
      return -1;
    }
    const size_t requested =
        std::min(bytes, static_cast<size_t>(remaining));
    if (requested == 0) {
      return ValidateCompletedStream() ? 0 : -1;
    }

    const int got = m_pSource->Read(buffer, requested);
    if (got <= 0 || static_cast<size_t>(got) > requested) {
      SetError(got == -1 && !m_pSource->GetError().empty()
                   ? m_pSource->GetError()
                   : "ZIP entry ended before its declared size");
      return -1;
    }
    if (m_bCRCValidationPossible) {
      CRC32(m_iActualCRC, buffer, got);
    }
    m_iFilePos += got;
    if (m_iFilePos == m_iUncompressedSize && !ValidateCompletedStream()) {
      return -1;
    }
    return got;
  }

  int WriteInternal(const void*, size_t) override {
    SetError("ZIP entries are read-only");
    return -1;
  }

  int SeekInternal(int offset) override {
    if (!m_bValid || offset < 0) {
      SetError(offset < 0 ? "ZIP entry seek is negative"
                          : "ZIP entry stream is invalid");
      return -1;
    }
    offset = std::min(offset, m_iUncompressedSize);
    if (m_pSource->Seek(offset) != offset) {
      SetError(m_pSource->GetError().empty() ? "Could not seek ZIP entry"
                                             : m_pSource->GetError());
      return -1;
    }
    if (offset == 0) {
      m_iActualCRC = 0;
      m_bCRCValidationPossible = true;
      m_bCRCValidated = false;
    } else if (offset != m_iFilePos) {
      m_bCRCValidationPossible = false;
      m_bCRCValidated = false;
    }
    m_iFilePos = offset;
    return offset;
  }

  int GetFileSize() const override { return m_iUncompressedSize; }
  int GetFD() override {
    return m_pSource == nullptr ? -1 : m_pSource->GetFD();
  }
  RageFileObjZipCRC* Copy() const override {
    try {
      std::unique_ptr<RageFileObjZipCRC> copy(new RageFileObjZipCRC(*this));
      return copy->m_bValid ? copy.release() : nullptr;
    } catch (...) {
      return nullptr;
    }
  }
  bool IsValid() const { return m_bValid; }

 private:
  bool ValidateCompletedStream() {
    if (m_bCRCValidated || !m_bCRCValidationPossible) {
      return true;
    }
    char extra = 0;
    const int trailing = m_pSource->Read(&extra, 1);
    if (trailing != 0) {
      SetError(trailing == -1 && !m_pSource->GetError().empty()
                   ? m_pSource->GetError()
                   : "ZIP entry contains undeclared output");
      return false;
    }
    if (m_iActualCRC != m_iExpectedCRC) {
      SetError("ZIP entry CRC mismatch");
      return false;
    }
    m_bCRCValidated = true;
    return true;
  }

  RageFileBasic* m_pSource{ nullptr };
  int m_iUncompressedSize{ 0 };
  int m_iFilePos{ 0 };
  uint32_t m_iExpectedCRC{ 0 };
  uint32_t m_iActualCRC{ 0 };
  bool m_bValid{ false };
  bool m_bCRCValidationPossible{ true };
  bool m_bCRCValidated{ false };

  RageFileObjZipCRC& operator=(const RageFileObjZipCRC&) = delete;
};
}  // namespace

RageFileDriverZip::RageFileDriverZip()
    : RageFileDriver(new NullFilenameDB), m_Mutex("RageFileDriverZip") {}

RageFileDriverZip::RageFileDriverZip(const std::string& sPath)
    : RageFileDriver(new NullFilenameDB), m_Mutex("RageFileDriverZip") {
  Load(sPath);
}

bool RageFileDriverZip::Load(const std::string& sPath) {
  if (m_pZip != nullptr) {
    WARN("RageFileDriverZip cannot load more than one archive");
    return false;
  }

  m_bFileOwned = true;
  m_sPath = sPath;
  m_Mutex.SetName(ssprintf("RageFileDriverZip(%s)", sPath.c_str()));

  std::unique_ptr<RageFile> pFile(new (std::nothrow) RageFile);
  if (pFile == nullptr) {
    WARN(ssprintf("Couldn't allocate ZIP reader for %s", sPath.c_str()));
    return false;
  }

  if (!pFile->Open(sPath)) {
    WARN(ssprintf(
        "Couldn't open %s: %s", sPath.c_str(), pFile->GetError().c_str()));
    return false;
  }

  m_pZip = pFile.release();
  m_bValid = ParseZipfile();

  return m_bValid;
}

bool RageFileDriverZip::Load(RageFileBasic* pFile) {
  if (m_pZip != nullptr || pFile == nullptr) {
    WARN("RageFileDriverZip received an invalid or duplicate input stream");
    return false;
  }
  m_sPath = ssprintf("%p", static_cast<void*>(pFile));
  m_Mutex.SetName(ssprintf("RageFileDriverZip(%p)", static_cast<void*>(pFile)));

  m_pZip = pFile;
  m_bValid = ParseZipfile();

  return m_bValid;
}

bool RageFileDriverZip::ReadEndCentralRecord(
    int& iTotalEntries, int& iCentralDirectoryOffset) {
  std::string sError;
  const std::string sSig = FileReading::ReadString(*m_pZip, 4, sError);
  const uint16_t diskNumber = FileReading::read_u16_le(*m_pZip, sError);
  const uint16_t centralDisk = FileReading::read_u16_le(*m_pZip, sError);
  const uint16_t diskEntries = FileReading::read_u16_le(*m_pZip, sError);
  const uint16_t totalEntries = FileReading::read_u16_le(*m_pZip, sError);
  const uint32_t centralSize = FileReading::read_u32_le(*m_pZip, sError);
  const uint32_t centralOffset = FileReading::read_u32_le(*m_pZip, sError);
  const uint16_t iCommentLength = FileReading::read_u16_le(*m_pZip, sError);
  m_sComment = FileReading::ReadString(*m_pZip, iCommentLength, sError);

  if (sError != "") {
    WARN(ssprintf("%s: %s", m_sPath.c_str(), sError.c_str()));
    return false;
  }
  if (sSig != "\x50\x4B\x05\x06") {
    WARN(ssprintf("%s: invalid end of central directory signature", m_sPath.c_str()));
    return false;
  }
  if (diskNumber != 0 || centralDisk != 0 || diskEntries != totalEntries) {
    WARN(ssprintf("%s: multi-disk ZIP archives are unsupported", m_sPath.c_str()));
    return false;
  }
  if (totalEntries == std::numeric_limits<uint16_t>::max() ||
      centralSize == std::numeric_limits<uint32_t>::max() ||
      centralOffset == std::numeric_limits<uint32_t>::max()) {
    WARN(ssprintf("%s: ZIP64 archives are unsupported", m_sPath.c_str()));
    return false;
  }
  const uint64_t centralEnd =
      static_cast<uint64_t>(centralOffset) + centralSize;
  if (centralOffset > static_cast<uint32_t>(std::numeric_limits<int>::max()) ||
      centralEnd > static_cast<uint64_t>(m_iEndCentralOffset)) {
    WARN(ssprintf("%s: central directory is outside archive bounds", m_sPath.c_str()));
    return false;
  }
  iTotalEntries = totalEntries;
  iCentralDirectoryOffset = static_cast<int>(centralOffset);
  m_iCentralDirectoryStart = iCentralDirectoryOffset;
  m_iCentralDirectoryEnd = static_cast<int>(centralEnd);

  return true;
}

/* Find the end of central directory record, and seek to it. */
bool RageFileDriverZip::SeekToEndCentralRecord() {
  if (m_pZip == nullptr) {
    return false;
  }
  const int fileSize = m_pZip->GetFileSize();
  constexpr int kEndRecordSize = 22;
  constexpr int kMaximumCommentSize = 65535;
  if (fileSize < kEndRecordSize) {
    return false;
  }
  const int iSearchTo =
      std::max(fileSize - (kEndRecordSize + kMaximumCommentSize), 0);
  int iRealPos = fileSize;

  while (iRealPos > 0 && iRealPos >= iSearchTo) {
    /* Move back in the file; leave some overlap between checks, to handle
     * the case where the signature crosses the block boundary. */
    char buf[1024 * 4];
    iRealPos -= sizeof(buf) - 4;
    iRealPos = std::max(0, iRealPos);
    if (m_pZip->Seek(iRealPos) != iRealPos) {
      return false;
    }

    int iGot = m_pZip->Read(buf, sizeof(buf));
    if (iGot == -1) {
      WARN(ssprintf("%s: %s", m_sPath.c_str(), m_pZip->GetError().c_str()));
      return false;
    }

    for (int iPos = iGot - 4; iPos >= 0; --iPos) {
      if (memcmp(buf + iPos, "\x50\x4B\x05\x06", 4)) {
        continue;
      }

      const int candidate = iRealPos + iPos;
      std::string sError;
      FileReading::Seek(*m_pZip, candidate + 20, sError);
      const uint16_t commentLength =
          FileReading::read_u16_le(*m_pZip, sError);
      if (!sError.empty() ||
          static_cast<int64_t>(candidate) + kEndRecordSize + commentLength !=
              fileSize) {
        continue;
      }
      if (m_pZip->Seek(candidate) != candidate) {
        return false;
      }
      m_iEndCentralOffset = candidate;
      return true;
    }
  }

  return false;
}

bool RageFileDriverZip::ParseZipfile() {
  if (!SeekToEndCentralRecord()) {
    WARN(ssprintf(
        "Couldn't open %s: couldn't find end of central directory record",
        m_sPath.c_str()));
    return false;
  }

  /* Read the end of central directory record. */
  int iTotalEntries, iCentralDirectoryOffset;
  if (!ReadEndCentralRecord(iTotalEntries, iCentralDirectoryOffset)) {
    return false; /* warned already */
  }

  /* Seek to the start of the central file directory. */
  if (m_pZip->Seek(iCentralDirectoryOffset) != iCentralDirectoryOffset) {
    WARN(ssprintf("%s: could not seek to central directory", m_sPath.c_str()));
    return false;
  }

  /* Loop through files in central directory. */
  try {
    m_pFiles.reserve(static_cast<size_t>(iTotalEntries));
  } catch (const std::bad_alloc&) {
    WARN(ssprintf("%s: out of memory reading ZIP directory", m_sPath.c_str()));
    return false;
  }
  for (int i = 0; i < iTotalEntries; ++i) {
    FileInfo info;
    info.m_iDataOffset = -1;
    int got = ProcessCdirFileHdr(info);
    if (got == -1) { /* error */
      return false;
    }
    if (got == 0) { /* skip */
      continue;
    }

    const std::string virtualPath = "/" + info.m_sName;
    if (FDB->GetFilePriv(virtualPath) != nullptr) {
      WARN(ssprintf(
          "%s: duplicate ZIP entry \"%s\"", m_sPath.c_str(),
          info.m_sName.c_str()));
      return false;
    }
    std::unique_ptr<FileInfo> pInfo;
    try {
      pInfo.reset(new FileInfo(info));
    } catch (const std::bad_alloc&) {
      WARN(ssprintf("%s: out of memory reading ZIP directory", m_sPath.c_str()));
      return false;
    }
    FDB->AddFile(
        virtualPath, pInfo->m_iUncompressedSize,
        static_cast<int>(pInfo->m_iCRC32), pInfo.get());
    m_pFiles.push_back(pInfo.release());
  }

  if (m_pZip->Tell() > m_iCentralDirectoryEnd) {
    WARN(ssprintf("%s: central directory entries exceed declared size", m_sPath.c_str()));
    return false;
  }

  if (m_pFiles.size() == 0) {
    WARN(
        ssprintf("%s: no files found in central file header", m_sPath.c_str()));
  }

  return true;
}

int RageFileDriverZip::ProcessCdirFileHdr(FileInfo& info) {
  constexpr int kCentralHeaderSize = 46;
  if (m_pZip->Tell() < 0 ||
      m_pZip->Tell() > m_iCentralDirectoryEnd - kCentralHeaderSize) {
    WARN(ssprintf("%s: truncated central directory", m_sPath.c_str()));
    return -1;
  }
  std::string sError;
  std::string sSig = FileReading::ReadString(*m_pZip, 4, sError);
  if (sSig != "\x50\x4B\x01\x02") {
    WARN(ssprintf(
        "%s: central directory record signature not found", m_sPath.c_str()));
    return -1;
  }

  FileReading::read_8(*m_pZip, sError); /* skip version made by */
  int iOSMadeBy = FileReading::read_8(*m_pZip, sError);
  FileReading::read_16_le(*m_pZip, sError); /* skip version needed to extract */
  const uint16_t iGeneralPurpose = FileReading::read_u16_le(*m_pZip, sError);
  info.m_iGeneralPurpose = iGeneralPurpose;
  info.m_iCompressionMethod =
      static_cast<ZipCompressionMethod>(
          FileReading::read_u16_le(*m_pZip, sError));
  FileReading::read_16_le(*m_pZip, sError); /* skip last mod file time */
  FileReading::read_16_le(*m_pZip, sError); /* skip last mod file date */
  info.m_iCRC32 = FileReading::read_u32_le(*m_pZip, sError);
  const uint32_t compressedSize = FileReading::read_u32_le(*m_pZip, sError);
  const uint32_t uncompressedSize = FileReading::read_u32_le(*m_pZip, sError);
  const uint16_t iFilenameLength = FileReading::read_u16_le(*m_pZip, sError);
  const uint16_t iExtraFieldLength = FileReading::read_u16_le(*m_pZip, sError);
  const uint16_t iFileCommentLength = FileReading::read_u16_le(*m_pZip, sError);
  FileReading::read_u16_le(
      *m_pZip, sError); /* relative offset of local header */
  FileReading::read_u16_le(*m_pZip, sError); /* skip internal file attributes */
  const uint32_t iExternalFileAttributes =
      FileReading::read_u32_le(*m_pZip, sError);
  const uint32_t localHeaderOffset =
      FileReading::read_u32_le(*m_pZip, sError);

  /* Check for errors before reading variable-length fields. */
  if (sError != "") {
    WARN(ssprintf("%s: %s", m_sPath.c_str(), sError.c_str()));
    return -1;
  }
  if (compressedSize > static_cast<uint32_t>(std::numeric_limits<int>::max()) ||
      uncompressedSize > static_cast<uint32_t>(std::numeric_limits<int>::max()) ||
      localHeaderOffset > static_cast<uint32_t>(std::numeric_limits<int>::max())) {
    WARN(ssprintf("%s: ZIP64 or oversized entry is unsupported", m_sPath.c_str()));
    return -1;
  }
  info.m_iCompressedSize = static_cast<int>(compressedSize);
  info.m_iUncompressedSize = static_cast<int>(uncompressedSize);
  info.m_iOffset = static_cast<int>(localHeaderOffset);

  const int64_t variableEnd = static_cast<int64_t>(m_pZip->Tell()) +
                              iFilenameLength + iExtraFieldLength +
                              iFileCommentLength;
  if (variableEnd > m_iCentralDirectoryEnd) {
    WARN(ssprintf("%s: ZIP entry metadata exceeds central directory", m_sPath.c_str()));
    return -1;
  }

  info.m_sName = FileReading::ReadString(*m_pZip, iFilenameLength, sError);
  FileReading::SkipBytes(
      *m_pZip, iExtraFieldLength, sError); /* skip extra field */
  FileReading::SkipBytes(
      *m_pZip, iFileCommentLength, sError); /* skip file comment */

  if (sError != "") {
    WARN(ssprintf("%s: %s", m_sPath.c_str(), sError.c_str()));
    return -1;
  }

  const bool directoryEntry =
      (!info.m_sName.empty() && info.m_sName.back() == '/') ||
      (iExternalFileAttributes & (1U << 4)) != 0 ||
      (iOSMadeBy == 3 &&
       ((iExternalFileAttributes >> 16) & 0170000) == 0040000);
  if (directoryEntry) {
    return 0;
  }
  if (!IsSafeZipPath(info.m_sName)) {
    WARN(ssprintf(
        "Skipped unsafe ZIP path \"%s\" in \"%s\"", info.m_sName.c_str(),
        m_sPath.c_str()));
    return 0;
  }

  /* Check usability last, so we always read past the whole entry and don't
   * leave the file pointer in the middle of a record. */
  if ((iGeneralPurpose & 1U) != 0 || (iGeneralPurpose & (1U << 6)) != 0) {
    WARN(ssprintf(
        "Skipped encrypted \"%s\" in \"%s\"", info.m_sName.c_str(),
        m_sPath.c_str()));
    return 0;
  }

  info.m_iFilePermissions = 0;
  enum { MADE_BY_UNIX = 3 };
  switch (iOSMadeBy) {
    case MADE_BY_UNIX:
      info.m_iFilePermissions = (iExternalFileAttributes >> 16) & 0x1FF;
      break;
  }

  if (info.m_iCompressionMethod != STORED &&
      info.m_iCompressionMethod != DEFLATED) {
    WARN(ssprintf(
        "File \"%s\" in \"%s\" uses unsupported compression method %i",
        info.m_sName.c_str(), m_sPath.c_str(), info.m_iCompressionMethod));

    return 0;
  }
  if (info.m_iCompressionMethod == STORED &&
      info.m_iCompressedSize != info.m_iUncompressedSize) {
    WARN(ssprintf(
        "Stored ZIP entry \"%s\" has inconsistent sizes", info.m_sName.c_str()));
    return -1;
  }

  return 1;
}

bool RageFileDriverZip::ReadLocalFileHeader(FileInfo& info) {
  /* Seek to and read the local file header. */
  constexpr int kLocalHeaderSize = 30;
  if (info.m_iOffset < 0 ||
      info.m_iOffset > m_iCentralDirectoryStart - kLocalHeaderSize ||
      m_pZip->Seek(info.m_iOffset) != info.m_iOffset) {
    WARN(ssprintf(
        "%s: invalid local header offset for \"%s\"", m_sPath.c_str(),
        info.m_sName.c_str()));
    return false;
  }

  std::string sError;
  std::string sSig = FileReading::ReadString(*m_pZip, 4, sError);

  if (sError != "") {
    WARN(ssprintf(
        "%s: error opening \"%s\": %s", m_sPath.c_str(), info.m_sName.c_str(),
        sError.c_str()));
    return false;
  }

  if (sSig != "\x50\x4B\x03\x04") {
    WARN(ssprintf(
        "%s: local file header not found for \"%s\"", m_sPath.c_str(),
        info.m_sName.c_str()));
    return false;
  }

  FileReading::read_u16_le(*m_pZip, sError); /* version needed */
  const uint16_t localFlags = FileReading::read_u16_le(*m_pZip, sError);
  const uint16_t localMethod = FileReading::read_u16_le(*m_pZip, sError);
  FileReading::read_u16_le(*m_pZip, sError); /* modification time */
  FileReading::read_u16_le(*m_pZip, sError); /* modification date */
  const uint32_t localCRC32 = FileReading::read_u32_le(*m_pZip, sError);
  const uint32_t localCompressedSize =
      FileReading::read_u32_le(*m_pZip, sError);
  const uint32_t localUncompressedSize =
      FileReading::read_u32_le(*m_pZip, sError);
  const uint16_t iFilenameLength = FileReading::read_u16_le(*m_pZip, sError);
  const uint16_t iExtraFieldLength = FileReading::read_u16_le(*m_pZip, sError);

  if (sError != "") {
    WARN(ssprintf("%s: %s", m_sPath.c_str(), sError.c_str()));
    return false;
  }
  const std::string localName =
      FileReading::ReadString(*m_pZip, iFilenameLength, sError);
  FileReading::SkipBytes(*m_pZip, iExtraFieldLength, sError);
  if (!sError.empty()) {
    WARN(ssprintf("%s: %s", m_sPath.c_str(), sError.c_str()));
    return false;
  }
  if (localName != info.m_sName || localFlags != info.m_iGeneralPurpose ||
      localMethod != static_cast<uint16_t>(info.m_iCompressionMethod)) {
    WARN(ssprintf(
        "%s: local and central headers disagree for \"%s\"", m_sPath.c_str(),
        info.m_sName.c_str()));
    return false;
  }
  const bool usesDataDescriptor = (localFlags & (1U << 3)) != 0;
  if (!usesDataDescriptor &&
      (localCRC32 != info.m_iCRC32 ||
       localCompressedSize != static_cast<uint32_t>(info.m_iCompressedSize) ||
       localUncompressedSize !=
           static_cast<uint32_t>(info.m_iUncompressedSize))) {
    WARN(ssprintf(
        "%s: local sizes or CRC disagree for \"%s\"", m_sPath.c_str(),
        info.m_sName.c_str()));
    return false;
  }
  info.m_iDataOffset = m_pZip->Tell();
  const int64_t dataEnd =
      static_cast<int64_t>(info.m_iDataOffset) + info.m_iCompressedSize;
  if (info.m_iDataOffset < 0 || dataEnd > m_iCentralDirectoryStart) {
    WARN(ssprintf(
        "%s: compressed data is outside bounds for \"%s\"", m_sPath.c_str(),
        info.m_sName.c_str()));
    info.m_iDataOffset = -1;
    return false;
  }

  return true;
}

RageFileDriverZip::~RageFileDriverZip() {
  for (unsigned i = 0; i < m_pFiles.size(); ++i) {
    delete m_pFiles[i];
  }

  if (m_bFileOwned) {
    delete m_pZip;
  }
}

const RageFileDriverZip::FileInfo* RageFileDriverZip::GetFileInfo(
    const std::string& sPath) const {
  if (!m_bValid) {
    return nullptr;
  }
  return (const FileInfo*)FDB->GetFilePriv(sPath);
}

RageFileBasic* RageFileDriverZip::Open(
    const std::string& sPath, int iMode, int& iErr) {
  iErr = 0;
  if (iMode & RageFile::WRITE) {
    iErr = ERROR_WRITING_NOT_SUPPORTED;
    return nullptr;
  }
  if ((iMode & RageFile::READ) == 0 || !m_bValid || m_pZip == nullptr) {
    iErr = EINVAL;
    return nullptr;
  }

  FileInfo* info = (FileInfo*)FDB->GetFilePriv(sPath);
  if (info == nullptr) {
    iErr = ENOENT;
    return nullptr;
  }

  try {
    std::unique_ptr<RageFileBasic> zipCopy;
    {
      LockMut(m_Mutex);

      /* If we haven't figured out the offset to the real data yet, do so now. */
      if (info->m_iDataOffset == -1 && !ReadLocalFileHeader(*info)) {
        iErr = EIO;
        return nullptr;
      }
      zipCopy.reset(m_pZip->Copy());
    }
    if (zipCopy == nullptr) {
      iErr = EIO;
      return nullptr;
    }

    std::unique_ptr<RageFileDriverSlice> pSlice(new RageFileDriverSlice(
        zipCopy.get(), info->m_iDataOffset, info->m_iCompressedSize));
    if (!pSlice->GetError().empty()) {
      iErr = EIO;
      return nullptr;
    }
    zipCopy.release();
    pSlice->DeleteFileWhenFinished();

    std::unique_ptr<RageFileBasic> entryStream;
    switch (info->m_iCompressionMethod) {
      case STORED:
        entryStream.reset(pSlice.release());
        break;
      case DEFLATED: {
        std::unique_ptr<RageFileObjInflate> pInflate(
            new RageFileObjInflate(pSlice.get(), info->m_iUncompressedSize));
        if (!pInflate->IsValid()) {
          iErr = EIO;
          return nullptr;
        }
        pSlice.release();
        pInflate->DeleteFileWhenFinished();
        entryStream.reset(pInflate.release());
        break;
      }
      default:
        iErr = ENOSYS;
        return nullptr;
    }
    std::unique_ptr<RageFileObjZipCRC> checkedEntry(new RageFileObjZipCRC(
        entryStream.get(), info->m_iUncompressedSize, info->m_iCRC32));
    if (!checkedEntry->IsValid()) {
      iErr = EIO;
      return nullptr;
    }
    entryStream.release();
    return checkedEntry.release();
  } catch (const std::bad_alloc&) {
    iErr = ENOMEM;
    return nullptr;
  } catch (...) {
    iErr = EIO;
    return nullptr;
  }
}

/* NOP for now.  This could check to see if the ZIP's mtime has changed, and
 * reload. */
void RageFileDriverZip::FlushDirCache(const std::string& /* sPath */) {}

/*
 * Copyright (c) 2003-2005 Glenn Maynard
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
