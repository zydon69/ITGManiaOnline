if(NOT DEFINED SM_ROOT_DIR OR NOT DEFINED SM_SRC_DIR OR NOT DEFINED SM_GENERATED_SRC_DIR)
  message(FATAL_ERROR "GenerateVerstub.cmake requires SM_ROOT_DIR, SM_SRC_DIR and SM_GENERATED_SRC_DIR")
endif()

execute_process(
  COMMAND git rev-parse --short HEAD
  WORKING_DIRECTORY "${SM_ROOT_DIR}"
  OUTPUT_VARIABLE generated_git_hash
  RESULT_VARIABLE git_result
  OUTPUT_STRIP_TRAILING_WHITESPACE)

if(NOT git_result EQUAL 0)
  set(generated_git_hash "UNKNOWN")
endif()

if(WITH_FULL_RELEASE)
  set(generated_product_version "${SM_VERSION_TRADITIONAL}")
elseif(WITH_NIGHTLY_RELEASE)
  set(generated_product_version "${SM_VERSION_TRADITIONAL}-NIGHTLY-git-${generated_git_hash}")
else()
  set(generated_product_version "${SM_VERSION_TRADITIONAL}-git-${generated_git_hash}")
endif()

set(output_path "${SM_GENERATED_SRC_DIR}/verstub.cpp")
file(READ "${SM_SRC_DIR}/verstub.cpp.in" template_content)

function(render_verstub output_var generated_date generated_time)
  set(rendered "${template_content}")
  string(REPLACE "@SM_VERSION_MAJOR@" "${SM_VERSION_MAJOR}" rendered "${rendered}")
  string(REPLACE "@SM_VERSION_MINOR@" "${SM_VERSION_MINOR}" rendered "${rendered}")
  string(REPLACE "@SM_VERSION_PATCH@" "${SM_VERSION_PATCH}" rendered "${rendered}")
  string(REPLACE "@SM_VERSION_GIT_HASH@" "${generated_git_hash}" rendered "${rendered}")
  string(REPLACE "@SM_VERSION_TRADITIONAL@" "${SM_VERSION_TRADITIONAL}" rendered "${rendered}")
  string(REPLACE "@SM_TIMESTAMP_DATE@" "${generated_date}" rendered "${rendered}")
  string(REPLACE "@SM_TIMESTAMP_TIME@" "${generated_time}" rendered "${rendered}")
  string(REPLACE "@SM_VERSION_GIT@" "${generated_product_version}" rendered "${rendered}")
  set("${output_var}" "${rendered}" PARENT_SCOPE)
endfunction()

string(TIMESTAMP build_date "%Y%m%d")
string(TIMESTAMP build_time "%H:%M:%S" UTC)
render_verstub(candidate_content "${build_date}" "${build_time}")
if(EXISTS "${output_path}")
  file(READ "${output_path}" current_content)
  if(current_content STREQUAL candidate_content)
    return()
  endif()
endif()

file(MAKE_DIRECTORY "${SM_GENERATED_SRC_DIR}")
file(WRITE "${output_path}" "${candidate_content}")
