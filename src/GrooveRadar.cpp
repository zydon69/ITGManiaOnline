#include "GrooveRadar.h"

#include "ActorFrame.h"
#include "ActorUtil.h"
#include "EnumHelper.h"
#include "LuaManager.h"
#include "PlayerNumber.h"
#include "RageDisplay.h"
#include "RageLog.h"
#include "RageMath.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "Steps.h"
#include "ThemeManager.h"
#include "ThemeMetric.h"
// I feel weird about this coupling, but it has to be done. -aj
#include <algorithm>
#include <cmath>
#include <vector>

#include "GameState.h"

REGISTER_ACTOR_CLASS(GrooveRadar);

static const ThemeMetric<float> RADAR_EDGE_WIDTH("GrooveRadar", "EdgeWidth");
static const ThemeMetric<float> RADAR_CENTER_ALPHA(
    "GrooveRadar", "CenterAlpha");

static float RADAR_VALUE_ROTATION(int iValueIndex) {
  return PI / 2 + PI * 2 / 5.0f * iValueIndex;
}

static const int NUM_SHOWN_RADAR_CATEGORIES = 5;

namespace {
bool IsValidGrooveRadarPlayer(PlayerNumber pn) {
  return pn >= PLAYER_1 && pn < NUM_PLAYERS;
}

void WarnGrooveRadar(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

float SanitizeRadarValue(float value) {
  if (!std::isfinite(value)) {
    return 0.0f;
  }
  return std::clamp(value, 0.0f, 1.0f);
}

float SanitizeRadarTween(float value) {
  if (!std::isfinite(value)) {
    return 1.0f;
  }
  return std::clamp(value, 0.0f, 1.0f);
}
}  // namespace

GrooveRadar::GrooveRadar() {
  if (THEME != nullptr) {
    m_sprRadarBase.Load(THEME->GetPathG("GrooveRadar", "base"));
  } else {
    WarnGrooveRadar("SRC_AUDIT_FIX SRC-1150: GrooveRadar loaded without THEME.");
    m_sprRadarBase.LoadFallback();
  }
  if (m_sprRadarBase.IsLoaded()) {
    m_Frame.AddChild(m_sprRadarBase);
  }
  m_Frame.SetName("RadarFrame");
  if (THEME != nullptr) {
    ActorUtil::LoadAllCommands(m_Frame, "GrooveRadar");
  }

  FOREACH_PlayerNumber(p) {
    // todo: remove dependency on radar base being a sprite. -aj
    const float baseWidth =
        m_sprRadarBase.IsLoaded() ? m_sprRadarBase->GetZoomedWidth() : 0.0f;
    m_GrooveRadarValueMap[p].SetRadius(baseWidth);
    m_Frame.AddChild(&m_GrooveRadarValueMap[p]);
    m_GrooveRadarValueMap[p].SetName(ssprintf("RadarValueMapP%d", p + 1));
    if (THEME != nullptr) {
      ActorUtil::LoadAllCommands(m_GrooveRadarValueMap[p], "GrooveRadar");
    }
  }

  this->AddChild(&m_Frame);

  for (int c = 0; c < NUM_SHOWN_RADAR_CATEGORIES; c++) {
    m_sprRadarLabels[c].SetName(ssprintf("Label%i", c + 1));
    if (THEME != nullptr) {
      m_sprRadarLabels[c].Load(THEME->GetPathG("GrooveRadar", "labels 1x5"));
    }
    m_sprRadarLabels[c].StopAnimating();
    m_sprRadarLabels[c].SetState(c);
    if (THEME != nullptr) {
      ActorUtil::LoadAllCommandsAndSetXY(m_sprRadarLabels[c], "GrooveRadar");
    }
    this->AddChild(&m_sprRadarLabels[c]);
  }
}

GrooveRadar::GrooveRadar(const GrooveRadar& cpy)
    : ActorFrame(cpy), m_sprRadarBase(cpy.m_sprRadarBase), m_Frame(cpy.m_Frame) {
  if (m_sprRadarBase.IsLoaded()) {
    m_Frame.AddChild(m_sprRadarBase);
  }

  FOREACH_PlayerNumber(p) {
    m_GrooveRadarValueMap[p].m_bValuesVisible =
        cpy.m_GrooveRadarValueMap[p].m_bValuesVisible;
    m_GrooveRadarValueMap[p].m_PercentTowardNew =
        SanitizeRadarTween(cpy.m_GrooveRadarValueMap[p].m_PercentTowardNew);
    m_GrooveRadarValueMap[p].m_PlayerNumber =
        cpy.m_GrooveRadarValueMap[p].m_PlayerNumber;
    m_GrooveRadarValueMap[p].SetRadius(
        cpy.m_GrooveRadarValueMap[p].GetUnzoomedWidth());
    for (int c = 0; c < NUM_RadarCategory; ++c) {
      m_GrooveRadarValueMap[p].m_fValuesNew[c] =
          SanitizeRadarValue(cpy.m_GrooveRadarValueMap[p].m_fValuesNew[c]);
      m_GrooveRadarValueMap[p].m_fValuesOld[c] =
          SanitizeRadarValue(cpy.m_GrooveRadarValueMap[p].m_fValuesOld[c]);
    }
    m_Frame.AddChild(&m_GrooveRadarValueMap[p]);
  }

  AddChild(&m_Frame);
  for (int c = 0; c < NUM_RadarCategory; ++c) {
    m_sprRadarLabels[c] = cpy.m_sprRadarLabels[c];
    AddChild(&m_sprRadarLabels[c]);
  }
}

void GrooveRadar::LoadFromNode(const XNode* pNode) {
  ActorFrame::LoadFromNode(pNode);
}

void GrooveRadar::SetEmpty(PlayerNumber pn) { SetFromSteps(pn, nullptr); }

void GrooveRadar::SetFromRadarValues(PlayerNumber pn, const RadarValues& rv) {
  if (!IsValidGrooveRadarPlayer(pn)) {
    WarnGrooveRadar("SRC_AUDIT_FIX SRC-1151: GrooveRadar ignored invalid player.");
    return;
  }
  m_GrooveRadarValueMap[pn].SetFromSteps(rv);
}

void GrooveRadar::SetFromSteps(
    PlayerNumber pn, Steps* pSteps)  // nullptr means no Song
{
  if (!IsValidGrooveRadarPlayer(pn)) {
    WarnGrooveRadar("SRC_AUDIT_FIX SRC-1151: GrooveRadar ignored invalid player.");
    return;
  }
  if (pSteps == nullptr) {
    m_GrooveRadarValueMap[pn].SetEmpty();
    return;
  }

  const RadarValues& rv = pSteps->GetRadarValues(pn);
  m_GrooveRadarValueMap[pn].SetFromSteps(rv);
}

void GrooveRadar::SetFromValues(PlayerNumber pn, std::vector<float> vals) {
  if (!IsValidGrooveRadarPlayer(pn)) {
    WarnGrooveRadar("SRC_AUDIT_FIX SRC-1151: GrooveRadar ignored invalid player.");
    return;
  }
  m_GrooveRadarValueMap[pn].SetFromValues(vals);
}

GrooveRadar::GrooveRadarValueMap::GrooveRadarValueMap() {
  m_bValuesVisible = false;
  m_PercentTowardNew = 0;

  for (int c = 0; c < NUM_SHOWN_RADAR_CATEGORIES; c++) {
    m_fValuesNew[c] = 0;
    m_fValuesOld[c] = 0;
  }
}

void GrooveRadar::GrooveRadarValueMap::SetEmpty() { m_bValuesVisible = false; }

void GrooveRadar::GrooveRadarValueMap::SetFromSteps(const RadarValues& rv) {
  const bool wasVisible = m_bValuesVisible;
  m_bValuesVisible = true;
  for (int c = 0; c < NUM_SHOWN_RADAR_CATEGORIES; c++) {
    const float percent = SanitizeRadarTween(m_PercentTowardNew);
    const float fValueCurrent =
        m_fValuesOld[c] * (1 - percent) + m_fValuesNew[c] * percent;
    m_fValuesOld[c] = fValueCurrent;
    m_fValuesNew[c] = SanitizeRadarValue(rv[c]);
  }

  if (!wasVisible) {
    m_PercentTowardNew = 1;
  } else {
    m_PercentTowardNew = 0;
  }
}

void GrooveRadar::GrooveRadarValueMap::SetFromValues(std::vector<float> vals) {
  const bool wasVisible = m_bValuesVisible;
  m_bValuesVisible = true;
  for (int c = 0; c < NUM_SHOWN_RADAR_CATEGORIES; c++) {
    const float percent = SanitizeRadarTween(m_PercentTowardNew);
    const float fValueCurrent =
        m_fValuesOld[c] * (1 - percent) + m_fValuesNew[c] * percent;
    m_fValuesOld[c] = fValueCurrent;
    const float value = c < static_cast<int>(vals.size()) ? vals[c] : 0.0f;
    m_fValuesNew[c] = SanitizeRadarValue(value);
  }

  if (!wasVisible) {
    m_PercentTowardNew = 1;
  } else {
    m_PercentTowardNew = 0;
  }
}

void GrooveRadar::GrooveRadarValueMap::Update(float fDeltaTime) {
  ActorFrame::Update(fDeltaTime);

  if (!std::isfinite(fDeltaTime) || fDeltaTime < 0.0f) {
    return;
  }
  m_PercentTowardNew = SanitizeRadarTween(m_PercentTowardNew);
  m_PercentTowardNew = std::min(m_PercentTowardNew + 4.0f * fDeltaTime, 1.0f);
}

void GrooveRadar::GrooveRadarValueMap::DrawPrimitives() {
  ActorFrame::DrawPrimitives();

  // draw radar filling
  const float fRadius = GetUnzoomedWidth() / 2.0f * 1.1f;
  if (DISPLAY == nullptr || m_pTempState == nullptr ||
      !std::isfinite(fRadius) || fRadius <= 0.0f) {
    return;
  }

  DISPLAY->ClearAllTextures();
  DISPLAY->SetTextureMode(TextureUnit_1, TextureMode_Modulate);
  RageSpriteVertex
      v[12];  // needed to draw 5 fan primitives and 10 strip primitives

  // xxx: We could either make the values invisible or draw a dot
  // (simulating real DDR). TODO: Make that choice up to the themer. -aj
  if (!m_bValuesVisible) {
    return;
  }

  // use a fan to draw the volume
  RageColor color = this->m_pTempState->diffuse[0];
  color.a = 0.5f;
  v[0].p = RageVector3(0, 0, 0);
  RageColor midcolor = color;
  const float centerAlpha = std::isfinite(RADAR_CENTER_ALPHA.GetValue())
                                ? RADAR_CENTER_ALPHA.GetValue()
                                : 0.0f;
  midcolor.a = std::clamp(centerAlpha, 0.0f, 1.0f);
  v[0].c = midcolor;
  v[1].c = color;
  const float percent = SanitizeRadarTween(m_PercentTowardNew);

  for (int i = 0; i < NUM_SHOWN_RADAR_CATEGORIES + 1;
       i++)  // do one extra to close the fan
  {
    const int c = i % NUM_SHOWN_RADAR_CATEGORIES;
    const float fDistFromCenter =
        (SanitizeRadarValue(m_fValuesOld[c]) * (1 - percent) +
         SanitizeRadarValue(m_fValuesNew[c]) * percent + 0.07f) *
        fRadius;
    const float fRotation = RADAR_VALUE_ROTATION(i);
    const float fX = std::cos(fRotation) * fDistFromCenter;
    const float fY = -std::sin(fRotation) * fDistFromCenter;

    v[1 + i].p = RageVector3(fX, fY, 0);
    v[1 + i].c = v[1].c;
  }

  DISPLAY->DrawFan(v, NUM_SHOWN_RADAR_CATEGORIES + 2);

  // use a line loop to draw the thick line
  for (int i = 0; i <= NUM_SHOWN_RADAR_CATEGORIES; i++) {
    const int c = i % NUM_SHOWN_RADAR_CATEGORIES;
    const float fDistFromCenter =
        (SanitizeRadarValue(m_fValuesOld[c]) * (1 - percent) +
         SanitizeRadarValue(m_fValuesNew[c]) * percent + 0.07f) *
        fRadius;
    const float fRotation = RADAR_VALUE_ROTATION(i);
    const float fX = std::cos(fRotation) * fDistFromCenter;
    const float fY = -std::sin(fRotation) * fDistFromCenter;

    v[i].p = RageVector3(fX, fY, 0);
    v[i].c = this->m_pTempState->diffuse[0];
  }

  // TODO: Add this back in -Chris
  //	switch( PREFSMAN->m_iPolygonRadar )
  //	{
  //	case 0:		DISPLAY->DrawLoop_LinesAndPoints( v,
  // NUM_SHOWN_RADAR_CATEGORIES, RADAR_EDGE_WIDTH );	break; 	case 1:
  // DISPLAY->DrawLoop_Polys( v, NUM_SHOWN_RADAR_CATEGORIES, RADAR_EDGE_WIDTH );
  // break; 	default: 	case -1:
  const float edgeWidth = std::isfinite(RADAR_EDGE_WIDTH.GetValue())
                              ? std::max(0.0f, RADAR_EDGE_WIDTH.GetValue())
                              : 0.0f;
  DISPLAY->DrawLineStrip(v, NUM_SHOWN_RADAR_CATEGORIES + 1, edgeWidth);
  //	break;
  //	}
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the GrooveRadar. */
class LunaGrooveRadar : public Luna<GrooveRadar> {
 public:
  static int SetFromRadarValues(T* p, lua_State* L) {
    PlayerNumber pn = Enum::Check<PlayerNumber>(L, 1);
    if (lua_isnil(L, 2)) {
      p->SetEmpty(pn);
    } else {
      RadarValues* pRV = Luna<RadarValues>::check(L, 2);
      p->SetFromRadarValues(pn, *pRV);
    }
    COMMON_RETURN_SELF;
  }
  static int SetFromValues(T* p, lua_State* L) {
    PlayerNumber pn = Enum::Check<PlayerNumber>(L, 1);
    if (!lua_istable(L, 2) || lua_isnil(L, 2)) {
      p->SetEmpty(pn);
    } else {
      std::vector<float> vals;
      LuaHelpers::ReadArrayFromTable(vals, L);
      p->SetFromValues(pn, vals);
    }
    COMMON_RETURN_SELF;
  }
  static int SetEmpty(T* p, lua_State* L) {
    p->SetEmpty(Enum::Check<PlayerNumber>(L, 1));
    COMMON_RETURN_SELF;
  }

  LunaGrooveRadar() {
    ADD_METHOD(SetFromRadarValues);
    ADD_METHOD(SetFromValues);
    ADD_METHOD(SetEmpty);
  }
};

LUA_REGISTER_DERIVED_CLASS(GrooveRadar, ActorFrame)
// lua end

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
