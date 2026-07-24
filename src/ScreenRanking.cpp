#include "ScreenRanking.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <string>
#include <utility>
#include <vector>

#include "Actor.h"
#include "ActorUtil.h"
#include "Course.h"
#include "Difficulty.h"
#include "EnumHelper.h"
#include "GameConstantsAndTypes.h"
#include "GameManager.h"
#include "GameState.h"
#include "HighScore.h"
#include "LuaManager.h"
#include "Profile.h"
#include "ProfileManager.h"
#include "RageLog.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "Screen.h"
#include "ScreenAttract.h"
#include "ScreenManager.h"
#include "ScreenMessage.h"
#include "SongManager.h"
#include "ThemeManager.h"
#include "global.h"

static const char* RankingTypeNames[] = {
    "Category",
    "Course",
};
XToString(RankingType);
LuaXType(RankingType);

AutoScreenMessage(SM_ShowNextPage);
AutoScreenMessage(SM_HidePage);

REGISTER_SCREEN_CLASS(ScreenRanking);

#define BULLET_X(row) (BULLET_START_X + ROW_SPACING_X * row)
#define BULLET_Y(row) (BULLET_START_Y + ROW_SPACING_Y * row)
#define NAME_X(row) (NAME_START_X + ROW_SPACING_X * row)
#define NAME_Y(row) (NAME_START_Y + ROW_SPACING_Y * row)
#define SCORE_X(row) (SCORE_START_X + ROW_SPACING_X * row)
#define SCORE_Y(row) (SCORE_START_Y + ROW_SPACING_Y * row)
#define POINTS_X(row) (POINTS_START_X + ROW_SPACING_X * row)
#define POINTS_Y(row) (POINTS_START_Y + ROW_SPACING_Y * row)
#define TIME_X(row) (TIME_START_X + ROW_SPACING_X * row)
#define TIME_Y(row) (TIME_START_Y + ROW_SPACING_Y * row)

static std::string STEPS_TYPE_COLOR_NAME(size_t i) {
  return ssprintf("StepsTypeColor%d", int(i + 1));
}

namespace {
void WarnScreenRanking(const std::string& message) {
  if (LOG != nullptr) {
    LOG->Warn("ScreenRanking: %s", message.c_str());
  }
}

bool IsThemeRuntimeAvailable() {
  return THEME != nullptr && THEME->IsThemeLoaded() && LUA != nullptr;
}

bool IsRankingTypeValid(RankingType rankingType) {
  return rankingType >= RankingType_Category &&
         rankingType < NUM_RankingType;
}

bool IsRankingCategoryValid(RankingCategory category) {
  return category >= RANKING_A && category < NUM_RankingCategory;
}

bool IsStepsTypeValid(StepsType stepsType) {
  return stepsType >= 0 && stepsType < NUM_StepsType;
}

bool IsUsableSeconds(float seconds) {
  return std::isfinite(seconds) && seconds > 0.0f;
}

bool LoadFontWithFallback(
    BitmapText& text, const std::string& group, const std::string& element) {
  if (!IsThemeRuntimeAvailable()) {
    WarnScreenRanking(
        ssprintf("refused font load %s/%s without theme runtime.",
                 group.c_str(),
                 element.c_str()));
    return false;
  }

  const std::string requestedFont = THEME->GetPathF(group, element, true);
  if (!requestedFont.empty() && text.LoadFromFont(requestedFont)) {
    return true;
  }

  const std::string fallbackFont = THEME->GetPathF("Common", "normal", true);
  if (!fallbackFont.empty() && text.LoadFromFont(fallbackFont)) {
    return true;
  }

  WarnScreenRanking(
      ssprintf("failed to load font %s/%s.", group.c_str(), element.c_str()));
  return false;
}

void LoadGraphicWithFallback(
    AutoActor& actor, const std::string& group, const std::string& element) {
  if (IsThemeRuntimeAvailable()) {
    const std::string path = THEME->GetPathG(group, element, true);
    if (!path.empty()) {
      actor.Load(path);
      return;
    }
  }

  WarnScreenRanking(
      ssprintf("using blank actor for graphic %s/%s.",
               group.c_str(),
               element.c_str()));
  actor.LoadFallback();
}

bool HasRankingManagers() {
  return IsThemeRuntimeAvailable() && GAMEMAN != nullptr &&
         GAMESTATE != nullptr && GAMESTATE->m_pCurGame != nullptr;
}

const HighScoreList* GetCourseHighScoreListForDisplay(
    const Profile* profile, const CourseID& courseID, const TrailID& trailID) {
  if (profile == nullptr) {
    return nullptr;
  }

  const auto courseIter = profile->m_CourseHighScores.find(courseID);
  if (courseIter == profile->m_CourseHighScores.end()) {
    return nullptr;
  }

  const auto trailIter = courseIter->second.m_TrailHighScores.find(trailID);
  if (trailIter == courseIter->second.m_TrailHighScores.end()) {
    return nullptr;
  }

  return &trailIter->second.hsl;
}
}  // namespace

ScreenRanking::PageToShow::PageToShow()
    : colorIndex(0),
      aTypes(),
      category(RankingCategory_Invalid),
      courseID(),
      trailID() {}

void ScreenRanking::Init() {
  m_vPagesToShow.clear();
  m_iNextPageToShow = 0;

  if (!IsThemeRuntimeAvailable()) {
    WarnScreenRanking("Init skipped without theme/Lua runtime.");
    return;
  }

  if (!HasRankingManagers()) {
    ScreenAttract::Init();
    WarnScreenRanking(
        "Init built attract shell without ranking managers/current game.");
    return;
  }

  STEPS_TYPES_TO_SHOW.Load(
      m_sName,
      "StepsTypesToHide");  // tricky: The metric name is "hide" because
                            // ThemeMetricStepsTypesToShow takes a list of what
                            // to hide and returns what StepsTypes to show
  PAGE_FADE_SECONDS.Load(m_sName, "PageFadeSeconds");

  ScreenAttract::Init();

  m_textStepsType.SetName("StepsType");
  LoadFontWithFallback(m_textStepsType, m_sName, "StepsType");
  m_textStepsType.SetShadowLength(0);
  this->AddChild(&m_textStepsType);
  LOAD_ALL_COMMANDS(m_textStepsType);

  RANKING_TYPE.Load(m_sName, "RankingType");
  COURSES_TO_SHOW.Load(m_sName, "CoursesToShow");
  SECONDS_PER_PAGE.Load(m_sName, "SecondsPerPage");

  NO_SCORE_NAME.Load(m_sName, "NoScoreName");
  ROW_SPACING_X.Load(m_sName, "RowSpacingX");
  ROW_SPACING_Y.Load(m_sName, "RowSpacingY");
  BULLET_START_X.Load(m_sName, "BulletStartX");
  BULLET_START_Y.Load(m_sName, "BulletStartY");
  NAME_START_X.Load(m_sName, "NameStartX");
  NAME_START_Y.Load(m_sName, "NameStartY");
  SCORE_START_X.Load(m_sName, "ScoreStartX");
  SCORE_START_Y.Load(m_sName, "ScoreStartY");
  POINTS_START_X.Load(m_sName, "PointsStartX");
  POINTS_START_Y.Load(m_sName, "PointsStartY");
  TIME_START_X.Load(m_sName, "TimeStartX");
  TIME_START_Y.Load(m_sName, "TimeStartY");
  STEPS_TYPE_COLOR.Load(m_sName, STEPS_TYPE_COLOR_NAME, NUM_RANKING_LINES);

  const RankingType rankingType = GetRankingType();
  const std::vector<StepsType>& stepsTypesToShow =
      STEPS_TYPES_TO_SHOW.GetValue();

  if (rankingType == RankingType_Category) {
    m_textCategory.SetName("Category");
    LoadFontWithFallback(m_textCategory, m_sName, "category");
    // m_textCategory.SetShadowLength( 0 );
    this->AddChild(&m_textCategory);
    LOAD_ALL_COMMANDS(m_textCategory);

    for (size_t i = 0; i < stepsTypesToShow.size(); i++) {
      const StepsType st = stepsTypesToShow[i];
      if (!IsStepsTypeValid(st)) {
        WarnScreenRanking(
            ssprintf("ignored invalid StepsType %d for category ranking.", st));
        continue;
      }

      for (int c = 0; c < NUM_RankingCategory; c++) {
        PageToShow pts;
        pts.colorIndex = i;
        pts.category = (RankingCategory)c;
        pts.aTypes.push_back(std::make_pair(Difficulty_Invalid, st));
        m_vPagesToShow.push_back(pts);
      }
    }
  }

  if (rankingType == RankingType_SpecificTrail) {
    m_Banner.SetName("Banner");
    this->AddChild(&m_Banner);
    LOAD_ALL_COMMANDS(m_Banner);

    m_textCourseTitle.SetName("CourseTitle");
    LoadFontWithFallback(m_textCourseTitle, m_sName, "course title");
    // m_textCourseTitle.SetShadowLength( 0 );
    this->AddChild(&m_textCourseTitle);
    LOAD_ALL_COMMANDS(m_textCourseTitle);

    std::vector<std::string> asCoursePaths;
    split(COURSES_TO_SHOW, ",", asCoursePaths, true);
    for (size_t i = 0; i < stepsTypesToShow.size(); i++) {
      const StepsType st = stepsTypesToShow[i];
      if (!IsStepsTypeValid(st)) {
        WarnScreenRanking(
            ssprintf("ignored invalid StepsType %d for course ranking.", st));
        continue;
      }

      for (size_t c = 0; c < asCoursePaths.size(); c++) {
        PageToShow pts;
        pts.colorIndex = i;
        pts.aTypes.push_back(std::make_pair(Difficulty_Invalid, st));
        if (SONGMAN == nullptr) {
          WarnScreenRanking("ignored course ranking page without SONGMAN.");
          continue;
        }

        Course* pCourse = SONGMAN->GetCourseFromPath(asCoursePaths[c]);
        if (pCourse == nullptr) {
          WarnScreenRanking(
              ssprintf("ignored unknown course path '%s'.",
                       asCoursePaths[c].c_str()));
          continue;
        }

        Trail* pTrail = pCourse->GetTrail(st);
        if (pTrail == nullptr) {
          WarnScreenRanking(
              ssprintf("ignored course '%s' without trail for StepsType %d.",
                       pCourse->GetDisplayFullTitle().c_str(),
                       st));
          continue;
        }

        pts.courseID.FromCourse(pCourse);
        pts.trailID.FromTrail(pTrail);
        m_vPagesToShow.push_back(pts);
      }
    }
  } else if (rankingType != RankingType_Category) {
    WarnScreenRanking(
        ssprintf("ignored invalid RankingType %d during init.", rankingType));
  }

  for (int l = 0; l < NUM_RANKING_LINES; l++) {
    LoadGraphicWithFallback(
        m_sprBullets[l], m_sName, ssprintf("bullets 1x%d", NUM_RANKING_LINES));
    m_sprBullets[l]->SetName(ssprintf("Bullet%d", l + 1));
    m_sprBullets[l]->StopAnimating();
    m_sprBullets[l]->SetState(l);
    m_sprBullets[l]->SetXY(BULLET_X(l), BULLET_Y(l));
    ActorUtil::LoadAllCommands(*m_sprBullets[l], m_sName);
    this->AddChild(m_sprBullets[l]);

    m_textNames[l].SetName(ssprintf("Name%d", l + 1));
    LoadFontWithFallback(m_textNames[l], m_sName, "name");
    m_textNames[l].SetXY(NAME_X(l), NAME_Y(l));
    ActorUtil::LoadAllCommands(m_textNames[l], m_sName);
    this->AddChild(&m_textNames[l]);

    m_textScores[l].SetName(ssprintf("Score%d", l + 1));
    LoadFontWithFallback(m_textScores[l], m_sName, "score");
    m_textScores[l].SetXY(SCORE_X(l), SCORE_Y(l));
    ActorUtil::LoadAllCommands(m_textScores[l], m_sName);
    this->AddChild(&m_textScores[l]);

    m_textPoints[l].SetName(ssprintf("Points%d", l + 1));
    LoadFontWithFallback(m_textPoints[l], m_sName, "points");
    m_textPoints[l].SetVisible(false);
    m_textPoints[l].SetXY(POINTS_X(l), POINTS_Y(l));
    ActorUtil::LoadAllCommands(m_textPoints[l], m_sName);
    this->AddChild(&m_textPoints[l]);

    m_textTime[l].SetName(ssprintf("Time%d", l + 1));
    LoadFontWithFallback(m_textTime[l], m_sName, "time");
    m_textTime[l].SetVisible(false);
    m_textTime[l].SetXY(TIME_X(l), TIME_Y(l));
    ActorUtil::LoadAllCommands(m_textTime[l], m_sName);
    this->AddChild(&m_textTime[l]);
  }
}

void ScreenRanking::BeginScreen() {
  m_iNextPageToShow = 0;
  ClearMessageQueue(SM_ShowNextPage);
  ClearMessageQueue(SM_HidePage);

  ScreenAttract::BeginScreen();

  this->HandleScreenMessage(SM_ShowNextPage);
}

void ScreenRanking::HandleScreenMessage(const ScreenMessage SM) {
  if (SM == SM_ShowNextPage) {
    bool pageShown = false;
    while (m_iNextPageToShow < m_vPagesToShow.size()) {
      const float fSecsToShow = SetPage(m_vPagesToShow[m_iNextPageToShow]);
      ++m_iNextPageToShow;
      if (!IsUsableSeconds(fSecsToShow)) {
        continue;
      }

      this->SortByDrawOrder();

      this->PlayCommand("NextPage");
      this->PostScreenMessage(
          SM_HidePage, std::max(0.0f, fSecsToShow - GetPageFadeSeconds()));
      pageShown = true;
      break;
    }

    if (!pageShown) {
      StartTransitioningScreen(SM_GoToNextScreen);
    }
  } else if (SM == SM_HidePage) {
    this->PlayCommand("SwitchedPage");
    this->PostScreenMessage(SM_ShowNextPage, GetPageFadeSeconds());
  }

  ScreenAttract::HandleScreenMessage(SM);
}

float ScreenRanking::SetPage(const PageToShow& pts) {
  // This is going to take a while to load.  Possibly longer than one frame.
  // So, zero the next update so we don't skip.
  if (SCREENMAN != nullptr) {
    SCREENMAN->ZeroNextUpdate();
  } else {
    WarnScreenRanking("SetPage continued without SCREENMAN.");
  }

  if (pts.aTypes.empty()) {
    WarnScreenRanking("ignored ranking page without StepsType data.");
    return 0.0f;
  }

  // init page
  StepsType st = pts.aTypes.front().second;
  if (!IsStepsTypeValid(st)) {
    WarnScreenRanking(
        ssprintf("ignored ranking page with invalid StepsType %d.", st));
    return 0.0f;
  }
  if (GAMEMAN == nullptr) {
    WarnScreenRanking("ignored ranking page without GAMEMAN.");
    return 0.0f;
  }
  m_textStepsType.SetText(GAMEMAN->GetStepsTypeInfo(st).GetLocalizedString());

  const RankingType rtype = GetRankingType();
  Course* pCourse = nullptr;
  Trail* pTrail = nullptr;
  if (rtype == RankingType_SpecificTrail) {
    if (GAMESTATE == nullptr) {
      WarnScreenRanking("ignored course ranking page without GAMESTATE.");
      return 0.0f;
    }

    pCourse = pts.courseID.ToCourse();
    if (pCourse == nullptr || !pts.trailID.IsValid()) {
      WarnScreenRanking("ignored course ranking page with stale course/trail id.");
      return 0.0f;
    }

    pTrail = pts.trailID.ToTrail(pCourse, true);
    if (pTrail == nullptr) {
      WarnScreenRanking("ignored course ranking page with missing trail.");
      return 0.0f;
    }
  }

  bool bShowScores = false;
  bool bShowPoints = false;
  bool bShowTime = false;
  switch (rtype) {
    case RankingType_Category:
      bShowScores = true;
      break;
    case RankingType_SpecificTrail:
      bShowScores = !pCourse->IsOni();
      bShowPoints = pCourse->IsOni();
      bShowTime = pCourse->IsOni();
      break;
    default:
      WarnScreenRanking(ssprintf("ignored invalid RankingType %d.", rtype));
      return 0.0f;
  }

  for (int l = 0; l < NUM_RANKING_LINES; l++) {
    m_textNames[l].SetDiffuseColor(GetStepsTypeColor(pts.colorIndex));

    m_textScores[l].SetVisible(bShowScores);
    m_textScores[l].SetDiffuseColor(GetStepsTypeColor(pts.colorIndex));

    m_textPoints[l].SetVisible(bShowPoints);
    m_textPoints[l].SetDiffuseColor(GetStepsTypeColor(pts.colorIndex));

    m_textTime[l].SetVisible(bShowTime);
    m_textTime[l].SetDiffuseColor(GetStepsTypeColor(pts.colorIndex));
  }

  const Profile* machineProfile =
      PROFILEMAN != nullptr ? PROFILEMAN->GetMachineProfile() : nullptr;
  if (machineProfile == nullptr) {
    WarnScreenRanking("ignored ranking page without machine profile.");
    return 0.0f;
  }

  switch (rtype) {
    case RankingType_Category: {
      if (!IsRankingCategoryValid(pts.category)) {
        WarnScreenRanking(
            ssprintf("ignored ranking page with invalid category %d.",
                     pts.category));
        return 0.0f;
      }

      m_textCategory.SetText(GetCategoryTitle(pts.category));

      for (int l = 0; l < NUM_RANKING_LINES; l++) {
        // No need to shadow at this point.
        st = pts.aTypes.front().second;
        const HighScoreList& hsl =
            machineProfile->GetCategoryHighScoreList(st, pts.category);
        HighScore hs;
        bool bRecentHighScore = false;
        if (l < (int)hsl.vHighScores.size()) {
          hs = hsl.vHighScores[l];
          const std::string* psName = hsl.vHighScores[l].GetNameMutable();
          bRecentHighScore = GAMESTATE != nullptr &&
                             find(
                                 GAMESTATE->m_vpsNamesThatWereFilled.begin(),
                                 GAMESTATE->m_vpsNamesThatWereFilled.end(),
                                 psName) !=
                                 GAMESTATE->m_vpsNamesThatWereFilled.end();
        } else {
          hs.SetName(NO_SCORE_NAME);
        }

        m_textNames[l].SetText(hs.GetDisplayName());
        m_textScores[l].SetText(ssprintf("%09i", hs.GetScore()));
        m_textNames[l].SetDiffuseColor(GetStepsTypeColor(pts.colorIndex));
        m_textScores[l].SetDiffuseColor(GetStepsTypeColor(pts.colorIndex));
        SetRecentScoreEffect(
            l, bRecentHighScore, bShowScores, bShowPoints, bShowTime);
      }
    }
      return GetSecondsPerPage();
    case RankingType_SpecificTrail: {
      m_textCourseTitle.SetText(pCourse->GetDisplayFullTitle());

      m_Banner.LoadFromCourse(pCourse);

      const HighScoreList* hsl =
          GetCourseHighScoreListForDisplay(
              machineProfile, pts.courseID, pts.trailID);
      for (int l = 0; l < NUM_RANKING_LINES; l++) {
        HighScore hs;
        bool bRecentHighScore = false;
        if (hsl != nullptr && l < (int)hsl->vHighScores.size()) {
          hs = hsl->vHighScores[l];
          const std::string* psName = hsl->vHighScores[l].GetNameMutable();
          bRecentHighScore = GAMESTATE != nullptr &&
                             find(
                                 GAMESTATE->m_vpsNamesThatWereFilled.begin(),
                                 GAMESTATE->m_vpsNamesThatWereFilled.end(),
                                 psName) !=
                                 GAMESTATE->m_vpsNamesThatWereFilled.end();
        } else {
          hs.SetName(NO_SCORE_NAME);
        }

        m_textNames[l].SetText(hs.GetDisplayName());
        if (pCourse->IsOni()) {
          m_textPoints[l].SetText(ssprintf("%04d", hs.GetScore()));
          m_textTime[l].SetText(SecondsToMMSSMsMs(hs.GetSurviveSeconds()));
          m_textScores[l].SetText("");
        } else {
          m_textPoints[l].SetText("");
          m_textTime[l].SetText("");
          m_textScores[l].SetText(ssprintf("%09d", hs.GetScore()));
        }
        m_textNames[l].SetDiffuseColor(GetStepsTypeColor(pts.colorIndex));
        m_textPoints[l].SetDiffuseColor(GetStepsTypeColor(pts.colorIndex));
        m_textTime[l].SetDiffuseColor(GetStepsTypeColor(pts.colorIndex));
        m_textScores[l].SetDiffuseColor(GetStepsTypeColor(pts.colorIndex));
        SetRecentScoreEffect(
            l, bRecentHighScore, bShowScores, bShowPoints, bShowTime);
      }
    }
      return GetSecondsPerPage();
    default:
      WarnScreenRanking(ssprintf("ignored invalid RankingType %d.", rtype));
      return 0.0f;
  }
}

RankingType ScreenRanking::GetRankingType() const {
  if (!RANKING_TYPE.IsLoaded()) {
    WarnScreenRanking("RankingType metric is not loaded; using category ranking.");
    return RankingType_Category;
  }

  const RankingType rankingType = RANKING_TYPE.GetValue();
  if (!IsRankingTypeValid(rankingType)) {
    WarnScreenRanking(
        ssprintf(
            "invalid RankingType %d; using category ranking.", rankingType));
    return RankingType_Category;
  }
  return rankingType;
}

float ScreenRanking::GetPageFadeSeconds() const {
  if (!PAGE_FADE_SECONDS.IsLoaded()) {
    return 0.0f;
  }

  const float seconds = PAGE_FADE_SECONDS.GetValue();
  if (!std::isfinite(seconds) || seconds < 0.0f) {
    WarnScreenRanking(
        ssprintf("invalid PageFadeSeconds %.3f; using 0.", seconds));
    return 0.0f;
  }
  return seconds;
}

float ScreenRanking::GetSecondsPerPage() const {
  if (!SECONDS_PER_PAGE.IsLoaded()) {
    return 1.0f;
  }

  const float seconds = SECONDS_PER_PAGE.GetValue();
  if (!IsUsableSeconds(seconds)) {
    WarnScreenRanking(
        ssprintf("invalid SecondsPerPage %.3f; using 1.", seconds));
    return 1.0f;
  }
  return seconds;
}

RageColor ScreenRanking::GetStepsTypeColor(size_t colorIndex) const {
  if (colorIndex >= NUM_RANKING_LINES) {
    WarnScreenRanking(
        ssprintf("color index %zu out of range; clamping.", colorIndex));
    colorIndex = NUM_RANKING_LINES - 1;
  }

  return STEPS_TYPE_COLOR.GetValue(colorIndex);
}

std::string ScreenRanking::GetCategoryTitle(RankingCategory category) const {
  const std::string categoryText(
      1, static_cast<char>('A' + static_cast<int>(category)));
  if (THEME == nullptr || !THEME->IsThemeLoaded() ||
      !THEME->HasString(m_sName, "CategoryFormat")) {
    return "Type " + categoryText;
  }

  std::string label = THEME->GetString(m_sName, "CategoryFormat");
  if (label.empty()) {
    return "Type " + categoryText;
  }

  const std::string original = label;
  Replace(label, "{category}", categoryText);
  Replace(label, "%s", categoryText);
  Replace(label, "%c", categoryText);
  if (label == original) {
    label += " " + categoryText;
  }
  return label;
}

void ScreenRanking::SetRecentScoreEffect(
    int row, bool recent, bool showScores, bool showPoints, bool showTime) {
  if (row < 0 || row >= NUM_RANKING_LINES) {
    return;
  }

  m_textNames[row].StopEffect();
  m_textScores[row].StopEffect();
  m_textPoints[row].StopEffect();
  m_textTime[row].StopEffect();

  if (!recent) {
    return;
  }

  m_textNames[row].SetEffectGlowBlink(
      0.1f, RageColor(1, 1, 1, 0.2f), RageColor(1, 1, 1, 0.8f));
  if (showScores) {
    m_textScores[row].SetEffectGlowBlink(
        0.1f, RageColor(1, 1, 1, 0.2f), RageColor(1, 1, 1, 0.8f));
  }
  if (showPoints) {
    m_textPoints[row].SetEffectGlowBlink(
        0.1f, RageColor(1, 1, 1, 0.2f), RageColor(1, 1, 1, 0.8f));
  }
  if (showTime) {
    m_textTime[row].SetEffectGlowBlink(
        0.1f, RageColor(1, 1, 1, 0.2f), RageColor(1, 1, 1, 0.8f));
  }
}

/*
 * (c) 2001-2007 Chris Danford, Glenn Maynard
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
