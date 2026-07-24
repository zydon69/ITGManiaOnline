set(course_cpp "${ITGMANIA_SOURCE_DIR}/src/Course.cpp")
set(course_util_h "${ITGMANIA_SOURCE_DIR}/src/CourseUtil.h")
set(course_loader_cpp "${ITGMANIA_SOURCE_DIR}/src/CourseLoaderCRS.cpp")

foreach(path IN ITEMS "${course_cpp}" "${course_util_h}" "${course_loader_cpp}")
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "Missing course source: ${path}")
  endif()
endforeach()

file(READ "${course_cpp}" course_source)
file(READ "${course_util_h}" course_util_header)
file(READ "${course_loader_cpp}" course_loader_source)

function(require_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "Course safety invariant failed: ${label}")
  endif()
endfunction()

function(require_not_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(NOT position EQUAL -1)
    message(FATAL_ERROR "Course safety invariant failed: ${label}")
  endif()
endfunction()

require_contains(
  "${course_source}"
  "if (ct < COURSE_TYPE_NONSTOP || ct >= NUM_CourseType)"
  "invalid course types are rejected before state mutation")
require_contains(
  "${course_source}"
  "trail.m_vEntries.size() != SortTrail.m_vEntries.size()"
  "incompatible difficulty trails fall back without asserting")
require_contains(
  "${course_source}"
  "if (cd < Difficulty_Beginner || cd >= NUM_Difficulty)"
  "course meter difficulty is checked before array access")
require_contains(
  "${course_loader_source}"
  "StringToFloat(rawValue, valueOut)"
  "CRS attack values use strict float conversion")
require_not_contains(
  "${course_util_header}"
  "ValidateEditCourseNametName"
  "misspelled dead edit-course declaration is removed")

message(STATUS "Course safety invariants passed")
