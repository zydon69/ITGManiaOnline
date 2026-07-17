if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

set(high_score_source "${ITGMANIA_SOURCE_DIR}/src/HighScore.cpp")
set(evaluation_header "${ITGMANIA_SOURCE_DIR}/src/ScreenEvaluation.h")
foreach(path IN ITEMS "${high_score_source}" "${evaluation_header}")
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "Missing high-score revalidation source: ${path}")
  endif()
endforeach()

file(READ "${high_score_source}" high_score)
file(READ "${evaluation_header}" evaluation)

function(require_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(position EQUAL -1)
    message(FATAL_ERROR "HighScore revalidation invariant failed: ${label}")
  endif()
endfunction()

function(require_not_contains content needle label)
  string(FIND "${content}" "${needle}" position)
  if(NOT position EQUAL -1)
    message(FATAL_ERROR "HighScore revalidation invariant failed: ${label}")
  endif()
endfunction()

require_contains("${high_score}" "bDisqualified = false;"
  "new scores initialize disqualification")
require_contains("${high_score}" "*this = HighScoreImpl();"
  "XML loading starts from canonical defaults")
require_contains("${high_score}" "SanitizePercentDP"
  "persisted percentages are finite and bounded")
require_contains("${high_score}" "iIndexOut = -1;"
  "rejected scores clear their output rank")
require_contains("${high_score}" "static const HighScore hs;"
  "empty lists expose an immutable fallback score")
require_contains("${high_score}" "MAX_REASONABLE_HIGH_SCORE_LIMIT"
  "imported and configured score lists remain bounded")
require_contains("${high_score}" "return lhs == rhs;"
  "score equality is an equivalence relation suitable for std::unique")
require_not_contains("${high_score}" "std::fabs(lhs - rhs) <= 0.000001f"
  "score equality does not use a non-transitive epsilon relation")
require_contains("${high_score}" "if (!ShouldDeduplicateHighScoreName(i->GetName()))"
  "empty names and fill-in markers are not collapsed")
require_contains("${evaluation}" "void PushSelf(lua_State* L) override;"
  "evaluation Lua binding retains its Actor override contract")

message(STATUS "HighScore revalidation invariants passed")
