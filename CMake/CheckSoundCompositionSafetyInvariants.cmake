if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

function(require_contains file needle description)
  file(READ "${ITGMANIA_SOURCE_DIR}/${file}" contents)
  string(FIND "${contents}" "${needle}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "${description}: '${needle}' missing from ${file}")
  endif()
endfunction()

require_contains(
  "src/RageSoundReader_Chain.cpp"
  "chain cursor passed a pending sound"
  "Chain reads must reject cursor discontinuities instead of stalling")
require_contains(
  "src/RageSoundReader_Chain.cpp"
  "if (iRead == RageSoundReader::END_OF_FILE)"
  "A source EOF must be distinguished from the end of the complete chain")
require_contains(
  "src/RageSoundReader_Chain.cpp"
  "chain could not advance to pending sound"
  "Mixed source exhaustion must preserve progress toward future sounds")
require_contains(
  "src/RageSoundReader_MP3.cpp"
  "emptyDecodedFrames >= 1024"
  "MP3 decoding must bound consecutive frames with no PCM output")
require_contains(
  "src/RageSoundPosMap.cpp"
  "m_iConsecutiveMinorDrifts <"
  "Long-running audio position drift counters must saturate")

message(STATUS "Sound composition safety invariants passed")
