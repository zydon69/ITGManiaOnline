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
    message(FATAL_ERROR "Forbidden pattern present: ${label}")
  endif()
endfunction()

read_source("src/NoteSkinManager.cpp" noteskin_manager_cpp)

require_contains(
  "${noteskin_manager_cpp}"
  "static std::map<std::string, std::unique_ptr<XNode>> g_ActorTemplateNodeCache"
  "NoteSkin runtime cache stores inert XNode templates")
require_contains(
  "${noteskin_manager_cpp}"
  "new XNode(*cached->second)"
  "NoteSkin runtime cache hits clone XNode templates")
require_contains(
  "${noteskin_manager_cpp}"
  "g_ActorTemplateNodeCache[cacheKey].reset(new XNode(*pNode));"
  "NoteSkin runtime cache stores a defensive XNode copy")
require_contains(
  "${noteskin_manager_cpp}"
  "NoteSkin actor XNode cache stats"
  "NoteSkin runtime cache emits diagnostic stats")
require_contains(
  "${noteskin_manager_cpp}"
  "return ActorUtil::LoadTableFromStackShowErrors(L);"
  "PushActorTemplate remains a direct Lua actor table loader")
require_contains(
  "${noteskin_manager_cpp}"
  "p->PushActorTemplate(L, sButton, sElement, false, \"4th\")"
  "Lua LoadActor binding bypasses the runtime XNode cache")

require_not_contains(
  "${noteskin_manager_cpp}"
  "g_ActorTemplateCache"
  "Do not restore the unsafe Lua table actor cache")
require_not_contains(
  "${noteskin_manager_cpp}"
  "LuaReference templateCopy"
  "Do not clone cached Lua actor tables")
require_not_contains(
  "${noteskin_manager_cpp}"
  "templateCopy.DeepCopy"
  "Do not deep-copy Lua actor tables for noteskin previews")
