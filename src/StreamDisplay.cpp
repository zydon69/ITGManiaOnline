#include "StreamDisplay.h"

#include <algorithm>
#include <cfloat>
#include <cmath>
#include <string>

#include "ActorFrame.h"
#include "EnumHelper.h"
#include "RageLog.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "Sprite.h"
#include "ThemeManager.h"
#include "global.h"

static const char* StreamTypeNames[] = {
    "Normal",
    "Passing",
    "Hot",
};
XToString(StreamType);

namespace {
void WarnStreamDisplayAuditFix(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

float SanitizeStreamDisplayUnit(float value, const char* field) {
  if (!std::isfinite(value)) {
    if (LOG != nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-1069: StreamDisplay reset non-finite %s.", field);
    }
    return 0.0f;
  }
  rage_clamp(value, 0.0f, 1.0f);
  return value;
}

float SanitizeStreamDisplayMetric(float value, float fallback, const char* name) {
  if (!std::isfinite(value)) {
    if (LOG != nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-1068: StreamDisplay used fallback for %s.", name);
    }
    return fallback;
  }
  return value;
}
}  // namespace

StreamDisplay::StreamDisplay() {
  m_fPercent = 0;
  m_fTrailingPercent = 0;
  m_fVelocity = 0;
  m_fPassingAlpha = 0;
  m_fHotAlpha = 0;
  m_bAlwaysBounce = false;

  m_bDeleteChildren = true;
}

void StreamDisplay::Load(
    const std::string& _sMetricsGroup) {
  DeleteAllChildren();
  FOREACH_ENUM(StreamType, st) {
    m_vpSprPill[st].clear();
  }

  std::string sMetricsGroup =
      _sMetricsGroup.empty() ? "StreamDisplay" : _sMetricsGroup;
  if (THEME == nullptr) {
    WarnStreamDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1067: StreamDisplay refused load without THEME.");
    return;
  }

  m_transformPill.SetFromReference(
      THEME->GetMetricR(sMetricsGroup, "PillTransformFunction"));
  VELOCITY_MULTIPLIER.Load(sMetricsGroup, "VelocityMultiplier");
  VELOCITY_MIN.Load(sMetricsGroup, "VelocityMin");
  VELOCITY_MAX.Load(sMetricsGroup, "VelocityMax");
  SPRING_MULTIPLIER.Load(sMetricsGroup, "SpringMultiplier");
  VISCOSITY_MULTIPLIER.Load(sMetricsGroup, "ViscosityMultiplier");

  float fTextureCoordScaleX =
      THEME->GetMetricF(sMetricsGroup, "TextureCoordScaleX");
  int iNumPills =
      static_cast<int>(THEME->GetMetricF(sMetricsGroup, "NumPills"));
  if (!std::isfinite(fTextureCoordScaleX) || fTextureCoordScaleX <= 0.0f) {
    WarnStreamDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1068: StreamDisplay used safe texture coord scale.");
    fTextureCoordScaleX = 1.0f;
  }
  if (iNumPills <= 0) {
    WarnStreamDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1068: StreamDisplay used one pill for invalid "
        "NumPills.");
    iNumPills = 1;
  }
  m_bAlwaysBounce = THEME->GetMetricB(sMetricsGroup, "AlwaysBounceNormalBar");

  FOREACH_ENUM(StreamType, st) {
    for (int i = 0; i < iNumPills; i++) {
      Sprite* pSpr = new Sprite;

      pSpr->Load(THEME->GetPathG(sMetricsGroup, StreamTypeToString(st)));
      m_vpSprPill[st].push_back(pSpr);

      m_transformPill.TransformItemDirect(*pSpr, -1, i, iNumPills);
      float f = 1 / fTextureCoordScaleX;
      pSpr->SetCustomTextureRect(RectF(f * i, 0, f * (i + 1), 1));

      this->AddChild(pSpr);
    }
  }
}

void StreamDisplay::Update(float fDeltaSecs) {
  if (!std::isfinite(fDeltaSecs) || fDeltaSecs < 0.0f) {
    WarnStreamDisplayAuditFix(
        "SRC_AUDIT_FIX SRC-1070: StreamDisplay ignored invalid update delta.");
    return;
  }
  ActorFrame::Update(fDeltaSecs);

  if (m_vpSprPill[StreamType_Normal].empty()) {
    return;
  }

  m_fPercent = SanitizeStreamDisplayUnit(m_fPercent, "percent");
  if (!std::isfinite(m_fTrailingPercent)) {
    m_fTrailingPercent = m_fPercent;
  }
  if (!std::isfinite(m_fVelocity)) {
    m_fVelocity = 0.0f;
  }

  const float fVelocityMultiplier =
      SanitizeStreamDisplayMetric(VELOCITY_MULTIPLIER, 0.0f, "velocity");
  float fVelocityMin =
      SanitizeStreamDisplayMetric(VELOCITY_MIN, -FLT_MAX, "velocity min");
  float fVelocityMax =
      SanitizeStreamDisplayMetric(VELOCITY_MAX, FLT_MAX, "velocity max");
  if (fVelocityMin > fVelocityMax) {
    std::swap(fVelocityMin, fVelocityMax);
  }
  const float fSpringMultiplier =
      SanitizeStreamDisplayMetric(SPRING_MULTIPLIER, 0.0f, "spring");
  const float fViscosityMultiplier =
      SanitizeStreamDisplayMetric(VISCOSITY_MULTIPLIER, 0.0f, "viscosity");

  // HACK:  Tweaking these values is very difficult.  Update the
  // "physics" many times so that the spring motion appears faster
  for (int i = 0; i < 10; i++) {
    const float fDelta = m_fPercent - m_fTrailingPercent;

    // Don't apply spring and viscous forces if we're full or empty.
    // Just move straight to either full or empty.
    if (m_fPercent <= 0 || m_fPercent >= 1) {
      if (std::abs(fDelta) < 0.00001f) {
        m_fVelocity = 0;  // prevent div/0
      } else {
        m_fVelocity = (fDelta / std::abs(fDelta)) * fVelocityMultiplier;
      }
    } else {
      const float fSpringForce = fDelta * fSpringMultiplier;
      m_fVelocity += fSpringForce * fDeltaSecs;

      const float fViscousForce = -m_fVelocity * fViscosityMultiplier;
      if (!m_bAlwaysBounce) {
        m_fVelocity += fViscousForce * fDeltaSecs;
      }
    }

    rage_clamp(m_fVelocity, fVelocityMin, fVelocityMax);

    m_fTrailingPercent += m_fVelocity * fDeltaSecs;
    if (!std::isfinite(m_fTrailingPercent)) {
      WarnStreamDisplayAuditFix(
          "SRC_AUDIT_FIX SRC-1070: StreamDisplay reset invalid trailing "
          "percent.");
      m_fTrailingPercent = m_fPercent;
      m_fVelocity = 0.0f;
      break;
    }
  }

  // Don't clamp life percentage a little outside the visible range so
  // that the clamp doesn't dampen the "jiggle" of the meter.
  rage_clamp(m_fTrailingPercent, -0.1f, 1.1f);

  // set crop of pills
  const float fPillWidthPercent =
      1.0f / static_cast<float>(m_vpSprPill[StreamType_Normal].size());
  FOREACH_ENUM(StreamType, st) {
    for (int i = 0; i < (int)m_vpSprPill[st].size(); i++) {
      Sprite* pSpr = m_vpSprPill[st][i];
      float fPercentFilledThisPill = SCALE(
          m_fTrailingPercent, fPillWidthPercent * i,
          fPillWidthPercent * (i + 1), 0.0f, 1.0f);
      rage_clamp(fPercentFilledThisPill, 0.0f, 1.0f);

      // XXX scale by current song speed

      pSpr->SetCropRight(1.0f - fPercentFilledThisPill);
      pSpr->SetTexCoordVelocity(-1, 0);

      // Optimization: Don't draw pills that are covered up
      switch (st) {
        DEFAULT_FAIL(st);
        case StreamType_Normal:
          pSpr->SetVisible(m_fPassingAlpha < 1 || m_fHotAlpha < 1);
          pSpr->SetDiffuseAlpha(1);
          break;
        case StreamType_Passing:
          pSpr->SetDiffuseAlpha(m_fPassingAlpha);
          pSpr->SetVisible(m_fHotAlpha < 1);
          break;
        case StreamType_Hot:
          pSpr->SetDiffuseAlpha(m_fHotAlpha);
          break;
      }
    }
  }
}

void StreamDisplay::SetPercent(float fPercent) {
#ifdef DEBUG
  float fLifeMultiplier =
      THEME == nullptr ? 1.0f : THEME->GetMetricF("LifeMeterBar", "LifeMultiplier");
#endif
  DEBUG_ASSERT(fPercent >= 0.0f && fPercent <= 1.0f * fLifeMultiplier);
  if (std::isnan(fPercent)) {
    DEBUG_ASSERT_M(0, "fPercent is NaN");
    fPercent = 1;
  }
  if (!std::isfinite(fPercent)) {
    DEBUG_ASSERT_M(0, "fPercent is infinite");
    fPercent = 1;
  }
  rage_clamp(fPercent, 0.0f, 1.0f);

  float fDeltaPercent = fPercent - m_fPercent;
  m_fVelocity += fDeltaPercent;
  m_fPercent = fPercent;
}

void StreamDisplay::SetPassingAlpha(float fPassingAlpha) {
  m_fPassingAlpha = SanitizeStreamDisplayUnit(fPassingAlpha, "passing alpha");
}

void StreamDisplay::SetHotAlpha(float fHotAlpha) {
  m_fHotAlpha = SanitizeStreamDisplayUnit(fHotAlpha, "hot alpha");
}

/*
 * (c) 2003-2004 Chris Danford
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
