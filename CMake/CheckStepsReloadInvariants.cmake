file(READ "${ITGMANIA_SOURCE_DIR}/src/Steps.cpp" STEPS_CPP)
file(READ "${ITGMANIA_SOURCE_DIR}/src/Steps.h" STEPS_H)

if(STEPS_CPP MATCHES "m_bNoteDataLoadAttempted" OR
   STEPS_H MATCHES "m_bNoteDataLoadAttempted")
  message(FATAL_ERROR
    "Steps must not permanently suppress NoteData reloads after Compress()")
endif()

if(NOT STEPS_CPP MATCHES
   "const bool loaded = this->GetNoteDataFromSimfile\\(\\);")
  message(FATAL_ERROR
    "Steps::Decompress must reload file-backed NoteData when memory was released")
endif()

if(NOT STEPS_CPP MATCHES
   "ShouldLogStepsIssue\\([\n ]*\"note-data-load")
  message(FATAL_ERROR
    "Steps load warnings must be deduplicated without changing reload behavior")
endif()

if(NOT STEPS_CPP MATCHES
   "FILEMAN == nullptr \\|\\| !FILEMAN->IsAFile\\(transformedStepFile\\)")
  message(FATAL_ERROR
    "Steps must not invoke the SM loader for a fallback file that does not exist")
endif()
