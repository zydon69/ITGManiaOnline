if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

function(read_source relative_path output_var)
  file(READ "${ITGMANIA_SOURCE_DIR}/${relative_path}" contents)
  set(${output_var} "${contents}" PARENT_SCOPE)
endfunction()

function(require_contains contents needle label)
  string(FIND "${contents}" "${needle}" offset)
  if(offset EQUAL -1)
    message(FATAL_ERROR "External-content safety invariant failed: ${label}")
  endif()
endfunction()

read_source("src/RageSurface.cpp" surface)
read_source("src/RageSurfaceUtils.cpp" surface_utils)
read_source("src/RageSurface_Load.cpp" surface_loader)
read_source("src/RageSurface_Load_PNG.cpp" png_loader)
read_source("src/ScreenInstallOverlay.cpp" installer)
read_source("src/LyricsLoader.cpp" lyrics_loader)
read_source("src/RageUtil_BackgroundLoader.cpp" background_loader)

foreach(required
    "png_get_error_ptr(png)"
    "kMaxDecodedPngBytes"
    "Unsupported PNG color type"
    "Invalid PNG palette"
    "new (std::nothrow) png_byte*[height]")
  require_contains("${png_loader}" "${required}" "PNG loader: ${required}")
endforeach()

if(png_loader MATCHES "FAIL_M\\s*\\(")
  message(FATAL_ERROR "Malformed PNG data must not terminate the process")
endif()

foreach(required
    "fmt(cpy.fmt)"
    "std::make_unique<RageSurfacePalette>(*cpy.palette)"
    "std::clamp<int>(ncolors, 0, 256)"
    "std::numeric_limits<size_t>::max()"
    "new (std::nothrow) uint8_t")
  require_contains("${surface}" "${required}" "surface core: ${required}")
endforeach()

foreach(required
    "kMaxCachedSurfaceBytes"
    "palette.ncolors < 0 || palette.ncolors > 256"
    "f.Write(&h, sizeof(h)) != static_cast<int>(sizeof(h))"
    "std::unique_ptr<RageSurface> img")
  require_contains("${surface_utils}" "${required}" "surface cache: ${required}")
endforeach()

require_contains(
  "${surface_loader}" "Image decoder returned success without a surface"
  "decoders must not publish null success")
require_contains(
  "${installer}" "class ScopedMount"
  "package mounts must be released by RAII")
require_contains(
  "${installer}" "IsInstallableContentPath"
  "packages must be restricted to content roots")
if(installer MATCHES "FAIL_M\\s*\\(")
  message(FATAL_ERROR "Package mount failures must not terminate the process")
endif()

require_contains(
  "${lyrics_loader}" "matches.size() != 2"
  "lyrics parsing must tolerate an unexpected regex result")
require_contains(
  "${background_loader}" "skipped non-directory"
  "background cache cleanup must tolerate filesystem races")

message(STATUS "External-content safety invariants passed")
