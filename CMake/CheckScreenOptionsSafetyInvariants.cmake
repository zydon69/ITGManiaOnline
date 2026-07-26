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

function(require_not_contains file needle description)
  file(READ "${ITGMANIA_SOURCE_DIR}/${file}" contents)
  string(FIND "${contents}" "${needle}" position)
  if(NOT position EQUAL -1)
    message(FATAL_ERROR "${description}: forbidden '${needle}' remains in ${file}")
  endif()
endfunction()

require_contains(
  "src/ScreenSetTime.cpp"
  "SafeSubtractTime(adjustedTime, now, newOffset)"
  "ScreenSetTime offset subtraction must be checked")
require_contains(
  "src/ScreenSetTime.cpp"
  "HOOKS == nullptr || !HOOKS->SetTime(adjusted)"
  "ScreenSetTime must preserve OS set-time failures")
require_contains(
  "src/ScreenSetTime.cpp"
  "Cancel(SM_GoToPrevScreen)"
  "ScreenSetTime back navigation must use the menu cancellation lifecycle")
require_contains(
  "src/ScreenSongOptions.cpp"
  "ExportOptionsAndGetChangeMask("
  "Song option export must observe whether the parent actually exported")
require_contains(
  "src/ScreenSongOptions.cpp"
  "before.current != options.GetCurrent().m_FailType"
  "Explicit fail detection must cover every option level")
require_not_contains(
  "src/ScreenSongOptions.cpp"
  "m_In.StartTransitioning()"
  "Song option initialization must not start its transition early")
require_contains(
  "src/ScreenOptions.cpp"
  "if (m_sprPage.IsLoaded())"
  "ScreenOptions must not dereference a missing page actor")
require_contains(
  "src/ScreenOptions.cpp"
  "if (m_sprLineHighlight[p].IsLoaded())"
  "ScreenOptions must not dereference a missing line highlight")
require_contains(
  "src/ScreenOptions.cpp"
  "if (m_sprMore.IsLoaded())"
  "ScreenOptions must not dereference a missing more actor")
require_contains(
  "src/ScreenOptions.cpp"
  "std::isfinite(configuredTweenSeconds)"
  "ScreenOptions cursor tween duration must be finite")
require_contains(
  "src/ScreenOptions.cpp"
  "focusedChoice >= static_cast<int>(row.GetRowDef().m_vsChoices.size())"
  "ScreenOptions must preserve stored focus when no valid choice exists")
require_contains(
  "src/ScreenOptions.cpp"
  "iCurrentChoiceWithFocus >= iNumChoices"
  "ScreenOptions absolute changes must normalize stale focus")
require_contains(
  "src/ScreenPlayerOptions.cpp"
  "if (m_sprDisqualify[p].IsLoaded())"
  "ScreenPlayerOptions must not dereference a missing disqualification actor")
require_contains(
  "src/ScreenPlayerOptions.cpp"
  "row->GetRowType() == OptionRow::RowType_Exit"
  "Player option preset synchronization must not export or import the exit row")
require_contains(
  "src/ScreenPlayerOptions.cpp"
  "UpdateDisqualified(rowIndex, pn)"
  "Player option preset imports must refresh disqualification state")
require_contains(
  "src/ScreenPlayerOptions.cpp"
  "row->Reload()"
  "Player option preset imports must refresh dynamic row availability")
require_contains(
  "src/ScreenPlayerOptions.cpp"
  "GameplayPresetRenameRequested"
  "Start on the gameplay preset row must open rename flow instead of leaving options")
require_contains(
  "src/ScreenPlayerOptions.cpp"
  "row->GetRowDef().m_sName == \"GameplayPresets\""
  "Gameplay preset rename must inspect the option handler name, not the actor name")
require_not_contains(
  "src/ScreenPlayerOptions.cpp"
  "row->GetName() == \"GameplayPresets\""
  "Gameplay preset rename must not inspect the unrelated actor name")
require_contains(
  "src/ScreenPlayerOptions.cpp"
  "ExportOptionsForPlayer(pn, rowIndex)"
  "Renaming a preset must preserve edits made on the current option page")
require_contains(
  "Themes/Simply Love/Scripts/SL-PlayerProfiles.lua"
  "SL_GameplayPresets = SL_GameplayPresets or {}"
  "Gameplay presets must tolerate the real theme-script load order")
require_contains(
  "Themes/Simply Love/metrics.ini"
  "local lines = \"GameplayPresets,SpeedModType"
  "Gameplay presets must remain first while speed type remains the initial editable row")
require_contains(
  "Themes/Simply Love/metrics.ini"
  "[ScreenTextEntry]\nQuestionY=_screen.cy-64\nQuestionOnCommand=_wrapwidthpixels,600\nAnswerY=_screen.cy+16\nPlayMusic=false"
  "Text entry overlays must preserve the song preview playing underneath")
require_contains(
  "Themes/Simply Love/Languages/en.ini"
  "GameplayPresets=Choose one of six per-profile gameplay presets.\n"
  "English gameplay preset help must remain a single concise sentence")
require_contains(
  "Themes/Simply Love/Languages/fr.ini"
  "GameplayPresets=Choisis l'un des six préréglages de gameplay propres au profil.\n"
  "French gameplay preset help must remain a single concise sentence")
require_not_contains(
  "Themes/Simply Love/Languages/en.ini"
  "GameplayPresets=Choose one of six per-profile gameplay presets.\\n"
  "English gameplay preset help must not regain additional paragraphs")
require_not_contains(
  "Themes/Simply Love/Languages/fr.ini"
  "GameplayPresets=Choisis l'un des six préréglages de gameplay propres au profil.\\n"
  "French gameplay preset help must not regain additional paragraphs")
require_contains(
  "Themes/Simply Love/BGAnimations/ScreenPlayerOptions overlay/default.lua"
  "ScreenOptions:SetOptionRowIndex(player, SpeedModTypeRowIndex)"
  "Player options must initially focus the speed type row")
require_contains(
  "Themes/Simply Love/BGAnimations/ScreenPlayerOptions overlay/default.lua"
  "GameplayPresetRenamedMessageCommand=function(self, params)"
  "Preset rename must have a dedicated label-only refresh path")
require_contains(
  "Themes/Simply Love/BGAnimations/ScreenPlayerOptions overlay/default.lua"
  "if pn then self:playcommand(\"Set\"..pn..\"Preset\") end"
  "Preset rename must refresh only the renamed player's label")
require_contains(
  "Themes/Simply Love/Graphics/OptionRow Frame.lua"
  "type(overlay.GetChild) == \"function\""
  "Option preview refresh must tolerate a modal or destroyed overlay")
require_contains(
  "Themes/Simply Love/Scripts/SL-PlayerProfiles.lua"
  "function GameplayPresets:Save(player)"
  "Gameplay presets must expose a targeted persistence path")
require_contains(
  "Themes/Simply Love/Scripts/SL-PlayerProfiles.lua"
  "settings.ColumnFlashOnMiss = nil"
  "Every gameplay preset slot must remove the deprecated flash setting")
require_not_contains(
  "Themes/Simply Love/Scripts/SL-PlayerProfiles.lua"
  "PROFILEMAN.SaveProfile gameplay preset rename"
  "Preset rename must not rewrite the entire profile and Stats.xml")
require_contains(
  "src/ScreenPlayerOptions.cpp"
  "Message message(\"GameplayPresetOptionsExported\")"
  "Accepted player-option exports must trigger targeted preset persistence")
require_contains(
  "Themes/Simply Love/BGAnimations/ScreenPlayerOptions overlay/default.lua"
  "GameplayPresetOptionsExportedMessageCommand=function(self)"
  "Every player-options page must persist presets after its complete export")
require_not_contains(
  "Themes/Simply Love/Scripts/SL-PlayerOptions.lua"
  "PersistGameplayPreset(pn)"
  "Individual option-row exports must never trigger disk writes")
require_contains(
  "src/OptionRowHandler.h"
  "ExportOptionForPreview"
  "Option row handlers must expose an explicitly side-effect-free preview path")
require_contains(
  "src/OptionRowHandler.cpp"
  "GAMESTATE->ApplyPreferredModifiers("
  "Option row previews must apply only the preferred modifiers needed for disqualification")
require_contains(
  "src/OptionRow.cpp"
  "ExportOptionsInternal(vpns, bRowHasFocus, true)"
  "Option rows must route previews separately from real exports")
require_contains(
  "src/ScreenOptionsMaster.cpp"
  "row->ExportOptionsForPreview(validPlayers, bRowHasFocus)"
  "Screen option previews must use the preview export path")
require_not_contains(
  "src/ScreenPlayerOptions.cpp"
  "ScreenOptionsPreviewExport"
  "ScreenPlayerOptions must not rely on an unread Lua thread variable for preview isolation")

message(STATUS "Screen options safety invariants passed")
