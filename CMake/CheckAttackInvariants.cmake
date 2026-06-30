if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

function(read_source relative_path output_var)
  set(path "${ITGMANIA_SOURCE_DIR}/${relative_path}")
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "Missing source file: ${path}")
  endif()
  file(READ "${path}" contents)
  set("${output_var}" "${contents}" PARENT_SCOPE)
endfunction()

function(require_contains haystack needle label)
  string(FIND "${haystack}" "${needle}" found_at)
  if(found_at EQUAL -1)
    message(FATAL_ERROR "Missing invariant: ${label}")
  endif()
endfunction()

function(require_not_contains haystack needle label)
  string(FIND "${haystack}" "${needle}" found_at)
  if(NOT found_at EQUAL -1)
    message(FATAL_ERROR "Forbidden pattern: ${label}")
  endif()
endfunction()

read_source("src/Attack.cpp" attack_cpp)
read_source("src/Attack.h" attack_h)
read_source("src/CourseLoaderCRS.cpp" course_loader_crs_cpp)
read_source("src/CourseWriterCRS.cpp" course_writer_crs_cpp)

require_contains(
  "${attack_h}"
  "inline constexpr float ATTACK_STARTS_NOW"
  "Attack starts-now sentinel is typed and scoped by C++")
require_not_contains(
  "${attack_h}"
  "#define ATTACK_STARTS_NOW"
  "Attack starts-now sentinel must not be a macro")
require_contains(
  "${attack_h}"
  "If this is ATTACK_STARTS_NOW"
  "Attack starts-now documentation names the real sentinel")
require_contains(
  "${attack_cpp}"
  "static void WarnAttack"
  "Attack warnings are routed through a log-safe helper")
require_contains(
  "${attack_cpp}"
  "if (LOG != nullptr)"
  "Attack warning helper guards LOG")
require_contains(
  "${attack_cpp}"
  "SanitizeModifiersForSerialization"
  "Attack serialization has a shared modifier sanitizer")
require_contains(
  "${attack_cpp}"
  "c == ':' || c == ';' || c == '\\r' || c == '\\n'"
  "Attack modifier serialization strips MSD delimiters")
require_contains(
  "${attack_cpp}"
  "GLOBAL_COURSE_MODIFIER_DURATION_SECONDS"
  "Global course modifier duration is named")
require_contains(
  "${attack_cpp}"
  "Trim(fragment)"
  "Attack GetNumAttacks ignores whitespace-only fragments")
require_not_contains(
  "${attack_cpp}"
  "#define EQUAL"
  "Attack equality must not leave a local macro defined")
require_contains(
  "${course_loader_crs_cpp}"
  "ParseCRSAttackFloat"
  "CRS attack parser rejects non-finite floats")
require_contains(
  "${course_loader_crs_cpp}"
  "std::isfinite(valueOut)"
  "CRS attack parser checks finite values")
require_contains(
  "${course_loader_crs_cpp}"
  "auto resetAttack"
  "CRS attack parser resets per-entry state")
require_contains(
  "${course_loader_crs_cpp}"
  "resetAttack();"
  "CRS attack parser clears state after malformed or completed attacks")
require_contains(
  "${course_writer_crs_cpp}"
  "Attack::SanitizeModifiersForSerialization"
  "CRS writer uses shared attack modifier sanitizer")
