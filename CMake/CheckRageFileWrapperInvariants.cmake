if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

file(READ "${ITGMANIA_SOURCE_DIR}/src/RageFileDriverMemory.cpp" memory_cpp)
file(READ "${ITGMANIA_SOURCE_DIR}/src/RageFileDriverMemory.h" memory_h)
file(READ "${ITGMANIA_SOURCE_DIR}/src/RageFileDriverSlice.cpp" slice_cpp)
file(READ "${ITGMANIA_SOURCE_DIR}/src/RageFileDriverReadAhead.cpp" readahead_cpp)
file(READ "${ITGMANIA_SOURCE_DIR}/src/RageFileDriverReadAhead.h" readahead_h)
file(READ "${ITGMANIA_SOURCE_DIR}/src/RageFileManager_ReadAhead.cpp" helpers_cpp)
file(READ "${ITGMANIA_SOURCE_DIR}/src/RageFileDriverDeflate.cpp" deflate_cpp)
file(READ "${ITGMANIA_SOURCE_DIR}/src/RageFileDriverDeflate.h" deflate_h)
file(READ "${ITGMANIA_SOURCE_DIR}/src/Profile.cpp" profile_cpp)
file(READ "${ITGMANIA_SOURCE_DIR}/src/tests/test_file_readers.cpp" reader_tests)
file(READ "${ITGMANIA_SOURCE_DIR}/src/RageFileDriverZip.cpp" zip_cpp)
file(READ "${ITGMANIA_SOURCE_DIR}/src/RageFileDriverZip.h" zip_h)

foreach(required
    "bytes > static_cast<size_t>(std::numeric_limits<int>::max() - m_iFilePos)"
    "std::string RageFileObjMem::GetString() const"
    "RageFileObj::Seek(newPos) != newPos"
    "if ((mode & RageFile::WRITE) != 0)")
  string(FIND "${memory_cpp}" "${required}" found_at)
  if(found_at EQUAL -1)
    message(FATAL_ERROR "Missing memory-file invariant: ${required}")
  endif()
endforeach()

foreach(required
    "kMaximumCommentSize = 65535"
    "candidate + 20"
    "multi-disk ZIP archives are unsupported"
    "ZIP64 archives are unsupported"
    "IsSafeZipPath"
    "duplicate ZIP entry"
    "local and central headers disagree"
    "compressed data is outside bounds"
    "class RageFileObjZipCRC final"
    "ZIP entry CRC mismatch"
    "LockMut(m_Mutex)"
    "zipCopy.reset(m_pZip->Copy())")
  string(FIND "${zip_cpp}" "${required}" found_at)
  if(found_at EQUAL -1)
    message(FATAL_ERROR "Missing ZIP trust-boundary invariant: ${required}")
  endif()
endforeach()

foreach(required
    "bool m_bValid"
    "uint32_t m_iCRC32"
    "uint16_t m_iGeneralPurpose"
    "RageFileDriverZip(const RageFileDriverZip&) = delete")
  string(FIND "${zip_h}" "${required}" found_at)
  if(found_at EQUAL -1)
    message(FATAL_ERROR "Missing ZIP ownership invariant: ${required}")
  endif()
endforeach()

foreach(required
    "bool RageFileObjInflate::ValidateStreamEnd()"
    "Compressed stream exceeds its declared size"
    "memcpy(decomp_buf, cpy.decomp_buf, sizeof(decomp_buf))"
    "m_bDeflateFinished"
    "Gzip stream has already been started"
    "const uint16_t iSize = FileReading::read_u16_le"
    "Gzip file is too short"
    "GunzipFile(mem.release(), sError, &iCRC32)")
  string(FIND "${deflate_cpp}" "${required}" found_at)
  if(found_at EQUAL -1)
    message(FATAL_ERROR "Missing deflate/gzip invariant: ${required}")
  endif()
endforeach()

foreach(required
    "bool m_bInflateInitialized"
    "bool m_bStreamEnded"
    "bool m_bDeflateInitialized"
    "RageFileObjDeflate(const RageFileObjDeflate&) = delete")
  string(FIND "${deflate_h}" "${required}" found_at)
  if(found_at EQUAL -1)
    message(FATAL_ERROR "Missing compressed-stream ownership invariant: ${required}")
  endif()
endforeach()

string(FIND "${profile_cpp}" "actualCRC32 != expectedCompressedCRC32" found_at)
if(found_at EQUAL -1)
  message(FATAL_ERROR "Compressed profiles must verify their gzip payload CRC")
endif()

foreach(required
    "partialCopy(partial.Copy())"
    "Gunzip accepted a corrupt payload CRC"
    "Gunzip accepted an incorrect declared output size"
    "Gunzip accepted a truncated deflate stream"
    "Empty gzip stream validation failed")
  string(FIND "${reader_tests}" "${required}" found_at)
  if(found_at EQUAL -1)
    message(FATAL_ERROR "Missing compressed-stream regression coverage: ${required}")
  endif()
endforeach()

string(FIND "${memory_h}" "RageFileObjMem& operator=(const RageFileObjMem&) = delete" found_at)
if(found_at EQUAL -1)
  message(FATAL_ERROR "Memory-file handles must not be assigned implicitly")
endif()

foreach(required
    "sliceEnd > sourceSize"
    "m_pFile->Seek(target) != target"
    "offset < 0")
  string(FIND "${slice_cpp}" "${required}" found_at)
  if(found_at EQUAL -1)
    message(FATAL_ERROR "Missing file-slice invariant: ${required}")
  endif()
endforeach()

foreach(required
    "m_iFilePos < static_cast<int>(m_sBuffer.size())"
    "Read-ahead wrapper is read-only"
    "m_pFile->Seek(sourcePos) != sourcePos"
    "RageFileObj::Seek(initialPos) != initialPos"
    "std::unique_ptr<RageFileBasic> sourceCopy")
  string(FIND "${readahead_cpp}" "${required}" found_at)
  if(found_at EQUAL -1)
    message(FATAL_ERROR "Missing read-ahead wrapper invariant: ${required}")
  endif()
endforeach()

if(readahead_h MATCHES "m_bReadAheadNeeded")
  message(FATAL_ERROR "Read-ahead cache selection must not depend on stale state")
endif()

foreach(required
    "pFile == nullptr || iBytes <= 0"
    "const off_t current = lseek"
    "bytes += start"
    "iSize < iPos || iFrom < 0")
  string(FIND "${helpers_cpp}" "${required}" found_at)
  if(found_at EQUAL -1)
    message(FATAL_ERROR "Missing platform read-ahead invariant: ${required}")
  endif()
endforeach()
