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
  "src/Screen.cpp"
  "const InputScheme* inputScheme = INPUTMAPPER->GetInputScheme();"
  "Lua input dispatch must snapshot and validate the active input scheme")
require_contains(
  "src/Screen.cpp"
  "std::vector<LuaReference> callbacks;"
  "Lua input dispatch must snapshot callbacks before invoking them")
require_contains(
  "src/Screen.cpp"
  "fDelay = SanitizeNonNegativeSeconds(fDelay);"
  "Posted screen-message delays must be finite and non-negative")
require_contains(
  "src/ScreenAttract.cpp"
  "IsReadyForAttractInput(pScreen)"
  "Attract input must respect transition and input-lock state")
require_contains(
  "src/ScreenAttract.cpp"
  "IsScreenUsable(startScreenName)"
  "Attract start-screen transitions must validate their target")

message(STATUS "Screen core revalidation invariants passed")
