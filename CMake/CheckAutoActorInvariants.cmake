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

function(require_source_tree_not_contains needle label)
  file(GLOB_RECURSE source_files
       "${ITGMANIA_SOURCE_DIR}/src/*.cpp"
       "${ITGMANIA_SOURCE_DIR}/src/*.h")
  foreach(source_file IN LISTS source_files)
    file(READ "${source_file}" contents)
    string(FIND "${contents}" "${needle}" found_at)
    if(NOT found_at EQUAL -1)
      message(FATAL_ERROR "Forbidden source tree pattern in ${source_file}: ${label}")
    endif()
  endforeach()
endfunction()

read_source("src/AutoActor.cpp" auto_actor_cpp)
read_source("src/AutoActor.h" auto_actor_h)

require_contains(
  "${auto_actor_h}"
  "#include <memory>"
  "AutoActor exposes explicit ownership types")
require_contains(
  "${auto_actor_h}"
  "std::unique_ptr<Actor> m_pActor;"
  "AutoActor owns actors through unique_ptr")
require_contains(
  "${auto_actor_h}"
  "AutoActor(AutoActor&& cpy) noexcept;"
  "AutoActor declares move construction")
require_contains(
  "${auto_actor_h}"
  "AutoActor& operator=(AutoActor&& cpy) noexcept;"
  "AutoActor declares move assignment")
require_contains(
  "${auto_actor_h}"
  "void Adopt(std::unique_ptr<Actor> pActor);"
  "AutoActor has an explicit ownership adoption API")
require_contains(
  "${auto_actor_h}"
  "void LoadFallback();"
  "AutoActor has an explicit fallback actor loader")
require_contains(
  "${auto_actor_h}"
  "Actor* Get()"
  "AutoActor has named pointer accessors")
require_contains(
  "${auto_actor_h}"
  "private:\n  void Load(Actor* pActor);"
  "AutoActor keeps raw pointer adoption out of the public API")

require_contains(
  "${auto_actor_cpp}"
  "#include \"ActorFrame.h\""
  "AutoActor can detach from parent frames before deletion")
require_contains(
  "${auto_actor_cpp}"
  "void DetachFromParent(Actor* actor)"
  "AutoActor centralizes parent detach before unload")
require_contains(
  "${auto_actor_cpp}"
  "parentFrame->RemoveChild(actor);"
  "AutoActor removes an owned actor from its parent frame before deletion")
require_contains(
  "${auto_actor_cpp}"
  "actor->SetParent(nullptr);"
  "AutoActor clears unexpected non-frame parents defensively")
require_contains(
  "${auto_actor_cpp}"
  "m_pActor.reset();"
  "AutoActor resets ownership through unique_ptr")
require_contains(
  "${auto_actor_cpp}"
  "void AutoActor::LoadFallback()"
  "AutoActor centralizes fallback actor creation")
require_not_contains(
  "${auto_actor_cpp}"
  "delete m_pActor"
  "AutoActor must not delete the owned actor without parent detach")

require_contains(
  "${auto_actor_cpp}"
  "AutoActor tmp(cpy);"
  "AutoActor copy assignment builds a temporary before replacing")
require_contains(
  "${auto_actor_cpp}"
  "std::swap(m_pActor, tmp.m_pActor);"
  "AutoActor copy assignment swaps only after the clone succeeds")
require_contains(
  "${auto_actor_cpp}"
  "std::unique_ptr<Actor> actor(ActorUtil::MakeActor(sPath));"
  "AutoActor path load builds the replacement before unload")
require_contains(
  "${auto_actor_cpp}"
  "std::unique_ptr<Actor> actor(ActorUtil::LoadFromNode(pNode, pParent));"
  "AutoActor node load builds the replacement before unload")

require_contains(
  "${auto_actor_cpp}"
  "THEME == nullptr || !THEME->IsThemeLoaded()"
  "AutoActor refuses theme loads without a loaded theme")
require_contains(
  "${auto_actor_cpp}"
  "THEME->GetPathInfo(pi, EC_BGANIMATIONS, sMetricsGroup, sElement, true)"
  "AutoActor background theme load uses optional path lookup")
require_contains(
  "${auto_actor_cpp}"
  "THEME->GetPathG(sScreenName, sActorName, true)"
  "AutoActor named theme load uses optional path lookup")
require_contains(
  "${auto_actor_cpp}"
  "THEME != nullptr && THEME->IsThemeLoaded()"
  "AutoActor loads theme commands only while a theme is loaded")
require_not_contains(
  "${auto_actor_cpp}"
  "GetPathInfo(pi, EC_BGANIMATIONS, sMetricsGroup, sElement);"
  "AutoActor must not use non-optional background theme paths")
require_not_contains(
  "${auto_actor_cpp}"
  "GetPathG(sScreenName, sActorName));"
  "AutoActor must not use non-optional named theme paths")
require_source_tree_not_contains(
  ".Load(new Actor"
  "Callers must use AutoActor::LoadFallback or explicit unique_ptr adoption")
require_source_tree_not_contains(
  ".Load(NOTESKIN->LoadActor"
  "Callers must wrap raw factory ownership in AutoActor::Adopt")
