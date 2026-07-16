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

read_source("src/LuaBinding.cpp" lua_binding_cpp)
read_source("src/OptionsBinding.h" options_binding_h)
read_source("src/PlayerOptions.cpp" player_options_cpp)
read_source("src/Player.cpp" player_cpp)

require_contains(
  "${lua_binding_cpp}"
  "!std::isfinite(s) || s < 0"
  "nonnegative Lua float arguments also reject NaN and infinity")
require_contains(
  "${options_binding_h}"
  "if (!std::isfinite(v) || !valid)"
  "all direct Lua float setters enforce finite values")
require_contains(
  "${player_options_cpp}"
  "StepsContainQuadsForPlayer(pSteps, pn)"
  "NoQuads disqualification distinguishes per-player quads from hands")
require_contains(
  "${player_options_cpp}"
  "timing == nullptr || timing->IsJudgableAtRow(row)"
  "NoQuads inspection uses the chart timing rather than global gameplay timing")
require_contains(
  "${player_options_cpp}"
  "SplitCompositeOrStackedNoteData"
  "NoQuads inspection separates couple and routine player ownership")
require_contains(
  "${player_options_cpp}"
  "IsEasierForSongAndSteps(e.pSong, e.pSteps, m_pn)"
  "course disqualification uses the owning player slot")
require_not_contains(
  "${player_options_cpp}"
  "IsEasierForSongAndSteps(e.pSong, e.pSteps, PLAYER_1)"
  "course disqualification must not force player one radar values")

require_contains(
  "${player_cpp}"
  "std::set<int> m_JudgedRows"
  "judged rows allocate by actual judged-row count instead of row index")
require_not_contains(
  "${player_cpp}"
  "std::vector<bool> m_vRows"
  "judged rows must not resize up to a sparse or corrupt row number")
require_contains(
  "${player_cpp}"
  "m_pIterUnjudgedMineRows = unjudgedMineRows.release();\n  m_bLoaded = true;"
  "Player becomes loaded only after every judging iterator is ready")
require_contains(
  "${player_cpp}"
  "std::make_unique<NoteData::all_tracks_iterator>"
  "judging iterators are prepared transactionally")
require_contains(
  "${player_cpp}"
  "iTrack >= m_NoteData.GetNumTracks() || iTrack >= styleTracks"
  "grouped holds validate note-data and style track bounds")
require_contains(
  "${player_cpp}"
  "Invalid early tap score %i at row %i track %i"
  "grouped holds normalize corrupt tap-result enums")
require_contains(
  "${player_cpp}"
  "Player::UpdateHoldNotes active seconds product"
  "hold active-time multiplication is checked after multiplication")
require_contains(
  "${player_cpp}"
  "fLifeFraction = std::clamp(fLifeFraction, 0.0f, 1.0f);"
  "hold life fractions stay in their documented range")
require_contains(
  "${player_cpp}"
  "if (!m_bLoaded || GAMESTATE == nullptr"
  "Player rendering requires a completely loaded instance")
require_contains(
  "${player_cpp}"
  "!IsValidPlayerNumberForPlayer(m_pPlayerState->m_PlayerNumber)"
  "life APIs reject invalid player identities")
require_contains(
  "${player_cpp}"
  "std::clamp<int64_t>(searchRows, 0, MAX_NOTE_ROW)"
  "step search distance cannot overflow signed integers")
require_contains(
  "${player_cpp}"
  "const int calorieTracks ="
  "calorie input inspection is bounded by note data and style columns")
require_contains(
  "${player_cpp}"
  "AddPlayerCaloriesSaturated"
  "calorie accumulation remains finite")
require_contains(
  "${player_cpp}"
  "Consuming attack note without target player"
  "untargetable attack notes are consumed instead of retriggered")
