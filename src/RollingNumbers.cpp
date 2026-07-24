#include "RollingNumbers.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <string>

#include "Actor.h"
#include "ActorUtil.h"
#include "BitmapText.h"
#include "LuaManager.h"
#include "RageLog.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "ThemeManager.h"

REGISTER_ACTOR_CLASS(RollingNumbers);

namespace {
void WarnRollingNumbersSafety(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

bool IsSafeRollingNumberFormat(const std::string& format) {
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
    while (j < format.size() && std::string("-+ #0").find(format[j]) != std::string::npos) {
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

std::string FormatRollingNumber(const std::string& format, float value) {
  if (!std::isfinite(value)) {
    WarnRollingNumbersSafety(
        "RollingNumbers reset non-finite text value.");
    value = 0.0f;
  }
  if (!IsSafeRollingNumberFormat(format)) {
    WarnRollingNumbersSafety(
        "RollingNumbers ignored unsafe TextFormat.");
    return ssprintf("%.0f", value);
  }
  return ssprintf(format.c_str(), value);
}
}  // namespace

RollingNumbers::RollingNumbers() {
  m_fCurrentNumber = 0;
  m_fTargetNumber = 0;
  m_fScoreVelocity = 0;
  m_metrics_loaded = false;
}

void RollingNumbers::Load(const std::string& sMetricsGroup) {
  if (THEME == nullptr) {
    WarnRollingNumbersSafety(
        "RollingNumbers refused load without THEME.");
    m_metrics_loaded = false;
    return;
  }
  const std::string sResolvedMetricsGroup =
      sMetricsGroup.empty() ? "RollingNumbers" : sMetricsGroup;
  if (sMetricsGroup.empty()) {
    WarnRollingNumbersSafety(
        "RollingNumbers fell back from empty metrics "
        "group.");
  }

  m_metrics_loaded = true;
  TEXT_FORMAT.Load(sResolvedMetricsGroup, "TextFormat");
  APPROACH_SECONDS.Load(sResolvedMetricsGroup, "ApproachSeconds");
  COMMIFY.Load(sResolvedMetricsGroup, "Commify");
  LEADING_ZERO_MULTIPLY_COLOR.Load(
      sResolvedMetricsGroup, "LeadingZeroMultiplyColor");

  UpdateText();
}

void RollingNumbers::DrawPart(
    const RageColor* diffuse, const RageColor& stroke, float crop_left,
    float crop_right) {
  if (diffuse == nullptr || m_pTempState == nullptr) {
    return;
  }
  if (!std::isfinite(crop_left)) {
    crop_left = 0.0f;
  }
  if (!std::isfinite(crop_right)) {
    crop_right = 0.0f;
  }
  rage_clamp(crop_left, 0.0f, 1.0f);
  rage_clamp(crop_right, 0.0f, 1.0f);
  for (int i = 0; i < NUM_DIFFUSE_COLORS; ++i) {
    m_pTempState->diffuse[i] = diffuse[i];
  }
  SetCurrStrokeColor(stroke);
  m_pTempState->crop.left = crop_left;
  m_pTempState->crop.right = crop_right;
  BitmapText::DrawPrimitives();
}

void RollingNumbers::DrawPrimitives() noexcept {
  if (!m_metrics_loaded || m_pTempState == nullptr) {
    return;
  }
  RageColor diffuse_orig[NUM_DIFFUSE_COLORS];
  RageColor diffuse_temp[NUM_DIFFUSE_COLORS];
  RageColor stroke_orig = GetCurrStrokeColor();
  RageColor stroke_temp = stroke_orig * LEADING_ZERO_MULTIPLY_COLOR;
  for (int i = 0; i < NUM_DIFFUSE_COLORS; ++i) {
    diffuse_orig[i] = m_pTempState->diffuse[i];
    diffuse_temp[i] = m_pTempState->diffuse[i] * LEADING_ZERO_MULTIPLY_COLOR;
  }
  float original_crop_left = m_pTempState->crop.left;
  float original_crop_right = m_pTempState->crop.right;

  std::string s = this->GetText();
  if (s.empty()) {
    BitmapText::DrawPrimitives();
    return;
  }
  int i;
  // find the first non-zero non-comma character, or the last character
  for (i = 0; i < (int)(s.length() - 1); i++) {
    if (s[i] != '0' && s[i] != ',') {
      break;
    }
  }

  // Rewind to the first number, even if it's a zero.  If the string is "0000",
  // we want the last zero to show in the regular color.
  for (; i >= 0; i--) {
    if (s[i] >= '0' && s[i] <= '9') {
      break;
    }
  }
  if (i < 0) {
    BitmapText::DrawPrimitives();
    return;
  }
  float f = i / (float)s.length();

  // draw leading part
  DrawPart(
      diffuse_temp, stroke_temp, std::max((float)0, original_crop_left),
      std::max(1 - f, original_crop_right));
  // draw regular color part
  DrawPart(
      diffuse_orig, stroke_orig, std::max(f, original_crop_left),
      std::max(0.0f, original_crop_right));

  m_pTempState->crop.left = original_crop_left;
  m_pTempState->crop.right = original_crop_right;
}

void RollingNumbers::Update(float fDeltaTime) {
  if (!std::isfinite(fDeltaTime) || fDeltaTime < 0.0f) {
    WarnRollingNumbersSafety(
        "RollingNumbers ignored invalid update delta.");
    BitmapText::Update(0.0f);
    return;
  }
  if (!std::isfinite(m_fCurrentNumber)) {
    m_fCurrentNumber = 0.0f;
  }
  if (!std::isfinite(m_fTargetNumber)) {
    m_fTargetNumber = 0.0f;
  }
  if (!std::isfinite(m_fScoreVelocity)) {
    m_fScoreVelocity = 0.0f;
  }
  if (m_fCurrentNumber != m_fTargetNumber) {
    fapproach(
        m_fCurrentNumber, m_fTargetNumber,
        std::abs(m_fScoreVelocity) * fDeltaTime);
    UpdateText();
  }

  BitmapText::Update(fDeltaTime);
}

void RollingNumbers::SetTargetNumber(float fTargetNumber) {
  if (!m_metrics_loaded) {
    LuaHelpers::ReportScriptError(
        "You must use Load to load the metrics for a RollingNumbers actor "
        "before doing anything else.");
    return;
  }
  if (fTargetNumber == m_fTargetNumber) {  // no change
    return;
  }
  if (!std::isfinite(fTargetNumber)) {
    WarnRollingNumbersSafety(
        "RollingNumbers reset non-finite target.");
    fTargetNumber = 0.0f;
  }
  if (!std::isfinite(m_fCurrentNumber)) {
    m_fCurrentNumber = 0.0f;
  }
  m_fTargetNumber = fTargetNumber;
  float approach_secs = APPROACH_SECONDS.GetValue();
  if (!std::isfinite(approach_secs) || approach_secs < 0.0f) {
    WarnRollingNumbersSafety(
        "RollingNumbers used instant approach for "
        "invalid ApproachSeconds.");
    approach_secs = 0.0f;
  }
  if (approach_secs > 0) {
    m_fScoreVelocity = (m_fTargetNumber - m_fCurrentNumber) / approach_secs;
  } else {
    m_fScoreVelocity = (m_fTargetNumber - m_fCurrentNumber);
  }
}

void RollingNumbers::UpdateText() {
  if (!m_metrics_loaded) {
    return;
  }
  std::string s =
      FormatRollingNumber(TEXT_FORMAT.GetValue(), m_fCurrentNumber);
  if (COMMIFY) {
    s = Commify(s);
  }
  SetText(s);
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the RollingNumbers. */
class LunaRollingNumbers : public Luna<RollingNumbers> {
 public:
  static int Load(T* p, lua_State* L) {
    p->Load(SArg(1));
    COMMON_RETURN_SELF;
  }
  static int targetnumber(T* p, lua_State* L) {
    p->SetTargetNumber(FArg(1));
    COMMON_RETURN_SELF;
  }

  LunaRollingNumbers() {
    ADD_METHOD(Load);
    ADD_METHOD(targetnumber);
  }
};

LUA_REGISTER_DERIVED_CLASS(RollingNumbers, BitmapText)

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
