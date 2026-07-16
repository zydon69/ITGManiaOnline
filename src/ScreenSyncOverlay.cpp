#include "ScreenSyncOverlay.h"

#include <algorithm>
#include <cmath>
#include <string>
#include <utility>
#include <vector>

#include "AdjustSync.h"
#include "Actor.h"
#include "GameConstantsAndTypes.h"
#include "GamePreferences.h"
#include "GameState.h"
#include "InputEventPlus.h"
#include "InputFilter.h"
#include "LocalizedString.h"
#include "MessageManager.h"
#include "PerfDiagnostics.h"
#include "PrefsManager.h"
#include "RageInputDevice.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "Screen.h"
#include "ScreenManager.h"
#include "Song.h"
#include "SongOptions.h"
#include "Steps.h"
#include "ThemeManager.h"
#include "TimingSegments.h"
#include "global.h"

namespace {
constexpr float MIN_SYNC_BPS = 0.001f;

bool IsFinite(float value) { return std::isfinite(value); }

void WarnSyncOverlay(const std::string& message) {
  if (LOG != nullptr) {
    LOG->Warn("ScreenSyncOverlay: %s", message.c_str());
  }
}

int GetAutosyncSampleDisplayCount() {
  return std::min(
      std::max(AdjustSync::s_iAutosyncOffsetSample + 1, 1),
      AdjustSync::OFFSET_SAMPLE_COUNT);
}

bool IsValidAutosyncType(AutosyncType type) {
  switch (type) {
    case AutosyncType_Off:
    case AutosyncType_Song:
    case AutosyncType_Machine:
    case AutosyncType_Tempo:
      return true;
    default:
      return false;
  }
}

bool PrepareBPSDelta(
    TimingData& timing, float beat, float delta, BPMSegment*& segment,
    float& new_bps) {
  segment = nullptr;
  new_bps = 0.0f;
  if (!IsFinite(beat) || !IsFinite(delta)) {
    return false;
  }
  if (timing.GetTimingSegments(SEGMENT_BPM).empty()) {
    return false;
  }

  segment = timing.GetBPMSegmentAtBeat(beat);
  if (segment == nullptr) {
    return false;
  }

  const float old_bps = segment->GetBPS();
  new_bps = old_bps + delta;
  if (!IsFinite(old_bps) || !IsFinite(new_bps) || new_bps < MIN_SYNC_BPS) {
    return false;
  }
  return true;
}
}

REGISTER_SCREEN_CLASS(ScreenSyncOverlay);

void ScreenSyncOverlay::Init() {
  Screen::Init();

  if (THEME != nullptr && THEME->IsThemeLoaded() && LUA != nullptr) {
    m_overlay.LoadB(m_sName, "overlay");
  } else {
    WarnSyncOverlay("using empty overlay actor because no theme is loaded.");
    m_overlay.LoadFallback();
  }
  AddChild(m_overlay);

  Update(0);
}

void ScreenSyncOverlay::Update(float fDeltaTime) {
  const bool gameplay_active = IsGameplayActive();
  this->SetVisible(gameplay_active);

  Screen::Update(fDeltaTime);

  if (!gameplay_active) {
    HideHelp();
    return;
  }

  UpdateText();
}

static LocalizedString AUTO_PLAY("ScreenSyncOverlay", "AutoPlay");
static LocalizedString AUTO_PLAY_CPU("ScreenSyncOverlay", "AutoPlayCPU");
static LocalizedString AUTO_SYNC_SONG("ScreenSyncOverlay", "AutoSync Song");
static LocalizedString AUTO_SYNC_MACHINE(
    "ScreenSyncOverlay", "AutoSync Machine");
static LocalizedString AUTO_SYNC_TEMPO("ScreenSyncOverlay", "AutoSync Tempo");
static LocalizedString ASSIST_CLAP("ScreenSyncOverlay", "Assist Clap");
static LocalizedString OLD_OFFSET("ScreenSyncOverlay", "Old offset");
static LocalizedString NEW_OFFSET("ScreenSyncOverlay", "New offset");
static LocalizedString COLLECTING_SAMPLE(
    "ScreenSyncOverlay", "Collecting sample");
static LocalizedString STANDARD_DEVIATION(
    "ScreenSyncOverlay", "Standard deviation");
void ScreenSyncOverlay::UpdateText() {
  if (!m_overlay.IsLoaded() || GAMESTATE == nullptr) {
    return;
  }

  // Update Status
  std::vector<std::string> vs;

  PlayerController pc = GamePreferences::m_AutoPlay.Get();
  switch (pc) {
    case PC_HUMAN:
      break;
    case PC_AUTOPLAY:
      vs.push_back(AUTO_PLAY);
      break;
    case PC_CPU:
      vs.push_back(AUTO_PLAY_CPU);
      break;
    default:
      WarnSyncOverlay(ssprintf("ignored invalid PlayerController %i.", pc));
      break;
  }

  if (GAMESTATE->m_SongOptions.GetCurrent().m_bAssistClap) {
    vs.push_back(ASSIST_CLAP);
  }

  AutosyncType type = GAMESTATE->m_SongOptions.GetCurrent().m_AutosyncType;
  if (!IsValidAutosyncType(type)) {
    WarnSyncOverlay(ssprintf("ignored invalid AutosyncType %i.", type));
    type = AutosyncType_Off;
  } else {
    switch (type) {
      case AutosyncType_Off:
        break;
      case AutosyncType_Song:
        vs.push_back(AUTO_SYNC_SONG);
        break;
      case AutosyncType_Machine:
        vs.push_back(AUTO_SYNC_MACHINE);
        break;
      case AutosyncType_Tempo:
        vs.push_back(AUTO_SYNC_TEMPO);
        break;
      default:
        break;
    }
  }

  if (GAMESTATE->m_pCurSong != nullptr &&
      PREFSMAN != nullptr &&
      !GAMESTATE->IsCourseMode())  // sync controls available
  {
    AdjustSync::GetSyncChangeTextGlobal(vs);
    AdjustSync::GetSyncChangeTextSong(vs);
  }

  Message set_status("SetStatus");
  set_status.SetParam("text", join("\n", vs));
  SendOverlayMessage(set_status);

  // Update SyncInfo
  bool visible = type != AutosyncType_Off;
  Message set_adjustments("SetAdjustments");
  std::string s;
  if (visible) {
    float fNew = 0.0f;
    float fOld = 0.0f;
    if (type == AutosyncType_Machine && PREFSMAN != nullptr) {
      fNew = PREFSMAN->m_fGlobalOffsetSeconds;
      fOld = AdjustSync::s_fGlobalOffsetSecondsOriginal;
    } else if (
        GAMESTATE->m_pCurSong != nullptr &&
        !AdjustSync::s_vpTimingDataOriginal.empty()) {
      fNew = GAMESTATE->m_pCurSong->m_SongTiming.m_fBeat0OffsetInSeconds;
      fOld = AdjustSync::s_vpTimingDataOriginal[0].m_fBeat0OffsetInSeconds;
    } else {
      visible = false;
    }

    if (!IsFinite(fNew) || !IsFinite(fOld)) {
      visible = false;
    }

    const float fStdDev =
        IsFinite(AdjustSync::s_fStandardDeviation)
            ? AdjustSync::s_fStandardDeviation
            : 0.0f;
    if (visible) {
      s += OLD_OFFSET.GetValue() + ssprintf(": %0.3f\n", fOld);
      s += NEW_OFFSET.GetValue() + ssprintf(": %0.3f\n", fNew);
      s += STANDARD_DEVIATION.GetValue() + ssprintf(": %0.3f\n", fStdDev);
      s += COLLECTING_SAMPLE.GetValue() +
           ssprintf(
               ": %d / %d", GetAutosyncSampleDisplayCount(),
               AdjustSync::OFFSET_SAMPLE_COUNT);
    }
  }
  set_adjustments.SetParam("visible", visible);
  set_adjustments.SetParam("text", visible ? s : std::string(""));
  SendOverlayMessage(set_adjustments);
}

static LocalizedString CANT_SYNC_WHILE_PLAYING_A_COURSE(
    "ScreenSyncOverlay", "Can't sync while playing a course.");
static LocalizedString SYNC_CHANGES_REVERTED(
    "ScreenSyncOverlay", "Sync changes reverted.");
bool ScreenSyncOverlay::Input(const InputEventPlus& input) {
  if (!IsGameplayActive()) {
    return Screen::Input(input);
  }

  if (input.DeviceI.device != DEVICE_KEYBOARD) {
    return Screen::Input(input);
  }

  Action a = Action_Invalid;
  bool bIncrease = false;
  if (!GetActionForInput(input, a, bIncrease)) {
    return Screen::Input(input);
  }

  if (!HasRuntimeForSync()) {
    WarnSyncOverlay("ignored sync input without complete runtime state.");
    return true;
  }

  if (GAMESTATE->IsCourseMode() && a != ChangeGlobalOffset) {
    if (SCREENMAN != nullptr) {
      SCREENMAN->SystemMessage(CANT_SYNC_WHILE_PLAYING_A_COURSE);
    }
    return true;
  }

  bool handled = true;
  bool changed = false;
  switch (a) {
    case RevertSyncChanges:
      if (input.type != IET_FIRST_PRESS) {
        return false;
      }
      if (SCREENMAN != nullptr) {
        SCREENMAN->SystemMessage(SYNC_CHANGES_REVERTED);
      }
      if (GAMESTATE != nullptr && PREFSMAN != nullptr) {
        AdjustSync::RevertSyncChanges();
        changed = true;
      }
      break;
    case ChangeSongBPM: {
      const float fDelta = GetInputDelta(input, bIncrease);
      changed = ApplyBPMDelta(fDelta);
    } break;
    case ChangeGlobalOffset:
    case ChangeSongOffset: {
      const float fDelta = GetInputDelta(input, bIncrease);
      changed = a == ChangeGlobalOffset ? ApplyGlobalOffsetDelta(fDelta)
                                        : ApplySongOffsetDelta(fDelta);
    } break;
    default:
      handled = false;
      break;
  }

  if (!handled) {
    return Screen::Input(input);
  }

  ShowHelp();
  if (changed || input.type == IET_RELEASE) {
    UpdateText();
  }
  return true;
}

bool ScreenSyncOverlay::IsGameplayActive() const {
  if (SCREENMAN == nullptr) {
    return false;
  }
  Screen* top = SCREENMAN->GetTopScreen();
  return top != nullptr && top->GetScreenType() == gameplay;
}

bool ScreenSyncOverlay::HasRuntimeForSync() const {
  return GAMESTATE != nullptr && SCREENMAN != nullptr;
}

bool ScreenSyncOverlay::IsShiftPressed() const {
  return INPUTFILTER != nullptr &&
         (INPUTFILTER->IsBeingPressed(
              DeviceInput(DEVICE_KEYBOARD, KEY_RSHIFT)) ||
          INPUTFILTER->IsBeingPressed(DeviceInput(DEVICE_KEYBOARD, KEY_LSHIFT)));
}

bool ScreenSyncOverlay::IsAltPressed() const {
  return INPUTFILTER != nullptr &&
         (INPUTFILTER->IsBeingPressed(DeviceInput(DEVICE_KEYBOARD, KEY_RALT)) ||
          INPUTFILTER->IsBeingPressed(DeviceInput(DEVICE_KEYBOARD, KEY_LALT)));
}

bool ScreenSyncOverlay::GetActionForInput(
    const InputEventPlus& input, Action& action, bool& increase) const {
  action = Action_Invalid;
  increase = true;

  switch (input.DeviceI.button) {
    case KEY_F4:
      action = RevertSyncChanges;
      return true;

    case KEY_F9:
      increase = false;
      [[fallthrough]];
    case KEY_F10:
      action = ChangeSongBPM;
      return true;

    case KEY_F11:
      increase = false;
      [[fallthrough]];
    case KEY_F12:
      action = IsShiftPressed() ? ChangeGlobalOffset : ChangeSongOffset;
      return true;

    default:
      return false;
  }
}

float ScreenSyncOverlay::GetInputDelta(
    const InputEventPlus& input, bool increase) const {
  float delta = increase ? +0.02f : -0.02f;
  if (IsAltPressed()) {
    delta /= 20.0f; /* 1ms */
  }

  switch (input.type) {
    case IET_RELEASE:
      return 0.0f;
    case IET_REPEAT:
      if (INPUTFILTER == nullptr ||
          INPUTFILTER->GetSecsHeld(input.DeviceI) < 1.0f) {
        return 0.0f;
      }
      delta *= 10.0f;
      break;
    default:
      break;
  }

  return IsFinite(delta) ? delta : 0.0f;
}

void ScreenSyncOverlay::ReleaseCurrentStepLookups() {
  if (GAMESTATE == nullptr) {
    return;
  }

  FOREACH_EnabledPlayer(pn) {
    Steps* steps = GAMESTATE->m_pCurSteps[pn];
    if (steps == nullptr) {
      continue;
    }
    TimingData* timing = steps->GetTimingData();
    if (timing != nullptr) {
      timing->ReleaseLookup();
    }
  }
}

bool ScreenSyncOverlay::ApplyBPMDelta(float delta) {
  if (delta == 0.0f) {
    return true;
  }
  if (GAMESTATE == nullptr || GAMESTATE->m_pCurSong == nullptr ||
      !IsFinite(GAMESTATE->m_Position.m_fSongBeat)) {
    return false;
  }

  Song* song = GAMESTATE->m_pCurSong;
  TimingData& song_timing = song->m_SongTiming;
  const float song_beat = GAMESTATE->m_Position.m_fSongBeat;
  const float second = song_timing.GetElapsedTimeFromBeat(song_beat);
  if (!IsFinite(second)) {
    return false;
  }

  struct PendingBPSUpdate {
    TimingData* timing;
    BPMSegment* segment;
    float new_bps;
  };
  std::vector<PendingBPSUpdate> updates;
  BPMSegment* song_segment = nullptr;
  float song_new_bps = 0.0f;
  if (!PrepareBPSDelta(
          song_timing, song_beat, delta, song_segment, song_new_bps)) {
    WarnSyncOverlay("ignored BPM delta that would produce invalid song timing.");
    return false;
  }
  updates.push_back({&song_timing, song_segment, song_new_bps});

  const std::vector<Steps*>& steps_list = song->GetAllSteps();
  for (Steps* steps : steps_list) {
    if (steps == nullptr || steps->m_Timing.empty()) {
      continue;
    }

    const float steps_beat = steps->m_Timing.GetBeatFromElapsedTime(second);
    if (!IsFinite(steps_beat)) {
      return false;
    }
    BPMSegment* steps_segment = nullptr;
    float steps_new_bps = 0.0f;
    if (!PrepareBPSDelta(
            steps->m_Timing, steps_beat, delta, steps_segment,
            steps_new_bps)) {
      WarnSyncOverlay(
          "ignored BPM delta because a steps timing could not be updated.");
      return false;
    }
    updates.push_back({&steps->m_Timing, steps_segment, steps_new_bps});
  }

  for (const PendingBPSUpdate& update : updates) {
    update.segment->SetBPS(update.new_bps);
    update.timing->ReleaseLookup();
  }

  ReleaseCurrentStepLookups();
  return true;
}

bool ScreenSyncOverlay::ApplyGlobalOffsetDelta(float delta) {
  if (delta == 0.0f) {
    return true;
  }
  if (PREFSMAN == nullptr || !IsFinite(delta)) {
    return false;
  }

  const float old_runtime_seconds = PREFSMAN->m_fGlobalOffsetSeconds.Get();
  const float new_runtime_seconds = old_runtime_seconds + delta;
  if (!IsFinite(old_runtime_seconds) || !IsFinite(new_runtime_seconds)) {
    WarnSyncOverlay("ignored non-finite global offset delta.");
    return false;
  }

  if (LogGlobalOffsetDiagnosticsEnabled() && LOG != nullptr) {
    LOG->Trace(
        "GLOBAL_OFFSET_TRACE: sync_overlay_change_global_offset "
        "delta=%.6f old_runtime_seconds=%.6f new_runtime_seconds=%.6f",
        delta, old_runtime_seconds, new_runtime_seconds);
  }
  PREFSMAN->SetGlobalOffsetSeconds(new_runtime_seconds);
  return true;
}

bool ScreenSyncOverlay::ApplySongOffsetDelta(float delta) {
  if (delta == 0.0f) {
    return true;
  }
  if (GAMESTATE == nullptr || GAMESTATE->m_pCurSong == nullptr ||
      !IsFinite(delta)) {
    return false;
  }

  Song* song = GAMESTATE->m_pCurSong;
  const float old_song_offset = song->m_SongTiming.m_fBeat0OffsetInSeconds;
  const float new_song_offset = old_song_offset + delta;
  if (!IsFinite(old_song_offset) || !IsFinite(new_song_offset)) {
    WarnSyncOverlay("ignored non-finite song offset delta.");
    return false;
  }

  std::vector<std::pair<TimingData*, float>> updates;
  updates.emplace_back(&song->m_SongTiming, new_song_offset);

  const std::vector<Steps*>& steps_list = song->GetAllSteps();
  for (Steps* steps : steps_list) {
    if (steps == nullptr || steps->m_Timing.empty()) {
      continue;
    }
    const float old_steps_offset = steps->m_Timing.m_fBeat0OffsetInSeconds;
    const float new_steps_offset = old_steps_offset + delta;
    if (!IsFinite(old_steps_offset) || !IsFinite(new_steps_offset)) {
      WarnSyncOverlay(
          "ignored song offset delta because a steps offset is invalid.");
      return false;
    }
    updates.emplace_back(&steps->m_Timing, new_steps_offset);
  }

  for (const auto& update : updates) {
    update.first->m_fBeat0OffsetInSeconds = update.second;
    update.first->ReleaseLookup();
  }

  ReleaseCurrentStepLookups();
  return true;
}

void ScreenSyncOverlay::SendOverlayMessage(Message& message) {
  if (m_overlay.IsLoaded()) {
    m_overlay->HandleMessage(message);
  }
}

void ScreenSyncOverlay::ShowHelp() {
  if (m_overlay.IsLoaded()) {
    m_overlay->PlayCommand("Show");
  }
}

void ScreenSyncOverlay::HideHelp() {
  if (m_overlay.IsLoaded()) {
    m_overlay->PlayCommand("Hide");
  }
}

/*
 * (c) 2001-2005 Chris Danford
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the
 * "Software"), to deal in the Software without restriction, including
 * without limitation the rights to use, copy, modify, merge, publish,
 * distribute, and/or sell copies of the Software, and to permit persons to
 * whom the Software is furnished to do so, provided that the above
 * copyright notice(s) and this permission notice appear in all copies of
 * the Software and that both the above copyright notice(s) and this
 * permission notice appear in supporting documentation.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 * OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
 * THIRD PARTY RIGHTS. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS
 * INCLUDED IN THIS NOTICE BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT
 * OR CONSEQUENTIAL DAMAGES, OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
 * OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
 * OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
 * PERFORMANCE OF THIS SOFTWARE.
 */
