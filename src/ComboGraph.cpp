#include "ComboGraph.h"

#include <algorithm>
#include <cmath>
#include <string>

#include "Actor.h"
#include "ActorFrame.h"
#include "ActorUtil.h"
#include "BitmapText.h"
#include "LuaManager.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "StageStats.h"
#include "ThemeManager.h"

const int MinComboSizeToShow = 5;

REGISTER_ACTOR_CLASS(ComboGraph);

namespace {
void WarnComboGraphAuditFix(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

void TraceComboGraphAuditFix(const char* message) {
  if (LOG != nullptr) {
    LOG->Trace("%s", message);
  }
}

float SanitizeComboGraphDimension(float value, const char* name) {
  if (!std::isfinite(value) || value <= 0.0f) {
    if (LOG != nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-1076: ComboGraph used fallback for invalid %s.",
          name);
    }
    return 1.0f;
  }
  return value;
}
}  // namespace

ComboGraph::ComboGraph() {
  DeleteChildrenWhenDone(true);

  m_fBodyWidth = 1.0f;
  m_fBodyHeight = 1.0f;
  m_pBacking = nullptr;
  m_pNormalCombo = nullptr;
  m_pMaxCombo = nullptr;
  m_pComboNumber = nullptr;
}

ComboGraph::ComboGraph(const ComboGraph& cpy)
    : ActorFrame(cpy),
      BODY_WIDTH(cpy.BODY_WIDTH),
      BODY_HEIGHT(cpy.BODY_HEIGHT),
      m_fBodyWidth(cpy.m_fBodyWidth),
      m_fBodyHeight(cpy.m_fBodyHeight),
      m_pBacking(nullptr),
      m_pNormalCombo(nullptr),
      m_pMaxCombo(nullptr),
      m_pComboNumber(nullptr) {
  DeleteAllChildren();
  DeleteChildrenWhenDone(true);

  if (cpy.m_pBacking != nullptr) {
    m_pBacking = cpy.m_pBacking->Copy();
    if (m_pBacking != nullptr) {
      AddChild(m_pBacking);
    }
  }
  if (cpy.m_pNormalCombo != nullptr) {
    m_pNormalCombo = cpy.m_pNormalCombo->Copy();
    if (m_pNormalCombo != nullptr) {
      AddChild(m_pNormalCombo);
    }
  }
  if (cpy.m_pMaxCombo != nullptr) {
    m_pMaxCombo = cpy.m_pMaxCombo->Copy();
    if (m_pMaxCombo != nullptr) {
      AddChild(m_pMaxCombo);
    }
  }
  if (cpy.m_pComboNumber != nullptr) {
    Actor* pActor = cpy.m_pComboNumber->Copy();
    m_pComboNumber = dynamic_cast<BitmapText*>(pActor);
    if (m_pComboNumber != nullptr) {
      AddChild(m_pComboNumber);
    } else {
      RageUtil::SafeDelete(pActor);
      WarnComboGraphAuditFix(
          "SRC_AUDIT_FIX SRC-1094: ComboGraph skipped invalid copied combo "
          "number template.");
    }
  }
}

ComboGraph::~ComboGraph() { ClearGeneratedActors(); }

void ComboGraph::ClearGeneratedActors() {
  for (Actor* actor : m_vpGeneratedActors) {
    RemoveChild(actor);
    RageUtil::SafeDelete(actor);
  }
  m_vpGeneratedActors.clear();
}

void ComboGraph::ClearTemplateActors() {
  ClearGeneratedActors();

  if (m_pBacking != nullptr) {
    RemoveChild(m_pBacking);
  }
  RageUtil::SafeDelete(m_pBacking);

  if (m_pNormalCombo != nullptr) {
    RemoveChild(m_pNormalCombo);
  }
  RageUtil::SafeDelete(m_pNormalCombo);

  if (m_pMaxCombo != nullptr) {
    RemoveChild(m_pMaxCombo);
  }
  RageUtil::SafeDelete(m_pMaxCombo);

  if (m_pComboNumber != nullptr) {
    RemoveChild(m_pComboNumber);
  }
  RageUtil::SafeDelete(m_pComboNumber);
}

void ComboGraph::Load(std::string sMetricsGroup) {
  ClearTemplateActors();

  if (sMetricsGroup.empty()) {
    WarnComboGraphAuditFix(
        "SRC_AUDIT_FIX SRC-1076: ComboGraph fell back from empty metrics "
        "group.");
    sMetricsGroup = "ComboGraph";
  }
  if (THEME == nullptr) {
    WarnComboGraphAuditFix(
        "SRC_AUDIT_FIX SRC-1076: ComboGraph refused load without THEME.");
    return;
  }

  BODY_WIDTH.Load(sMetricsGroup, "BodyWidth");
  BODY_HEIGHT.Load(sMetricsGroup, "BodyHeight");
  m_fBodyWidth = SanitizeComboGraphDimension(BODY_WIDTH, "BodyWidth");
  m_fBodyHeight = SanitizeComboGraphDimension(BODY_HEIGHT, "BodyHeight");

  // These need to be set so that a theme can use zoomtowidth/zoomtoheight and
  // get correct behavior.
  this->SetWidth(m_fBodyWidth);
  this->SetHeight(m_fBodyHeight);

  Actor* pActor = nullptr;

  m_pBacking = ActorUtil::MakeActor(THEME->GetPathG(sMetricsGroup, "Backing"));
  if (m_pBacking != nullptr) {
    m_pBacking->ZoomToWidth(m_fBodyWidth);
    m_pBacking->ZoomToHeight(m_fBodyHeight);
    this->AddChild(m_pBacking);
  }

  m_pNormalCombo =
      ActorUtil::MakeActor(THEME->GetPathG(sMetricsGroup, "NormalCombo"));
  if (m_pNormalCombo != nullptr) {
    m_pNormalCombo->ZoomToWidth(m_fBodyWidth);
    m_pNormalCombo->ZoomToHeight(m_fBodyHeight);
    this->AddChild(m_pNormalCombo);
  }

  m_pMaxCombo =
      ActorUtil::MakeActor(THEME->GetPathG(sMetricsGroup, "MaxCombo"));
  if (m_pMaxCombo != nullptr) {
    m_pMaxCombo->ZoomToWidth(m_fBodyWidth);
    m_pMaxCombo->ZoomToHeight(m_fBodyHeight);
    this->AddChild(m_pMaxCombo);
  }

  pActor = ActorUtil::MakeActor(THEME->GetPathG(sMetricsGroup, "ComboNumber"));
  if (pActor != nullptr) {
    m_pComboNumber = dynamic_cast<BitmapText*>(pActor);
    if (m_pComboNumber != nullptr) {
      this->AddChild(m_pComboNumber);
    } else {
      LuaHelpers::ReportScriptErrorFmt(
          "ComboGraph: \"sMetricsGroup\" \"ComboNumber\" must be a BitmapText");
      RageUtil::SafeDelete(pActor);
    }
  }
}

void ComboGraph::Set(const StageStats& s, const PlayerStageStats& pss) {
  ClearGeneratedActors();

  const float fFirstSecond = 0;
  const float fLastSecond = s.GetTotalPossibleStepsSeconds();
  if (!std::isfinite(fLastSecond) || fLastSecond <= fFirstSecond) {
    WarnComboGraphAuditFix(
        "SRC_AUDIT_FIX SRC-264: ComboGraph ignored invalid total seconds.");
    return;
  }
  if (m_pNormalCombo == nullptr || m_pMaxCombo == nullptr ||
      m_pComboNumber == nullptr) {
    WarnComboGraphAuditFix(
        "SRC_AUDIT_FIX SRC-263: ComboGraph missing required templates.");
    return;
  }

  // Find the largest combo.
  int iMaxComboSize = 0;
  for (unsigned i = 0; i < pss.m_ComboList.size(); ++i) {
    const PlayerStageStats::Combo_t& combo = pss.m_ComboList[i];
    if (combo.GetStageCnt() < MinComboSizeToShow ||
        !std::isfinite(combo.m_fStartSecond) ||
        !std::isfinite(combo.m_fSizeSeconds) || combo.m_fSizeSeconds <= 0.0f) {
      continue;
    }
    const float fStart = std::max(combo.m_fStartSecond, fFirstSecond);
    const float fEnd =
        std::min(combo.m_fStartSecond + combo.m_fSizeSeconds, fLastSecond);
    if (fEnd <= fStart) {
      continue;
    }
    iMaxComboSize = std::max(iMaxComboSize, combo.GetStageCnt());
  }

  for (unsigned i = 0; i < pss.m_ComboList.size(); ++i) {
    const PlayerStageStats::Combo_t& combo = pss.m_ComboList[i];
    if (combo.GetStageCnt() < MinComboSizeToShow) {
      continue;  // too small
    }

    const bool bIsMax = (combo.GetStageCnt() == iMaxComboSize);
    if (!std::isfinite(combo.m_fStartSecond) ||
        !std::isfinite(combo.m_fSizeSeconds) || combo.m_fSizeSeconds <= 0.0f) {
      TraceComboGraphAuditFix(
          "SRC_AUDIT_FIX SRC-264: ComboGraph skipped invalid combo timing.");
      continue;
    }
    const float fClampedStart = std::max(combo.m_fStartSecond, fFirstSecond);
    const float fClampedEnd =
        std::min(combo.m_fStartSecond + combo.m_fSizeSeconds, fLastSecond);
    if (fClampedEnd <= fClampedStart) {
      TraceComboGraphAuditFix(
          "SRC_AUDIT_FIX SRC-1078: ComboGraph skipped out-of-range combo.");
      continue;
    }

    if (LOG != nullptr) {
      LOG->Trace(
          "combo %i is %f+%f of %f", i, fClampedStart,
          fClampedEnd - fClampedStart, fLastSecond);
    }
    Actor* pSprite = bIsMax ? m_pMaxCombo->Copy() : m_pNormalCombo->Copy();
    if (pSprite == nullptr) {
      WarnComboGraphAuditFix(
          "SRC_AUDIT_FIX SRC-1079: ComboGraph skipped null copied combo "
          "template.");
      continue;
    }

    const float fStart =
        SCALE(fClampedStart, fFirstSecond, fLastSecond, 0.0f, 1.0f);
    const float fSize =
        SCALE(
            fClampedEnd - fClampedStart, 0, fLastSecond - fFirstSecond, 0.0f,
            1.0f);
    pSprite->SetCropLeft(SCALE(fSize, 0.0f, 1.0f, 0.5f, 0.0f));
    pSprite->SetCropRight(SCALE(fSize, 0.0f, 1.0f, 0.5f, 0.0f));

    pSprite->SetCropLeft(fStart);
    pSprite->SetCropRight(1 - (fSize + fStart));

    this->AddChild(pSprite);
    m_vpGeneratedActors.push_back(pSprite);
  }

  for (unsigned i = 0; i < pss.m_ComboList.size(); ++i) {
    const PlayerStageStats::Combo_t& combo = pss.m_ComboList[i];
    if (combo.GetStageCnt() < MinComboSizeToShow) {
      continue;  // too small
    }

    if (!iMaxComboSize) {
      continue;
    }

    const bool bIsMax = (combo.GetStageCnt() == iMaxComboSize);
    if (!bIsMax) {
      continue;
    }
    if (!std::isfinite(combo.m_fStartSecond) ||
        !std::isfinite(combo.m_fSizeSeconds) || combo.m_fSizeSeconds <= 0.0f) {
      continue;
    }
    const float fClampedStart = std::max(combo.m_fStartSecond, fFirstSecond);
    const float fClampedEnd =
        std::min(combo.m_fStartSecond + combo.m_fSizeSeconds, fLastSecond);
    if (fClampedEnd <= fClampedStart) {
      continue;
    }

    BitmapText* pText = m_pComboNumber->Copy();
    if (pText == nullptr) {
      WarnComboGraphAuditFix(
          "SRC_AUDIT_FIX SRC-1079: ComboGraph skipped null copied combo "
          "number.");
      continue;
    }

    const float fStart =
        SCALE(fClampedStart, fFirstSecond, fLastSecond, 0.0f, 1.0f);
    const float fSize =
        SCALE(
            fClampedEnd - fClampedStart, 0, fLastSecond - fFirstSecond, 0.0f,
            1.0f);

    const float fCenterPercent = fStart + fSize / 2;
    const float fCenterXPos = SCALE(
        fCenterPercent, 0.0f, 1.0f, -m_fBodyWidth / 2.0f,
        m_fBodyWidth / 2.0f);
    pText->SetX(fCenterXPos);

    pText->SetText(ssprintf("%i", combo.GetStageCnt()));

    this->AddChild(pText);
    m_vpGeneratedActors.push_back(pText);
  }

  // Hide the templates.
  m_pNormalCombo->SetVisible(false);
  m_pMaxCombo->SetVisible(false);
  m_pComboNumber->SetVisible(false);
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the ComboGraph. */
class LunaComboGraph : public Luna<ComboGraph> {
 public:
  static int Load(T* p, lua_State* L) {
    p->Load(SArg(1));
    COMMON_RETURN_SELF;
  }
  static int Set(T* p, lua_State* L) {
    StageStats* pStageStats =
        lua_isnil(L, 1) ? nullptr : Luna<StageStats>::check(L, 1);
    PlayerStageStats* pPlayerStageStats =
        lua_isnil(L, 2) ? nullptr : Luna<PlayerStageStats>::check(L, 2);
    if (pStageStats == nullptr) {
      luaL_error(L, "The StageStats passed to ComboGraph:Set are nil.");
    }
    if (pPlayerStageStats == nullptr) {
      luaL_error(L, "The PlayerStageStats passed to ComboGraph:Set are nil.");
    }
    p->Set(*pStageStats, *pPlayerStageStats);
    COMMON_RETURN_SELF;
  }

  LunaComboGraph() {
    ADD_METHOD(Load);
    ADD_METHOD(Set);
  }
};

LUA_REGISTER_DERIVED_CLASS(ComboGraph, ActorFrame)
// lua end

/*
 * (c) 2003 Glenn Maynard
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
