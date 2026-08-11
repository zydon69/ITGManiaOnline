if(NOT DEFINED ITGMANIA_SOURCE_DIR)
  message(FATAL_ERROR "ITGMANIA_SOURCE_DIR is required")
endif()

function(read_source relative_path output_var)
  set(path "${ITGMANIA_SOURCE_DIR}/${relative_path}")
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "Log hygiene invariant missing ${relative_path}")
  endif()
  file(READ "${path}" contents)
  set(${output_var} "${contents}" PARENT_SCOPE)
endfunction()

function(require_contains contents needle label)
  string(FIND "${contents}" "${needle}" offset)
  if(offset EQUAL -1)
    message(FATAL_ERROR "Log hygiene invariant failed: ${label}")
  endif()
endfunction()

function(require_not_contains contents needle label)
  string(FIND "${contents}" "${needle}" offset)
  if(NOT offset EQUAL -1)
    message(FATAL_ERROR "Log hygiene invariant failed: ${label}")
  endif()
endfunction()

read_source("src/ScreenGameplay.cpp" screen_gameplay)
read_source("src/ScreenStatsOverlay.cpp" stats_overlay)
read_source("src/GameLoop.cpp" game_loop)
read_source("src/RageLog.cpp" rage_log)
read_source("src/ThemeManager.cpp" theme_manager)
read_source("src/GameState.cpp" game_state)
read_source("src/ScreenOptionsMaster.cpp" options_master)
read_source("src/NoteDataUtil.cpp" note_data_util)
read_source("src/Steps.cpp" steps)
read_source("src/PerfDiagnostics.h" perf_diagnostics_header)
read_source("src/PerfDiagnostics.cpp" perf_diagnostics)
read_source("src/PrefsManager.cpp" prefs_manager)
read_source("src/SongManager.cpp" song_manager)
read_source("src/SongCacheIndex.cpp" song_cache_index)
read_source("src/NotesLoaderSSC.cpp" notes_loader_ssc)
read_source("src/TeejusbFsrManager.cpp" teejusb_fsr_manager)
read_source("src/archutils/Win32/GraphicsWindow.cpp" graphics_window_win32)
read_source("Themes/Simply Love/metrics.ini" simply_love_metrics)
read_source(
  "src/arch/LowLevelWindow/LowLevelWindow_Win32.cpp"
  low_level_window_win32)
read_source(
  "src/arch/MemoryCard/MemoryCardDriverThreaded_Windows.cpp"
  memory_card_windows)
read_source("Themes/Simply Love/Scripts/SL-Helpers.lua" sl_helpers)
read_source("Themes/Simply Love/Scripts/SL-ITGOnlineClient.lua" online_client)
read_source("Themes/Simply Love/Scripts/99 SL-ThemePrefs.lua" theme_prefs)
read_source("Themes/Simply Love/BGAnimations/ScreenGameplay overlay/TrackExScoreJudgments.lua" score_tracker)

require_not_contains(
  "${screen_gameplay}" "GAMEPLAY_FRAME_HITCH"
  "gameplay must not duplicate the centralized frame hitch detector")
require_contains(
  "${game_loop}" "incoming_delta_hitch"
  "frame hitch diagnostics must remain centralized and preference-gated")
require_not_contains(
  "${game_loop}" "allowWhenDisabled"
  "frame hitch diagnostics must never bypass the diagnostics preference")
require_contains(
  "${game_loop}" "static void TraceFpsDrop() {\n  if (!PerfDiagnosticsEnabled())"
  "FPS-drop diagnostics must remain preference-gated")
require_contains(
  "${stats_overlay}" "PerfDiagnosticsEnabled() ||"
  "performance diagnostics must include exact visible drop timestamps")
require_contains(
  "${rage_log}" "const bool writeToMainLog"
  "user content diagnostics must be isolated from the engine log")
require_contains(
  "${rage_log}" "m_bInfoToDisk && (where & WRITE_TO_INFO)"
  "info.txt writes must honor their dedicated preference")
require_contains(
  "${rage_log}" "(!b || (g_fileLog->IsOpen() && g_fileTimeLog->IsOpen()))"
  "failed log file opens must remain retryable")
require_contains(
  "${rage_log}" "if (g_fileUserLog->IsOpen())"
  "flush must skip closed log files")
require_contains(
  "${rage_log}" "if (m_bShowLogOutput == show)"
  "console output changes must be idempotent")
require_contains(
  "${rage_log}" "if (n < 0 || n >= BACKLOG_LINES"
  "recent-log lookup must reject negative indexes")
require_contains(
  "${perf_diagnostics_header}" "PRINTF(1, 2)"
  "review-src diagnostics must retain compile-time format checking")
require_contains(
  "${perf_diagnostics}" "LogWindowsEventDiagnosticsEnabled()"
  "Win32 event diagnostics must have a dedicated gate")
require_not_contains(
  "${graphics_window_win32}"
  "CHECKPOINT_M(ssprintf(\"%p, %u, %08x, %08x\""
  "Win32 window messages must not flood generic checkpoint logs")
require_contains(
  "${graphics_window_win32}" "WIN32_EVENT_TRACE"
  "opt-in Win32 event traces must remain identifiable")
require_contains(
  "${simply_love_metrics}"
  "LineLogWindowsEventDiagnostics=\"conf,LogWindowsEventDiagnostics\""
  "Win32 event diagnostics must remain configurable")
require_contains(
  "${prefs_manager}"
  "TranslateDeprecatedFlags();\n  ResetNonEssentialDiagnosticsForCurrentBuild();\n  RefreshPerfDiagnosticsPreferenceCache();"
  "factory reset must refresh diagnostic preference caches")
require_contains(
  "${prefs_manager}" "m_bLogSkips(\"LogSkips\", false)"
  "frame-skip logging must be opt-in by default")
require_contains(
  "${prefs_manager}" "m_bLogCheckpoints(\"LogCheckpoints\", false)"
  "generic checkpoint logging must be opt-in by default")
require_contains(
  "${prefs_manager}" "m_bShowLogOutput(\"ShowLogOutput\", false)"
  "the platform log window must be disabled by default")
require_contains(
  "${prefs_manager}" "ResetNonEssentialDiagnosticsForCurrentBuild()"
  "persisted diagnostics must be reset once for every compiled build")
require_contains(
  "${perf_diagnostics}" "\"DiagnosticsResetBuildId\", \"\""
  "the engine diagnostics reset must remember the current build")
require_contains(
  "${perf_diagnostics}" "\"ShowLogOutput\","
  "the per-build diagnostics reset must close the log window")
require_not_contains(
  "${song_manager}" "skipped invalid course file"
  "unavailable dynamic courses must not be reported as invalid files")
require_contains(
  "${song_manager}" "CONTENT_TRACE: skipped unavailable or invalid course"
  "unplayable course diagnostics must be content-gated")
require_contains(
  "${song_cache_index}" "bCacheIndexExists || LogContentLoadDiagnosticsEnabled()"
  "an absent first-run song cache index must stay quiet by default")
require_contains(
  "${notes_loader_ssc}" "if (LogContentLoadDiagnosticsEnabled())"
  "invalid external scroll ratios must be content-gated and rate-limited")
require_contains(
  "${teejusb_fsr_manager}" "if (!DoesFileExist(kAssignmentsPath))"
  "the optional FSR assignment file must not emit a failed-read trace")
require_not_contains(
  "${low_level_window_win32}"
  "const char* errToPrint = hr_ssprintf"
  "Win32 rendering errors must not retain a dangling temporary string")
require_not_contains(
  "${memory_card_windows}" "LOG->Trace(sDrive.c_str())"
  "dynamic strings must not be interpreted as logger format strings")
require_contains(
  "${theme_manager}" "THEME_TRACE: lua_scripts_loaded"
  "theme script diagnostics must be summarized per theme")
require_not_contains(
  "${theme_manager}" "THEME_TRACE: lua_script_load path"
  "theme diagnostics must not emit one line per script")
require_not_contains(
  "${game_state}" "JoinPlayer ignored duplicate join"
  "idempotent joins must not be warnings")
require_contains(
  "${options_master}" "if (!GAMESTATE->IsHumanPlayer(pn))"
  "force-all-player screens must avoid duplicate join requests")
require_contains(
  "${note_data_util}" "LOG->UserLog("
  "malformed note-data diagnostics must use the content log")
require_contains(
  "${steps}" "uses unsupported style"
  "unsupported chart styles must use the content log")
require_contains(
  "${sl_helpers}" "visualStyle == \"Technique\" and \"Arrows\""
  "Technique fallback banners must explicitly reuse Arrows assets")
require_contains(
  "${score_tracker}" "traceCounts[reason] % 250"
  "per-judgment score traces must be aggressively sampled")
require_contains(
  "${online_client}" "ITGOnline.onlineFlowLoggingDefaultEnabled = false"
  "online flow diagnostics must be opt-in before preferences load")
require_contains(
  "${online_client}" "[\"OnlineTrace\"] = \"false\""
  "the generated online debug configuration must be quiet")
require_contains(
  "${online_client}" "[\"BuildId\"] = buildId"
  "online debug overrides must reset for every compiled build")
require_not_contains(
  "${online_client}" "ITGOnline.onlineFlowLoggingDefaultEnabled = true"
  "online flow diagnostics must never be enabled by a hard-coded default")
require_contains(
  "${online_client}" "song_availability_pack_sync_match_pending"
  "local hashing must be logged as a pending availability state")
require_contains(
  "${online_client}" "online_score_trace(\"ignored_stale_score_leaderboard"
  "stale score snapshots must use the dedicated score diagnostics gate")
foreach(pref_name IN ITEMS
    ITGOnlineGameplayLayoutLogs
    ITGOnlineNetworkLogs
    ITGOnlineAuthLogs
    ITGOnlineScoreLogs)
  require_contains(
    "${theme_prefs}" "${pref_name} = {\n\t\t\tDefault = false"
    "${pref_name} must remain disabled by default")
endforeach()
require_contains(
  "${theme_prefs}" "DiagnosticsResetBuildId = {"
  "theme diagnostic preferences must remember the current build")
require_contains(
  "${theme_prefs}" "ThemePrefs.Set(pref_name, false)"
  "theme diagnostic preferences must reset on a newly compiled build")

message(STATUS "Log hygiene invariants passed")
