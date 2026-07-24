#include "LifeMeterTime.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <limits>
#include <string>

#include "Actor.h"
#include "Course.h"
#include "GameConstantsAndTypes.h"
#include "GameState.h"
#include "LifeMeter.h"
#include "MessageManager.h"
#include "PlayerNumber.h"
#include "PlayerStageStats.h"
#include "PlayerState.h"
#include "Preference.h"
#include "RadarValues.h"
#include "RageLog.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "Song.h"
#include "StatsManager.h"
#include "Steps.h"
#include "StreamDisplay.h"
#include "ThemeManager.h"
#include "ThemeMetric.h"
#include "global.h"

const float FULL_LIFE_SECONDS = 1.5f * 60;

static ThemeMetric<float> METER_WIDTH("LifeMeterTime", "MeterWidth");
static ThemeMetric<float> METER_HEIGHT("LifeMeterTime", "MeterHeight");
static ThemeMetric<float> DANGER_THRESHOLD("LifeMeterTime", "DangerThreshold");
static ThemeMetric<float> INITIAL_VALUE("LifeMeterTime", "InitialValue");
static ThemeMetric<float> MIN_LIFE_TIME("LifeMeterTime", "MinLifeTime");

static const float g_fTimeMeterSecondsChangeInit[] = {
    +0.0f,  // SE_CheckpointHit
    +0.2f,  // SE_W1
    +0.0f,  // SE_W2
    -0.5f,  // SE_W3
    -1.0f,  // SE_W4
    -2.0f,  // SE_W5
    -4.0f,  // SE_Miss
    -2.0f,  // SE_HitMine
    -0.0f,  // SE_CheckpointMiss
    -0.0f,  // SE_Held
    -4.0f,  // SE_LetGo
    -0.0f,  // SE_Missed
};
static_assert(ARRAYLEN(g_fTimeMeterSecondsChangeInit) == NUM_ScoreEvent);

static void TimeMeterSecondsChangeInit(
    size_t /*ScoreEvent*/ i, std::string& sNameOut, float& defaultValueOut) {
  sNameOut = "TimeMeterSecondsChange" + ScoreEventToString((ScoreEvent)i);
  defaultValueOut = g_fTimeMeterSecondsChangeInit[i];
}

static Preference1D<float> g_fTimeMeterSecondsChange(
    TimeMeterSecondsChangeInit, NUM_ScoreEvent);

namespace {
bool IsValidPlayerNumber(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

bool IsValidTapNoteScore(TapNoteScore score) {
  return score >= TNS_None && score < NUM_TapNoteScore;
}

bool IsValidHoldNoteScore(HoldNoteScore score) {
  return score >= HNS_None && score < NUM_HoldNoteScore;
}

float SanitizeSeconds(float seconds, const char* context) {
  if (std::isfinite(seconds)) {
    return seconds;
  }

  LOG->Warn(
      "%s: corrected non-finite seconds %f to 0.", context,
      seconds);
  return 0.0f;
}

float AddSecondsSaturated(float current, float delta, const char* context) {
  current = SanitizeSeconds(current, context);
  delta = SanitizeSeconds(delta, context);
  const double sum = static_cast<double>(current) + delta;
  if (sum > std::numeric_limits<float>::max()) {
    LOG->Warn("%s: saturated positive seconds sum.", context);
    return std::numeric_limits<float>::max();
  }
  if (sum < -std::numeric_limits<float>::max()) {
    LOG->Warn("%s: saturated negative seconds sum.", context);
    return -std::numeric_limits<float>::max();
  }
  return static_cast<float>(sum);
}

float SanitizeDimension(float value) {
  return std::isfinite(value) && value > 0.0f ? value : 1.0f;
}
}  // namespace

LifeMeterTime::LifeMeterTime() {
  m_fLifeTotalGainedSeconds = 0;
  m_fLifeTotalLostSeconds = 0;
  m_pStream = nullptr;
}

LifeMeterTime::~LifeMeterTime() { ResetLoadedActors(); }

void LifeMeterTime::ResetLoadedActors() {
  if (m_sprBackground.IsLoaded()) {
    RemoveChild(m_sprBackground);
    m_sprBackground.Unload();
  }
  RemoveChild(&m_quadDangerGlow);
  if (m_pStream != nullptr) {
    RemoveChild(m_pStream);
    RageUtil::SafeDelete(m_pStream);
  }
  if (m_sprFrame.IsLoaded()) {
    RemoveChild(m_sprFrame);
    m_sprFrame.Unload();
  }
}

void LifeMeterTime::Load(
    const PlayerState* pPlayerState, PlayerStageStats* pPlayerStageStats) {
  LifeMeter::Load(pPlayerState, pPlayerStageStats);
  ResetLoadedActors();
  m_fLifeTotalGainedSeconds = 0.0f;
  m_fLifeTotalLostSeconds = 0.0f;

  if (pPlayerState == nullptr || pPlayerStageStats == nullptr ||
      !IsValidPlayerNumber(pPlayerState->m_PlayerNumber) || THEME == nullptr ||
      GAMESTATE == nullptr) {
    LOG->Warn(
        "LifeMeterTime refused load without complete runtime "
        "state.");
    return;
  }

  const std::string sType = "LifeMeterTime";
  const float meterWidth = SanitizeDimension(METER_WIDTH);
  const float meterHeight = SanitizeDimension(METER_HEIGHT);

  m_sprBackground.Load(THEME->GetPathG(sType, "background"));
  m_sprBackground->SetName("Background");
  m_sprBackground->ZoomToWidth(meterWidth);
  m_sprBackground->ZoomToHeight(meterHeight);
  this->AddChild(m_sprBackground);

  m_quadDangerGlow.ZoomToWidth(meterWidth);
  m_quadDangerGlow.ZoomToHeight(meterHeight);
  // hardcoded effects...
  m_quadDangerGlow.SetEffectDiffuseShift(
      1.0f, RageColor(1, 0, 0, 0.8f), RageColor(1, 0, 0, 0));
  m_quadDangerGlow.SetEffectClock(Actor::CLOCK_BGM_BEAT);
  this->AddChild(&m_quadDangerGlow);

  m_pStream = new StreamDisplay;
  bool bExtra = GAMESTATE->IsAnExtraStage();
  m_pStream->Load(bExtra ? "StreamDisplayExtra" : "StreamDisplay");
  this->AddChild(m_pStream);

  std::string sExtra = bExtra ? "extra " : "";
  m_sprFrame.Load(THEME->GetPathG(sType, sExtra + "frame"));
  m_sprFrame->SetName("Frame");
  this->AddChild(m_sprFrame);

  m_soundGainLife.Load(THEME->GetPathS(sType, "GainLife"));
}

void LifeMeterTime::OnLoadSong() {
  if (GAMESTATE == nullptr || STATSMAN == nullptr ||
      m_pPlayerState == nullptr ||
      !IsValidPlayerNumber(m_pPlayerState->m_PlayerNumber)) {
    LOG->Warn(
        "LifeMeterTime ignored OnLoadSong without "
        "complete runtime state.");
    return;
  }
  if (GetLifeSeconds() <= 0 && GAMESTATE->GetCourseSongIndex() > 0) {
    return;
  }

  float fOldLife = m_fLifeTotalLostSeconds;
  float fGainSeconds = 0;
  if (GAMESTATE->IsCourseMode()) {
    Course* pCourse = GAMESTATE->m_pCurCourse;
    const int courseSongIndex = GAMESTATE->GetCourseSongIndex();
    if (pCourse == nullptr || courseSongIndex < 0 ||
        static_cast<size_t>(courseSongIndex) >= pCourse->m_vEntries.size()) {
      LOG->Warn(
          "LifeMeterTime ignored invalid course entry "
          "%i of %zu.",
          courseSongIndex, pCourse == nullptr ? 0 : pCourse->m_vEntries.size());
      return;
    }
    fGainSeconds = pCourse->m_vEntries[courseSongIndex].fGainSeconds;
  } else {
    // Placeholderish, at least this way it won't crash when someone tries it
    // out in non-course mode. -Kyz
    Song* song = GAMESTATE->m_pCurSong;
    if (song == nullptr) {
      LOG->Warn(
          "LifeMeterTime ignored OnLoadSong without "
          "current song.");
      return;
    }
    float song_len = song->m_fMusicLengthSeconds;
    PlayerNumber pn = m_pPlayerState->m_PlayerNumber;
    if (!IsValidPlayerNumber(pn) || GAMESTATE->m_pCurSteps[pn] == nullptr) {
      LOG->Warn(
          "LifeMeterTime ignored OnLoadSong with "
          "invalid player/steps %i.",
          pn);
      return;
    }
    Steps* steps = GAMESTATE->m_pCurSteps[pn];
    RadarValues radars = steps->GetRadarValues(pn);
    float scorable_things =
        radars[RadarCategory_TapsAndHolds] + radars[RadarCategory_Lifts];
    if (g_fTimeMeterSecondsChange[SE_Held] > 0.0f) {
      scorable_things +=
          radars[RadarCategory_Holds] + radars[RadarCategory_Rolls];
    }
    // Calculate the amount of time to give for the player to need 80% W1.
    float gainable_score_time =
        scorable_things * g_fTimeMeterSecondsChange[SE_W1];
    fGainSeconds = song_len - (gainable_score_time * INITIAL_VALUE);
  }

  fGainSeconds = SanitizeSeconds(fGainSeconds, "LifeMeterTime gain");
  const float minLifeTime =
      std::isfinite((float)MIN_LIFE_TIME) ? (float)MIN_LIFE_TIME : 0.0f;
  if (minLifeTime > fGainSeconds) {
    fGainSeconds = minLifeTime;
  }
  m_fLifeTotalGainedSeconds = AddSecondsSaturated(
      m_fLifeTotalGainedSeconds, fGainSeconds,
      "LifeMeterTime gained total");
  m_soundGainLife.Play(false);
  SendLifeChangedMessage(fOldLife, TapNoteScore_Invalid, HoldNoteScore_Invalid);
}

void LifeMeterTime::ChangeLife(TapNoteScore tns) {
  if (GetLifeSeconds() <= 0) {
    return;
  }
  if (!IsValidTapNoteScore(tns)) {
    LOG->Warn(
        "LifeMeterTime ignored invalid TapNoteScore "
        "%i.",
        tns);
    return;
  }

  float fMeterChange = 0;
  switch (tns) {
    case TNS_None:
    case TNS_AvoidMine:
      fMeterChange = 0;
      break;
    case TNS_W1:
      fMeterChange = g_fTimeMeterSecondsChange[SE_W1];
      break;
    case TNS_W2:
      fMeterChange = g_fTimeMeterSecondsChange[SE_W2];
      break;
    case TNS_W3:
      fMeterChange = g_fTimeMeterSecondsChange[SE_W3];
      break;
    case TNS_W4:
      fMeterChange = g_fTimeMeterSecondsChange[SE_W4];
      break;
    case TNS_W5:
      fMeterChange = g_fTimeMeterSecondsChange[SE_W5];
      break;
    case TNS_Miss:
      fMeterChange = g_fTimeMeterSecondsChange[SE_Miss];
      break;
    case TNS_HitMine:
      fMeterChange = g_fTimeMeterSecondsChange[SE_HitMine];
      break;
    case TNS_CheckpointHit:
      fMeterChange = g_fTimeMeterSecondsChange[SE_CheckpointHit];
      break;
    case TNS_CheckpointMiss:
      fMeterChange = g_fTimeMeterSecondsChange[SE_CheckpointMiss];
      break;
    default:
      break;
  }

  float fOldLife = m_fLifeTotalLostSeconds;
  m_fLifeTotalLostSeconds = AddSecondsSaturated(
      m_fLifeTotalLostSeconds, -fMeterChange,
      "LifeMeterTime tap total");
  SendLifeChangedMessage(fOldLife, tns, HoldNoteScore_Invalid);
}

void LifeMeterTime::ChangeLife(HoldNoteScore hns, TapNoteScore tns) {
  if (GetLifeSeconds() <= 0) {
    return;
  }
  if (!IsValidHoldNoteScore(hns)) {
    LOG->Warn(
        "LifeMeterTime ignored invalid HoldNoteScore "
        "%i.",
        hns);
    return;
  }
  if (hns == HNS_None) {
    return;
  }

  float fMeterChange = 0;
  switch (hns) {
    case HNS_Held:
      fMeterChange = g_fTimeMeterSecondsChange[SE_Held];
      break;
    case HNS_LetGo:
      fMeterChange = g_fTimeMeterSecondsChange[SE_LetGo];
      break;
    case HNS_Missed:
      fMeterChange = g_fTimeMeterSecondsChange[SE_Missed];
      break;
    default:
      break;
  }

  float fOldLife = m_fLifeTotalLostSeconds;
  m_fLifeTotalLostSeconds = AddSecondsSaturated(
      m_fLifeTotalLostSeconds, -fMeterChange,
      "LifeMeterTime hold total");
  SendLifeChangedMessage(fOldLife, tns, hns);
}

void LifeMeterTime::ChangeLife(float delta) {
  if (!std::isfinite(delta)) {
    LOG->Warn(
        "LifeMeterTime ignored non-finite life delta "
        "%f.",
        delta);
    return;
  }
  float old_life = m_fLifeTotalLostSeconds;
  m_fLifeTotalLostSeconds = AddSecondsSaturated(
      m_fLifeTotalLostSeconds, -delta, "LifeMeterTime direct total");
  SendLifeChangedMessage(old_life, TapNoteScore_Invalid, HoldNoteScore_Invalid);
}

void LifeMeterTime::SetLife(float value) {
  if (!std::isfinite(value)) {
    LOG->Warn(
        "LifeMeterTime ignored non-finite SetLife %f.",
        value);
    return;
  }
  float old_life = m_fLifeTotalLostSeconds;
  m_fLifeTotalLostSeconds = value;
  SendLifeChangedMessage(old_life, TapNoteScore_Invalid, HoldNoteScore_Invalid);
}

void LifeMeterTime::HandleTapScoreNone() {
  // do nothing.
}

void LifeMeterTime::SendLifeChangedMessage(
    float fOldLife, TapNoteScore tns, HoldNoteScore hns) {
  if (m_pPlayerState == nullptr ||
      !IsValidPlayerNumber(m_pPlayerState->m_PlayerNumber) ||
      MESSAGEMAN == nullptr) {
    LOG->Trace(
        "LifeMeterTime skipped LifeChanged broadcast "
        "without PlayerState.");
    return;
  }
  Message msg("LifeChanged");
  msg.SetParam("Player", m_pPlayerState->m_PlayerNumber);
  msg.SetParam("TapNoteScore", LuaReference::Create(tns));
  msg.SetParam("HoldNoteScore", LuaReference::Create(hns));
  msg.SetParam("OldLife", fOldLife);
  const double difference =
      static_cast<double>(SanitizeSeconds(fOldLife, "LifeMeterTime old life")) -
      SanitizeSeconds(m_fLifeTotalLostSeconds, "LifeMeterTime current life");
  const float finiteDifference = static_cast<float>(std::max(
      -static_cast<double>(std::numeric_limits<float>::max()),
      std::min(
          static_cast<double>(std::numeric_limits<float>::max()), difference)));
  msg.SetParam("Difference", finiteDifference);
  msg.SetParam("LifeMeter", LuaReference::CreateFromPush(*this));
  MESSAGEMAN->Broadcast(msg);
}

bool LifeMeterTime::IsInDanger() const {
  if (m_pStream == nullptr || !DANGER_THRESHOLD.IsLoaded() ||
      !std::isfinite((float)DANGER_THRESHOLD)) {
    return false;
  }
  return m_pStream->GetPercent() < DANGER_THRESHOLD;
}

bool LifeMeterTime::IsHot() const { return false; }

bool LifeMeterTime::IsFailing() const { return GetLifeSeconds() <= 0; }

void LifeMeterTime::Update(float fDeltaTime) {
  if (m_pStream == nullptr || m_pPlayerState == nullptr ||
      m_pPlayerStageStats == nullptr) {
    LOG->Trace(
        "LifeMeterTime skipped update without complete "
        "state.");
    return;
  }
  if (!std::isfinite(fDeltaTime) || fDeltaTime < 0.0f) {
    LOG->Warn(
        "LifeMeterTime ignored invalid update delta %f.",
        fDeltaTime);
    return;
  }
  // update current stage stats so ScoreDisplayLifeTime can show the right thing
  float fSecs = GetLifeSeconds();
  fSecs = std::max(0.0f, fSecs);
  m_pPlayerStageStats->m_fLifeRemainingSeconds = fSecs;

  LifeMeter::Update(fDeltaTime);

  m_pStream->SetPercent(GetLife());
  m_pStream->SetPassingAlpha(0);
  m_pStream->SetHotAlpha(0);

  if (m_pPlayerState->m_HealthState == HealthState_Danger) {
    m_quadDangerGlow.SetDiffuseAlpha(1);
  } else {
    m_quadDangerGlow.SetDiffuseAlpha(0);
  }
}

float LifeMeterTime::GetLife() const {
  float fPercent = GetLifeSeconds() / FULL_LIFE_SECONDS;
  if (!std::isfinite(fPercent)) {
    LOG->Trace(
        "LifeMeterTime corrected non-finite percent.");
    fPercent = 0.0f;
  }
  rage_clamp(fPercent, 0, 1);
  return fPercent;
}

float LifeMeterTime::GetLifeSeconds() const {
  const float gained = SanitizeSeconds(
      m_fLifeTotalGainedSeconds, "LifeMeterTime gained");
  const float lost =
      SanitizeSeconds(m_fLifeTotalLostSeconds, "LifeMeterTime lost");
  const float steps = STATSMAN == nullptr
                          ? 0.0f
                          : SanitizeSeconds(
                                STATSMAN->m_CurStageStats.m_fStepsSeconds,
                                "LifeMeterTime steps");
  const double remaining =
      static_cast<double>(gained) - lost - static_cast<double>(steps);
  if (remaining > std::numeric_limits<float>::max()) {
    return std::numeric_limits<float>::max();
  }
  if (remaining < -std::numeric_limits<float>::max()) {
    return -std::numeric_limits<float>::max();
  }
  return static_cast<float>(remaining);
}

/*
 * (c) 2001-2004 Chris Danford
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
