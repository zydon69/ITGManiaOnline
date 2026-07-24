#include "TechCounts.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <string>
#include <vector>

#include "EnumHelper.h"
#include "GameConstantsAndTypes.h"
#include "LuaBinding.h"
#include "LuaManager.h"
#include "NoteAnnotation.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "StepParityDatastructs.h"

static const char* TechCountsCategoryNames[] = {
    "Crossovers",     "HalfCrossovers",   "FullCrossovers", "Footswitches",
    "UpFootswitches", "DownFootswitches", "Sideswitches",   "Jacks",
    "Brackets",       "Doublesteps"};

XToString(TechCountsCategory);
XToLocalizedString(TechCountsCategory);
LuaFunction(
    TechCountsCategoryToLocalizedString,
    TechCountsCategoryToLocalizedString(Enum::Check<TechCountsCategory>(L, 1)));
LuaXType(TechCountsCategory);

// 0.176 ~= 1/8th at 175bpm
// Anything slower isn't counted as a jack
constexpr float JACK_CUTOFF = 0.176f;
// 0.3 = 1/4th at 200bpm (or 3/16th at 150bpm)
// Anything slower isn't counted as a footswitch
constexpr float FOOTSWITCH_CUTOFF = 0.3f;
// 0.235 ~= 1/8th at 128bpm
// Anything slower isn't counted as a doublestep
constexpr float DOUBLESTEP_CUTOFF = 0.235f;

static bool IsValidLayoutColumn(
    const StepParity::StageLayout* layout, int column) {
  return layout != nullptr && column >= 0 && column < layout->columnCount &&
         column < static_cast<int>(layout->columns.size());
}

static bool IsValidRowColumn(const StepParity::Row& row, int column) {
  return column >= 0 && column < static_cast<int>(row.columns.size());
}

static bool IsValidFootColumn(
    const StepParity::StageLayout* layout, int column) {
  return column == StepParity::INVALID_COLUMN ||
         IsValidLayoutColumn(layout, column);
}

static bool ValidateLayoutColumns(
    const StepParity::StageLayout* layout, const std::vector<int>& columns,
    const char* label) {
  for (int column : columns) {
    if (!IsValidLayoutColumn(layout, column)) {
      LOG->Warn(
          "TechCounts layout has invalid %s column %d.",
          label, column);
      return false;
    }
  }
  return true;
}

static bool ValidateTechCountsInput(
    const std::vector<StepParity::Row>& rows,
    const StepParity::StageLayout* layout) {
  if (layout == nullptr) {
    LOG->Warn("TechCounts requested without layout.");
    return false;
  }
  if (layout->columnCount <= 0 ||
      layout->columns.size() != static_cast<size_t>(layout->columnCount)) {
    LOG->Warn(
        "TechCounts layout column count mismatch "
        "(columnCount=%d, columns=%zu).",
        layout->columnCount, layout->columns.size());
    return false;
  }
  if (!ValidateLayoutColumns(layout, layout->upArrows, "up") ||
      !ValidateLayoutColumns(layout, layout->downArrows, "down") ||
      !ValidateLayoutColumns(layout, layout->sideArrows, "side")) {
    return false;
  }

  for (size_t rowIndex = 0; rowIndex < rows.size(); ++rowIndex) {
    const StepParity::Row& row = rows[rowIndex];
    if (!std::isfinite(row.second) || !std::isfinite(row.beat) ||
        (rowIndex > 0 && row.second < rows[rowIndex - 1].second)) {
      LOG->Warn(
          "TechCounts row %zu has invalid/non-monotonic "
          "timing (beat=%.6f second=%.6f).",
          rowIndex, row.beat, row.second);
      return false;
    }
    if (row.columns.size() != static_cast<size_t>(layout->columnCount)) {
      LOG->Warn(
          "TechCounts row %zu has %zu columns; "
          "expected %d.",
          rowIndex, row.columns.size(), layout->columnCount);
      return false;
    }
    if (row.whereTheFeetAre.size() < StepParity::NUM_Foot) {
      LOG->Warn(
          "TechCounts row %zu has %zu foot "
          "placements; expected at least %d.",
          rowIndex, row.whereTheFeetAre.size(), StepParity::NUM_Foot);
      return false;
    }
    for (StepParity::Foot foot : StepParity::FEET) {
      if (!IsValidFootColumn(layout, row.whereTheFeetAre[foot])) {
        LOG->Warn(
            "TechCounts row %zu has invalid foot "
            "placement column %d.",
            rowIndex, row.whereTheFeetAre[foot]);
        return false;
      }
    }
  }

  return true;
}

static void AddTechCount(
    TechCounts& out, NoteAnnotation& annotation, TechCountsCategory category) {
  out[category] += 1;
  annotation.tech.push_back(category);
}

static NoteAnnotation MakeAnnotationForRow(const StepParity::Row& row) {
  NoteAnnotation annotation;
  annotation.beat = row.beat;
  annotation.whereTheFeetAre.reserve(row.whereTheFeetAre.size());
  for (int column : row.whereTheFeetAre) {
    annotation.whereTheFeetAre.push_back(static_cast<int8_t>(std::clamp(
        column, static_cast<int>(std::numeric_limits<int8_t>::min()),
        static_cast<int>(std::numeric_limits<int8_t>::max()))));
  }
  return annotation;
}

// TechCounts methods
TechCounts::TechCounts() { MakeUnknown(); }

void TechCounts::MakeUnknown() {
  FOREACH_ENUM(TechCountsCategory, rc) { (*this)[rc] = TECHCOUNTS_VAL_UNKNOWN; }
}

void TechCounts::Zero() {
  FOREACH_ENUM(TechCountsCategory, rc) { (*this)[rc] = 0; }
}

bool TechCounts::IsValidCategoryIndex(int cat) {
  return cat >= 0 && cat < NUM_TechCountsCategory;
}

float& TechCounts::InvalidMutableValue(int cat) {
  thread_local float invalidValue = TECHCOUNTS_VAL_UNKNOWN;
  invalidValue = TECHCOUNTS_VAL_UNKNOWN;
  LOG->Warn(
      "invalid mutable TechCounts index %d.", cat);
  return invalidValue;
}

float TechCounts::operator[](TechCountsCategory cat) const {
  return (*this)[static_cast<int>(cat)];
}

float& TechCounts::operator[](TechCountsCategory cat) {
  return (*this)[static_cast<int>(cat)];
}

float TechCounts::operator[](int cat) const {
  if (!IsValidCategoryIndex(cat)) {
    LOG->Warn("invalid TechCounts index %d.", cat);
    return TECHCOUNTS_VAL_UNKNOWN;
  }
  return m_Values[cat];
}

float& TechCounts::operator[](int cat) {
  if (!IsValidCategoryIndex(cat)) {
    return InvalidMutableValue(cat);
  }
  return m_Values[cat];
}

std::string TechCounts::ToString(int iMaxValues) const {
  if (iMaxValues == -1) {
    iMaxValues = NUM_TechCountsCategory;
  }
  iMaxValues = std::min(iMaxValues, (int)NUM_TechCountsCategory);

  std::vector<std::string> asTechCounts;
  for (int r = 0; r < iMaxValues; r++) {
    asTechCounts.push_back(ssprintf("%.6f", (*this)[r]));
  }

  return join(",", asTechCounts);
}

void TechCounts::FromString(std::string sTechCounts) {
  std::vector<std::string> saValues;
  split(sTechCounts, ",", saValues, true);

  MakeUnknown();
  if (saValues.size() != NUM_TechCountsCategory) {
    LOG->Warn(
        "TechCounts cache has %zu values; expected %d.",
        saValues.size(), NUM_TechCountsCategory);
  }

  const size_t valuesToRead =
      std::min(saValues.size(), static_cast<size_t>(NUM_TechCountsCategory));
  for (size_t i = 0; i < valuesToRead; ++i) {
    float value = TECHCOUNTS_VAL_UNKNOWN;
    if (!StringConversion::FromString<float>(saValues[i], value)) {
      LOG->Warn(
          "invalid TechCounts value '%s' at index %zu.",
          saValues[i].c_str(), i);
      continue;
    }
    if (!std::isfinite(value) || value < TECHCOUNTS_VAL_UNKNOWN) {
      LOG->Warn(
          "invalid non-finite/out-of-range TechCounts value "
          "'%s' at index %zu.",
          saValues[i].c_str(), i);
      continue;
    }
    (*this)[static_cast<int>(i)] = value;
  }
}

void TechCounts::CalculateTechCountsFromRows(
    const std::vector<StepParity::Row>& rows,
    const StepParity::StageLayout* layout, TechCounts& out) {
  std::vector<NoteAnnotation> unusedAnnotations;
  CalculateTechCountsFromRows(rows, layout, out, unusedAnnotations);
}

void TechCounts::CalculateTechCountsFromRows(
    const std::vector<StepParity::Row>& rows,
    const StepParity::StageLayout* layout, TechCounts& out,
    std::vector<NoteAnnotation>& annotationsOut) {
  annotationsOut.clear();
  if (!ValidateTechCountsInput(rows, layout)) {
    out.MakeUnknown();
    return;
  }
  annotationsOut.reserve(rows.size());

  for (size_t i = 0; i < rows.size(); ++i) {
    const StepParity::Row& currentRow = rows[i];
    NoteAnnotation annotation = MakeAnnotationForRow(currentRow);

    // Jacks are same arrow same foot
    // Doublestep is same foot on successive arrows
    // Brackets are jumps with one foot

    // Footswitch is different foot on the up or down arrow
    // Sideswitch is footswitch on left or right arrow
    // Crossovers are left foot on right arrow or vice versa

    // Check for brackets before any previous-row comparisons so brackets on
    // the first row are counted.
    if (currentRow.noteCount >= 2) {
      if (currentRow.whereTheFeetAre[StepParity::LEFT_HEEL] !=
              StepParity::INVALID_COLUMN &&
          currentRow.whereTheFeetAre[StepParity::LEFT_TOE] !=
              StepParity::INVALID_COLUMN) {
        AddTechCount(out, annotation, TechCountsCategory_Brackets);
      }

      if (currentRow.whereTheFeetAre[StepParity::RIGHT_HEEL] !=
              StepParity::INVALID_COLUMN &&
          currentRow.whereTheFeetAre[StepParity::RIGHT_TOE] !=
              StepParity::INVALID_COLUMN) {
        AddTechCount(out, annotation, TechCountsCategory_Brackets);
      }
    }

    if (i == 0) {
      annotationsOut.push_back(annotation);
      continue;
    }

    const StepParity::Row& previousRow = rows[i - 1];
    float elapsedTime = currentRow.second - previousRow.second;

    // Check for jacks and doublesteps
    if (currentRow.noteCount == 1 && previousRow.noteCount == 1) {
      for (StepParity::Foot foot : StepParity::FEET) {
        if (currentRow.whereTheFeetAre[foot] == StepParity::INVALID_COLUMN ||
            previousRow.whereTheFeetAre[foot] == StepParity::INVALID_COLUMN) {
          continue;
        }

        if (previousRow.whereTheFeetAre[foot] ==
            currentRow.whereTheFeetAre[foot]) {
          if (elapsedTime < JACK_CUTOFF) {
            AddTechCount(out, annotation, TechCountsCategory_Jacks);
          }
        } else {
          if (elapsedTime < DOUBLESTEP_CUTOFF) {
            AddTechCount(out, annotation, TechCountsCategory_Doublesteps);
          }
        }
      }
    }

    // Check for up footswitches
    for (int c : layout->upArrows) {
      if (isFootswitch(c, currentRow, previousRow, elapsedTime)) {
        AddTechCount(out, annotation, TechCountsCategory_UpFootswitches);
        AddTechCount(out, annotation, TechCountsCategory_Footswitches);
      }
    }
    // Check for down footswitches
    for (int c : layout->downArrows) {
      if (isFootswitch(c, currentRow, previousRow, elapsedTime)) {
        AddTechCount(out, annotation, TechCountsCategory_DownFootswitches);
        AddTechCount(out, annotation, TechCountsCategory_Footswitches);
      }
    }

    // Check for sideswitches
    for (int c : layout->sideArrows) {
      if (isFootswitch(c, currentRow, previousRow, elapsedTime)) {
        AddTechCount(out, annotation, TechCountsCategory_Sideswitches);
      }
    }

    // Check for crossovers
    int leftHeel = currentRow.whereTheFeetAre[StepParity::LEFT_HEEL];
    int leftToe = currentRow.whereTheFeetAre[StepParity::LEFT_TOE];
    int rightHeel = currentRow.whereTheFeetAre[StepParity::RIGHT_HEEL];
    int rightToe = currentRow.whereTheFeetAre[StepParity::RIGHT_TOE];

    int previousLeftHeel = previousRow.whereTheFeetAre[StepParity::LEFT_HEEL];
    int previousLeftToe = previousRow.whereTheFeetAre[StepParity::LEFT_TOE];
    int previousRightHeel = previousRow.whereTheFeetAre[StepParity::RIGHT_HEEL];
    int previousRightToe = previousRow.whereTheFeetAre[StepParity::RIGHT_TOE];

    // Check for the following:
    // - We moved the right foot on this row,
    // - we moved the left foot on the previous row,
    // - we didn't move the right foot on the previous row
    // - Is the position of the right foot farther left than the left foot
    // - If so, check the row before the previous row for the following:
    //   - Was the right foot on a difference position
    //   - Was the right foot farther right than the left?
    //     - If so, then this was a full crossover (like RDL, starting on right
    //     foot)
    //     - otherwise, then this was probably a half crossover (like UDL,
    //     starting on right foot)
    if (rightHeel != StepParity::INVALID_COLUMN &&
        previousLeftHeel != StepParity::INVALID_COLUMN &&
        previousRightHeel == StepParity::INVALID_COLUMN) {
      StepParity::StagePoint leftPos =
          layout->averagePoint(previousLeftHeel, previousLeftToe);
      StepParity::StagePoint rightPos =
          layout->averagePoint(rightHeel, rightToe);

      if (rightPos.x < leftPos.x) {
        if (i > 1) {
          const StepParity::Row& previousPreviousRow = rows[i - 2];
          int previousPreviousRightHeel =
              previousPreviousRow.whereTheFeetAre[StepParity::RIGHT_HEEL];

          if (previousPreviousRightHeel != StepParity::INVALID_COLUMN &&
              previousPreviousRightHeel != rightHeel) {
            StepParity::StagePoint previousPreviousRightPos =
                layout->columns[previousPreviousRightHeel];
            if (previousPreviousRightPos.x > leftPos.x) {
              AddTechCount(
                  out, annotation, TechCountsCategory_FullCrossovers);
            } else {
              AddTechCount(
                  out, annotation, TechCountsCategory_HalfCrossovers);
            }
            AddTechCount(out, annotation, TechCountsCategory_Crossovers);
          }
        } else {
          AddTechCount(out, annotation, TechCountsCategory_HalfCrossovers);
          AddTechCount(out, annotation, TechCountsCategory_Crossovers);
        }
      }
    }
    // And check the same thing, starting with left foot
    else if (
        leftHeel != StepParity::INVALID_COLUMN &&
        previousRightHeel != StepParity::INVALID_COLUMN &&
        previousLeftHeel == StepParity::INVALID_COLUMN) {
      StepParity::StagePoint leftPos = layout->averagePoint(leftHeel, leftToe);
      StepParity::StagePoint rightPos =
          layout->averagePoint(previousRightHeel, previousRightToe);

      if (rightPos.x < leftPos.x) {
        if (i > 1) {
          const StepParity::Row& previousPreviousRow = rows[i - 2];
          int previousPreviousLeftHeel =
              previousPreviousRow.whereTheFeetAre[StepParity::LEFT_HEEL];
          if (previousPreviousLeftHeel != StepParity::INVALID_COLUMN &&
              previousPreviousLeftHeel != leftHeel) {
            StepParity::StagePoint previousPreviousLeftPos =
                layout->columns[previousPreviousLeftHeel];
            if (rightPos.x > previousPreviousLeftPos.x) {
              AddTechCount(
                  out, annotation, TechCountsCategory_FullCrossovers);
            } else {
              AddTechCount(
                  out, annotation, TechCountsCategory_HalfCrossovers);
            }
            AddTechCount(out, annotation, TechCountsCategory_Crossovers);
          }
        } else {
          AddTechCount(out, annotation, TechCountsCategory_HalfCrossovers);
          AddTechCount(out, annotation, TechCountsCategory_Crossovers);
        }
      }
    }
    annotationsOut.push_back(annotation);
  }
}

bool TechCounts::isFootswitch(
    int c, const StepParity::Row& currentRow,
    const StepParity::Row& previousRow, float elapsedTime) {
  if (!IsValidRowColumn(currentRow, c) || !IsValidRowColumn(previousRow, c)) {
    LOG->Warn(
        "footswitch check received invalid column %d.",
        c);
    return false;
  }

  if (currentRow.columns[c] == StepParity::NONE ||
      previousRow.columns[c] == StepParity::NONE) {
    return false;
  }

  if (previousRow.columns[c] != currentRow.columns[c] &&
      StepParity::OTHER_PART_OF_FOOT[previousRow.columns[c]] !=
          currentRow.columns[c] &&
      elapsedTime < FOOTSWITCH_CUTOFF) {
    return true;
  }
  return false;
}

// lua start
class LunaTechCounts : public Luna<TechCounts> {
 public:
  static int GetValue(T* p, lua_State* L) {
    lua_pushnumber(L, (*p)[Enum::Check<TechCountsCategory>(L, 1)]);
    return 1;
  }

  LunaTechCounts() { ADD_METHOD(GetValue); }
};

LUA_REGISTER_CLASS(TechCounts)

/*
 * (c) 2023 Michael Votaw
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
