#include "BPMDisplay.h"

#include <algorithm>
#include <climits>
#include <cmath>
#include <cctype>
#include <string>
#include <vector>

#include "ActorUtil.h"
#include "BitmapText.h"
#include "CommonMetrics.h"
#include "Course.h"
#include "GameConstantsAndTypes.h"
#include "GameState.h"
#include "PlayerNumber.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "RageUtil/RandomNumbers.h"
#include "Song.h"
#include "Steps.h"
#include "Style.h"
#include "ThemeManager.h"
#include "global.h"

REGISTER_ACTOR_CLASS(BPMDisplay);

namespace {
constexpr float kDefaultBpmCycleTime = 1.0f;
constexpr float kDefaultRandomCycleTime = 0.2f;

void WarnBPMDisplayAuditFix(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

bool IsSafeBPMFormat(const std::string& format) {
  if (format.empty() || format.size() > 64) {
    return false;
  }
  int conversions = 0;
  for (size_t i = 0; i < format.size(); ++i) {
    if (format[i] != '%') {
      continue;
    }
    if (i + 1 < format.size() && format[i + 1] == '%') {
      ++i;
      continue;
    }
    ++conversions;
    if (conversions > 1) {
      return false;
    }
    size_t j = i + 1;
    while (j < format.size() &&
           std::string("-+ #0").find(format[j]) != std::string::npos) {
      ++j;
    }
    int width = 0;
    while (j < format.size() &&
           std::isdigit(static_cast<unsigned char>(format[j]))) {
      width = width * 10 + (format[j] - '0');
      if (width > 16) {
        return false;
      }
      ++j;
    }
    if (j < format.size() && format[j] == '.') {
      ++j;
      int precision = 0;
      while (j < format.size() &&
             std::isdigit(static_cast<unsigned char>(format[j]))) {
        precision = precision * 10 + (format[j] - '0');
        if (precision > 6) {
          return false;
        }
        ++j;
      }
    }
    if (j >= format.size()) {
      return false;
    }
    if (std::string("fFeEgG").find(format[j]) == std::string::npos) {
      return false;
    }
  }
  return conversions == 1;
}

std::string FormatBPMText(const std::string& format, float value) {
  if (!std::isfinite(value)) {
    WarnBPMDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1117: BPMDisplay reset non-finite BPM text value.");
    value = 0.0f;
  }
  if (!IsSafeBPMFormat(format)) {
    WarnBPMDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1118: BPMDisplay ignored unsafe FormatString.");
    return ssprintf("%.0f", value);
  }
  return ssprintf(format.c_str(), value);
}

float SanitizeCycleTime(float value, float fallback, const char* context) {
  if (!std::isfinite(value) || value <= 0.0f) {
    WarnBPMDisplayAuditFix(context);
    return fallback;
  }
  return value;
}

bool IsUsableDisplayBPM(float value) {
  return value == -1.0f || (std::isfinite(value) && value >= 0.0f);
}

std::vector<float> SanitizeDisplayBPMs(const DisplayBpms& bpms) {
  std::vector<float> sanitized;
  sanitized.reserve(bpms.vfBpms.size());
  for (float bpm : bpms.vfBpms) {
    if (!IsUsableDisplayBPM(bpm)) {
      WarnBPMDisplayAuditFix(
          "SRC_AUDIT_FIX SRC-1117: BPMDisplay ignored invalid BPM value.");
      continue;
    }
    sanitized.push_back(bpm);
  }
  return sanitized;
}
}  // namespace

BPMDisplay::BPMDisplay() {
  m_fBPMFrom = m_fBPMTo = 0;
  m_iCurrentBPM = 0;
  m_BPMS.push_back(0);
  m_fPercentInState = 0;
  m_fCycleTime = 1.0f;
}

void BPMDisplay::Load() {
  if (THEME == nullptr || m_sName.empty()) {
    WarnBPMDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1114: BPMDisplay refused metric load without theme "
        "or name.");
    return;
  }

  SET_NO_BPM_COMMAND.Load(m_sName, "SetNoBpmCommand");
  SET_NORMAL_COMMAND.Load(m_sName, "SetNormalCommand");
  SET_CHANGING_COMMAND.Load(m_sName, "SetChangeCommand");
  SET_RANDOM_COMMAND.Load(m_sName, "SetRandomCommand");
  SET_EXTRA_COMMAND.Load(m_sName, "SetExtraCommand");
  CYCLE.Load(m_sName, "Cycle");
  RANDOM_CYCLE_SPEED.Load(m_sName, "RandomCycleSpeed");
  COURSE_CYCLE_SPEED.Load(m_sName, "CourseCycleSpeed");
  SEPARATOR.Load(m_sName, "Separator");
  SHOW_QMARKS.Load(m_sName, "ShowQMarksInRandomCycle");
  NO_BPM_TEXT.Load(m_sName, "NoBpmText");
  QUESTIONMARKS_TEXT.Load(m_sName, "QuestionMarksText");
  RANDOM_TEXT.Load(m_sName, "RandomText");
  VARIOUS_TEXT.Load(m_sName, "VariousText");
  BPM_FORMAT_STRING.Load(m_sName, "FormatString");

  RunCommands(SET_NORMAL_COMMAND);
}

void BPMDisplay::LoadFromNode(const XNode* pNode) {
  if (pNode == nullptr) {
    WarnBPMDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1114: BPMDisplay ignored null XML node.");
    return;
  }
  BitmapText::LoadFromNode(pNode);
  Load();
}

float BPMDisplay::GetActiveBPM() const {
  return m_fBPMTo + (m_fBPMFrom - m_fBPMTo) * m_fPercentInState;
}

void BPMDisplay::Update(float fDeltaTime) {
  if (!std::isfinite(fDeltaTime) || fDeltaTime < 0.0f) {
    WarnBPMDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1115: BPMDisplay ignored invalid update delta.");
    BitmapText::Update(0.0f);
    return;
  }
  BitmapText::Update(fDeltaTime);

  if (!(bool)CYCLE) {
    return;
  }
  if (m_BPMS.size() == 0) {
    return;  // no bpm
  }

  m_fCycleTime = SanitizeCycleTime(
      m_fCycleTime, kDefaultBpmCycleTime,
      "SRC_AUDIT_FIX SRC-1115: BPMDisplay repaired invalid cycle time.");
  m_fPercentInState -= fDeltaTime / m_fCycleTime;
  if (m_fPercentInState < 0) {
    // go to next state
    m_fPercentInState = 1;  // reset timer

    m_iCurrentBPM = (m_iCurrentBPM + 1) % m_BPMS.size();
    m_fBPMFrom = m_fBPMTo;
    m_fBPMTo = m_BPMS[m_iCurrentBPM];

    if (m_fBPMTo == -1) {
      m_fBPMFrom = -1;
      if ((bool)SHOW_QMARKS) {
        SetText(
            (RandomFloat(0, 1) > 0.90f)
                ? (std::string)QUESTIONMARKS_TEXT
                : FormatBPMText(BPM_FORMAT_STRING, RandomFloat(0, 999)));
      } else {
        SetText(FormatBPMText(BPM_FORMAT_STRING, RandomFloat(0, 999)));
      }
    } else if (m_fBPMFrom == -1) {
      m_fBPMFrom = m_fBPMTo;
    }
  }

  if (m_fBPMTo != -1) {
    const float fActualBPM = GetActiveBPM();
    SetText(FormatBPMText(BPM_FORMAT_STRING, fActualBPM));
  }
}

void BPMDisplay::SetBPMRange(const DisplayBpms& bpms) {
  m_BPMS.clear();

  const std::vector<float> BPMS = SanitizeDisplayBPMs(bpms);
  if (BPMS.empty()) {
    WarnBPMDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1116: BPMDisplay fell back from empty BPM range.");
    NoBPM();
    return;
  }

  bool AllIdentical = true;
  for (unsigned i = 0; i < BPMS.size(); ++i) {
    if (i > 0 && BPMS[i] != BPMS[i - 1]) {
      AllIdentical = false;
    }
  }

  if (!(bool)CYCLE) {
    int MinBPM = INT_MAX;
    int MaxBPM = INT_MIN;
    for (unsigned i = 0; i < BPMS.size(); ++i) {
      MinBPM = std::min(MinBPM, static_cast<int>(BPMS[i] + 0.5));
      MaxBPM = std::max(MaxBPM, static_cast<int>(BPMS[i] + 0.5));
    }
    if (MinBPM == MaxBPM) {
      if (MinBPM == -1) {
        SetText(RANDOM_TEXT);  // random (was "...") -aj
      } else {
        SetText(ssprintf("%i", MinBPM));
      }
    } else {
      SetText(ssprintf("%i%s%i", MinBPM, SEPARATOR.GetValue().c_str(), MaxBPM));
    }
  } else {
    for (unsigned i = 0; i < BPMS.size(); ++i) {
      m_BPMS.push_back(BPMS[i]);
      if (BPMS[i] != -1) {
        m_BPMS.push_back(BPMS[i]);  // hold
      }
    }

    m_iCurrentBPM = std::min(
        1, static_cast<int>(m_BPMS.size()));  // start on the first hold
    m_fBPMFrom = BPMS[0];
    m_fBPMTo = BPMS[0];
    m_fPercentInState = 1;
  }

  if (GAMESTATE != nullptr && GAMESTATE->IsAnExtraStageAndSelectionLocked()) {
    RunCommands(SET_EXTRA_COMMAND);
  } else if (!AllIdentical) {
    RunCommands(SET_CHANGING_COMMAND);
  } else {
    RunCommands(SET_NORMAL_COMMAND);
  }
}

void BPMDisplay::CycleRandomly() {
  DisplayBpms bpms;
  bpms.Add(-1);
  SetBPMRange(bpms);

  RunCommands(SET_RANDOM_COMMAND);

  m_fCycleTime = (float)RANDOM_CYCLE_SPEED;

  m_fCycleTime = SanitizeCycleTime(
      m_fCycleTime, kDefaultRandomCycleTime,
      "SRC_AUDIT_FIX SRC-1115: BPMDisplay used default random cycle time.");
}

void BPMDisplay::NoBPM() {
  m_BPMS.clear();
  SetText(NO_BPM_TEXT);
  RunCommands(SET_NO_BPM_COMMAND);
}

void BPMDisplay::SetBpmFromSong(const Song* pSong) {
  if (pSong == nullptr) {
    WarnBPMDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1119: BPMDisplay ignored null song.");
    NoBPM();
    return;
  }
  switch (pSong->m_DisplayBPMType) {
    case DISPLAY_BPM_ACTUAL:
    case DISPLAY_BPM_SPECIFIED: {
      DisplayBpms bpms;
      pSong->GetDisplayBpms(bpms);
      SetBPMRange(bpms);
      m_fCycleTime = 1.0f;
    } break;
    case DISPLAY_BPM_RANDOM:
      CycleRandomly();
      break;
    default:
      WarnBPMDisplayAuditFix(
          "SRC_AUDIT_FIX SRC-1119: BPMDisplay fell back from invalid display "
          "BPM type.");
      NoBPM();
      break;
  }
}

void BPMDisplay::SetBpmFromSteps(const Steps* pSteps) {
  if (pSteps == nullptr) {
    WarnBPMDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1119: BPMDisplay ignored null steps.");
    NoBPM();
    return;
  }
  DisplayBpms bpms;
  float fMinBPM, fMaxBPM;
  pSteps->GetTimingData()->GetActualBPM(fMinBPM, fMaxBPM);
  bpms.Add(fMinBPM);
  bpms.Add(fMaxBPM);
  SetBPMRange(bpms);
  m_fCycleTime = 1.0f;
}

void BPMDisplay::SetBpmFromCourse(const Course* pCourse) {
  if (pCourse == nullptr) {
    WarnBPMDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1119: BPMDisplay ignored null course.");
    NoBPM();
    return;
  }
  if (GAMESTATE == nullptr ||
      GAMESTATE->GetCurrentStyle(PLAYER_INVALID) == nullptr) {
    WarnBPMDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1119: BPMDisplay refused course BPM without style.");
    SetVarious();
    return;
  }

  StepsType st = GAMESTATE->GetCurrentStyle(PLAYER_INVALID)->m_StepsType;
  Trail* pTrail = pCourse->GetTrail(st);
  // GetTranslitFullTitle because "Crashinfo.txt is garbled because of the ANSI
  // output as usual." -f
  if (pTrail == nullptr) {
    WarnBPMDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1119: BPMDisplay fell back from missing course "
        "trail.");
    SetVarious();
    return;
  }

  m_fCycleTime = (float)COURSE_CYCLE_SPEED;
  m_fCycleTime = SanitizeCycleTime(
      m_fCycleTime, kDefaultBpmCycleTime,
      "SRC_AUDIT_FIX SRC-1115: BPMDisplay used default course cycle time.");

  if ((int)pTrail->m_vEntries.size() >
      CommonMetrics::MAX_COURSE_ENTRIES_BEFORE_VARIOUS) {
    SetVarious();
    return;
  }

  DisplayBpms bpms;
  pTrail->GetDisplayBpms(bpms);
  SetBPMRange(bpms);
}

void BPMDisplay::SetConstantBpm(float fBPM) {
  if (!std::isfinite(fBPM) || fBPM < 0.0f) {
    WarnBPMDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1117: BPMDisplay reset invalid constant BPM.");
    fBPM = 0.0f;
  }
  DisplayBpms bpms;
  bpms.Add(fBPM);
  SetBPMRange(bpms);
}

void BPMDisplay::SetVarious() {
  m_BPMS.clear();
  m_BPMS.push_back(-1);
  SetText(VARIOUS_TEXT);
}

void BPMDisplay::SetFromGameState() {
  if (GAMESTATE == nullptr) {
    WarnBPMDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1121: BPMDisplay fell back without GAMESTATE.");
    NoBPM();
    return;
  }
  if (GAMESTATE->m_pCurSong.Get()) {
    if (GAMESTATE->IsAnExtraStageAndSelectionLocked()) {
      CycleRandomly();
    } else {
      SetBpmFromSong(GAMESTATE->m_pCurSong);
    }
    return;
  }
  if (GAMESTATE->m_pCurCourse.Get()) {
    if (GAMESTATE->GetCurrentStyle(PLAYER_INVALID) == nullptr)
      ;  // This is true when backing out from ScreenSelectCourse to
         // ScreenTitleMenu.  So, don't call SetBpmFromCourse where an assert
         // will fire.
    else {
      SetBpmFromCourse(GAMESTATE->m_pCurCourse);
    }

    return;
  }

  NoBPM();
}

// SongBPMDisplay (in-game BPM display)
class SongBPMDisplay : public BPMDisplay {
 public:
  SongBPMDisplay();
  virtual SongBPMDisplay* Copy() const;
  virtual void Update(float fDeltaTime);

 private:
  float m_fLastGameStateBPM;
};

SongBPMDisplay::SongBPMDisplay() { m_fLastGameStateBPM = 0; }

void SongBPMDisplay::Update(float fDeltaTime) {
  if (GAMESTATE == nullptr) {
    NoBPM();
    BPMDisplay::Update(fDeltaTime);
    return;
  }
  float fGameStateBPM = GAMESTATE->m_Position.m_fCurBPS * 60.0f;
  if (!std::isfinite(fGameStateBPM) || fGameStateBPM < 0.0f) {
    fGameStateBPM = 0.0f;
  }
  if (m_fLastGameStateBPM != fGameStateBPM) {
    m_fLastGameStateBPM = fGameStateBPM;
    SetConstantBpm(fGameStateBPM);
  }

  BPMDisplay::Update(fDeltaTime);
}

REGISTER_ACTOR_CLASS(SongBPMDisplay);

#include "LuaBinding.h"
/** @brief Allow Lua to have access to the BPMDisplay. */
class LunaBPMDisplay : public Luna<BPMDisplay> {
 public:
  static int SetFromGameState(T* p, lua_State* L) {
    p->SetFromGameState();
    COMMON_RETURN_SELF;
  }
  static int SetFromSong(T* p, lua_State* L) {
    if (lua_isnil(L, 1)) {
      p->NoBPM();
    } else {
      const Song* pSong = Luna<Song>::check(L, 1, true);
      p->SetBpmFromSong(pSong);
    }
    COMMON_RETURN_SELF;
  }
  static int SetFromSteps(T* p, lua_State* L) {
    if (lua_isnil(L, 1)) {
      p->NoBPM();
    } else {
      const Steps* pSteps = Luna<Steps>::check(L, 1, true);
      p->SetBpmFromSteps(pSteps);
    }
    COMMON_RETURN_SELF;
  }
  static int SetFromCourse(T* p, lua_State* L) {
    if (lua_isnil(L, 1)) {
      p->NoBPM();
    } else {
      const Course* pCourse = Luna<Course>::check(L, 1, true);
      p->SetBpmFromCourse(pCourse);
    }
    COMMON_RETURN_SELF;
  }
  static int GetText(T* p, lua_State* L) {
    lua_pushstring(L, p->GetText().c_str());
    return 1;
  }

  LunaBPMDisplay() {
    ADD_METHOD(SetFromGameState);
    ADD_METHOD(SetFromSong);
    ADD_METHOD(SetFromSteps);
    ADD_METHOD(SetFromCourse);
    ADD_METHOD(GetText);
  }
};

LUA_REGISTER_DERIVED_CLASS(BPMDisplay, BitmapText)

/*
 * (c) 2001-2002 Chris Danford
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
