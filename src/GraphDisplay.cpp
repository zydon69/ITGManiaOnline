#include "GraphDisplay.h"

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include "Actor.h"
#include "ActorFrame.h"
#include "ActorUtil.h"
#include "LuaManager.h"
#include "RageLog.h"
#include "RageDisplay.h"
#include "RageMath.h"
#include "RageTexture.h"
#include "RageTextureManager.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "Song.h"
#include "StageStats.h"
#include "ThemeManager.h"

// #define DIVIDE_LINE_WIDTH
// THEME->GetMetricI(m_sName,"TexturedBottomHalf")
REGISTER_ACTOR_CLASS(GraphDisplay);

enum { VALUE_RESOLUTION = 100 };

namespace {
void WarnGraphDisplayAuditFix(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

void TraceGraphDisplayAuditFix(const char* message) {
  if (LOG != nullptr) {
    LOG->Trace("%s", message);
  }
}

bool IsFiniteGraphPoint(const RageSpriteVertex& vertex) {
  return std::isfinite(vertex.p.x) && std::isfinite(vertex.p.y) &&
         std::isfinite(vertex.p.z);
}

void DetachAndUnloadAutoActor(ActorFrame& frame, AutoActor& actor) {
  if (!actor.IsLoaded()) {
    return;
  }
  frame.RemoveChild(actor);
  actor.Unload();
}
}  // namespace

class GraphLine : public Actor {
 public:
  enum { iSubdivisions = 4 };
  enum { iCircleVertices = iSubdivisions + 2 };
  void DrawPrimitives() {
    if (DISPLAY == nullptr || m_pTempState == nullptr) {
      TraceGraphDisplayAuditFix(
          "SRC_AUDIT_FIX SRC-1074: GraphLine skipped draw without display "
          "state.");
      return;
    }

    Actor::SetGlobalRenderStates();  // set Actor-specified render states

    DISPLAY->ClearAllTextures();

    // Must call this after setting the texture or else texture
    // parameters have no effect.
    Actor::SetTextureRenderStates();

    for (unsigned i = 0; i < m_Quads.size(); ++i) {
      m_Quads[i].c = this->m_pTempState->diffuse[0];
    }
    for (unsigned i = 0; i < m_pCircles.size(); ++i) {
      m_pCircles[i].c = this->m_pTempState->diffuse[0];
    }

    if (!m_Quads.empty()) {
      DISPLAY->DrawQuads(m_Quads.data(), m_Quads.size());
    }

    int iFans = m_pCircles.size() / iCircleVertices;
    for (int i = 0; i < iFans; ++i) {
      DISPLAY->DrawFan(
          m_pCircles.data() + iCircleVertices * i, iCircleVertices);
    }
  }

  static void MakeCircle(
      const RageSpriteVertex& v, RageSpriteVertex* pVerts, int iSubdivisions,
      float fRadius) {
    if (pVerts == nullptr || iSubdivisions <= 0 || !std::isfinite(fRadius) ||
        !IsFiniteGraphPoint(v)) {
      return;
    }

    pVerts[0] = v;

    for (int i = 0; i < iSubdivisions + 1; ++i) {
      const float fRotation = float(i) / iSubdivisions * 2 * PI;
      const float fX = std::cos(fRotation) * fRadius;
      const float fY = -std::sin(fRotation) * fRadius;
      pVerts[1 + i] = v;
      pVerts[1 + i].p.x += fX;
      pVerts[1 + i].p.y += fY;
    }
  }

  void Set(const RageSpriteVertex* m_LineStrip, int iSize) {
    m_pCircles.clear();
    m_Quads.clear();
    if (m_LineStrip == nullptr || iSize <= 0) {
      TraceGraphDisplayAuditFix(
          "SRC_AUDIT_FIX SRC-257: GraphLine received empty line strip.");
      return;
    }

    std::vector<RageSpriteVertex> validLineStrip;
    validLineStrip.reserve(iSize);
    for (int i = 0; i < iSize; ++i) {
      if (IsFiniteGraphPoint(m_LineStrip[i])) {
        validLineStrip.push_back(m_LineStrip[i]);
      }
    }
    if (validLineStrip.empty()) {
      TraceGraphDisplayAuditFix(
          "SRC_AUDIT_FIX SRC-1074: GraphLine received no finite vertices.");
      return;
    }

    m_pCircles.resize(validLineStrip.size() * iCircleVertices);

    for (int i = 0; i < static_cast<int>(validLineStrip.size()); ++i) {
      MakeCircle(
          validLineStrip[i], &m_pCircles[0] + iCircleVertices * i,
          iSubdivisions,
          1);
    }

    int iNumLines = static_cast<int>(validLineStrip.size()) - 1;
    if (iNumLines <= 0) {
      return;
    }
    m_Quads.reserve(iNumLines * 4);
    for (int i = 0; i < iNumLines; ++i) {
      const RageSpriteVertex& p1 = validLineStrip[i];
      const RageSpriteVertex& p2 = validLineStrip[i + 1];

      float opp = p2.p.x - p1.p.x;
      float adj = p2.p.y - p1.p.y;
      float hyp = std::pow(opp * opp + adj * adj, 0.5f);
      if (!std::isfinite(hyp) || hyp <= 0.0001f) {
        TraceGraphDisplayAuditFix(
            "SRC_AUDIT_FIX SRC-258: GraphLine skipped invalid segment.");
        continue;
      }

      float lsin = opp / hyp;
      float lcos = adj / hyp;

      RageSpriteVertex v[4];
      v[0] = v[1] = p1;
      v[2] = v[3] = p2;

      int iLineWidth = 2;
      float ydist = lsin * iLineWidth / 2;
      float xdist = lcos * iLineWidth / 2;

      v[0].p.x += xdist;
      v[0].p.y -= ydist;
      v[1].p.x -= xdist;
      v[1].p.y += ydist;
      v[2].p.x -= xdist;
      v[2].p.y += ydist;
      v[3].p.x += xdist;
      v[3].p.y -= ydist;
      m_Quads.insert(m_Quads.end(), v, v + 4);
    }
  }

  virtual GraphLine* Copy() const;

 private:
  std::vector<RageSpriteVertex> m_Quads;
  std::vector<RageSpriteVertex> m_pCircles;
};
REGISTER_ACTOR_CLASS(GraphLine);

class GraphBody : public Actor {
 public:
  GraphBody(std::string sFile) {
    m_pTexture = sFile.empty() || TEXTUREMAN == nullptr
                     ? nullptr
                     : TEXTUREMAN->LoadTexture(sFile);
    if (m_pTexture == nullptr) {
      if (LOG != nullptr) {
        LOG->Warn(
            "SRC_AUDIT_FIX SRC-259: GraphBody could not load texture '%s'.",
            sFile.c_str());
      }
    }

    for (int i = 0; i < 2 * VALUE_RESOLUTION; ++i) {
      m_Slices[i].p = RageVector3(0, 0, 0);
      m_Slices[i].c = RageColor(1, 1, 1, 1);
      m_Slices[i].t = RageVector2(0, 0);
    }
  }
  ~GraphBody() {
    if (TEXTUREMAN != nullptr && m_pTexture != nullptr) {
      TEXTUREMAN->UnloadTexture(m_pTexture);
    }
    m_pTexture = nullptr;
  }

  void DrawPrimitives() {
    if (DISPLAY == nullptr || m_pTexture == nullptr) {
      return;
    }
    Actor::SetGlobalRenderStates();  // set Actor-specified render states

    DISPLAY->ClearAllTextures();
    DISPLAY->SetTexture(TextureUnit_1, m_pTexture->GetTexHandle());

    // Must call this after setting the texture or else texture
    // parameters have no effect.
    Actor::SetTextureRenderStates();

    DISPLAY->SetTextureMode(TextureUnit_1, TextureMode_Modulate);
    DISPLAY->DrawQuadStrip(m_Slices, ARRAYLEN(m_Slices));
  }

  RageTexture* m_pTexture;
  RageSpriteVertex m_Slices[2 * VALUE_RESOLUTION];
};

GraphDisplay::GraphDisplay() {
  m_pGraphLine = nullptr;
  m_pGraphBody = nullptr;
}

GraphDisplay::~GraphDisplay() {
  ClearGraphActors();
}

void GraphDisplay::ClearSongBoundaries() {
  for (Actor* p : m_vpSongBoundaries) {
    RemoveChild(p);
    RageUtil::SafeDelete(p);
  }
  m_vpSongBoundaries.clear();
}

void GraphDisplay::ClearGraphActors() {
  ClearSongBoundaries();

  DetachAndUnloadAutoActor(*this, m_sprBarely);
  DetachAndUnloadAutoActor(*this, m_sprBacking);
  DetachAndUnloadAutoActor(*this, m_sprSongBoundary);

  if (m_pGraphLine != nullptr) {
    RemoveChild(m_pGraphLine);
  }
  RageUtil::SafeDelete(m_pGraphLine);
  if (m_pGraphBody != nullptr) {
    RemoveChild(m_pGraphBody);
  }
  RageUtil::SafeDelete(m_pGraphBody);
}

void GraphDisplay::Set(const StageStats& ss, const PlayerStageStats& pss) {
  ClearSongBoundaries();

  float fTotalStepSeconds = ss.GetTotalPossibleStepsSeconds();
  if (!std::isfinite(fTotalStepSeconds) || fTotalStepSeconds <= 0.0f) {
    WarnGraphDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-261: GraphDisplay received invalid total seconds.");
    fTotalStepSeconds = 1.0f;
  }

  m_Values.assign(VALUE_RESOLUTION, 0.0f);
  pss.GetLifeRecord(
      m_Values.data(), VALUE_RESOLUTION, fTotalStepSeconds);
  for (float& value : m_Values) {
    if (!std::isfinite(value)) {
      TraceGraphDisplayAuditFix(
          "SRC_AUDIT_FIX SRC-260: GraphDisplay corrected non-finite life "
          "value.");
      value = 0.0f;
    }
    rage_clamp(value, 0.f, 1.f);
  }

  UpdateVerts();

  // Show song boundaries
  float fSec = 0;
  const std::vector<Song*>& possibleSongs = ss.m_vpPossibleSongs;

  if (possibleSongs.size() > 1) {
    std::for_each(
        possibleSongs.begin(), possibleSongs.end() - 1, [&](Song* song) {
          if (!m_sprSongBoundary.IsLoaded()) {
            TraceGraphDisplayAuditFix(
                "SRC_AUDIT_FIX SRC-1075: GraphDisplay skipped unloaded song "
                "boundary actor.");
            return;
          }
          if (song == nullptr) {
            TraceGraphDisplayAuditFix(
                "SRC_AUDIT_FIX SRC-261: GraphDisplay skipped null song "
                "boundary.");
            return;
          }
          const float songSeconds = song->GetStepsSeconds();
          if (!std::isfinite(songSeconds) || songSeconds < 0.0f) {
            TraceGraphDisplayAuditFix(
                "SRC_AUDIT_FIX SRC-261: GraphDisplay skipped invalid song "
                "seconds.");
            return;
          }
          fSec += songSeconds;

          Actor* p = m_sprSongBoundary->Copy();
          m_vpSongBoundaries.push_back(p);
          float fX = SCALE(
              fSec, 0, fTotalStepSeconds, m_quadVertices.left,
              m_quadVertices.right);
          p->SetX(fX);
          this->AddChild(p);
        });
  }

  if (!m_sprBarely.IsLoaded()) {
    return;
  }

  if (!pss.m_bFailed) {
    // Search for the min life record to show "Just Barely!"
    float fMinLifeSoFar = 1.0f;
    int iMinLifeSoFarAt = 0;

    for (int i = 0; i < VALUE_RESOLUTION; ++i) {
      float fLife = m_Values[i];
      if (fLife < fMinLifeSoFar) {
        fMinLifeSoFar = fLife;
        iMinLifeSoFarAt = i;
      }
    }

    if (fMinLifeSoFar > 0.0f && fMinLifeSoFar < 0.1f) {
      float fX = SCALE(
          float(iMinLifeSoFarAt), 0.0f, float(VALUE_RESOLUTION - 1),
          m_quadVertices.left, m_quadVertices.right);
      m_sprBarely->SetX(fX);
      m_sprBarely->SetVisible(true);
    } else {
      m_sprBarely->SetVisible(false);
    }
  } else {
    m_sprBarely->SetVisible(false);
  }
}

void GraphDisplay::Load(std::string sMetricsGroup) {
  ClearGraphActors();

  if (sMetricsGroup.empty()) {
    WarnGraphDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1071: GraphDisplay fell back from empty metrics "
        "group.");
    sMetricsGroup = "GraphDisplay";
  }

  if (THEME == nullptr) {
    WarnGraphDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1071: GraphDisplay refused load without THEME.");
    return;
  }

  m_size.x = THEME->GetMetricI(sMetricsGroup, "BodyWidth");
  m_size.y = THEME->GetMetricI(sMetricsGroup, "BodyHeight");
  if (m_size.x <= 0 || m_size.y <= 0) {
    WarnGraphDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1072: GraphDisplay corrected invalid body size.");
    m_size.x = std::max(m_size.x, 1.0f);
    m_size.y = std::max(m_size.y, 1.0f);
  }

  m_sprBacking.Load(THEME->GetPathG(sMetricsGroup, "Backing"));
  m_sprBacking->ZoomToWidth(m_size.x);
  m_sprBacking->ZoomToHeight(m_size.y);
  this->AddChild(m_sprBacking);

  m_pGraphBody = new GraphBody(THEME->GetPathG(sMetricsGroup, "Body", true));
  this->AddChild(m_pGraphBody);

  m_pGraphLine = new GraphLine;
  m_pGraphLine->SetName("Line");
  ActorUtil::LoadAllCommands(m_pGraphLine, sMetricsGroup);
  this->AddChild(m_pGraphLine);

  m_sprSongBoundary.Load(THEME->GetPathG(sMetricsGroup, "SongBoundary"));

  m_sprBarely.Load(THEME->GetPathG(sMetricsGroup, "Barely"));
  m_sprBarely->SetVisible(false);
  this->AddChild(m_sprBarely);
}

void GraphDisplay::UpdateVerts() {
  if (m_pGraphBody == nullptr || m_pGraphLine == nullptr ||
      m_pGraphBody->m_pTexture == nullptr ||
      m_Values.size() != VALUE_RESOLUTION) {
    TraceGraphDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-262: GraphDisplay skipped vertex update before "
        "complete load.");
    return;
  }
  if (!std::isfinite(m_size.x) || !std::isfinite(m_size.y) || m_size.x <= 0 ||
      m_size.y <= 0) {
    WarnGraphDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1073: GraphDisplay skipped invalid graph size.");
    return;
  }

  m_quadVertices.left = -m_size.x / 2;
  m_quadVertices.right = m_size.x / 2;
  m_quadVertices.top = -m_size.y / 2;
  m_quadVertices.bottom = m_size.y / 2;

  RageSpriteVertex LineStrip[VALUE_RESOLUTION];
  for (int i = 0; i < VALUE_RESOLUTION; ++i) {
    const float fX = SCALE(
        float(i), 0.0f, float(VALUE_RESOLUTION - 1), m_quadVertices.left,
        m_quadVertices.right);
    const float fY = SCALE(
        m_Values[i], 0.0f, 1.0f, m_quadVertices.bottom, m_quadVertices.top);

    m_pGraphBody->m_Slices[i * 2 + 0].p = RageVector3(fX, fY, 0);
    m_pGraphBody->m_Slices[i * 2 + 1].p =
        RageVector3(fX, m_quadVertices.bottom, 0);

    const RectF* pRect = m_pGraphBody->m_pTexture->GetTextureCoordRect(0);
    if (pRect == nullptr) {
      WarnGraphDisplayAuditFix(
          "SRC_AUDIT_FIX SRC-1073: GraphDisplay skipped null texture rect.");
      return;
    }

    const float fU = SCALE(
        fX, m_quadVertices.left, m_quadVertices.right, pRect->left,
        pRect->right);
    const float fV = SCALE(
        fY, m_quadVertices.top, m_quadVertices.bottom, pRect->top,
        pRect->bottom);
    m_pGraphBody->m_Slices[i * 2 + 0].t = RageVector2(fU, fV);
    m_pGraphBody->m_Slices[i * 2 + 1].t = RageVector2(fU, pRect->bottom);

    LineStrip[i].p = RageVector3(fX, fY, 0);
    LineStrip[i].c = RageColor(1, 1, 1, 1);
    LineStrip[i].t = RageVector2(0, 0);
  }

  m_pGraphLine->Set(LineStrip, VALUE_RESOLUTION);
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the GraphDisplay. */
class LunaGraphDisplay : public Luna<GraphDisplay> {
 public:
  static int Load(T* p, lua_State* L) {
    p->Load(SArg(1));
    COMMON_RETURN_SELF;
  }
  static int Set(T* p, lua_State* L) {
    StageStats* pStageStats = Luna<StageStats>::check(L, 1);
    PlayerStageStats* pPlayerStageStats = Luna<PlayerStageStats>::check(L, 2);
    if (pStageStats == nullptr) {
      luaL_error(L, "The StageStats passed to GraphDisplay:Set are nil.");
    }
    if (pPlayerStageStats == nullptr) {
      luaL_error(L, "The PlayerStageStats passed to GraphDisplay:Set are nil.");
    }
    p->Set(*pStageStats, *pPlayerStageStats);
    COMMON_RETURN_SELF;
  }

  LunaGraphDisplay() {
    ADD_METHOD(Load);
    ADD_METHOD(Set);
  }
};

LUA_REGISTER_DERIVED_CLASS(GraphDisplay, ActorFrame)
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
