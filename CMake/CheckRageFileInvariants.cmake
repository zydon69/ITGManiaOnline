if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

function(read_source relative_path output_var)
  set(path "${ITGMANIA_SOURCE_DIR}/${relative_path}")
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "RageFile invariant missing ${relative_path}")
  endif()
  file(READ "${path}" contents)
  set(${output_var} "${contents}" PARENT_SCOPE)
endfunction()

function(require_contains contents needle label)
  string(FIND "${contents}" "${needle}" offset)
  if(offset EQUAL -1)
    message(FATAL_ERROR "RageFile invariant failed: ${label}")
  endif()
endfunction()

function(require_not_contains contents needle label)
  string(FIND "${contents}" "${needle}" offset)
  if(NOT offset EQUAL -1)
    message(FATAL_ERROR "RageFile invariant failed: ${label}")
  endif()
endfunction()

read_source("src/RageFile.cpp" rage_file)
read_source("src/RageFile.h" rage_file_header)
read_source("src/RageFileBasic.cpp" rage_file_basic)
read_source("src/RageFileBasic.h" rage_file_basic_header)
read_source("src/RageFileDriverDirect.cpp" direct_driver)

require_contains(
  "${rage_file}" "m_File = FILEMAN->Open(m_Path, mode, error);"
  "normalized paths must reach the file manager")
require_contains(
  "${rage_file}" "ClearError();"
  "open must clear stale errors")
require_contains(
  "${rage_file_basic}" "std::unique_ptr<char[]> writeBuffer;"
  "buffer copies must be exception safe")
require_not_contains(
  "${rage_file_basic}"
  "memcpy(m_pWriteBuffer, cpy.m_pWriteBuffer, m_iWriteBufferUsed)"
  "copy must not use an uninitialized write-buffer length")
require_contains(
  "${rage_file_basic}" "sBuffer.clear();"
  "string reads must replace their output")
require_contains(
  "${rage_file_basic}" "Write element count is outside the supported range"
  "element writes must reject overflowing products")
require_not_contains(
  "${rage_file_basic}"
  "int iRet = Write(pBuffer, iBytes * iNmemb) / iBytes;"
  "element writes must not divide their result twice")
require_contains(
  "${rage_file_basic}" "Seek target is outside the supported range"
  "relative seek arithmetic must be checked")
require_contains(
  "${rage_file_basic}" "Partial buffered write"
  "buffered writes must preserve partial-write failures")
require_contains(
  "${rage_file_basic}" "CRC32(m_iCRC32, pBuffer, iRet);"
  "CRC must cover only bytes actually written")
require_contains(
  "${rage_file_basic}" "!m_bCRC32Enabled || iRet == nullptr"
  "CRC output pointers must be validated")
require_contains(
  "${direct_driver}" "while (written < iBytes)"
  "direct writes must complete short system writes")
require_contains(
  "${rage_file_header}" "RageFile& operator=(const RageFile& rhs) = delete;"
  "RageFile assignment ownership must be explicit")
require_contains(
  "${rage_file_basic_header}" "~RageFileObj() override;"
  "RageFileObj virtual contracts must be explicit")

message(STATUS "RageFile invariants passed")
