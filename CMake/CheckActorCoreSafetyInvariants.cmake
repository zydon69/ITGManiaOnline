if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

file(READ "${ITGMANIA_SOURCE_DIR}/src/Actor.cpp" actor_source)
file(READ "${ITGMANIA_SOURCE_DIR}/src/ActorFrame.cpp" frame_source)
file(READ "${ITGMANIA_SOURCE_DIR}/src/ActorFrame.h" frame_header)
file(READ "${ITGMANIA_SOURCE_DIR}/src/ActorUtil.cpp" util_source)
file(READ "${ITGMANIA_SOURCE_DIR}/src/AutoActor.cpp" auto_source)
file(READ "${ITGMANIA_SOURCE_DIR}/src/AutoActor.h" auto_header)
file(READ "${ITGMANIA_SOURCE_DIR}/src/Screen.cpp" screen_source)

function(require_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "Actor core safety invariant failed: ${label}")
  endif()
endfunction()

function(require_not_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(NOT position EQUAL -1)
    message(FATAL_ERROR "Actor core safety invariant failed: ${label}")
  endif()
endfunction()

require_contains(
  "${actor_source}"
  "Actor* const currentParent = m_pParent;"
  "actor assignment preserves destination parentage")
require_contains(
  "${actor_source}"
  "std::unordered_set<const Actor*> visited;"
  "actor parent walks detect cycles")
require_contains(
  "${frame_source}"
  "size_t remainingVisits = m_SubActors.size();"
  "hot child traversals are mutation bounded")
require_contains(
  "${frame_source}"
  "std::vector<std::unique_ptr<Actor>> copiedChildren;"
  "owned frame copies are transactional")
require_contains(
  "${frame_source}"
  "Publish each completed child immediately"
  "child node loading preserves InitCommand sibling visibility")
require_not_contains(
  "${frame_source}"
  "DeleteAllChildren();\n  for (std::unique_ptr<Actor>& child : loadedChildren)"
  "child node loading must not replace constructor or prior children")
require_contains(
  "${frame_header}"
  "fFOV >= 0.0f && fFOV < 180.0f"
  "FOV accepts the engine's zero orthographic sentinel")
require_contains(
  "${screen_source}"
  "SetFOV(0);"
  "screens explicitly require zero-FOV orthographic projection")
require_contains(
  "${util_source}"
  "std::unique_ptr<Actor> actor(pfn());"
  "factory actors remain owned while loading")
require_contains(
  "${util_source}"
  "if (asPaths.empty())"
  "path resolution handles filtered empty candidates")
require_not_contains(
  "${auto_header}"
  "void Load(Actor*"
  "AutoActor does not expose raw ownership loading")
require_contains(
  "${auto_source}"
  "if (pActor.get() == m_pActor.get())"
  "AutoActor rejects duplicate ownership adoption")

message(STATUS "Actor core safety invariants passed")
