#include "ProfileManager.h"

#include <algorithm>
#include <cstddef>
#include <limits>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "Character.h"
#include "CharacterManager.h"
#include "Course.h"
#include "EnumHelper.h"
#include "GameConstantsAndTypes.h"
#include "GameState.h"
#include "Grade.h"
#include "HighScore.h"
#include "LuaManager.h"
#include "MemoryCardManager.h"
#include "PlayerNumber.h"
#include "Preference.h"
#include "PrefsManager.h"
#include "Profile.h"
#include "RageFileManager.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "Song.h"
#include "SongManager.h"
#include "StdString.h"
#include "Steps.h"
#include "StepsUtil.h"
#include "ThemeManager.h"
#include "ThemeMetric.h"
#include "XmlFile.h"
#include "global.h"

ProfileManager* PROFILEMAN =
    nullptr;  // global and accessible from anywhere in our program

#define ID_DIGITS 8
#define ID_DIGITS_STR "8"
#define MAX_ID 99999999

static void DefaultLocalProfileIDInit(
    size_t /*PlayerNumber*/ i, std::string& sNameOut,
    std::string& defaultValueOut) {
  sNameOut = ssprintf("DefaultLocalProfileIDP%d", int(i + 1));
  defaultValueOut = "";
}

Preference<bool> ProfileManager::m_bProfileStepEdits("ProfileStepEdits", true);
Preference<bool> ProfileManager::m_bProfileCourseEdits(
    "ProfileCourseEdits", true);
Preference1D<std::string> ProfileManager::m_sDefaultLocalProfileID(
    DefaultLocalProfileIDInit, NUM_PLAYERS);

const std::string NEW_MEM_CARD_NAME = "";
const std::string USER_PROFILES_DIR = "/Save/LocalProfiles/";
const std::string MACHINE_PROFILE_DIR = "/Save/MachineProfile/";
const std::string LAST_GOOD_SUBDIR = "LastGood/";

// Directories to search for a profile if m_sMemoryCardProfileSubdir doesn't
// exist, separated by ";":
static Preference<std::string> g_sMemoryCardProfileImportSubdirs(
    "MemoryCardProfileImportSubdirs",
    "StepMania 5.1;StepMania 5;In The Groove 2");

static std::string LocalProfileIDToDir(const std::string& sProfileID) {
  return USER_PROFILES_DIR + sProfileID + "/";
}
static std::string LocalProfileDirToID(const std::string& sDir) {
  return Basename(sDir);
}

struct DirAndProfile;

static bool IsProfilePlayerNumberValid(PlayerNumber pn, const char* context);

static bool IsSafeProfilePathComponent(const std::string& value) {
  return !value.empty() && value != "." && value != ".." &&
         value.find("..") == std::string::npos &&
         value.find('/') == std::string::npos &&
         value.find('\\') == std::string::npos &&
         value.find(':') == std::string::npos;
}

static bool IsSafeLocalProfileID(const std::string& profile_id) {
  return IsSafeProfilePathComponent(profile_id);
}

static bool NormalizeMemoryCardProfileSubdir(
    const std::string& raw, std::string& normalized) {
  normalized = raw;
  TrimLeft(normalized);
  TrimRight(normalized);
  while (!normalized.empty() && normalized.front() == '/') {
    normalized.erase(normalized.begin());
  }
  while (!normalized.empty() && normalized.back() == '/') {
    normalized.erase(normalized.end() - 1);
  }
  return IsSafeProfilePathComponent(normalized);
}

static void AppendUniqueMemoryCardSubdir(
    std::vector<std::string>& dirs, const std::string& raw) {
  std::string normalized;
  if (!NormalizeMemoryCardProfileSubdir(raw, normalized)) {
    LOG->Warn(
        "ProfileManager: ignoring unsafe memory card profile subdir '%s'",
        raw.c_str());
    return;
  }
  if (std::find(dirs.begin(), dirs.end(), normalized) == dirs.end()) {
    dirs.push_back(normalized);
  }
}

static bool BuildMemoryCardProfileDir(
    PlayerNumber pn, const std::string& subdir, std::string& out) {
  if (!IsProfilePlayerNumberValid(pn, "BuildMemoryCardProfileDir")) {
    return false;
  }
  std::string normalized;
  if (!NormalizeMemoryCardProfileSubdir(subdir, normalized)) {
    return false;
  }
  out = MEM_CARD_MOUNT_POINT[pn] + normalized + "/";
  return true;
}

static bool ShouldSignProfiles() {
  return PREFSMAN != nullptr && PREFSMAN->m_bSignProfileData;
}

static ProfileSortOrder GetProfileSortOrder() {
  return PREFSMAN != nullptr ? PREFSMAN->m_ProfileSortOrder.Get()
                             : ProfileSortOrder_Priority;
}

static bool GetProfileSortAscending() {
  return PREFSMAN == nullptr || PREFSMAN->m_bProfileSortOrderAscending;
}

static bool IsValidProfileSlot(ProfileSlot slot) {
  return slot == ProfileSlot_Player1 || slot == ProfileSlot_Player2 ||
         slot == ProfileSlot_Machine;
}

static const std::string& EmptyProfileDir() {
  static const std::string empty;
  return empty;
}

static const char* RankingMarkerForPlayer(PlayerNumber pn) {
  if (pn >= 0 && static_cast<size_t>(pn) < RANKING_TO_FILL_IN_MARKER.size()) {
    return RANKING_TO_FILL_IN_MARKER[pn].c_str();
  }
  return "????";
}

static int CompareProfileDisplayName(
    const DirAndProfile& a, const DirAndProfile& b);

struct DirAndProfile {
  std::string sDir;
  Profile profile;
  void swap(DirAndProfile& other) {
    sDir.swap(other.sDir);
    profile.swap(other.profile);
  }
};
static std::vector<DirAndProfile> g_vLocalProfile;

static int CompareProfileDisplayName(
    const DirAndProfile& a, const DirAndProfile& b) {
  int result = CompareNoCase(
      a.profile.GetDisplayNameOrHighScoreName(),
      b.profile.GetDisplayNameOrHighScoreName());
  if (result != 0) {
    return result;
  }
  return CompareNoCase(LocalProfileDirToID(a.sDir), LocalProfileDirToID(b.sDir));
}

static ThemeMetric<bool> FIXED_PROFILES("ProfileManager", "FixedProfiles");
static ThemeMetric<int> NUM_FIXED_PROFILES(
    "ProfileManager", "NumFixedProfiles");
#define FIXED_PROFILE_CHARACTER_ID(i) \
  THEME->GetMetric(                   \
      "ProfileManager", ssprintf("FixedProfileCharacterID%d", int(i + 1)))

static int GetFixedProfileCount() {
  int fixed_profiles = NUM_FIXED_PROFILES;
  if (fixed_profiles < 0) {
    LOG->Warn(
        "ProfileManager: NumFixedProfiles was %d; clamping to 0",
        fixed_profiles);
    return 0;
  }
  if (fixed_profiles > MAX_ID + 1) {
    LOG->Warn(
        "ProfileManager: NumFixedProfiles was %d; clamping to %d",
        fixed_profiles, MAX_ID + 1);
    return MAX_ID + 1;
  }
  return fixed_profiles;
}

static bool IsProfilePlayerNumberValid(PlayerNumber pn, const char* context) {
  if (pn >= 0 && pn < NUM_PLAYERS) {
    return true;
  }

  LOG->Warn("%s: invalid player number %d", context, int(pn));
  return false;
}

ProfileManager::ProfileManager() : m_stats_prefix("") {
  m_pMachineProfile = new Profile;
  FOREACH_PlayerNumber(pn) m_pMemoryCardProfile[pn] = new Profile;

  // Register with Lua.
  if (LUA != nullptr) {
    Lua* L = LUA->Get();
    if (L != nullptr) {
      lua_pushstring(L, "PROFILEMAN");
      this->PushSelf(L);
      lua_settable(L, LUA_GLOBALSINDEX);
      LUA->Release(L);
    }
  }
}

ProfileManager::~ProfileManager() {
  // Unregister with Lua.
  if (LUA != nullptr) {
    LUA->UnsetGlobal("PROFILEMAN");
  }

  RageUtil::SafeDelete(m_pMachineProfile);
  FOREACH_PlayerNumber(pn) RageUtil::SafeDelete(m_pMemoryCardProfile[pn]);
}

void ProfileManager::Init() {
  FOREACH_PlayerNumber(p) {
    m_bWasLoadedFromMemoryCard[p] = false;
    m_bLastLoadWasTamperedOrCorrupt[p] = false;
    m_bLastLoadWasFromLastGood[p] = false;
    m_bNeedToBackUpLastLoad[p] = false;
    m_bNewProfile[p] = false;
  }

  LoadMachineProfile();

  RefreshLocalProfilesFromDisk();

  if (FIXED_PROFILES) {
    if (THEME == nullptr || CHARMAN == nullptr) {
      LOG->Warn(
          "ProfileManager::Init: fixed profiles requested before theme or "
          "characters are available");
      return;
    }

    const int fixed_profile_count = GetFixedProfileCount();

    // resize to the fixed number
    if ((int)g_vLocalProfile.size() > fixed_profile_count) {
      g_vLocalProfile.erase(
          g_vLocalProfile.begin() + fixed_profile_count,
          g_vLocalProfile.end());
    }

    for (int i = g_vLocalProfile.size(); i < fixed_profile_count; i++) {
      std::string sCharacterID = FIXED_PROFILE_CHARACTER_ID(i);
      Character* pCharacter = CHARMAN->GetCharacterFromID(sCharacterID);
      if (pCharacter == nullptr) {
        LOG->Warn(
            "ProfileManager::Init: fixed profile character '%s' was not found",
            sCharacterID.c_str());
        continue;
      }
      std::string sProfileID;
      if (!CreateLocalProfile(pCharacter->GetDisplayName(), sProfileID)) {
        LOG->Warn(
            "ProfileManager::Init: failed to create fixed profile for '%s'",
            sCharacterID.c_str());
        continue;
      }
      Profile* pProfile = GetLocalProfile(sProfileID);
      if (pProfile == nullptr) {
        LOG->Warn(
            "ProfileManager::Init: fixed profile '%s' was not available after "
            "creation",
            sProfileID.c_str());
        continue;
      }
      pProfile->m_sCharacterID = sCharacterID;
      if (!SaveLocalProfile(sProfileID)) {
        LOG->Warn(
            "ProfileManager::Init: failed to save fixed profile '%s'",
            sProfileID.c_str());
      }
    }

    if ((int)g_vLocalProfile.size() != fixed_profile_count) {
      LOG->Warn(
          "ProfileManager::Init: expected %d fixed profiles, found %zu",
          fixed_profile_count, g_vLocalProfile.size());
    }
  }
}

bool ProfileManager::FixedProfiles() const { return FIXED_PROFILES; }

ProfileLoadResult ProfileManager::LoadProfile(
    PlayerNumber pn, std::string sProfileDir, bool bIsMemCard) {
  LOG->Trace(
      "LoadingProfile P%d, %s, %d", pn + 1, sProfileDir.c_str(), bIsMemCard);

  if (!IsProfilePlayerNumberValid(pn, "ProfileManager::LoadProfile")) {
    return ProfileLoadResult_FailedNoProfile;
  }

  if (sProfileDir.empty() || Right(sProfileDir, 1) != "/") {
    LOG->Warn(
        "ProfileManager::LoadProfile: refusing invalid profile dir '%s'",
        sProfileDir.c_str());
    return ProfileLoadResult_FailedNoProfile;
  }

  Profile* profile = bIsMemCard
                         ? m_pMemoryCardProfile[pn]
                         : GetLocalProfile(LocalProfileDirToID(sProfileDir));
  if (profile == nullptr) {
    LOG->Warn(
        "ProfileManager::LoadProfile: no profile storage available for '%s'",
        sProfileDir.c_str());
    return ProfileLoadResult_FailedNoProfile;
  }

  m_sProfileDir[pn] = sProfileDir;
  m_bWasLoadedFromMemoryCard[pn] = bIsMemCard;
  m_bLastLoadWasTamperedOrCorrupt[pn] = false;
  m_bLastLoadWasFromLastGood[pn] = false;
  m_bNeedToBackUpLastLoad[pn] = false;

  // Try to load the original, non-backup data.
  ProfileLoadResult lr = profile->LoadAllFromDir(m_sProfileDir[pn], ShouldSignProfiles());

  std::string sBackupDir = m_sProfileDir[pn] + LAST_GOOD_SUBDIR;

  if (lr == ProfileLoadResult_Success) {
    /* Next time the profile is written, move this good profile into LastGood.
     */
    m_bNeedToBackUpLastLoad[pn] = true;
  }

  m_bLastLoadWasTamperedOrCorrupt[pn] = lr == ProfileLoadResult_FailedTampered;

  //
  // Try to load from the backup if the original data fails to load
  //
  if (lr == ProfileLoadResult_FailedTampered) {
    lr = profile->LoadAllFromDir(sBackupDir, ShouldSignProfiles());
    m_bLastLoadWasFromLastGood[pn] = lr == ProfileLoadResult_Success;

    /* If the LastGood profile doesn't exist at all, and the actual profile was
     * failed_tampered, then the error should be failed_tampered and not
     * failed_no_profile. */
    if (lr == ProfileLoadResult_FailedNoProfile) {
      LOG->Trace(
          "Profile was corrupt and LastGood for %s doesn't exist; error is "
          "ProfileLoadResult_FailedTampered",
          sProfileDir.c_str());
      lr = ProfileLoadResult_FailedTampered;
    }
  }

  if (lr == ProfileLoadResult_Success) {
    if (profile->m_sDisplayName.empty()) {
      profile->m_sDisplayName = PlayerNumberToLocalizedString(pn);
    }
    profile->LoadCustomFunction(sProfileDir, pn);
    profile->LoadSongsFromDir(sProfileDir, ProfileSlot(pn));
  }

  LOG->Trace("Done loading profile - result %d", lr);

  return lr;
}

bool ProfileManager::LoadLocalProfileFromMachine(PlayerNumber pn) {
  if (!IsProfilePlayerNumberValid(
          pn, "ProfileManager::LoadLocalProfileFromMachine")) {
    return false;
  }

  std::string sProfileID = m_sDefaultLocalProfileID[pn];
  m_sProfileDir[pn] = "";
  m_sProfileDirImportedFrom[pn] = "";
  m_bWasLoadedFromMemoryCard[pn] = false;
  m_bLastLoadWasTamperedOrCorrupt[pn] = false;
  m_bLastLoadWasFromLastGood[pn] = false;
  m_bNeedToBackUpLastLoad[pn] = false;
  m_bNewProfile[pn] = false;

  if (!IsSafeLocalProfileID(sProfileID)) {
    if (!sProfileID.empty()) {
      LOG->Warn(
          "ProfileManager::LoadLocalProfileFromMachine: refusing unsafe profile "
          "id '%s'",
          sProfileID.c_str());
    }
    return false;
  }

  Profile* local_profile = GetLocalProfile(sProfileID);
  if (local_profile == nullptr) {
    return false;
  }

  // Make sure the profile is currently not in use by another player
  if (GAMESTATE != nullptr) {
    FOREACH_HumanPlayer(pl) {
      if (pl != pn && IsPersistentProfile(pl) && GetProfile(pl) == local_profile) {
        return false;
      }
    }
  }

  m_sProfileDir[pn] = LocalProfileIDToDir(sProfileID);

  local_profile->LoadCustomFunction(m_sProfileDir[pn], pn);

  return true;
}

void ProfileManager::GetMemoryCardProfileDirectoriesToTry(
    std::vector<std::string>& asDirsToTry) {
  asDirsToTry.clear();

  /* Try to load the preferred profile. */
  if (PREFSMAN != nullptr) {
    AppendUniqueMemoryCardSubdir(
        asDirsToTry, PREFSMAN->m_sMemoryCardProfileSubdir.Get());
  }

  /* If that failed, try loading from all fallback directories. */
  std::vector<std::string> fallback_dirs;
  split(g_sMemoryCardProfileImportSubdirs, ";", fallback_dirs, true);
  for (const std::string& fallback_dir : fallback_dirs) {
    AppendUniqueMemoryCardSubdir(asDirsToTry, fallback_dir);
  }
}

bool ProfileManager::LoadProfileFromMemoryCard(
    PlayerNumber pn, bool bLoadEdits) {
  if (!IsProfilePlayerNumberValid(
          pn, "ProfileManager::LoadProfileFromMemoryCard")) {
    return false;
  }

  UnloadProfile(pn);

  // mount slot
  if (MEMCARDMAN == nullptr ||
      MEMCARDMAN->GetCardState(pn) != MemoryCardState_Ready) {
    return false;
  }

  std::vector<std::string> asDirsToTry;
  GetMemoryCardProfileDirectoriesToTry(asDirsToTry);
  m_bNewProfile[pn] = true;
  bool bLoadedProfile = false;

  for (unsigned i = 0; i < asDirsToTry.size(); ++i) {
    const std::string& sSubdir = asDirsToTry[i];
    std::string sDir;
    if (!BuildMemoryCardProfileDir(pn, sSubdir, sDir)) {
      continue;
    }

    /* If the load fails with ProfileLoadResult_FailedNoProfile, keep searching.
     * However, if it fails with failed_tampered, data existed but couldn't be
     * loaded; we don't want to mess with it, since it's confusing and may wipe
     * out recoverable backup data.  The only time we really want to import data
     * is on the very first use, when the new profile doesn't exist at all,
     * but we also want to import scores in the case where the player created
     * a directory for edits before playing, so keep searching if the directory
     * exists with exists with no scores. */
    ProfileLoadResult res = LoadProfile(pn, sDir, true);
    if (res == ProfileLoadResult_Success) {
      m_bNewProfile[pn] = false;
      bLoadedProfile = true;
      /* If importing, store the directory we imported from, for display
       * purposes. */
      if (i > 0) {
        m_sProfileDirImportedFrom[pn] = sSubdir;
      }
      break;
    }

    if (res == ProfileLoadResult_FailedTampered) {
      m_bNewProfile[pn] = false;
      break;
    }
  }

  if (!bLoadedProfile) {
    LOG->Warn(
        "Memory card profile for P%d did not load; refusing to treat it as a "
        "writable profile",
        pn + 1);
    UnloadProfile(pn);
    return false;
  }

  /* If we imported a profile fallback directory, change the memory card
   * directory back to the preferred directory: never write over imported
   * scores. */
  std::string preferred_profile_dir;
  if (asDirsToTry.empty() ||
      !BuildMemoryCardProfileDir(pn, asDirsToTry.front(), preferred_profile_dir)) {
    LOG->Warn(
        "ProfileManager::LoadProfileFromMemoryCard: no writable memory card "
        "profile directory for P%d",
        pn + 1);
    UnloadProfile(pn);
    return false;
  }
  m_sProfileDir[pn] = preferred_profile_dir;

  /* Load edits from all fallback directories, newest first. */
  if (bLoadEdits && SONGMAN != nullptr && MEMCARDMAN->IsMounted(pn)) {
    for (unsigned i = 0; i < asDirsToTry.size(); ++i) {
      const std::string& sSubdir = asDirsToTry[i];
      std::string sDir;
      if (!BuildMemoryCardProfileDir(pn, sSubdir, sDir)) {
        continue;
      }

      if (m_bProfileStepEdits) {
        SONGMAN->LoadStepEditsFromProfileDir(sDir, (ProfileSlot)pn);
      }
      if (m_bProfileCourseEdits) {
        SONGMAN->LoadCourseEditsFromProfileDir(sDir, (ProfileSlot)pn);
      }
    }
  }

  return true;
}

bool ProfileManager::LoadFirstAvailableProfile(
    PlayerNumber pn, bool bLoadEdits) {
  if (!IsProfilePlayerNumberValid(
          pn, "ProfileManager::LoadFirstAvailableProfile")) {
    return false;
  }

  if (LoadProfileFromMemoryCard(pn, bLoadEdits)) {
    return true;
  }

  if (LoadLocalProfileFromMachine(pn)) {
    return true;
  }

  return false;
}

bool ProfileManager::FastLoadProfileNameFromMemoryCard(
    std::string sRootDir, std::string& sName) const {
  std::vector<std::string> asDirsToTry;
  GetMemoryCardProfileDirectoriesToTry(asDirsToTry);

  if (sRootDir.empty() || Right(sRootDir, 1) != "/") {
    LOG->Warn(
        "ProfileManager::FastLoadProfileNameFromMemoryCard: refusing invalid "
        "root dir '%s'",
        sRootDir.c_str());
    return false;
  }

  for (unsigned i = 0; i < asDirsToTry.size(); ++i) {
    const std::string& sSubdir = asDirsToTry[i];
    std::string normalized;
    if (!NormalizeMemoryCardProfileSubdir(sSubdir, normalized)) {
      continue;
    }
    std::string sDir = sRootDir + normalized + "/";

    Profile profile;
    ProfileLoadResult res = profile.LoadEditableDataFromDir(sDir);
    if (res == ProfileLoadResult_FailedNoProfile) {
      res = profile.LoadAllFromDir(sDir, ShouldSignProfiles());
    }
    if (res == ProfileLoadResult_Success) {
      sName = profile.GetDisplayNameOrHighScoreName();
      return true;
    } else if (res != ProfileLoadResult_FailedNoProfile) {
      break;
    }
  }

  return false;
}

bool ProfileManager::SaveProfile(PlayerNumber pn) const {
  if (!IsProfilePlayerNumberValid(pn, "ProfileManager::SaveProfile")) {
    return false;
  }

  if (m_sProfileDir[pn].empty()) {
    return false;
  }

  const Profile* profile = GetProfile(pn);
  if (profile == nullptr) {
    LOG->Warn(
        "ProfileManager::SaveProfile: refusing to save P%d because no profile "
        "is loaded",
        pn + 1);
    return false;
  }

  if (ProfileWasLoadedFromMemoryCard(pn) &&
      (MEMCARDMAN == nullptr || !MEMCARDMAN->IsMounted(pn))) {
    LOG->Warn(
        "ProfileManager::SaveProfile: refusing to save P%d because the memory "
        "card is not mounted",
        pn + 1);
    return false;
  }

  /*
   * If the profile we're writing was loaded from the primary (non-backup)
   * data, then we've validated it and know it's good.  Before writing our
   * new data, move the old, good data to the backup.  (Only do this once;
   * if we save the profile more than once, we haven't re-validated the
   * newly written data.)
   */
  if (m_bNeedToBackUpLastLoad[pn]) {
    std::string sBackupDir = m_sProfileDir[pn] + LAST_GOOD_SUBDIR;
    if (!Profile::MoveBackupToDir(m_sProfileDir[pn], sBackupDir)) {
      LOG->Warn(
          "ProfileManager::SaveProfile: refusing to overwrite profile '%s' "
          "because LastGood backup failed",
          m_sProfileDir[pn].c_str());
      return false;
    }
    m_bNeedToBackUpLastLoad[pn] = false;
  }

  bool b = profile->SaveAllToDir(m_sProfileDir[pn], ShouldSignProfiles());

  return b;
}

bool ProfileManager::SaveLocalProfile(std::string sProfileID) {
  if (!IsSafeLocalProfileID(sProfileID)) {
    LOG->Warn(
        "ProfileManager::SaveLocalProfile: refusing unsafe profile id '%s'",
        sProfileID.c_str());
    return false;
  }

  const Profile* pProfile = GetLocalProfile(sProfileID);
  if (pProfile == nullptr) {
    LOG->Warn(
        "ProfileManager::SaveLocalProfile: profile '%s' does not exist",
        sProfileID.c_str());
    return false;
  }
  std::string sDir = LocalProfileIDToDir(sProfileID);
  bool b = pProfile->SaveAllToDir(sDir, ShouldSignProfiles());
  return b;
}

void ProfileManager::UnloadProfile(PlayerNumber pn) {
  if (!IsProfilePlayerNumberValid(pn, "ProfileManager::UnloadProfile")) {
    return;
  }

  const bool had_profile_dir = !m_sProfileDir[pn].empty();
  m_sProfileDir[pn] = "";
  m_sProfileDirImportedFrom[pn] = "";
  m_bWasLoadedFromMemoryCard[pn] = false;
  m_bLastLoadWasTamperedOrCorrupt[pn] = false;
  m_bLastLoadWasFromLastGood[pn] = false;
  m_bNeedToBackUpLastLoad[pn] = false;
  m_bNewProfile[pn] = false;
  if (m_pMemoryCardProfile[pn] != nullptr) {
    m_pMemoryCardProfile[pn]->InitAll();
  }
  if (had_profile_dir && SONGMAN != nullptr) {
    SONGMAN->FreeAllLoadedFromProfile((ProfileSlot)pn);
  }
}

const Profile* ProfileManager::GetProfile(PlayerNumber pn) const {
  if (!IsProfilePlayerNumberValid(pn, "ProfileManager::GetProfile")) {
    return nullptr;
  }

  if (m_sProfileDir[pn].empty()) {
    // return an empty profile
    return m_pMemoryCardProfile[pn];
  } else if (ProfileWasLoadedFromMemoryCard(pn)) {
    return m_pMemoryCardProfile[pn];
  } else {
    std::string sProfileID = LocalProfileDirToID(m_sProfileDir[pn]);
    return GetLocalProfile(sProfileID);
  }
}

std::string ProfileManager::GetPlayerName(PlayerNumber pn) const {
  const Profile* prof = GetProfile(pn);
  return prof ? prof->GetDisplayNameOrHighScoreName() : std::string();
}

bool ProfileManager::IsPersistentProfile(PlayerNumber pn) const {
  if (!IsProfilePlayerNumberValid(
          pn, "ProfileManager::IsPersistentProfile")) {
    return false;
  }
  return !m_sProfileDir[pn].empty();
}

void ProfileManager::UnloadAllLocalProfiles() { g_vLocalProfile.clear(); }

static bool LoadLocalProfileForList(DirAndProfile& profile) {
  ProfileLoadResult result =
      profile.profile.LoadAllFromDir(profile.sDir, ShouldSignProfiles());
  if (result != ProfileLoadResult_Success) {
    LOG->Warn(
        "ProfileManager: skipping local profile '%s' because it failed to load "
        "with result %d",
        profile.sDir.c_str(), result);
    return false;
  }
  return true;
}

static void LoadLocalProfilesInCategory(
    std::vector<DirAndProfile>& category,
    std::vector<DirAndProfile>& destination) {
  for (DirAndProfile& profile : category) {
    if (LoadLocalProfileForList(profile)) {
      destination.push_back(profile);
    }
  }
}

void ProfileManager::RefreshLocalProfilesFromDisk() {
  UnloadAllLocalProfiles();

  switch (GetProfileSortOrder()) {
    case ProfileSortOrder_Alphabetical:
      LoadLocalProfilesByName();
      break;
    case ProfileSortOrder_Recent:
      LoadLocalProfilesByRecent();
      break;
    case ProfileSortOrder_CreationTime:
      LoadLocalProfilesByCreationTime();
      break;
    default:
      LoadLocalProfilesByPriority();
      break;
  }
}

void ProfileManager::LoadLocalProfilesByPriority() {
  std::vector<std::string> profile_ids;
  GetDirListing(USER_PROFILES_DIR + "*", profile_ids, true, true);
  // Profiles have 3 types:
  // 1.  Guest profiles:
  //   Meant for use by guests, always at the top of the list.
  // 2.  Normal profiles:
  //   Meant for normal use, listed after guests.
  // e.  Test profiles:
  //   Meant for use when testing things, listed last.
  // If the user renames a profile directory manually, that should not be a
  // problem. -Kyz
  std::map<ProfileType, std::vector<DirAndProfile>> categorized_profiles;
  // The type data for a profile is in its own file so that loading isn't
  // slowed down by copying temporary profiles around to make sure the list
  // is sorted.  The profiles are loaded at the end. -Kyz
  for (const std::string& id : profile_ids) {
    DirAndProfile derp;
    derp.sDir = id + "/";
    derp.profile.LoadEditableDataFromDir(derp.sDir);
    derp.profile.LoadTypeFromDir(derp.sDir);
    categorized_profiles[derp.profile.m_Type].push_back(derp);
  }

  for (auto& category : categorized_profiles) {
    std::stable_sort(
        category.second.begin(), category.second.end(),
        [](const DirAndProfile& a, const DirAndProfile& b) {
          if (a.profile.m_ListPriority != b.profile.m_ListPriority) {
            return a.profile.m_ListPriority < b.profile.m_ListPriority;
          }
          return CompareProfileDisplayName(a, b) < 0;
        });
    for (size_t i = 0; i < category.second.size(); ++i) {
      category.second[i].profile.m_ListPriority = static_cast<int>(i);
    }
  }

  LoadLocalProfilesInCategory(
      categorized_profiles[ProfileType_Guest], g_vLocalProfile);
  LoadLocalProfilesInCategory(
      categorized_profiles[ProfileType_Normal], g_vLocalProfile);
  LoadLocalProfilesInCategory(
      categorized_profiles[ProfileType_Test], g_vLocalProfile);
}

void ProfileManager::LoadLocalProfilesByName() {
  std::vector<std::string> profile_ids;
  GetDirListing(USER_PROFILES_DIR + "*", profile_ids, true, true);

  // Create separate vectors for each profile type
  std::vector<DirAndProfile> guestProfiles;
  std::vector<DirAndProfile> normalProfiles;
  std::vector<DirAndProfile> testProfiles;

  for (const std::string& id : profile_ids) {
    DirAndProfile derp;
    derp.sDir = id + "/";
    derp.profile.LoadEditableDataFromDir(derp.sDir);
    derp.profile.LoadTypeFromDir(derp.sDir);
    // insert profile into the appropriate vector based on profile type
    switch (derp.profile.m_Type) {
      case ProfileType_Guest:
        guestProfiles.push_back(derp);
        break;
      case ProfileType_Normal:
        normalProfiles.push_back(derp);
        break;
      case ProfileType_Test:
        testProfiles.push_back(derp);
        break;
      default:
        break;
    }
  }

  // Sort each vector by display name
  if (GetProfileSortAscending()) {
    auto displayNameAscending = [](const DirAndProfile& a,
                                   const DirAndProfile& b) {
      return CompareProfileDisplayName(a, b) < 0;
    };
    std::sort(guestProfiles.begin(), guestProfiles.end(), displayNameAscending);
    std::sort(
        normalProfiles.begin(), normalProfiles.end(), displayNameAscending);
    std::sort(testProfiles.begin(), testProfiles.end(), displayNameAscending);
  } else {
    auto displayNameDescending = [](const DirAndProfile& a,
                                    const DirAndProfile& b) {
      return CompareProfileDisplayName(a, b) > 0;
    };
    std::sort(
        guestProfiles.begin(), guestProfiles.end(), displayNameDescending);
    std::sort(
        normalProfiles.begin(), normalProfiles.end(), displayNameDescending);
    std::sort(testProfiles.begin(), testProfiles.end(), displayNameDescending);
  }

  LoadLocalProfilesInCategory(guestProfiles, g_vLocalProfile);
  LoadLocalProfilesInCategory(normalProfiles, g_vLocalProfile);
  LoadLocalProfilesInCategory(testProfiles, g_vLocalProfile);
}

// This function is used within RefreshLocalProfilesFromDisk() to sort the
// profiles by date.
void ProfileManager::LoadLocalProfilesByRecent() {
  std::vector<std::string> profile_ids;
  GetDirListing(USER_PROFILES_DIR + "*", profile_ids, true, true);

  // Create separate vectors for each profile type
  std::vector<DirAndProfile> guestProfiles;
  std::vector<DirAndProfile> normalProfiles;
  std::vector<DirAndProfile> testProfiles;

  // The type data for a profile is in its own file so that loading isn't
  // slowed down by copying temporary profiles around to make sure the list
  // is sorted.	The profiles are loaded at the end. -Kyz
  for (const std::string& id : profile_ids) {
    DirAndProfile derp;
    derp.sDir = id + "/";
    derp.profile.LoadTypeFromDir(derp.sDir);
    // insert profile into the appropriate vector based on profile type
    switch (derp.profile.m_Type) {
      case ProfileType_Guest:
        guestProfiles.push_back(derp);
        break;
      case ProfileType_Normal:
        normalProfiles.push_back(derp);
        break;
      case ProfileType_Test:
        testProfiles.push_back(derp);
        break;
      default:
        break;
    }
  }

  // Sort each vector by date
  if (GetProfileSortAscending()) {
    auto lastPlayedAscending = [](const DirAndProfile& a,
                                  const DirAndProfile& b) {
      if (a.profile.m_LastPlayedDate != b.profile.m_LastPlayedDate) {
        return a.profile.m_LastPlayedDate > b.profile.m_LastPlayedDate;
      }
      return CompareProfileDisplayName(a, b) < 0;
    };
    std::sort(guestProfiles.begin(), guestProfiles.end(), lastPlayedAscending);
    std::sort(
        normalProfiles.begin(), normalProfiles.end(), lastPlayedAscending);
    std::sort(testProfiles.begin(), testProfiles.end(), lastPlayedAscending);
  } else {
    auto lastPlayedDescending = [](const DirAndProfile& a,
                                   const DirAndProfile& b) {
      if (a.profile.m_LastPlayedDate != b.profile.m_LastPlayedDate) {
        return a.profile.m_LastPlayedDate < b.profile.m_LastPlayedDate;
      }
      return CompareProfileDisplayName(a, b) < 0;
    };
    std::sort(guestProfiles.begin(), guestProfiles.end(), lastPlayedDescending);
    std::sort(
        normalProfiles.begin(), normalProfiles.end(), lastPlayedDescending);
    std::sort(testProfiles.begin(), testProfiles.end(), lastPlayedDescending);
  }

  LoadLocalProfilesInCategory(guestProfiles, g_vLocalProfile);
  LoadLocalProfilesInCategory(normalProfiles, g_vLocalProfile);
  LoadLocalProfilesInCategory(testProfiles, g_vLocalProfile);
}

void ProfileManager::LoadLocalProfilesByCreationTime() {
  std::vector<std::string> profile_ids;
  GetDirListing(USER_PROFILES_DIR + "*", profile_ids, true, true);

  std::vector<DirAndProfile> guestProfiles;
  std::vector<DirAndProfile> normalProfiles;
  std::vector<DirAndProfile> testProfiles;

  for (const std::string& id : profile_ids) {
    DirAndProfile derp;
    derp.sDir = id + "/";
    derp.profile.LoadEditableDataFromDir(derp.sDir);
    derp.profile.LoadTypeFromDir(derp.sDir);
    switch (derp.profile.m_Type) {
      case ProfileType_Guest:
        guestProfiles.push_back(derp);
        break;
      case ProfileType_Normal:
        normalProfiles.push_back(derp);
        break;
      case ProfileType_Test:
        testProfiles.push_back(derp);
        break;
      default:
        break;
    }
  }

  if (GetProfileSortAscending()) {
    auto creationAscending = [](const DirAndProfile& a,
                                const DirAndProfile& b) {
      if (a.profile.m_CreationTime != b.profile.m_CreationTime) {
        return a.profile.m_CreationTime > b.profile.m_CreationTime;
      }
      return CompareProfileDisplayName(a, b) < 0;
    };
    std::sort(guestProfiles.begin(), guestProfiles.end(), creationAscending);
    std::sort(normalProfiles.begin(), normalProfiles.end(), creationAscending);
    std::sort(testProfiles.begin(), testProfiles.end(), creationAscending);
  } else {
    auto creationDescending = [](const DirAndProfile& a,
                                 const DirAndProfile& b) {
      if (a.profile.m_CreationTime != b.profile.m_CreationTime) {
        return a.profile.m_CreationTime < b.profile.m_CreationTime;
      }
      return CompareProfileDisplayName(a, b) < 0;
    };
    std::sort(guestProfiles.begin(), guestProfiles.end(), creationDescending);
    std::sort(
        normalProfiles.begin(), normalProfiles.end(), creationDescending);
    std::sort(testProfiles.begin(), testProfiles.end(), creationDescending);
  }

  LoadLocalProfilesInCategory(guestProfiles, g_vLocalProfile);
  LoadLocalProfilesInCategory(normalProfiles, g_vLocalProfile);
  LoadLocalProfilesInCategory(testProfiles, g_vLocalProfile);
}

const Profile* ProfileManager::GetLocalProfile(
    const std::string& sProfileID) const {
  if (!IsSafeLocalProfileID(sProfileID)) {
    return nullptr;
  }

  std::string sDir = LocalProfileIDToDir(sProfileID);
  for (const DirAndProfile& dap : g_vLocalProfile) {
    const std::string& sOther = dap.sDir;
    if (sOther == sDir) {
      return &dap.profile;
    }
  }

  return nullptr;
}

bool ProfileManager::CreateLocalProfile(
    std::string sName, std::string& sProfileIDOut) {
  sProfileIDOut = "";
  sName = Profile::NormalizeDisplayName(sName);
  if (sName.empty()) {
    LOG->Warn("ProfileManager::CreateLocalProfile: empty profile name");
    return false;
  }
  if (Profile::ContainsInvalidDisplayNameChar(sName)) {
    LOG->Warn(
        "ProfileManager::CreateLocalProfile: refusing profile name with "
        "invalid path or quote characters");
    return false;
  }

  // Find a directory directory name that's a number greater than all
  // existing numbers.  This preserves the "order by create date".
  // Profile IDs are actually the directory names, so they can be any string,
  // and we have to handle the case where the user renames one.
  // Since the user can rename them, they might have any number, wrapping our
  // counter or setting it to a ridiculous value.  That case must also be
  // handled. -Kyz
  int max_profile_number = -1;
  int first_free_number = 0;
  std::vector<std::string> profile_ids;
  GetLocalProfileIDs(profile_ids);
  for (std::vector<std::string>::const_iterator id = profile_ids.begin();
       id != profile_ids.end(); ++id) {
    int tmp = 0;
    if ((*id) >> tmp) {
      // The profile ids are already in order, so we don't have to handle the
      // case where 5 is encountered before 3.
      if (tmp == first_free_number) {
        ++first_free_number;
      }
      max_profile_number = std::max(tmp, max_profile_number);
    }
  }

  int profile_number = max_profile_number + 1;
  // Prevent profiles from going over the 8 digit limit.
  if (profile_number > MAX_ID || profile_number < 0) {
    profile_number = first_free_number;
  }
  if (profile_number < 0 || profile_number > MAX_ID) {
    LOG->Warn(
        "ProfileManager::CreateLocalProfile: too many profiles, cannot "
        "assign a new ID");
    return false;
  }
  std::string profile_id = ssprintf("%0" ID_DIGITS_STR "d", profile_number);

  // make sure this id doesn't already exist
  if (GetLocalProfile(profile_id) != nullptr) {
    LOG->Warn(
        "ProfileManager::CreateLocalProfile: generated duplicate profile ID "
        "'%s'",
        profile_id.c_str());
    return false;
  }

  // Create the new profile.
  std::unique_ptr<Profile> pProfile(new Profile);
  pProfile->m_sDisplayName = sName;
  pProfile->m_CreationTime = DateTime::GetNowDateTime();
  if (CHARMAN == nullptr) {
    LOG->Warn(
        "ProfileManager::CreateLocalProfile: character manager is not "
        "available");
    return false;
  }
  Character* pCharacter = CHARMAN->GetRandomCharacter();
  if (pCharacter == nullptr) {
    LOG->Warn(
        "ProfileManager::CreateLocalProfile: no character available for new "
        "profile");
    return false;
  }
  pProfile->m_sCharacterID = pCharacter->m_sCharacterID;

  // Save it to disk.
  std::string sProfileDir = LocalProfileIDToDir(profile_id);
  if (!pProfile->SaveAllToDir(sProfileDir, ShouldSignProfiles())) {
    return false;
  }

  AddLocalProfileByID(pProfile.release(), profile_id);

  sProfileIDOut = profile_id;
  return true;
}

static void InsertProfileIntoList(DirAndProfile& derp) {
  bool inserted = false;
  derp.profile.m_ListPriority = 0;
  int index = -1;
  for (auto curr = g_vLocalProfile.begin(); curr != g_vLocalProfile.end();
       ++curr) {
    ++index;
    if (curr->profile.m_Type > derp.profile.m_Type) {
      if (!derp.profile.SaveTypeToDir(derp.sDir)) {
        LOG->Warn(
            "ProfileManager: failed to save Type.ini for '%s'",
            derp.sDir.c_str());
      }
      g_vLocalProfile.insert(curr, derp);
      inserted = true;
      break;
    } else if (curr->profile.m_Type == derp.profile.m_Type) {
      ++derp.profile.m_ListPriority;
    }
  }

  if (!inserted) {
    if (!derp.profile.SaveTypeToDir(derp.sDir)) {
      LOG->Warn(
          "ProfileManager: failed to save Type.ini for '%s'",
          derp.sDir.c_str());
    }
    index = static_cast<int>(g_vLocalProfile.size());
    g_vLocalProfile.push_back(derp);
  }

  // The above should run regardless of profile sort in case the user decides to
  // change back to priority sorting.
  if (PROFILEMAN == nullptr) {
    return;
  }

  switch (GetProfileSortOrder()) {
    case ProfileSortOrder_Recent:
    case ProfileSortOrder_CreationTime:
      PROFILEMAN->MoveProfileTopBottom(index, GetProfileSortAscending());
      break;
    case ProfileSortOrder_Alphabetical:
      PROFILEMAN->MoveProfileSorted(index, GetProfileSortAscending());
      break;
    default:
      break;
  }
}

void ProfileManager::AddLocalProfileByID(
    Profile* pProfile, std::string sProfileID) {
  std::unique_ptr<Profile> owned_profile(pProfile);
  if (owned_profile == nullptr) {
    LOG->Warn("ProfileManager::AddLocalProfileByID: null profile");
    return;
  }
  if (!IsSafeLocalProfileID(sProfileID)) {
    LOG->Warn(
        "ProfileManager::AddLocalProfileByID: refusing unsafe profile id '%s'",
        sProfileID.c_str());
    return;
  }
  // make sure this id doesn't already exist
  if (GetLocalProfile(sProfileID) != nullptr) {
    LOG->Warn(
        "ProfileManager::AddLocalProfileByID: profile '%s' already exists",
        sProfileID.c_str());
    return;
  }

  DirAndProfile derp;
  derp.sDir = LocalProfileIDToDir(sProfileID);
  derp.profile = *owned_profile;
  InsertProfileIntoList(derp);
}

bool ProfileManager::RenameLocalProfile(
    std::string sProfileID, std::string sNewName) {
  if (!IsSafeLocalProfileID(sProfileID)) {
    LOG->Warn(
        "ProfileManager::RenameLocalProfile: refusing unsafe profile id '%s'",
        sProfileID.c_str());
    return false;
  }

  Profile* pProfile = ProfileManager::GetLocalProfile(sProfileID);
  if (pProfile == nullptr) {
    LOG->Warn(
        "ProfileManager::RenameLocalProfile: profile '%s' does not exist",
        sProfileID.c_str());
    return false;
  }
  sNewName = Profile::NormalizeDisplayName(sNewName);
  if (sNewName.empty()) {
    LOG->Warn(
        "ProfileManager::RenameLocalProfile: empty normalized profile name "
        "for '%s'",
        sProfileID.c_str());
    return false;
  }
  if (Profile::ContainsInvalidDisplayNameChar(sNewName)) {
    LOG->Warn(
        "ProfileManager::RenameLocalProfile: refusing profile name with "
        "invalid path or quote characters for '%s'",
        sProfileID.c_str());
    return false;
  }
  pProfile->m_sDisplayName = sNewName;

  std::string sProfileDir = LocalProfileIDToDir(sProfileID);
  return pProfile->SaveAllToDir(sProfileDir, ShouldSignProfiles());
}

bool ProfileManager::DeleteLocalProfile(std::string sProfileID) {
  if (!IsSafeLocalProfileID(sProfileID)) {
    LOG->Warn(
        "ProfileManager::DeleteLocalProfile: refusing unsafe profile id '%s'",
        sProfileID.c_str());
    return false;
  }
  if (FixedProfiles()) {
    LOG->Warn(
        "ProfileManager::DeleteLocalProfile: refusing to delete '%s' while "
        "fixed profiles are enabled",
        sProfileID.c_str());
    return false;
  }

  Profile* pProfile = ProfileManager::GetLocalProfile(sProfileID);
  if (pProfile == nullptr) {
    LOG->Warn(
        "ProfileManager::DeleteLocalProfile: profile '%s' does not exist",
        sProfileID.c_str());
    return false;
  }
  std::string sProfileDir = LocalProfileIDToDir(sProfileID);

  FOREACH_PlayerNumber(pn) {
    if (IsPersistentProfile(pn) && GetProfile(pn) == pProfile) {
      LOG->Warn(
          "ProfileManager::DeleteLocalProfile: refusing to delete active "
          "profile '%s' for P%d",
          sProfileID.c_str(), pn + 1);
      return false;
    }
  }

  // flush directory cache in an attempt to get this working
  if (FILEMAN != nullptr) {
    FILEMAN->FlushDirCache(sProfileDir);
  }

  for (std::vector<DirAndProfile>::iterator i = g_vLocalProfile.begin();
       i != g_vLocalProfile.end(); ++i) {
    if (i->sDir == sProfileDir) {
      if (DeleteRecursive(sProfileDir)) {
        g_vLocalProfile.erase(i);

        // Delete all references to this profileID
        for (Preference<std::string>* j : m_sDefaultLocalProfileID.m_v) {
          if (j->Get() == sProfileID) {
            j->Set("");
          }
        }
        return true;
      } else {
        LOG->Warn(
            "[ProfileManager::DeleteLocalProfile] DeleteRecursive(%s) failed",
            sProfileID.c_str());
        return false;
      }
    }
  }

  LOG->Warn(
      "DeleteLocalProfile: ProfileID '%s' doesn't exist", sProfileID.c_str());
  return false;
}

void ProfileManager::SaveMachineProfile() const {
  if (m_pMachineProfile == nullptr) {
    LOG->Warn("ProfileManager::SaveMachineProfile: no machine profile");
    return;
  }

  // If the machine name has changed, make sure we use the new name.
  // It's important that this name be applied before the Player profiles
  // are saved, so that the Player's profiles show the right machine name.
  if (PREFSMAN != nullptr) {
    const_cast<ProfileManager*>(this)->m_pMachineProfile->m_sDisplayName =
        PREFSMAN->m_sMachineName;
  }

  if (!m_pMachineProfile->SaveAllToDir(
          MACHINE_PROFILE_DIR, false)) { /* don't sign machine profiles */
    LOG->Warn(
        "ProfileManager::SaveMachineProfile: failed to save machine profile "
        "to '%s'",
        MACHINE_PROFILE_DIR.c_str());
  }
}

void ProfileManager::LoadMachineProfile() {
  if (m_pMachineProfile == nullptr) {
    m_pMachineProfile = new Profile;
  }

  ProfileLoadResult lr =
      m_pMachineProfile->LoadAllFromDir(MACHINE_PROFILE_DIR, false);
  if (lr == ProfileLoadResult_FailedNoProfile) {
    m_pMachineProfile->InitAll();
    if (!m_pMachineProfile->SaveAllToDir(
            MACHINE_PROFILE_DIR, false)) { /* don't sign machine profiles */
      LOG->Warn(
          "ProfileManager::LoadMachineProfile: failed to create missing "
          "machine profile at '%s'",
          MACHINE_PROFILE_DIR.c_str());
    }
  } else if (lr != ProfileLoadResult_Success) {
    LOG->Warn(
        "ProfileManager::LoadMachineProfile: machine profile at '%s' failed "
        "to load with result %d; resetting in-memory profile",
        MACHINE_PROFILE_DIR.c_str(), lr);
    m_pMachineProfile->InitAll();
    if (!m_pMachineProfile->SaveAllToDir(
            MACHINE_PROFILE_DIR, false)) { /* don't sign machine profiles */
      LOG->Warn(
          "ProfileManager::LoadMachineProfile: failed to replace invalid "
          "machine profile at '%s'",
          MACHINE_PROFILE_DIR.c_str());
    }
  }

  // If the machine name has changed, make sure we use the new name
  if (PREFSMAN != nullptr) {
    m_pMachineProfile->m_sDisplayName = PREFSMAN->m_sMachineName;
  }

  LoadMachineProfileEdits();
}

void ProfileManager::LoadMachineProfileEdits() {
  if (SONGMAN == nullptr) {
    return;
  }
  SONGMAN->FreeAllLoadedFromProfile(ProfileSlot_Machine);
  if (m_bProfileStepEdits) {
    SONGMAN->LoadStepEditsFromProfileDir(
        MACHINE_PROFILE_DIR, ProfileSlot_Machine);
  }
  if (m_bProfileCourseEdits) {
    SONGMAN->LoadCourseEditsFromProfileDir(
        MACHINE_PROFILE_DIR, ProfileSlot_Machine);
  }
}

bool ProfileManager::ProfileWasLoadedFromMemoryCard(PlayerNumber pn) const {
  if (!IsProfilePlayerNumberValid(
          pn, "ProfileManager::ProfileWasLoadedFromMemoryCard")) {
    return false;
  }
  return !m_sProfileDir[pn].empty() && m_bWasLoadedFromMemoryCard[pn];
}

bool ProfileManager::ProfileFromMemoryCardIsNew(PlayerNumber pn) const {
  if (!IsProfilePlayerNumberValid(
          pn, "ProfileManager::ProfileFromMemoryCardIsNew")) {
    return false;
  }
  return GetProfile(pn) && m_bWasLoadedFromMemoryCard[pn] && m_bNewProfile[pn];
}

bool ProfileManager::LastLoadWasTamperedOrCorrupt(PlayerNumber pn) const {
  if (!IsProfilePlayerNumberValid(
          pn, "ProfileManager::LastLoadWasTamperedOrCorrupt")) {
    return false;
  }
  return !m_sProfileDir[pn].empty() && m_bLastLoadWasTamperedOrCorrupt[pn];
}

bool ProfileManager::LastLoadWasFromLastGood(PlayerNumber pn) const {
  if (!IsProfilePlayerNumberValid(
          pn, "ProfileManager::LastLoadWasFromLastGood")) {
    return false;
  }
  return !m_sProfileDir[pn].empty() && m_bLastLoadWasFromLastGood[pn];
}

const std::string& ProfileManager::GetProfileDir(ProfileSlot slot) const {
  switch (slot) {
    case ProfileSlot_Player1:
    case ProfileSlot_Player2:
      return m_sProfileDir[slot];
    case ProfileSlot_Machine:
      return MACHINE_PROFILE_DIR;
    default:
      LOG->Warn(
          "ProfileManager::GetProfileDir: invalid profile slot %d", int(slot));
      return EmptyProfileDir();
  }
}

std::string ProfileManager::GetProfileDirImportedFrom(ProfileSlot slot) const {
  switch (slot) {
    case ProfileSlot_Player1:
    case ProfileSlot_Player2:
      return m_sProfileDirImportedFrom[slot];
    case ProfileSlot_Machine:
      return std::string();
    default:
      LOG->Warn(
          "ProfileManager::GetProfileDirImportedFrom: invalid profile slot %d",
          int(slot));
      return std::string();
  }
}

const Profile* ProfileManager::GetProfile(ProfileSlot slot) const {
  switch (slot) {
    case ProfileSlot_Player1:
    case ProfileSlot_Player2:
      return GetProfile((PlayerNumber)slot);
    case ProfileSlot_Machine:
      return m_pMachineProfile;
    default:
      LOG->Warn(
          "ProfileManager::GetProfile: invalid profile slot %d", int(slot));
      return nullptr;
  }
}

void ProfileManager::MergeLocalProfiles(
    const std::string& from_id, const std::string& to_id) {
  if (from_id == to_id || !IsSafeLocalProfileID(from_id) ||
      !IsSafeLocalProfileID(to_id)) {
    return;
  }
  Profile* from = GetLocalProfile(from_id);
  Profile* to = GetLocalProfile(to_id);
  if (from == nullptr || to == nullptr) {
    return;
  }
  to->MergeScoresFromOtherProfile(
      from, false, LocalProfileIDToDir(from_id), LocalProfileIDToDir(to_id));
  SaveLocalProfile(to_id);
}

void ProfileManager::MergeLocalProfileIntoMachine(
    const std::string& from_id, bool skip_totals) {
  if (!IsSafeLocalProfileID(from_id)) {
    return;
  }
  Profile* from = GetLocalProfile(from_id);
  Profile* machine_profile = GetMachineProfile();
  if (from == nullptr || machine_profile == nullptr) {
    return;
  }
  machine_profile->MergeScoresFromOtherProfile(
      from, skip_totals, LocalProfileIDToDir(from_id), MACHINE_PROFILE_DIR);
  SaveMachineProfile();
}

void ProfileManager::ChangeProfileType(int index, ProfileType new_type) {
  if (index < 0 || static_cast<size_t>(index) >= g_vLocalProfile.size()) {
    return;
  }
  if (new_type == g_vLocalProfile[index].profile.m_Type) {
    return;
  }
  DirAndProfile derp = g_vLocalProfile[index];
  g_vLocalProfile.erase(g_vLocalProfile.begin() + index);
  derp.profile.m_Type = new_type;
  InsertProfileIntoList(derp);
}

void ProfileManager::MoveProfileTopBottom(int index, bool top) {
  if (index < 0 || static_cast<size_t>(index) >= g_vLocalProfile.size()) {
    return;
  }

  int swindex = 0;
  // There may be guest profiles at the top of the list, so we need to skip over
  // them if moving to the top. If we're moving the profile to the bottom we
  // should stop once we find the first test profile.
  for (size_t i = 0; i < g_vLocalProfile.size(); ++i) {
    ProfileType type = g_vLocalProfile[i].profile.m_Type;
    if (!top) {
      if (type == ProfileType_Test) {
        break;
      }
    } else {
      if (type != ProfileType_Guest) {
        break;
      }
    }
    swindex++;
  }
  if (top && index < swindex) {
    return;
  }

  // Save the profile to move
  DirAndProfile profile = g_vLocalProfile[index];
  // Remove the profile from its current position
  g_vLocalProfile.erase(g_vLocalProfile.begin() + index);
  if (!top && index < swindex) {
    --swindex;
  }
  if (swindex < 0) {
    swindex = 0;
  }
  if (static_cast<size_t>(swindex) > g_vLocalProfile.size()) {
    swindex = static_cast<int>(g_vLocalProfile.size());
  }
  // Insert the profile at the beginning of the list
  g_vLocalProfile.insert(g_vLocalProfile.begin() + swindex, profile);
}

void ProfileManager::MoveProfileSorted(int index, bool bAscending) {
  if (index < 0 || static_cast<size_t>(index) >= g_vLocalProfile.size()) {
    return;
  }

  const ProfileType moved_type = g_vLocalProfile[index].profile.m_Type;
  int swindex = 0;
  while (static_cast<size_t>(swindex) < g_vLocalProfile.size() &&
         g_vLocalProfile[swindex].profile.m_Type < moved_type) {
    ++swindex;
  }

  int endindex = swindex;
  while (static_cast<size_t>(endindex) < g_vLocalProfile.size() &&
         g_vLocalProfile[endindex].profile.m_Type == moved_type) {
    ++endindex;
  }

  if (index < swindex || index >= endindex) {
    return;
  }

  // Copy the profile to be moved
  DirAndProfile temp = g_vLocalProfile[index];

  // Remove the profile from the list
  g_vLocalProfile.erase(g_vLocalProfile.begin() + index);
  if (index < endindex) {
    --endindex;
  }

  // Find the correct location to insert the profile
  auto it = std::lower_bound(
      g_vLocalProfile.begin() + swindex, g_vLocalProfile.begin() + endindex,
      temp,
      [bAscending](const DirAndProfile& a, const DirAndProfile& b) {
        const int result = CompareProfileDisplayName(a, b);
        return bAscending ? result < 0 : result > 0;
      });
  g_vLocalProfile.insert(it, temp);
}

void ProfileManager::MoveProfilePriority(int index, bool up) {
  if (index < 0 || static_cast<size_t>(index) >= g_vLocalProfile.size()) {
    return;
  }
  int swindex = index + ((up * -2) + 1);
  ProfileType type = g_vLocalProfile[index].profile.m_Type;
  // Only swap if both indices are valid and the types match.
  if (swindex >= 0 && static_cast<size_t>(swindex) < g_vLocalProfile.size() &&
      g_vLocalProfile[swindex].profile.m_Type ==
          g_vLocalProfile[index].profile.m_Type) {
    g_vLocalProfile[index].swap(g_vLocalProfile[swindex]);
  }
  int priority = 0;
  for (DirAndProfile& curr : g_vLocalProfile) {
    if (curr.profile.m_Type == type) {
      curr.profile.m_ListPriority = priority++;
      if (!curr.profile.SaveTypeToDir(curr.sDir)) {
        LOG->Warn(
            "ProfileManager::MoveProfilePriority: failed to save Type.ini for "
            "'%s'",
            curr.sDir.c_str());
      }
    } else if (curr.profile.m_Type > type) {
      break;
    }
  }
}

//
// General
//
void ProfileManager::IncrementToastiesCount(PlayerNumber pn) {
  auto increment_toasty = [](Profile* profile) {
    if (profile != nullptr &&
        profile->m_iNumToasties < std::numeric_limits<int>::max()) {
      ++profile->m_iNumToasties;
    }
  };

  if (IsPersistentProfile(pn)) {
    increment_toasty(GetProfile(pn));
  }
  increment_toasty(GetMachineProfile());
}

void ProfileManager::AddStepTotals(
    PlayerNumber pn, int iNumTapsAndHolds, int iNumJumps, int iNumHolds,
    int iNumRolls, int iNumMines, int iNumHands, int iNumLifts,
    float fCaloriesBurned) {
  if (IsPersistentProfile(pn)) {
    Profile* profile = GetProfile(pn);
    if (profile != nullptr) {
      profile->AddStepTotals(
          iNumTapsAndHolds, iNumJumps, iNumHolds, iNumRolls, iNumMines,
          iNumHands, iNumLifts, fCaloriesBurned);
    }
  }
  Profile* machine_profile = GetMachineProfile();
  if (machine_profile != nullptr) {
    machine_profile->AddStepTotals(
        iNumTapsAndHolds, iNumJumps, iNumHolds, iNumRolls, iNumMines, iNumHands,
        iNumLifts, fCaloriesBurned);
  }
}

//
// Song stats
//
int ProfileManager::GetSongNumTimesPlayed(
    const Song* pSong, ProfileSlot slot) const {
  const Profile* profile = GetProfile(slot);
  if (pSong == nullptr || profile == nullptr) {
    return 0;
  }
  return profile->GetSongNumTimesPlayed(pSong);
}

void ProfileManager::AddStepsScore(
    const Song* pSong, const Steps* pSteps, PlayerNumber pn,
    const HighScore& hs_, int& iPersonalIndexOut, int& iMachineIndexOut) {
  HighScore hs = hs_;
  hs.SetPercentDP(
      std::max(0.0f, hs.GetPercentDP()));  // bump up negative scores

  iPersonalIndexOut = -1;
  iMachineIndexOut = -1;

  if (!IsProfilePlayerNumberValid(pn, "ProfileManager::AddStepsScore") ||
      pSong == nullptr || pSteps == nullptr) {
    return;
  }

  // In event mode, set the score's name immediately to the Profile's last
  // used name.  If no profile last used name exists, use "EVNT".
  if (GAMESTATE != nullptr && GAMESTATE->IsEventMode()) {
    Profile* pProfile = GetProfile(pn);
    if (pProfile && !pProfile->m_sLastUsedHighScoreName.empty()) {
      hs.SetName(pProfile->m_sLastUsedHighScoreName);
    } else {
      hs.SetName("EVNT");
    }
  } else {
    hs.SetName(RankingMarkerForPlayer(pn));
  }

  //
  // save high score
  //
  if (IsPersistentProfile(pn)) {
    Profile* profile = GetProfile(pn);
    if (profile != nullptr) {
      profile->AddStepsHighScore(pSong, pSteps, hs, iPersonalIndexOut);
    }
  }

  // don't save machine scores for a failed song
  const float min_machine_score =
      PREFSMAN != nullptr ? PREFSMAN->m_fMinPercentageForMachineSongHighScore
                          : 0.0f;
  if (hs.GetPercentDP() >= min_machine_score &&
      hs.GetGrade() != Grade_Failed) {
    // don't leave machine high scores for edits loaded from the player's card
    if (!pSteps->IsAPlayerEdit()) {
      Profile* machine_profile = GetMachineProfile();
      if (machine_profile != nullptr) {
        machine_profile->AddStepsHighScore(
            pSong, pSteps, hs, iMachineIndexOut);
      }
    }
  }

  /*
  // save recent score
  if( IsPersistentProfile(pn) )
          GetProfile(pn)->SaveStepsRecentScore( pSong, pSteps, hs );
  GetMachineProfile()->SaveStepsRecentScore( pSong, pSteps, hs );
  */
}

void ProfileManager::IncrementStepsPlayCount(
    const Song* pSong, const Steps* pSteps, PlayerNumber pn) {
  if (!IsProfilePlayerNumberValid(pn, "ProfileManager::IncrementStepsPlayCount") ||
      pSong == nullptr || pSteps == nullptr) {
    return;
  }
  if (IsPersistentProfile(pn)) {
    Profile* profile = GetProfile(pn);
    if (profile != nullptr) {
      profile->IncrementStepsPlayCount(pSong, pSteps);
    }
  }
  Profile* machine_profile = GetMachineProfile();
  if (machine_profile != nullptr) {
    machine_profile->IncrementStepsPlayCount(pSong, pSteps);
  }
}

// Course stats
void ProfileManager::AddCourseScore(
    const Course* pCourse, const Trail* pTrail, PlayerNumber pn,
    const HighScore& hs_, int& iPersonalIndexOut, int& iMachineIndexOut) {
  HighScore hs = hs_;
  hs.SetPercentDP(
      std::max(0.0f, hs.GetPercentDP()));  // bump up negative scores

  iPersonalIndexOut = -1;
  iMachineIndexOut = -1;

  if (!IsProfilePlayerNumberValid(pn, "ProfileManager::AddCourseScore") ||
      pCourse == nullptr || pTrail == nullptr) {
    return;
  }

  // In event mode, set the score's name immediately to the Profile's last
  // used name. If no profile last used name exists, use "EVNT".
  if (GAMESTATE != nullptr && GAMESTATE->IsEventMode()) {
    Profile* pProfile = GetProfile(pn);
    if (pProfile && !pProfile->m_sLastUsedHighScoreName.empty()) {
      hs.SetName(pProfile->m_sLastUsedHighScoreName);
    } else {
      hs.SetName("EVNT");
    }
  } else {
    hs.SetName(RankingMarkerForPlayer(pn));
  }

  // save high score
  if (IsPersistentProfile(pn)) {
    Profile* profile = GetProfile(pn);
    if (profile != nullptr) {
      profile->AddCourseHighScore(pCourse, pTrail, hs, iPersonalIndexOut);
    }
  }
  const float min_machine_score =
      PREFSMAN != nullptr ? PREFSMAN->m_fMinPercentageForMachineCourseHighScore
                          : 0.0f;
  if (hs.GetPercentDP() >= min_machine_score) {
    Profile* machine_profile = GetMachineProfile();
    if (machine_profile != nullptr) {
      machine_profile->AddCourseHighScore(
          pCourse, pTrail, hs, iMachineIndexOut);
    }
  }

  /*
  // save recent score
  if( IsPersistentProfile(pn) )
          GetProfile(pn)->SaveCourseRecentScore( pCourse, pTrail, hs );
  GetMachineProfile()->SaveCourseRecentScore( pCourse, pTrail, hs );
  */
}

void ProfileManager::IncrementCoursePlayCount(
    const Course* pCourse, const Trail* pTrail, PlayerNumber pn) {
  if (!IsProfilePlayerNumberValid(
          pn, "ProfileManager::IncrementCoursePlayCount") ||
      pCourse == nullptr || pTrail == nullptr) {
    return;
  }
  if (IsPersistentProfile(pn)) {
    Profile* profile = GetProfile(pn);
    if (profile != nullptr) {
      profile->IncrementCoursePlayCount(pCourse, pTrail);
    }
  }
  Profile* machine_profile = GetMachineProfile();
  if (machine_profile != nullptr) {
    machine_profile->IncrementCoursePlayCount(pCourse, pTrail);
  }
}

// Category stats
void ProfileManager::AddCategoryScore(
    StepsType st, RankingCategory rc, PlayerNumber pn, const HighScore& hs_,
    int& iPersonalIndexOut, int& iMachineIndexOut) {
  HighScore hs = hs_;
  iPersonalIndexOut = -1;
  iMachineIndexOut = -1;
  if (!IsProfilePlayerNumberValid(pn, "ProfileManager::AddCategoryScore")) {
    return;
  }
  hs.SetName(RankingMarkerForPlayer(pn));
  if (IsPersistentProfile(pn)) {
    Profile* profile = GetProfile(pn);
    if (profile != nullptr) {
      profile->AddCategoryHighScore(st, rc, hs, iPersonalIndexOut);
    }
  }
  const float min_machine_score =
      PREFSMAN != nullptr ? PREFSMAN->m_fMinPercentageForMachineSongHighScore
                          : 0.0f;
  if (hs.GetPercentDP() > min_machine_score) {
    Profile* machine_profile = GetMachineProfile();
    if (machine_profile != nullptr) {
      machine_profile->AddCategoryHighScore(st, rc, hs, iMachineIndexOut);
    }
  }
}

void ProfileManager::IncrementCategoryPlayCount(
    StepsType st, RankingCategory rc, PlayerNumber pn) {
  if (!IsProfilePlayerNumberValid(
          pn, "ProfileManager::IncrementCategoryPlayCount")) {
    return;
  }
  if (IsPersistentProfile(pn)) {
    Profile* profile = GetProfile(pn);
    if (profile != nullptr) {
      profile->IncrementCategoryPlayCount(st, rc);
    }
  }
  Profile* machine_profile = GetMachineProfile();
  if (machine_profile != nullptr) {
    machine_profile->IncrementCategoryPlayCount(st, rc);
  }
}

bool ProfileManager::IsPersistentProfile(ProfileSlot slot) const {
  switch (slot) {
    case ProfileSlot_Player1:
    case ProfileSlot_Player2:
      return GAMESTATE != nullptr && GAMESTATE->IsHumanPlayer((PlayerNumber)slot) &&
             !m_sProfileDir[slot].empty();
    case ProfileSlot_Machine:
      return m_pMachineProfile != nullptr;
    default:
      LOG->Warn(
          "ProfileManager::IsPersistentProfile: invalid profile slot %d",
          int(slot));
      return false;
  }
}

void ProfileManager::GetLocalProfileIDs(
    std::vector<std::string>& vsProfileIDsOut) const {
  vsProfileIDsOut.clear();
  for (const DirAndProfile& i : g_vLocalProfile) {
    std::string sID = LocalProfileDirToID(i.sDir);
    vsProfileIDsOut.push_back(sID);
  }
}

void ProfileManager::GetLocalProfileDisplayNames(
    std::vector<std::string>& vsProfileDisplayNamesOut) const {
  vsProfileDisplayNamesOut.clear();
  for (const DirAndProfile& i : g_vLocalProfile) {
    vsProfileDisplayNamesOut.push_back(i.profile.m_sDisplayName);
  }
}

int ProfileManager::GetLocalProfileIndexFromID(std::string sProfileID) const {
  if (!IsSafeLocalProfileID(sProfileID)) {
    return -1;
  }
  std::string sDir = LocalProfileIDToDir(sProfileID);
  int j = 0;
  for (const DirAndProfile& i : g_vLocalProfile) {
    if (i.sDir == sDir) {
      return j;
    }
    ++j;
  }
  return -1;
}

std::string ProfileManager::GetLocalProfileIDFromIndex(int iIndex) {
  if (iIndex < 0 || static_cast<size_t>(iIndex) >= g_vLocalProfile.size()) {
    LOG->Warn(
        "ProfileManager::GetLocalProfileIDFromIndex: index %d out of range",
        iIndex);
    return std::string();
  }
  std::string sID = LocalProfileDirToID(g_vLocalProfile[iIndex].sDir);
  return sID;
}

Profile* ProfileManager::GetLocalProfileFromIndex(int iIndex) {
  if (iIndex < 0 || static_cast<size_t>(iIndex) >= g_vLocalProfile.size()) {
    LOG->Warn(
        "ProfileManager::GetLocalProfileFromIndex: index %d out of range",
        iIndex);
    return nullptr;
  }
  return &g_vLocalProfile[iIndex].profile;
}

int ProfileManager::GetNumLocalProfiles() const {
  return static_cast<int>(
      std::min<size_t>(g_vLocalProfile.size(), std::numeric_limits<int>::max()));
}

void ProfileManager::SetStatsPrefix(const std::string& prefix) {
  if (!prefix.empty() && !IsSafeProfilePathComponent(prefix)) {
    LOG->Warn(
        "ProfileManager::SetStatsPrefix: refusing unsafe stats prefix '%s'",
        prefix.c_str());
    return;
  }

  m_stats_prefix = prefix;
  const bool sign_profiles = ShouldSignProfiles();
  for (size_t i = 0; i < g_vLocalProfile.size(); ++i) {
    g_vLocalProfile[i].profile.HandleStatsPrefixChange(
        g_vLocalProfile[i].sDir, sign_profiles);
  }
  FOREACH_PlayerNumber(pn) {
    if (ProfileWasLoadedFromMemoryCard(pn)) {
      if (MEMCARDMAN == nullptr || !MEMCARDMAN->IsMounted(pn)) {
        LOG->Warn(
            "ProfileManager::SetStatsPrefix: skipping memory card profile "
            "for P%d because the card is not mounted",
            pn + 1);
        continue;
      }
      Profile* profile = GetProfile(pn);
      if (profile != nullptr) {
        profile->HandleStatsPrefixChange(m_sProfileDir[pn], sign_profiles);
      }
    }
  }
  if (m_pMachineProfile != nullptr) {
    m_pMachineProfile->HandleStatsPrefixChange(MACHINE_PROFILE_DIR, false);
  }
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the ProfileManager. */
class LunaProfileManager : public Luna<ProfileManager> {
 public:
  static int GetStatsPrefix(T* p, lua_State* L) {
    lua_pushstring(L, p->GetStatsPrefix().c_str());
    return 1;
  }
  static int SetStatsPrefix(T* p, lua_State* L) {
    std::string prefix = SArg(1);
    p->SetStatsPrefix(prefix);
    COMMON_RETURN_SELF;
  }
  static int IsPersistentProfile(T* p, lua_State* L) {
    PlayerNumber pn = Enum::Check<PlayerNumber>(L, 1, true);
    lua_pushboolean(L, pn != PLAYER_INVALID && p->IsPersistentProfile(pn));
    return 1;
  }
  static int GetProfile(T* p, lua_State* L) {
    PlayerNumber pn = Enum::Check<PlayerNumber>(L, 1, true);
    Profile* pP = p->GetProfile(pn);
    if (pP != nullptr) {
      pP->PushSelf(L);
    } else {
      lua_pushnil(L);
    }
    return 1;
  }
  static int GetMachineProfile(T* p, lua_State* L) {
    Profile* profile = p->GetMachineProfile();
    if (profile != nullptr) {
      profile->PushSelf(L);
    } else {
      lua_pushnil(L);
    }
    return 1;
  }
  static int SaveMachineProfile(T* p, lua_State*) {
    p->SaveMachineProfile();
    return 0;
  }
  static int GetLocalProfile(T* p, lua_State* L) {
    Profile* pProfile = p->GetLocalProfile(SArg(1));
    if (pProfile) {
      pProfile->PushSelf(L);
    } else {
      lua_pushnil(L);
    }
    return 1;
  }
  static int GetLocalProfileFromIndex(T* p, lua_State* L) {
    int index = IArg(1);
    if (index < 0 || index >= p->GetNumLocalProfiles()) {
      lua_pushnil(L);
      return 1;
    }
    Profile* pProfile = p->GetLocalProfileFromIndex(index);
    if (pProfile == nullptr) {
      lua_pushnil(L);
      return 1;
    }
    pProfile->PushSelf(L);
    return 1;
  }
  static int GetLocalProfileIDFromIndex(T* p, lua_State* L) {
    int index = IArg(1);
    if (index < 0 || index >= p->GetNumLocalProfiles()) {
      lua_pushstring(L, "");
      return 1;
    }
    lua_pushstring(L, p->GetLocalProfileIDFromIndex(index).c_str());
    return 1;
  }
  static int GetLocalProfileIndexFromID(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetLocalProfileIndexFromID(SArg(1)));
    return 1;
  }
  static int GetNumLocalProfiles(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetNumLocalProfiles());
    return 1;
  }
  static int GetProfileDir(T* p, lua_State* L) {
    ProfileSlot slot = Enum::Check<ProfileSlot>(L, 1, true);
    if (!IsValidProfileSlot(slot)) {
      lua_pushstring(L, "");
      return 1;
    }
    lua_pushstring(L, p->GetProfileDir(slot).c_str());
    return 1;
  }
  static int IsSongNew(T* p, lua_State* L) {
    Song* song = lua_isnil(L, 1) ? nullptr : Luna<Song>::check(L, 1);
    lua_pushboolean(L, song != nullptr && p->IsSongNew(song));
    return 1;
  }
  static int ProfileWasLoadedFromMemoryCard(T* p, lua_State* L) {
    PlayerNumber pn = Enum::Check<PlayerNumber>(L, 1, true);
    lua_pushboolean(
        L, pn != PLAYER_INVALID && p->ProfileWasLoadedFromMemoryCard(pn));
    return 1;
  }
  static int LastLoadWasTamperedOrCorrupt(T* p, lua_State* L) {
    PlayerNumber pn = Enum::Check<PlayerNumber>(L, 1, true);
    lua_pushboolean(
        L, pn != PLAYER_INVALID && p->LastLoadWasTamperedOrCorrupt(pn));
    return 1;
  }
  static int GetPlayerName(T* p, lua_State* L) {
    PlayerNumber pn = Enum::Check<PlayerNumber>(L, 1, true);
    lua_pushstring(L, p->GetPlayerName(pn).c_str());
    return 1;
  }

  static int LocalProfileIDToDir(T*, lua_State* L) {
    std::string profile_id = SArg(1);
    if (!IsSafeLocalProfileID(profile_id)) {
      lua_pushstring(L, "");
      return 1;
    }
    std::string dir = ::LocalProfileIDToDir(profile_id);
    lua_pushstring(L, dir.c_str());
    return 1;
  }
  static int CreateLocalProfile(T* p, lua_State* L) {
    std::string sProfileID;
    bool ok = p->CreateLocalProfile(SArg(1), sProfileID);
    lua_pushboolean(L, ok);
    lua_pushstring(L, sProfileID.c_str());
    return 2;
  }
  static int RefreshLocalProfilesFromDisk(T* p, lua_State* L) {
    p->RefreshLocalProfilesFromDisk();
    return 0;
  }
  static int SaveProfile(T* p, lua_State* L) {
    PlayerNumber pn = Enum::Check<PlayerNumber>(L, 1, true);
    lua_pushboolean(L, pn != PLAYER_INVALID && p->SaveProfile(pn));
    return 1;
  }
  static int SaveLocalProfile(T* p, lua_State* L) {
    lua_pushboolean(L, p->SaveLocalProfile(SArg(1)));
    return 1;
  }
  static int ProfileFromMemoryCardIsNew(T* p, lua_State* L) {
    PlayerNumber pn = Enum::Check<PlayerNumber>(L, 1, true);
    lua_pushboolean(
        L, pn != PLAYER_INVALID && p->ProfileFromMemoryCardIsNew(pn));
    return 1;
  }
  static int GetSongNumTimesPlayed(T* p, lua_State* L) {
    Song* song = lua_isnil(L, 1) ? nullptr : Luna<Song>::check(L, 1);
    ProfileSlot slot = Enum::Check<ProfileSlot>(L, 2, true);
    lua_pushnumber(
        L, IsValidProfileSlot(slot) ? p->GetSongNumTimesPlayed(song, slot) : 0);
    return 1;
  }
  static int GetLocalProfileIDs(T* p, lua_State* L) {
    std::vector<std::string> vsProfileIDs;
    p->GetLocalProfileIDs(vsProfileIDs);
    LuaHelpers::CreateTableFromArray<std::string>(vsProfileIDs, L);
    return 1;
  }
  static int GetLocalProfileDisplayNames(T* p, lua_State* L) {
    std::vector<std::string> vsProfileNames;
    p->GetLocalProfileDisplayNames(vsProfileNames);
    LuaHelpers::CreateTableFromArray<std::string>(vsProfileNames, L);
    return 1;
  }

  LunaProfileManager() {
    ADD_METHOD(GetStatsPrefix);
    ADD_METHOD(SetStatsPrefix);
    ADD_METHOD(IsPersistentProfile);
    ADD_METHOD(GetProfile);
    ADD_METHOD(GetMachineProfile);
    ADD_METHOD(SaveMachineProfile);
    ADD_METHOD(GetLocalProfile);
    ADD_METHOD(GetLocalProfileFromIndex);
    ADD_METHOD(GetLocalProfileIDFromIndex);
    ADD_METHOD(GetLocalProfileIndexFromID);
    ADD_METHOD(GetNumLocalProfiles);
    ADD_METHOD(GetProfileDir);
    ADD_METHOD(IsSongNew);
    ADD_METHOD(ProfileWasLoadedFromMemoryCard);
    ADD_METHOD(LastLoadWasTamperedOrCorrupt);
    ADD_METHOD(GetPlayerName);
    //
    ADD_METHOD(SaveProfile);
    ADD_METHOD(SaveLocalProfile);
    ADD_METHOD(ProfileFromMemoryCardIsNew);
    ADD_METHOD(GetSongNumTimesPlayed);
    ADD_METHOD(GetLocalProfileIDs);
    ADD_METHOD(GetLocalProfileDisplayNames);
    ADD_METHOD(LocalProfileIDToDir);
    ADD_METHOD(CreateLocalProfile);
    ADD_METHOD(RefreshLocalProfilesFromDisk);
  }
};

LUA_REGISTER_CLASS(ProfileManager)
// lua end

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
