#include "ScreenUnlockStatus.h"

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include "Actor.h"
#include "ActorUtil.h"
#include "BitmapText.h"
#include "Course.h"
#include "Difficulty.h"
#include "PrefsManager.h"
#include "Profile.h"
#include "ProfileManager.h"
#include "RageLog.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "Screen.h"
#include "ScreenAttract.h"
#include "ScreenMessage.h"
#include "Song.h"
#include "SongManager.h"
#include "Sprite.h"
#include "ThemeManager.h"
#include "UnlockManager.h"
#include "global.h"

namespace {
const char* UNLOCK_STATUS_SCREEN = "ScreenUnlockStatus";

struct UnlockStatusMetrics {
  float textX;
  float textStartY;
  float textEndY;
  float textZoom;
  float textRows;
  int textRowsForLoop;
  float textMaxWidth;
  float iconX;
  float iconSize;
  int scrollMode;
  std::string pointsType;
  apActorCommands iconCommand;
  float timeToDisplay;
  float pointsZoom;
};

void WarnScreenUnlockStatus(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("SRC_AUDIT_FIX ScreenUnlockStatus: %s", message);
  }
}

bool IsFinite(float value) {
  return std::isfinite(value);
}

float GetMetricF(const std::string& metric, float fallback) {
  if (THEME == nullptr) {
    WarnScreenUnlockStatus("theme manager is missing while reading metrics.");
    return fallback;
  }
  if (!THEME->IsThemeLoaded() ||
      !THEME->HasMetric(UNLOCK_STATUS_SCREEN, metric)) {
    WarnScreenUnlockStatus(
        ssprintf("metric '%s' is missing; using fallback.", metric.c_str())
            .c_str());
    return fallback;
  }

  const float value = THEME->GetMetricF(UNLOCK_STATUS_SCREEN, metric);
  if (!IsFinite(value)) {
    WarnScreenUnlockStatus(
        ssprintf("metric '%s' is not finite; using fallback.", metric.c_str())
            .c_str());
    return fallback;
  }
  return value;
}

float GetNonNegativeMetricF(const std::string& metric, float fallback) {
  const float value = GetMetricF(metric, fallback);
  if (value < 0.0f) {
    WarnScreenUnlockStatus(
        ssprintf("metric '%s' is negative; using fallback.", metric.c_str())
            .c_str());
    return fallback;
  }
  return value;
}

float GetPositiveMetricF(const std::string& metric, float fallback) {
  const float value = GetMetricF(metric, fallback);
  if (value <= 0.0f) {
    WarnScreenUnlockStatus(
        ssprintf("metric '%s' is not positive; using fallback.", metric.c_str())
            .c_str());
    return fallback;
  }
  return value;
}

int GetScrollMode() {
  if (THEME == nullptr) {
    return 0;
  }
  if (!THEME->IsThemeLoaded() ||
      !THEME->HasMetric(UNLOCK_STATUS_SCREEN, "UnlockTextScroll")) {
    return 0;
  }

  const int scrollMode =
      THEME->GetMetricI(UNLOCK_STATUS_SCREEN, "UnlockTextScroll");
  if (scrollMode < 0 || scrollMode > 3) {
    WarnScreenUnlockStatus(
        ssprintf("UnlockTextScroll=%d is outside [0,3]; clamping.",
                 scrollMode)
            .c_str());
  }
  return std::clamp(scrollMode, 0, 3);
}

std::string GetMetricString(
    const std::string& metric, const std::string& fallback) {
  if (THEME == nullptr) {
    return fallback;
  }
  if (!THEME->IsThemeLoaded() ||
      !THEME->HasMetric(UNLOCK_STATUS_SCREEN, metric)) {
    WarnScreenUnlockStatus(
        ssprintf("metric '%s' is missing; using fallback.", metric.c_str())
            .c_str());
    return fallback;
  }

  std::string value = THEME->GetMetric(UNLOCK_STATUS_SCREEN, metric);
  if (value.empty()) {
    WarnScreenUnlockStatus(
        ssprintf("metric '%s' is empty; using fallback.", metric.c_str())
            .c_str());
    return fallback;
  }
  return value;
}

apActorCommands GetMetricCommands(const std::string& metric) {
  if (THEME == nullptr) {
    return ActorUtil::ParseActorCommands("");
  }
  if (!THEME->IsThemeLoaded() ||
      !THEME->HasMetric(UNLOCK_STATUS_SCREEN, metric)) {
    return ActorUtil::ParseActorCommands("");
  }
  return THEME->GetMetricA(UNLOCK_STATUS_SCREEN, metric);
}

std::string GetFontPath(
    const std::string& group, const std::string& element) {
  if (THEME == nullptr) {
    return "";
  }
  return THEME->GetPathF(group, element, true);
}

std::string GetGraphicPath(
    const std::string& group, const std::string& element) {
  if (THEME == nullptr) {
    return "";
  }
  return THEME->GetPathG(group, element, true);
}

bool LoadFontWithFallback(
    BitmapText& text, const std::string& group, const std::string& element) {
  const std::string requestedFont = GetFontPath(group, element);
  if (!requestedFont.empty() && text.LoadFromFont(requestedFont)) {
    return true;
  }

  const std::string fallbackFont = GetFontPath("Common", "normal");
  if (!fallbackFont.empty() && text.LoadFromFont(fallbackFont)) {
    return true;
  }

  WarnScreenUnlockStatus("failed to load text font.");
  return false;
}

UnlockStatusMetrics LoadMetrics() {
  UnlockStatusMetrics metrics;
  metrics.textX = 0.0f;
  metrics.textStartY = 0.0f;
  metrics.textEndY = 0.0f;
  metrics.textZoom = 1.0f;
  metrics.textRows = 1.0f;
  metrics.textRowsForLoop = 1;
  metrics.textMaxWidth = 320.0f;
  metrics.iconX = 0.0f;
  metrics.iconSize = 1.0f;
  metrics.scrollMode = GetScrollMode();
  metrics.pointsType = GetMetricString("TypeOfPointsToDisplay", "DP");
  metrics.iconCommand = GetMetricCommands("UnlockIconCommand");
  metrics.timeToDisplay = GetNonNegativeMetricF("TimeToDisplay", 0.0f);
  metrics.pointsZoom = GetPositiveMetricF("PointsZoom", 1.0f);

  if (metrics.scrollMode == 0) {
    return metrics;
  }

  metrics.textX = GetMetricF("UnlockTextScrollX", 0.0f);
  metrics.textStartY = GetMetricF("UnlockTextScrollStartY", 0.0f);
  metrics.textEndY = GetMetricF("UnlockTextScrollEndY", 0.0f);
  metrics.textZoom = GetPositiveMetricF("UnlockTextScrollZoom", 1.0f);
  metrics.textRows = GetPositiveMetricF("UnlockTextScrollRows", 1.0f);
  metrics.textMaxWidth =
      GetPositiveMetricF("UnlockTextScrollMaxWidth", 320.0f);
  if (metrics.scrollMode >= 2) {
    metrics.iconX = GetMetricF("UnlockTextScrollIconX", 0.0f);
    metrics.iconSize = GetPositiveMetricF("UnlockTextScrollIconSize", 1.0f);
  }
  metrics.textRowsForLoop =
      std::max(1, static_cast<int>(std::floor(metrics.textRows)));
  return metrics;
}

bool HasUnlockManagers() {
  if (THEME == nullptr || UNLOCKMAN == nullptr || PREFSMAN == nullptr) {
    WarnScreenUnlockStatus("required theme/unlock/preferences manager missing.");
    return false;
  }
  return true;
}

bool HasMachineProfile() {
  return PROFILEMAN != nullptr && PROFILEMAN->GetMachineProfile() != nullptr;
}

UnlockEntryStatus GetUnlockStatus(const UnlockEntry& entry) {
  if (!HasMachineProfile() || UNLOCKMAN == nullptr || SONGMAN == nullptr) {
    WarnScreenUnlockStatus(
        "unlock status requested without required managers/profile.");
    return UnlockEntryStatus_RequrementsNotMet;
  }
  return entry.GetUnlockEntryStatus();
}

bool IsUnlocked(UnlockEntryStatus status) {
  return status == UnlockEntryStatus_Unlocked;
}

Song* GetEntrySong(const UnlockEntry& entry) {
  if (SONGMAN == nullptr || !entry.m_Song.IsValid()) {
    return nullptr;
  }
  return entry.m_Song.ToSong();
}

Course* GetEntryCourse(const UnlockEntry& entry) {
  if (SONGMAN == nullptr || !entry.m_Course.IsValid()) {
    return nullptr;
  }
  return entry.m_Course.ToCourse();
}

std::string GetSongTitle(const Song* song) {
  if (song == nullptr) {
    return "";
  }

  std::string title = song->GetDisplayMainTitle();
  const std::string subtitle = song->GetDisplaySubTitle();
  if (!subtitle.empty()) {
    title += "\n" + subtitle;
  }
  return title;
}

RageColor GetSongColor(const Song* song) {
  if (song == nullptr || SONGMAN == nullptr) {
    return RageColor(1, 1, 1, 1);
  }
  return SONGMAN->GetSongGroupColor(song->m_sGroupName);
}

void ConfigureUnlockText(
    BitmapText& text, const UnlockEntry& entry, UnlockEntryStatus status,
    float maxWidth) {
  text.SetMaxWidth(maxWidth);

  if (!IsUnlocked(status)) {
    text.SetText("???");
    text.SetZoomX(1);
    return;
  }

  switch (entry.m_Type) {
    case UnlockRewardType_Song: {
      const Song* song = GetEntrySong(entry);
      text.SetText(song != nullptr ? GetSongTitle(song) : "");
      text.SetGlobalDiffuseColor(GetSongColor(song));
      break;
    }
    case UnlockRewardType_Steps:
    case UnlockRewardType_Steps_Type: {
      const Song* song = GetEntrySong(entry);
      std::string title = GetSongTitle(song);
      if (entry.m_dc != Difficulty_Invalid) {
        if (!title.empty()) {
          title += "\n";
        }
        title += DifficultyToString(entry.m_dc);
      }
      if (entry.m_Type == UnlockRewardType_Steps_Type &&
          entry.m_StepsType != StepsType_Invalid) {
        title += " " + StepsTypeToString(entry.m_StepsType);
      }
      text.SetText(title);
      text.SetGlobalDiffuseColor(GetSongColor(song));
      break;
    }
    case UnlockRewardType_Course: {
      const Course* course = GetEntryCourse(entry);
      text.SetText(course != nullptr ? course->GetDisplayFullTitle() : "");
      text.SetGlobalDiffuseColor(RageColor(0, 1, 0, 1));
      break;
    }
    case UnlockRewardType_Modifier:
      text.SetText(entry.GetModifier());
      text.SetGlobalDiffuseColor(RageColor(1, 1, 1, 1));
      break;
    default:
      text.SetText("");
      text.SetGlobalDiffuseColor(RageColor(0.5f, 0, 0, 1));
      break;
  }
}

float SafeDivide(float numerator, float denominator) {
  if (!IsFinite(numerator) || !IsFinite(denominator) || denominator <= 0.0f) {
    return 0.0f;
  }
  return numerator / denominator;
}

float SecondsToScroll(float timeToDisplay, bool reserveIntroSecond) {
  if (!IsFinite(timeToDisplay) || timeToDisplay <= 0.0f) {
    return 0.0f;
  }

  if (reserveIntroSecond) {
    return std::max(0.0f, timeToDisplay - 1.0f);
  }

  if (timeToDisplay > 2.0f) {
    return timeToDisplay - 1.0f;
  }
  return timeToDisplay;
}

float SecondsPerCycle(
    const UnlockStatusMetrics& metrics, unsigned unlockCount,
    bool reserveIntroSecond) {
  const float scrollSeconds =
      SecondsToScroll(metrics.timeToDisplay, reserveIntroSecond);
  const float denominator =
      metrics.scrollMode == 3
          ? metrics.textRows * 3.0f + static_cast<float>(unlockCount) + 4.0f
          : metrics.textRows + static_cast<float>(unlockCount);
  return SafeDivide(scrollSeconds, denominator);
}

void RunScrollCommand(
    Actor& actor, const UnlockStatusMetrics& metrics, unsigned oneBasedIndex,
    unsigned unlockCount, float secondsPerCycle) {
  if (metrics.scrollMode == 3 &&
      metrics.textRows + static_cast<float>(oneBasedIndex) >
          static_cast<float>(unlockCount)) {
    const float targetRow =
        -0.5f + static_cast<float>(oneBasedIndex) + metrics.textRows -
        static_cast<float>(unlockCount);
    const float stopOffPoint =
        metrics.textEndY -
        SafeDivide(targetRow, metrics.textRows) *
            (metrics.textEndY - metrics.textStartY);
    const float firstCycleTime =
        std::max(0.0f, (metrics.textRows - targetRow) * secondsPerCycle);
    const float secondCycleTime =
        std::max(0.0f, (6.0f + targetRow) * secondsPerCycle - firstCycleTime);

    actor.RunCommands(ActorUtil::ParseActorCommands(ssprintf(
        "diffusealpha,0;sleep,%f;diffusealpha,1;linear,%f;y,%f;linear,%f;y,%f;"
        "linear,0.1;diffusealpha,0",
        secondsPerCycle * static_cast<float>(oneBasedIndex - 1),
        firstCycleTime, stopOffPoint, secondCycleTime, metrics.textEndY)));
    return;
  }

  actor.RunCommands(ActorUtil::ParseActorCommands(ssprintf(
      "diffusealpha,0;sleep,%f;diffusealpha,1;linear,%f;y,%f;linear,0.1;"
      "diffusealpha,0",
      secondsPerCycle * static_cast<float>(oneBasedIndex - 1),
      secondsPerCycle * metrics.textRows, metrics.textEndY)));
}

void RunLastUnlockCommand(
    Actor& actor, const UnlockStatusMetrics& metrics, unsigned unlockCount,
    unsigned oneBasedRow, float secondsPerCycle) {
  actor.RunCommands(ActorUtil::ParseActorCommands(ssprintf(
      "diffusealpha,0;sleep,%f;diffusealpha,1;linear,%f;y,%f;",
      secondsPerCycle *
          (static_cast<float>(unlockCount) +
           2.0f * static_cast<float>(oneBasedRow) - 2.0f),
      secondsPerCycle *
          ((metrics.textRows - static_cast<float>(oneBasedRow)) * 2.0f + 1.0f),
      metrics.textStartY +
          (metrics.textEndY - metrics.textStartY) *
              SafeDivide(metrics.textRows - static_cast<float>(oneBasedRow) +
                             0.5f,
                         metrics.textRows))));
}

Sprite* CreateUnlockSprite(
    unsigned oneBasedIndex, bool revealGraphic, float x, float y,
    float iconSize) {
  Sprite* sprite = Sprite::NewBlankSprite();
  if (sprite == nullptr) {
    WarnScreenUnlockStatus("failed to allocate unlock sprite.");
    return nullptr;
  }

  if (revealGraphic) {
    const std::string graphic = GetGraphicPath(
        UNLOCK_STATUS_SCREEN, ssprintf("%04u icon", oneBasedIndex));
    if (!graphic.empty()) {
      sprite->Load(graphic);
    } else {
      WarnScreenUnlockStatus(
          ssprintf("missing icon graphic for unlock %u.", oneBasedIndex)
              .c_str());
    }
  }

  sprite->SetXY(x, y);
  if (iconSize > 0.0f) {
    sprite->SetHeight(iconSize);
    sprite->SetWidth(iconSize);
  }
  return sprite;
}

bool AddUnlockTextActor(
    std::vector<BitmapText*>& actors, const UnlockEntry& entry,
    UnlockEntryStatus status, const UnlockStatusMetrics& metrics,
    unsigned oneBasedIndex, unsigned unlockCount, float secondsPerCycle) {
  BitmapText* text = new BitmapText;
  if (!LoadFontWithFallback(*text, UNLOCK_STATUS_SCREEN, "text")) {
    delete text;
    return false;
  }

  text->SetHorizAlign(align_left);
  text->SetZoom(metrics.textZoom);
  ConfigureUnlockText(*text, entry, status, metrics.textMaxWidth);
  text->SetXY(metrics.textX, metrics.textStartY);
  RunScrollCommand(
      *text, metrics, oneBasedIndex, unlockCount, secondsPerCycle);

  actors.push_back(text);
  return true;
}

UnlockRequirement PointsRequirementFromMetric(const std::string& pointsType) {
  if (pointsType == "AP" || pointsType == "Arcade") {
    return UnlockRequirement_ArcadePoints;
  }
  if (pointsType == "SP" || pointsType == "Song") {
    return UnlockRequirement_SongPoints;
  }
  if (pointsType != "DP" && pointsType != "Dance") {
    WarnScreenUnlockStatus(
        ssprintf("unknown TypeOfPointsToDisplay '%s'; using DP.",
                 pointsType.c_str())
            .c_str());
  }
  return UnlockRequirement_DancePoints;
}

std::string PointsUntilNextUnlockText(const std::string& pointsType) {
  if (UNLOCKMAN == nullptr || !HasMachineProfile()) {
    WarnScreenUnlockStatus("points display requested without unlock/profile.");
    return "0";
  }

  const UnlockRequirement requirement = PointsRequirementFromMetric(pointsType);
  return ssprintf(
      "%d",
      static_cast<int>(UNLOCKMAN->PointsUntilNextUnlock(requirement)));
}
}  // namespace

REGISTER_SCREEN_CLASS(ScreenUnlockStatus);

void ScreenUnlockStatus::Init() {
  ClearOwnedActors();
  RemoveChild(&PointsUntilNextUnlock);

  if (!HasUnlockManagers()) {
    PostScreenMessage(SM_GoToNextScreen, 0);
    return;
  }

  ScreenAttract::Init();
  RemoveChild(&PointsUntilNextUnlock);

  const std::vector<UnlockEntry>& unlockEntries = UNLOCKMAN->m_UnlockEntries;
  const unsigned unlockCount = static_cast<unsigned>(unlockEntries.size());
  if (!PREFSMAN->m_bUseUnlockSystem || unlockEntries.empty()) {
    PostScreenMessage(SM_GoToNextScreen, 0);
    return;
  }

  const UnlockStatusMetrics metrics = LoadMetrics();

  std::vector<UnlockEntryStatus> unlockStatuses;
  unlockStatuses.reserve(unlockEntries.size());
  for (const UnlockEntry& entry : unlockEntries) {
    unlockStatuses.push_back(GetUnlockStatus(entry));
  }

  LoadFontWithFallback(PointsUntilNextUnlock, "Common", "normal");
  PointsUntilNextUnlock.SetHorizAlign(align_left);

  for (unsigned i = 0; i < unlockCount; ++i) {
    if (!IsUnlocked(unlockStatuses[i])) {
      continue;
    }

    Sprite* sprite = CreateUnlockSprite(
        i + 1, true, 0.0f, 0.0f, 0.0f);
    if (sprite == nullptr) {
      continue;
    }

    sprite->SetName(ssprintf("Unlock%04u", i + 1));
    LOAD_ALL_COMMANDS_AND_SET_XY(sprite);
    sprite->RunCommands(metrics.iconCommand);
    Unlocks.push_back(sprite);
    AddChild(sprite);
  }

  if (metrics.scrollMode != 0) {
    const float secondsPerCycle =
        SecondsPerCycle(metrics, unlockCount, false);

    for (unsigned i = 0; i < unlockCount; ++i) {
      const unsigned oneBasedIndex = i + 1;
      const UnlockEntry& entry = unlockEntries[i];
      const UnlockEntryStatus status = unlockStatuses[i];

      AddUnlockTextActor(
          item, entry, status, metrics, oneBasedIndex, unlockCount,
          secondsPerCycle);

      if (metrics.scrollMode >= 2) {
        Sprite* icon = CreateUnlockSprite(
            oneBasedIndex, IsUnlocked(status), metrics.iconX,
            metrics.textStartY, metrics.iconSize);
        if (icon != nullptr) {
          RunScrollCommand(
              *icon, metrics, oneBasedIndex, unlockCount, secondsPerCycle);
          ItemIcons.push_back(icon);
        }
      }

      if (metrics.scrollMode == 3 && IsUnlocked(status)) {
        LastUnlocks.push_back(static_cast<int>(oneBasedIndex));
      }
    }
  }

  if (metrics.scrollMode == 3 && !LastUnlocks.empty()) {
    const float secondsPerCycle = SecondsPerCycle(metrics, unlockCount, true);
    const unsigned rowsToShow = std::min(
        static_cast<unsigned>(metrics.textRowsForLoop),
        static_cast<unsigned>(LastUnlocks.size()));

    for (unsigned i = 1; i <= rowsToShow; ++i) {
      const unsigned nextIcon =
          static_cast<unsigned>(LastUnlocks[LastUnlocks.size() - i]);
      if (nextIcon == 0 || nextIcon > unlockCount) {
        WarnScreenUnlockStatus("last unlock index is outside unlock table.");
        continue;
      }

      const UnlockEntry& entry = unlockEntries[nextIcon - 1];
      BitmapText* text = new BitmapText;
      if (!LoadFontWithFallback(*text, UNLOCK_STATUS_SCREEN, "text")) {
        delete text;
        continue;
      }
      text->SetHorizAlign(align_left);
      text->SetZoom(metrics.textZoom);
      ConfigureUnlockText(
          *text, entry, unlockStatuses[nextIcon - 1], metrics.textMaxWidth);
      text->SetXY(metrics.textX, metrics.textStartY);
      RunLastUnlockCommand(*text, metrics, unlockCount, i, secondsPerCycle);
      item.push_back(text);

      Sprite* icon = CreateUnlockSprite(
          nextIcon, true, metrics.iconX, metrics.textStartY, metrics.iconSize);
      if (icon != nullptr) {
        RunLastUnlockCommand(*icon, metrics, unlockCount, i, secondsPerCycle);
        ItemIcons.push_back(icon);
      }
    }
  }

  for (int i = static_cast<int>(item.size()) - 1; i >= 0; --i) {
    if (item[i] != nullptr) {
      AddChild(item[i]);
    }
  }

  for (int i = static_cast<int>(ItemIcons.size()) - 1; i >= 0; --i) {
    if (ItemIcons[i] != nullptr) {
      AddChild(ItemIcons[i]);
    }
  }

  PointsUntilNextUnlock.SetName("PointsDisplay");
  PointsUntilNextUnlock.SetText(PointsUntilNextUnlockText(metrics.pointsType));
  PointsUntilNextUnlock.SetZoom(metrics.pointsZoom);
  LOAD_ALL_COMMANDS_AND_SET_XY(PointsUntilNextUnlock);
  AddChild(&PointsUntilNextUnlock);

  ClearMessageQueue(SM_BeginFadingOut);
  PostScreenMessage(SM_BeginFadingOut, metrics.timeToDisplay);
}

void ScreenUnlockStatus::ClearOwnedActors() {
  for (Sprite* actor : Unlocks) {
    if (actor != nullptr) {
      RemoveChild(actor);
      RageUtil::SafeDelete(actor);
    }
  }
  Unlocks.clear();

  for (BitmapText* actor : item) {
    if (actor != nullptr) {
      RemoveChild(actor);
      RageUtil::SafeDelete(actor);
    }
  }
  item.clear();

  for (Sprite* actor : ItemIcons) {
    if (actor != nullptr) {
      RemoveChild(actor);
      RageUtil::SafeDelete(actor);
    }
  }
  ItemIcons.clear();

  LastUnlocks.clear();
}

ScreenUnlockStatus::~ScreenUnlockStatus() {
  RemoveChild(&PointsUntilNextUnlock);
  ClearOwnedActors();
}

/*
 * (c) 2003 Andrew Wong
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
