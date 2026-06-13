#include "CourseUtil.h"

#include <algorithm>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "Course.h"
#include "CourseWriterCRS.h"
#include "Difficulty.h"
#include "EnumHelper.h"
#include "GameConstantsAndTypes.h"
#include "GameState.h"
#include "LocalizedString.h"
#include "PlayerNumber.h"
#include "Profile.h"
#include "ProfileManager.h"
#include "RageFileManager.h"
#include "RageLog.h"
#include "RageTimer.h"
#include "RageUtil.h"
#include "RageUtil/RandomNumbers.h"
#include "SongManager.h"
#include "SongOptions.h"
#include "StdString.h"
#include "Style.h"
#include "ThemeManager.h"
#include "XmlFile.h"
#include "arch/Dialog/Dialog.h"
#include "global.h"

// Sorting stuff
static bool CompareCoursePointersByName(
    const Course* pCourse1, const Course* pCourse2) {
  if (pCourse1 == pCourse2) {
    return false;
  }
  if (pCourse1 == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX SRC-666: null course sorted after valid courses.");
    return false;
  }
  if (pCourse2 == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX SRC-666: null course sorted after valid courses.");
    return true;
  }
  std::string sName1 = pCourse1->GetDisplayFullTitle();
  std::string sName2 = pCourse2->GetDisplayFullTitle();
  return CompareNoCase(sName1, sName2) < 0;
}

static bool CompareCoursePointersByAutogen(
    const Course* pCourse1, const Course* pCourse2) {
  if (pCourse1 == pCourse2) {
    return false;
  }
  if (pCourse1 == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX SRC-666: null course sorted after valid courses.");
    return false;
  }
  if (pCourse2 == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX SRC-666: null course sorted after valid courses.");
    return true;
  }
  int b1 = pCourse1->m_bIsAutogen;
  int b2 = pCourse2->m_bIsAutogen;
  if (b1 < b2) {
    return true;
  } else if (b1 > b2) {
    return false;
  } else {
    return CompareCoursePointersByName(pCourse1, pCourse2);
  }
}

static bool CompareCoursePointersByDifficulty(
    const Course* pCourse1, const Course* pCourse2) {
  if (pCourse1 == pCourse2) {
    return false;
  }
  if (pCourse1 == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX SRC-666: null course sorted after valid courses.");
    return false;
  }
  if (pCourse2 == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX SRC-666: null course sorted after valid courses.");
    return true;
  }
  int iNum1 = pCourse1->GetEstimatedNumStages();
  int iNum2 = pCourse2->GetEstimatedNumStages();
  if (iNum1 < iNum2) {
    return true;
  } else if (iNum1 > iNum2) {
    return false;
  } else {  // iNum1 == iNum2
    return CompareCoursePointersByAutogen(pCourse1, pCourse2);
  }
}

static bool CompareCoursePointersByTotalDifficulty(
    const Course* pCourse1, const Course* pCourse2) {
  if (pCourse1 == pCourse2) {
    return false;
  }
  if (pCourse1 == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX SRC-666: null course sorted after valid courses.");
    return false;
  }
  if (pCourse2 == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX SRC-666: null course sorted after valid courses.");
    return true;
  }
  int iNum1 = pCourse1->m_SortOrder_TotalDifficulty;
  int iNum2 = pCourse2->m_SortOrder_TotalDifficulty;

  if (iNum1 == iNum2) {
    return CompareCoursePointersByAutogen(pCourse1, pCourse2);
  }
  return iNum1 < iNum2;
}

static bool MovePlayersBestToEnd(
    const Course* pCourse1, const Course* pCourse2) {
  if (pCourse1 == pCourse2) {
    return false;
  }
  if (pCourse1 == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX SRC-666: null course sorted after valid courses.");
    return false;
  }
  if (pCourse2 == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX SRC-666: null course sorted after valid courses.");
    return true;
  }
  bool C1HasBest = pCourse1->CourseHasBestOrWorst();
  bool C2HasBest = pCourse2->CourseHasBestOrWorst();
  if (!C1HasBest && !C2HasBest) {
    return false;
  }
  if (C1HasBest && !C2HasBest) {
    return false;
  }
  if (!C1HasBest && C2HasBest) {
    return true;
  }

  return CompareCoursePointersByName(pCourse1, pCourse2);
}

static bool CompareRandom(const Course* pCourse1, const Course* pCourse2) {
  if (pCourse1 == pCourse2) {
    return false;
  }
  if (pCourse1 == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX SRC-666: null course sorted after valid courses.");
    return false;
  }
  if (pCourse2 == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX SRC-666: null course sorted after valid courses.");
    return true;
  }
  return (pCourse1->AllSongsAreFixed() && !pCourse2->AllSongsAreFixed());
}

static bool CompareCoursePointersByRanking(
    const Course* pCourse1, const Course* pCourse2) {
  if (pCourse1 == pCourse2) {
    return false;
  }
  if (pCourse1 == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX SRC-666: null course sorted after valid courses.");
    return false;
  }
  if (pCourse2 == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX SRC-666: null course sorted after valid courses.");
    return true;
  }
  int iNum1 = pCourse1->m_SortOrder_Ranking;
  int iNum2 = pCourse2->m_SortOrder_Ranking;

  if (iNum1 == iNum2) {
    return CompareCoursePointersByAutogen(pCourse1, pCourse2);
  }
  return iNum1 < iNum2;
}

static bool GetCurrentCourseStepsType(StepsType& stOut, const char* sContext) {
  const Style* pStyle = GAMESTATE->GetCurrentStyle(PLAYER_INVALID);
  if (pStyle == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-134: %s requested without a current style; falling "
        "back to title sort",
        sContext);
    return false;
  }
  stOut = pStyle->m_StepsType;
  return true;
}

void CourseUtil::SortCoursePointerArrayByDifficulty(
    std::vector<Course*>& vpCoursesInOut) {
  sort(
      vpCoursesInOut.begin(), vpCoursesInOut.end(),
      CompareCoursePointersByDifficulty);
}

void CourseUtil::SortCoursePointerArrayByRanking(
    std::vector<Course*>& vpCoursesInOut) {
  StepsType st = StepsType_Invalid;
  if (!GetCurrentCourseStepsType(st, "SortCoursePointerArrayByRanking")) {
    SortCoursePointerArrayByTitle(vpCoursesInOut);
    return;
  }
  for (unsigned i = 0; i < vpCoursesInOut.size(); i++) {
    if (vpCoursesInOut[i] == nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-667: skipped null course while updating ranking "
          "sort stats.");
      continue;
    }
    vpCoursesInOut[i]->UpdateCourseStats(st);
  }
  sort(
      vpCoursesInOut.begin(), vpCoursesInOut.end(),
      CompareCoursePointersByRanking);
}

void CourseUtil::SortCoursePointerArrayByTotalDifficulty(
    std::vector<Course*>& vpCoursesInOut) {
  StepsType st = StepsType_Invalid;
  if (!GetCurrentCourseStepsType(st, "SortCoursePointerArrayByTotalDifficulty")) {
    SortCoursePointerArrayByTitle(vpCoursesInOut);
    return;
  }
  for (unsigned i = 0; i < vpCoursesInOut.size(); i++) {
    if (vpCoursesInOut[i] == nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-667: skipped null course while updating total "
          "difficulty sort stats.");
      continue;
    }
    vpCoursesInOut[i]->UpdateCourseStats(st);
  }
  sort(
      vpCoursesInOut.begin(), vpCoursesInOut.end(),
      CompareCoursePointersByTotalDifficulty);
}

// this code isn't ready yet!!
#if 0
std::string GetSectionNameFromCourseAndSort( const Course *pCourse, SortOrder so )
{
	if( pCourse == nullptr )
		return std::string();
	// more code here
}

void SortCoursePointerArrayBySectionName( std::vector<Course*> &vpCoursesInOut, SortOrder so )
{
	std::string sOther = SORT_OTHER.GetValue();
	for(unsigned i = 0; i < vpCoursesInOut.size(); ++i)
	{
		std::string val = GetSectionNameFromCourseAndSort( vpCoursesInOut[i], so );

		/* Make sure 0-9 comes first and OTHER comes last. */
		if( val == "0-9" )			val = "0";
		else if( val == sOther )    val = "2";
		else						val = "1" + MakeSortString(val);

		//g_mapSongSortVal[vpSongsInOut[i]] = val;
	}
}
#endif
// ok real code begins again

static bool CompareCoursePointersByType(
    const Course* pCourse1, const Course* pCourse2) {
  if (pCourse1 == pCourse2) {
    return false;
  }
  if (pCourse1 == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX SRC-666: null course sorted after valid courses.");
    return false;
  }
  if (pCourse2 == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX SRC-666: null course sorted after valid courses.");
    return true;
  }
  return pCourse1->GetPlayMode() < pCourse2->GetPlayMode();
}

void CourseUtil::SortCoursePointerArrayByType(
    std::vector<Course*>& vpCoursesInOut) {
  stable_sort(
      vpCoursesInOut.begin(), vpCoursesInOut.end(),
      CompareCoursePointersByType);
}

void CourseUtil::MoveRandomToEnd(std::vector<Course*>& vpCoursesInOut) {
  stable_sort(vpCoursesInOut.begin(), vpCoursesInOut.end(), CompareRandom);
}

static std::map<const Course*, std::string> course_sort_val;

bool CompareCoursePointersBySortValueAscending(
    const Course* pSong1, const Course* pSong2) {
  const auto p1 = course_sort_val.find(pSong1);
  const auto p2 = course_sort_val.find(pSong2);
  const std::string s1 =
      p1 == course_sort_val.end() ? std::string() : p1->second;
  const std::string s2 =
      p2 == course_sort_val.end() ? std::string() : p2->second;
  return s1 < s2;
}

bool CompareCoursePointersBySortValueDescending(
    const Course* pSong1, const Course* pSong2) {
  const auto p1 = course_sort_val.find(pSong1);
  const auto p2 = course_sort_val.find(pSong2);
  const std::string s1 =
      p1 == course_sort_val.end() ? std::string() : p1->second;
  const std::string s2 =
      p2 == course_sort_val.end() ? std::string() : p2->second;
  return s1 > s2;
}

bool CompareCoursePointersByTitle(
    const Course* pCourse1, const Course* pCourse2) {
  return CompareCoursePointersByName(pCourse1, pCourse2);
}

void CourseUtil::SortCoursePointerArrayByTitle(
    std::vector<Course*>& vpCoursesInOut) {
  sort(
      vpCoursesInOut.begin(), vpCoursesInOut.end(),
      CompareCoursePointersByTitle);
}

void CourseUtil::SortCoursePointerArrayByAvgDifficulty(
    std::vector<Course*>& vpCoursesInOut) {
  RageTimer foo;
  StepsType st = StepsType_Invalid;
  if (!GetCurrentCourseStepsType(st, "SortCoursePointerArrayByAvgDifficulty")) {
    SortCoursePointerArrayByTitle(vpCoursesInOut);
    return;
  }
  course_sort_val.clear();
  for (unsigned i = 0; i < vpCoursesInOut.size(); ++i) {
    if (vpCoursesInOut[i] == nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-667: skipped null course while computing average "
          "difficulty sort value.");
      course_sort_val[vpCoursesInOut[i]] = std::string();
      continue;
    }
    int iMeter = vpCoursesInOut[i]->GetMeter(st, Difficulty_Medium);
    course_sort_val[vpCoursesInOut[i]] = ssprintf("%06i", iMeter);
  }
  sort(
      vpCoursesInOut.begin(), vpCoursesInOut.end(),
      CompareCoursePointersByTitle);
  stable_sort(
      vpCoursesInOut.begin(), vpCoursesInOut.end(),
      CompareCoursePointersBySortValueAscending);

  stable_sort(
      vpCoursesInOut.begin(), vpCoursesInOut.end(), MovePlayersBestToEnd);
  course_sort_val.clear();
}

void CourseUtil::SortCoursePointerArrayByNumPlays(
    std::vector<Course*>& vpCoursesInOut, ProfileSlot slot, bool bDescending) {
  if (PROFILEMAN == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-669: course play-count sort requested without "
        "PROFILEMAN; falling back to title sort.");
    SortCoursePointerArrayByTitle(vpCoursesInOut);
    return;
  }
  if (!PROFILEMAN->IsPersistentProfile(slot)) {
    return;  // nothing to do since we don't have data
  }
  Profile* pProfile = PROFILEMAN->GetProfile(slot);
  SortCoursePointerArrayByNumPlays(vpCoursesInOut, pProfile, bDescending);
}

void CourseUtil::SortCoursePointerArrayByNumPlays(
    std::vector<Course*>& vpCoursesInOut, const Profile* pProfile,
    bool bDescending) {
  if (pProfile == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-669: course play-count sort requested without "
        "profile; falling back to title sort.");
    SortCoursePointerArrayByTitle(vpCoursesInOut);
    return;
  }
  course_sort_val.clear();
  for (unsigned i = 0; i < vpCoursesInOut.size(); ++i) {
    course_sort_val[vpCoursesInOut[i]] =
        ssprintf("%09i", pProfile->GetCourseNumTimesPlayed(vpCoursesInOut[i]));
  }
  stable_sort(
      vpCoursesInOut.begin(), vpCoursesInOut.end(),
      bDescending ? CompareCoursePointersBySortValueDescending
                  : CompareCoursePointersBySortValueAscending);
  course_sort_val.clear();
}

void CourseUtil::SortByMostRecentlyPlayedForMachine(
    std::vector<Course*>& vpCoursesInOut) {
  Profile* pProfile =
      PROFILEMAN == nullptr ? nullptr : PROFILEMAN->GetMachineProfile();
  if (pProfile == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-669: recent course sort requested without machine "
        "profile; falling back to title sort.");
    SortCoursePointerArrayByTitle(vpCoursesInOut);
    return;
  }

  course_sort_val.clear();
  for (const Course* c : vpCoursesInOut) {
    int iNumTimesPlayed = pProfile->GetCourseNumTimesPlayed(c);
    std::string val = iNumTimesPlayed
                          ? pProfile->GetCourseLastPlayedDateTime(c).GetString()
                          : std::string("9999999999999");
    course_sort_val[c] = val;
  }

  stable_sort(
      vpCoursesInOut.begin(), vpCoursesInOut.end(),
      CompareCoursePointersBySortValueAscending);
  course_sort_val.clear();
}

void CourseUtil::MakeDefaultEditCourseEntry(CourseEntry& out) {
  Song* pDefaultSong =
      GAMESTATE == nullptr ? nullptr : GAMESTATE->GetDefaultSong();
  if (pDefaultSong == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-670: default edit course entry requested without "
        "default song.");
  }
  out.songID.FromSong(pDefaultSong);
  out.stepsCriteria.m_difficulty = Difficulty_Medium;
}

//////////////////////////////////
// Autogen
//////////////////////////////////

void CourseUtil::AutogenEndlessFromGroup(
    const std::string& sGroupName, Difficulty diff, Course& out) {
  if (SONGMAN == nullptr || THEME == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-671: cannot autogen endless course for group '%s' "
        "without SONGMAN or THEME.",
        sGroupName.c_str());
    out.m_vEntries.clear();
    return;
  }
  if (diff < Difficulty_Beginner || diff >= NUM_Difficulty) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-671: invalid autogen difficulty %i for group '%s'; "
        "using Medium.",
        diff, sGroupName.c_str());
    diff = Difficulty_Medium;
  }

  out.m_bIsAutogen = true;
  out.m_bRepeat = true;
  out.m_bShuffle = true;
  out.m_iLives = -1;
  out.m_vEntries.clear();
  FOREACH_ENUM(Difficulty, dc)
  out.m_iCustomMeter[dc] = -1;

  if (sGroupName == "") {
    out.m_sMainTitle = "All Songs";
    // this sounds reasonable... -aj
    out.m_sBannerPath = THEME->GetPathG("Banner", "all music");
  } else {
    out.m_sMainTitle = SONGMAN->ShortenGroupName(sGroupName);
    out.m_sBannerPath = SONGMAN->GetSongGroupBannerPath(sGroupName);
  }

  // We want multiple songs, so we can try to prevent repeats during
  // gameplay. (We might still get a repeat at the repeat boundary,
  // but that'd be rare.) -glenn
  CourseEntry e;
  e.songCriteria.m_vsGroupNames.push_back(sGroupName);
  e.stepsCriteria.m_difficulty = diff;
  e.bSecret = true;

  // Insert a copy of e for each song in the group.
  out.m_vEntries.insert(
      out.m_vEntries.end(), SONGMAN->GetSongs(sGroupName).size(), e);
}

void CourseUtil::AutogenNonstopFromGroup(
    const std::string& sGroupName, Difficulty diff, Course& out) {
  AutogenEndlessFromGroup(sGroupName, diff, out);

  out.m_bRepeat = false;

  out.m_sMainTitle += " Random";

  if (out.m_vEntries.empty()) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-128: skipped nonstop autogen entries for empty group "
        "'%s'",
        sGroupName.c_str());
    return;
  }

  // resize to 4
  while (out.m_vEntries.size() < 4) {
    out.m_vEntries.push_back(out.m_vEntries[0]);
  }
  while (out.m_vEntries.size() > 4) {
    out.m_vEntries.pop_back();
  }
}

void CourseUtil::AutogenOniFromArtist(
    const std::string& sArtistName, std::string sArtistNameTranslit,
    std::vector<Song*> aSongs, Difficulty dc, Course& out) {
  out.m_bIsAutogen = true;
  out.m_bRepeat = false;
  out.m_bShuffle = true;
  out.m_bSortByMeter = true;

  out.m_iLives = 4;
  FOREACH_ENUM(Difficulty, cd)
  out.m_iCustomMeter[cd] = -1;

  ASSERT(sArtistName != "");
  ASSERT(aSongs.size() > 0);

  /* "Artist Oni" is a little repetitive; "by Artist" stands out less, and
   * lowercasing "by" puts more emphasis on the artist's name. It also sorts
   * them together. */
  out.m_sMainTitle = "by " + sArtistName;
  if (sArtistNameTranslit != sArtistName) {
    out.m_sMainTitleTranslit = "by " + sArtistNameTranslit;
  }

  // How would we handle Artist Oni course banners, anyways? -aj
  // m_sBannerPath = ""; // XXX

  /* Shuffle the list to determine which songs we'll use. Shuffle it
   * deterministically, so we always get the same set of songs unless the
   * song set changes. */
  {
    RandomGen rng(GetHashForString(sArtistName) + aSongs.size());
    std::shuffle(aSongs.begin(), aSongs.end(), rng);
  }

  // Only use up to four songs.
  if (aSongs.size() > 4) {
    aSongs.erase(aSongs.begin() + 4, aSongs.end());
  }

  CourseEntry e;
  e.stepsCriteria.m_difficulty = dc;

  for (unsigned i = 0; i < aSongs.size(); ++i) {
    e.songID.FromSong(aSongs[i]);
    out.m_vEntries.push_back(e);
  }
}

void CourseUtil::WarnOnInvalidMods(std::string sMods) {
  PlayerOptions po;
  SongOptions so;
  std::vector<std::string> vs;
  split(sMods, ",", vs, true);
  for (const std::string& s : vs) {
    bool bValid = false;
    std::string sErrorDetail;
    bValid |= po.FromOneModString(s, sErrorDetail);
    bValid |= so.FromOneModString(s, sErrorDetail);
    /* ==Invalid options that used to be valid==
     * all noteskins (solo, note, foon, &c.)
     * protiming (done in Lua now)
     * ==Things I've seen in real course files==
     * 900% BRINK (damnit japan)
     * TISPY
     * 9000% OVERCOMING (what?)
     * 9200% TORNADE (it's like a grenade but a tornado)
     * 50% PROTIMING (HOW THE HELL DOES 50% PROTIMING EVEN WORK)
     * BREAK
     */
    if (!bValid) {
      std::string sFullError =
          ssprintf("Error processing '%s' in '%s'", s.c_str(), sMods.c_str());
      if (!sErrorDetail.empty()) {
        sFullError += ": " + sErrorDetail;
      }
      LOG->UserLog("", "", "%s", sFullError.c_str());
      Dialog::OK(sFullError, "INVALID_PLAYER_OPTION_WARNING");
    }
  }
}

int EditCourseUtil::MAX_NAME_LENGTH = 16;
int EditCourseUtil::MAX_PER_PROFILE = 32;
int EditCourseUtil::MIN_WORKOUT_MINUTES = 4;
int EditCourseUtil::MAX_WORKOUT_MINUTES = 90;
bool EditCourseUtil::s_bNewCourseNeedsName = false;

bool EditCourseUtil::Save(Course* pCourse) {
  if (pCourse == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX SRC-135: refusing to save a null course");
    return false;
  }
  return EditCourseUtil::RenameAndSave(pCourse, pCourse->GetDisplayFullTitle());
}

bool EditCourseUtil::RenameAndSave(Course* pCourse, std::string sNewName) {
  if (pCourse == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX SRC-135: refusing to rename/save a null course");
    return false;
  }
  Trim(sNewName);
  if (sNewName.empty()) {
    LOG->Warn("SRC_AUDIT_FIX SRC-133: refusing to save course with empty name");
    return false;
  }

  EditCourseUtil::s_bNewCourseNeedsName = false;

  const std::string sOldFilePath = pCourse->m_sPath;
  const std::string sOldName = pCourse->m_sMainTitle;
  std::string sNewFilePath;
  if (pCourse->IsAnEdit()) {
    const ProfileSlot slot = pCourse->GetLoadedFromProfileSlot();
    if (!PROFILEMAN->IsPersistentProfile(slot)) {
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-130: cannot save edit course '%s' because profile "
          "slot %i is not persistent",
          sNewName.c_str(), slot);
      return false;
    }
    sNewFilePath =
        PROFILEMAN->GetProfileDir(slot) + EDIT_COURSES_SUBDIR + sNewName + ".crs";
  } else {
    std::string sDir, sName, sExt;
    splitpath(pCourse->m_sPath, sDir, sName, sExt);
    sNewFilePath = sDir + sNewName + sExt;
  }

  pCourse->m_sMainTitle = sNewName;
  pCourse->m_sPath = sNewFilePath;
  if (!CourseWriterCRS::Write(*pCourse, pCourse->m_sPath, false)) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-129: failed to save course '%s' to '%s'; keeping "
        "old path '%s'",
        sNewName.c_str(), sNewFilePath.c_str(), sOldFilePath.c_str());
    pCourse->m_sMainTitle = sOldName;
    pCourse->m_sPath = sOldFilePath;
    return false;
  }

  // Remove the old file only after the replacement has been written.
  if (!sOldFilePath.empty() && sNewFilePath != sOldFilePath &&
      !FILEMAN->Remove(sOldFilePath)) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-129: saved renamed course '%s' but could not remove "
        "old file '%s'",
        sNewFilePath.c_str(), sOldFilePath.c_str());
  }
  return true;
}

bool EditCourseUtil::RemoveAndDeleteFile(Course* pCourse) {
  if (pCourse == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX SRC-135: refusing to delete a null course");
    return false;
  }
  if (!FILEMAN->Remove(pCourse->m_sPath)) {
    return false;
  }
  FILEMAN->Remove(pCourse->GetCacheFilePath());
  if (pCourse->IsAnEdit()) {
    const ProfileSlot slot = pCourse->GetLoadedFromProfileSlot();
    if (PROFILEMAN->IsPersistentProfile(slot)) {
      const std::string sProfileDir = PROFILEMAN->GetProfileDir(slot);
      SONGMAN->FreeAllLoadedFromProfile(slot);
      SONGMAN->LoadStepEditsFromProfileDir(sProfileDir, slot);
      SONGMAN->LoadCourseEditsFromProfileDir(sProfileDir, slot);
    } else {
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-131: deleted edit course '%s' but profile slot %i "
          "is not persistent, so edits were not reloaded",
          pCourse->m_sPath.c_str(), slot);
    }
  } else {
    SONGMAN->DeleteCourse(pCourse);
    delete pCourse;
  }
  return true;
}

static LocalizedString YOU_MUST_SUPPLY_NAME(
    "CourseUtil", "You must supply a name for your course.");
static LocalizedString EDIT_NAME_CONFLICTS(
    "CourseUtil",
    "The name you chose conflicts with another course. Please use a different "
    "name.");
static LocalizedString EDIT_NAME_CANNOT_CONTAIN(
    "CourseUtil",
    "The course name cannot contain any of the following characters: %s");
bool EditCourseUtil::ValidateEditCourseName(
    const std::string& sAnswer, std::string& sErrorOut) {
  std::string sTrimmedAnswer = sAnswer;
  Trim(sTrimmedAnswer);
  if (sTrimmedAnswer.empty()) {
    sErrorOut = YOU_MUST_SUPPLY_NAME;
    return false;
  }

  static const std::string sInvalidChars = "\\/:*?\"<>|";
  if (strpbrk(sTrimmedAnswer.c_str(), sInvalidChars.c_str()) != nullptr) {
    sErrorOut = ssprintf(
        EDIT_NAME_CANNOT_CONTAIN.GetValue().c_str(), sInvalidChars.c_str());
    return false;
  }

  // Check for name conflicts
  std::vector<Course*> vpCourses;
  EditCourseUtil::GetAllEditCourses(vpCourses);
  for (const Course* p : vpCourses) {
    if (GAMESTATE->m_pCurCourse == p) {
      continue;  // don't comepare name against ourself
    }

    if (CompareNoCase(p->GetDisplayFullTitle(), sTrimmedAnswer) == 0) {
      sErrorOut = EDIT_NAME_CONFLICTS;
      return false;
    }
  }

  return true;
}

void EditCourseUtil::UpdateAndSetTrail() {
  ASSERT(GAMESTATE->GetCurrentStyle(PLAYER_INVALID) != nullptr);
  StepsType st = GAMESTATE->GetCurrentStyle(PLAYER_INVALID)->m_StepsType;
  Trail* pTrail = nullptr;
  if (GAMESTATE->m_pCurCourse) {
    pTrail = GAMESTATE->m_pCurCourse->GetTrailForceRegenCache(st);
  }
  GAMESTATE->m_pCurTrail[PLAYER_1].Set(pTrail);
}

void EditCourseUtil::PrepareForPlay() {
  GAMESTATE->m_pCurSong.Set(
      nullptr);  // CurSong will be set if we back out.  Set it back to nullptr
                 // so that ScreenStage won't show the last song.
  GAMESTATE->m_PlayMode.Set(PLAY_MODE_ENDLESS);
  GAMESTATE->m_bSideIsJoined[0] = true;

  PROFILEMAN->GetProfile(ProfileSlot_Player1)->m_GoalType = GoalType_Time;
  Course* pCourse = GAMESTATE->m_pCurCourse;
  PROFILEMAN->GetProfile(ProfileSlot_Player1)->m_iGoalSeconds =
      static_cast<int>(pCourse->m_fGoalSeconds);
}

void EditCourseUtil::GetAllEditCourses(std::vector<Course*>& vpCoursesOut) {
  std::vector<Course*> vpCoursesTemp;
  SONGMAN->GetAllCourses(vpCoursesTemp, false);
  for (Course* c : vpCoursesTemp) {
    if (c->GetLoadedFromProfileSlot() != ProfileSlot_Invalid) {
      vpCoursesOut.push_back(c);
    }
  }
}

void EditCourseUtil::LoadDefaults(Course& out) {
  out = Course();

  out.m_fGoalSeconds = 0;

  // pick a default name
  // XXX: Make this localizable
  std::vector<Course*> vpCourses;
  EditCourseUtil::GetAllEditCourses(vpCourses);
  for (int i = 0; i < 10000; i++) {
    out.m_sMainTitle = ssprintf("Workout %d", i + 1);

    const bool bNameTaken =
        std::any_of(vpCourses.begin(), vpCourses.end(), [&](const Course* p) {
          return out.m_sMainTitle == p->m_sMainTitle;
        });
    if (!bNameTaken) {
      break;
    }
  }

  std::vector<Song*> vpSongs;
  SONGMAN->GetPreferredSortSongs(vpSongs);
  for (int i = 0; i < (int)vpSongs.size() && i < 6; i++) {
    CourseEntry ce;
    ce.songID.FromSong(vpSongs[i]);
    ce.stepsCriteria.m_difficulty = Difficulty_Easy;
    out.m_vEntries.push_back(ce);
  }
}

//////////////////////////////////
// CourseID
//////////////////////////////////

void CourseID::FromCourse(const Course* p) {
  if (p) {
    if (p->m_bIsAutogen) {
      sPath = "";
      sFullTitle = p->GetTranslitFullTitle();
    } else {
      sPath = p->m_sPath;
      sFullTitle = "";
    }
  } else {
    sPath = "";
    sFullTitle = "";
  }

  // HACK for backwards compatibility:
  // Strip off leading "/".  2005/05/21 file layer changes added a leading
  // slash.
  if (Left(sPath, 1) == "/") {
    sPath.erase(sPath.begin());
  }
}

Course* CourseID::ToCourse() const {
  Course* pCourse = nullptr;
  if (!sPath.empty()) {
    // HACK for backwards compatibility:
    // Re-add the leading "/".  2005/05/21 file layer changes added a leading
    // slash.
    std::string slash_path = sPath;
    if (Left(slash_path, 1) != "/") {
      slash_path = "/" + slash_path;
    }

    pCourse = SONGMAN->GetCourseFromPath(slash_path);
  }

  if (pCourse == nullptr && !sFullTitle.empty()) {
    pCourse = SONGMAN->GetCourseFromName(sFullTitle);
  }

  return pCourse;
}

XNode* CourseID::CreateNode() const {
  XNode* pNode = new XNode("Course");
  ;

  if (!sPath.empty()) {
    pNode->AppendAttr("Path", sPath);
  }
  if (!sFullTitle.empty()) {
    pNode->AppendAttr("FullTitle", sFullTitle);
  }

  return pNode;
}

void CourseID::LoadFromNode(const XNode* pNode) {
  sFullTitle = std::string();
  sPath = std::string();
  if (pNode == nullptr || pNode->GetName() != "Course") {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-136: ignored invalid CourseID XML node '%s'",
        pNode == nullptr ? "(null)" : pNode->GetName().c_str());
    return;
  }
  if (!pNode->GetAttrValue("Path", sPath)) {
    pNode->GetAttrValue("FullTitle", sFullTitle);
  }

  // HACK for backwards compatibility: /AdditionalCourses has been merged into
  // /Courses
  if (Left(sPath, 18) == "AdditionalCourses/") {
    sPath.replace(0, 18, "Courses/");
  }
}

std::string CourseID::ToString() const {
  if (!sPath.empty()) {
    return sPath;
  }
  if (!sFullTitle.empty()) {
    return sFullTitle;
  }
  return std::string();
}

bool CourseID::IsValid() const { return !sPath.empty() || !sFullTitle.empty(); }

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
