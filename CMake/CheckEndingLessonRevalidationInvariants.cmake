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
  "src/ScreenEnding.cpp"
  "song->GetStepsByStepsType(style->m_StepsType)"
  "Ending test setup must select steps compatible with its style")
require_contains(
  "src/ScreenGameplayLesson.cpp"
  "std::unique_ptr<Actor> page(ActorUtil::MakeActor(vs[i]))"
  "Lesson pages must distinguish failed loads from AutoActor fallbacks")
require_contains(
  "src/ScreenGameplayLesson.cpp"
  "RestoreLessonControllers();\n    BeginBackingOutFromGameplay();"
  "Leaving lesson pages must restore player controllers")
require_contains(
  "src/ScreenGameplayLesson.cpp"
  "HideCurrentPageIfValid();\n      EnterLessonPlay(true);"
  "Invalid lesson page state must recover into playable gameplay")

message(STATUS "Ending and lesson revalidation invariants passed")
