#include "RadarValues.h"

#include <algorithm>
#include <string>
#include <vector>

#include "EnumHelper.h"
#include "GameConstantsAndTypes.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "ThemeMetric.h"
#include "XmlFile.h"
#include "global.h"

ThemeMetric<bool> RadarValues::WRITE_SIMPLE_VALIES(
    "RadarValues", "WriteSimpleValues");
ThemeMetric<bool> RadarValues::WRITE_COMPLEX_VALIES(
    "RadarValues", "WriteComplexValues");

RadarValues::RadarValues() { MakeUnknown(); }

bool RadarValues::IsValidCategory(int cat) {
  return cat >= 0 && cat < NUM_RadarCategory;
}

float& RadarValues::InvalidValue() {
  static float invalid = RADAR_VAL_UNKNOWN;
  LOG->Trace(
      "RadarValues ignored invalid mutable category access.");
  invalid = RADAR_VAL_UNKNOWN;
  return invalid;
}

const float& RadarValues::InvalidConstValue() {
  static const float invalid = RADAR_VAL_UNKNOWN;
  LOG->Trace("RadarValues ignored invalid category access.");
  return invalid;
}

void RadarValues::MakeUnknown() {
  FOREACH_ENUM(RadarCategory, rc) { (*this)[rc] = RADAR_VAL_UNKNOWN; }
}

void RadarValues::Zero() {
  FOREACH_ENUM(RadarCategory, rc) { (*this)[rc] = 0; }
}

XNode* RadarValues::CreateNode(
    bool bIncludeSimpleValues, bool bIncludeComplexValues) const {
  XNode* pNode = new XNode("RadarValues");

  // TRICKY: Don't print a remainder for the integer values.
  FOREACH_ENUM(RadarCategory, rc) {
    if (rc >= RadarCategory_TapsAndHolds) {
      if (bIncludeSimpleValues) {
        pNode->AppendChild(RadarCategoryToString(rc), (int)((*this)[rc]));
      }
    } else {
      if (bIncludeComplexValues) {
        pNode->AppendChild(RadarCategoryToString(rc), (*this)[rc]);
      }
    }
  }

  return pNode;
}

void RadarValues::LoadFromNode(const XNode* pNode) {
  if (pNode == nullptr || pNode->GetName() != "RadarValues") {
    LOG->Trace(
        "RadarValues ignored invalid XML node while loading.");
    MakeUnknown();
    return;
  }

  MakeUnknown();

  FOREACH_ENUM(RadarCategory, rc) {
    const std::string category = RadarCategoryToString(rc);
    const XNode* child = pNode->GetChild(category);
    if (child == nullptr) {
      continue;
    }
    std::string rawValue;
    child->GetTextValue(rawValue);
    float value = RADAR_VAL_UNKNOWN;
    if (!StringToFloat(rawValue, value)) {
      LOG->Trace(
          "RadarValues rejected malformed XML value "
          "'%s' for category '%s'.",
          rawValue.c_str(), category.c_str());
      continue;
    }
    (*this)[rc] = value;
  }
}

/* iMaxValues is only used for writing compatibility fields in non-cache
 * SM files; they're never actually read. */
std::string RadarValues::ToString(int iMaxValues) const {
  if (iMaxValues == -1) {
    iMaxValues = NUM_RadarCategory;
  }
  iMaxValues = std::min(iMaxValues, (int)NUM_RadarCategory);

  std::vector<std::string> asRadarValues;
  for (int r = 0; r < iMaxValues; r++) {
    asRadarValues.push_back(ssprintf("%.3f", (*this)[r]));
  }

  return join(",", asRadarValues);
}

void RadarValues::FromString(std::string sRadarValues) {
  std::vector<std::string> saValues;
  split(sRadarValues, ",", saValues, true);

  if (saValues.empty()) {
    MakeUnknown();
    return;
  }

  MakeUnknown();
  const size_t valuesToRead = std::min(saValues.size(), (size_t)NUM_RadarCategory);
  for (size_t rc = 0; rc < valuesToRead; ++rc) {
    float value = RADAR_VAL_UNKNOWN;
    if (!StringToFloat(saValues[rc], value)) {
      LOG->Trace(
          "RadarValues rejected malformed cached value '%s'.",
          saValues[rc].c_str());
      MakeUnknown();
      return;
    }
    (*this)[static_cast<int>(rc)] = value;
  }
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the RadarValues. */
class LunaRadarValues : public Luna<RadarValues> {
 public:
  static int GetValue(T* p, lua_State* L) {
    lua_pushnumber(L, (*p)[Enum::Check<RadarCategory>(L, 1)]);
    return 1;
  }

  LunaRadarValues() { ADD_METHOD(GetValue); }
};

LUA_REGISTER_CLASS(RadarValues)

void RadarValues::PushSelf(lua_State* L) const {
  const_cast<RadarValues*>(this)->PushSelf(L);
}
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
