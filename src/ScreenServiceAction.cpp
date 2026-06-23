#include "ScreenServiceAction.h"

#include <algorithm>
#include <cstddef>
#include <string>
#include <vector>

#include "Bookkeeper.h"
#include "Course.h"
#include "CourseLoaderCRS.h"
#include "GameConstantsAndTypes.h"
#include "GameState.h"
#include "LocalizedString.h"
#include "MemoryCardManager.h"
#include "NotesLoaderSSC.h"
#include "PlayerNumber.h"
#include "PrefsManager.h"
#include "Profile.h"
#include "ProfileManager.h"
#include "RageFileManager.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "ScreenPrompt.h"
#include "SongManager.h"
#include "StepMania.h"
#include "ThemeManager.h"

namespace {
typedef std::string (*ServiceActionFn)();

struct ServiceActionEntry {
  const char* name;
  ServiceActionFn fn;
};

struct EditCopyStats {
  EditCopyStats()
      : copied(0), overwritten(0), ignored(0), failed(0) {}

  int copied;
  int overwritten;
  int ignored;
  int failed;
};

struct SyncFileStats {
  SyncFileStats()
      : added(0), deleted(0), overwritten(0), failed(0) {}

  int added;
  int deleted;
  int overwritten;
  int failed;
};

static LocalizedString BOOKKEEPING_DATA_CLEARED(
    "ScreenServiceAction", "Bookkeeping data cleared.");
static LocalizedString BOOKKEEPING_DATA_NOT_CLEARED(
    "ScreenServiceAction", "Bookkeeping data not cleared.");
static LocalizedString MACHINE_STATS_CLEARED(
    "ScreenServiceAction", "Machine stats cleared.");
static LocalizedString MACHINE_STATS_NOT_CLEARED(
    "ScreenServiceAction", "Machine stats not cleared.");
static LocalizedString MACHINE_EDITS_CLEARED(
    "ScreenServiceAction", "%d edits cleared, %d errors.");
static LocalizedString MACHINE_EDITS_NOT_CLEARED(
    "ScreenServiceAction", "Machine edits not cleared.");
static LocalizedString MEMORY_CARD_EDITS_NOT_CLEARED(
    "ScreenServiceAction", "Edits not cleared - No memory cards ready.");
static LocalizedString EDITS_CLEARED(
    "ScreenServiceAction", "%d edits cleared, %d errors.");
static LocalizedString STATS_NOT_SAVED(
    "ScreenServiceAction", "Stats not saved - No memory cards ready.");
static LocalizedString MACHINE_STATS_SAVED(
    "ScreenServiceAction", "Machine stats saved to P%d card.");
static LocalizedString ERROR_SAVING_MACHINE_STATS(
    "ScreenServiceAction", "Error saving machine stats to P%d card.");
static LocalizedString STATS_NOT_LOADED(
    "ScreenServiceAction", "Stats not loaded - No memory cards ready.");
static LocalizedString MACHINE_STATS_LOADED(
    "ScreenServiceAction", "Machine stats loaded from P%d card.");
static LocalizedString ERROR_LOADING_MACHINE_STATS(
    "ScreenServiceAction", "Error loading machine stats from P%d card.");
static LocalizedString THERE_IS_NO_PROFILE(
    "ScreenServiceAction", "There is no machine profile on P%d card.");
static LocalizedString PROFILE_CORRUPT(
    "ScreenServiceAction",
    "The profile on P%d card contains corrupt or tampered data.");
static LocalizedString EDITS_NOT_COPIED(
    "ScreenServiceAction", "Edits not copied - No memory cards ready.");
static LocalizedString COPIED_TO_CARD(
    "ScreenServiceAction", "Copied to P%d card:");
static LocalizedString COPIED_FROM_CARD(
    "ScreenServiceAction", "Copied from P%d card:");
static LocalizedString COPIED("ScreenServiceAction", "%d copied");
static LocalizedString OVERWRITTEN("ScreenServiceAction", "%d overwritten");
static LocalizedString ADDED("ScreenServiceAction", "%d added");
static LocalizedString IGNORED("ScreenServiceAction", "%d ignored");
static LocalizedString FAILED("ScreenServiceAction", "%d failed");
static LocalizedString DELETED("ScreenServiceAction", "%d deleted");
static LocalizedString PREFERENCES_RESET(
    "ScreenServiceAction", "Preferences reset.");
static LocalizedString SERVICE_ACTION_CONFIRM(
    "ScreenServiceAction", "Execute service action?");
static LocalizedString SERVICE_ACTION_WARNING(
    "ScreenServiceAction",
    "This may modify profiles, preferences, or memory card data.");
static LocalizedString SERVICE_ACTION_UNAVAILABLE(
    "ScreenServiceAction", "Service action unavailable.");
static LocalizedString NO_SERVICE_ACTIONS(
    "ScreenServiceAction", "No service actions configured.");
static LocalizedString MULTIPLE_SERVICE_ACTIONS_REFUSED(
    "ScreenServiceAction",
    "Multiple service actions are not allowed in one request.");
static LocalizedString INVALID_SERVICE_ACTION(
    "ScreenServiceAction", "Invalid service action.");
static LocalizedString INVALID_MEMORY_CARD_PROFILE_DIR(
    "ScreenServiceAction", "Invalid memory card profile directory.");

void WarnServiceAction(const std::string& message) {
  if (LOG != nullptr) {
    LOG->Warn("SRC_AUDIT_FIX ScreenServiceAction: %s", message.c_str());
  }
}

std::string IntToString(int value) {
  return ssprintf("%d", value);
}

std::string FormatLocalizedNumbers(
    const std::string& text, const std::vector<int>& values) {
  std::string out;
  std::size_t valueIndex = 0;
  for (std::size_t i = 0; i < text.size(); ++i) {
    if (text[i] == '%' && i + 1 < text.size()) {
      const char specifier = text[i + 1];
      if (specifier == 'd' || specifier == 'i' || specifier == 'u') {
        if (valueIndex < values.size()) {
          out += IntToString(values[valueIndex++]);
        } else {
          out += "%";
          out += specifier;
        }
        ++i;
        continue;
      }
      if (specifier == '%') {
        out += "%";
        ++i;
        continue;
      }
    }
    out += text[i];
  }

  for (; valueIndex < values.size(); ++valueIndex) {
    if (!out.empty()) {
      out += " ";
    }
    out += IntToString(values[valueIndex]);
  }
  return out;
}

std::string FormatLocalizedInt(LocalizedString& text, int value) {
  std::vector<int> values;
  values.push_back(value);
  return FormatLocalizedNumbers(text.GetValue(), values);
}

std::string FormatLocalizedTwoInts(LocalizedString& text, int first, int second) {
  std::vector<int> values;
  values.push_back(first);
  values.push_back(second);
  return FormatLocalizedNumbers(text.GetValue(), values);
}

std::string FormatCardMessage(LocalizedString& text, PlayerNumber pn) {
  return FormatLocalizedInt(text, static_cast<int>(pn) + 1);
}

bool HasFileManager() {
  if (FILEMAN == nullptr) {
    WarnServiceAction("FILEMAN is unavailable.");
    return false;
  }
  return true;
}

bool HasProfileManager() {
  if (PROFILEMAN == nullptr || PROFILEMAN->GetMachineProfile() == nullptr) {
    WarnServiceAction("PROFILEMAN or machine profile is unavailable.");
    return false;
  }
  return true;
}

bool HasPrefsManager() {
  if (PREFSMAN == nullptr) {
    WarnServiceAction("PREFSMAN is unavailable.");
    return false;
  }
  return true;
}

std::string EnsureTrailingSlash(const std::string& path) {
  if (path.empty() || path[path.size() - 1] == '/') {
    return path;
  }
  return path + "/";
}

bool IsSafeRelativeProfileSubdir(const std::string& subdir) {
  return !subdir.empty() && subdir[0] != '/' && subdir[0] != '\\' &&
         subdir.find("..") == std::string::npos &&
         subdir.find(':') == std::string::npos &&
         subdir.find('\\') == std::string::npos;
}

bool GetMemoryCardProfileSubdir(std::string& subdirOut) {
  if (!HasPrefsManager()) {
    return false;
  }

  subdirOut = PREFSMAN->m_sMemoryCardProfileSubdir.Get();
  Trim(subdirOut);
  if (!IsSafeRelativeProfileSubdir(subdirOut)) {
    WarnServiceAction(
        "refused unsafe memory card profile subdir '" + subdirOut + "'.");
    return false;
  }
  return true;
}

std::string JoinProfileDir(const std::string& base, const std::string& subdir) {
  return EnsureTrailingSlash(base) + subdir + "/";
}

bool EnsureDirectory(const std::string& path) {
  if (!HasFileManager()) {
    return false;
  }
  if (FILEMAN->IsADirectory(path)) {
    return true;
  }
  FILEMAN->CreateDir(path);
  return FILEMAN->IsADirectory(path);
}

bool ListFiles(
    const std::string& dir, const std::string& mask,
    std::vector<std::string>& files, bool returnPathToo, bool requireDir) {
  files.clear();
  if (!HasFileManager()) {
    return false;
  }
  if (!FILEMAN->IsADirectory(dir)) {
    if (requireDir) {
      WarnServiceAction("required directory is missing: " + dir);
      return false;
    }
    return true;
  }
  GetDirListing(dir + mask, files, false, returnPathToo);
  return true;
}

bool SaveMachineProfileWithResult() {
  if (!HasProfileManager() || !HasFileManager()) {
    return false;
  }

  Profile* profile = PROFILEMAN->GetMachineProfile();
  if (PREFSMAN != nullptr) {
    profile->m_sDisplayName = PREFSMAN->m_sMachineName;
  }
  return profile->SaveAllToDir(PROFILEMAN->GetProfileDir(ProfileSlot_Machine), false);
}

bool ReloadMachineProfileIfUsable() {
  if (!HasProfileManager() || PREFSMAN == nullptr || SONGMAN == nullptr) {
    WarnServiceAction("machine profile reload skipped due to missing managers.");
    return false;
  }
  PROFILEMAN->LoadMachineProfile();
  return true;
}

class ScopedMemoryCardMount {
 public:
  ScopedMemoryCardMount()
      : m_pn(PLAYER_INVALID), m_bMountedByUs(false), m_bReady(false) {
    if (MEMCARDMAN == nullptr) {
      WarnServiceAction("MEMCARDMAN is unavailable.");
      return;
    }

    FOREACH_PlayerNumber(pn) {
      if (MEMCARDMAN->GetCardState(pn) != MemoryCardState_Ready) {
        continue;
      }

      if (MEMCARDMAN->IsMounted(pn)) {
        m_pn = pn;
        m_bReady = true;
        return;
      }

      if (MEMCARDMAN->MountCard(pn)) {
        m_pn = pn;
        m_bMountedByUs = true;
        m_bReady = true;
        return;
      }

      WarnServiceAction(
          "ready memory card failed to mount for player " +
          IntToString(static_cast<int>(pn) + 1) + ".");
    }
  }

  ~ScopedMemoryCardMount() {
    if (m_bReady && m_bMountedByUs && MEMCARDMAN != nullptr) {
      MEMCARDMAN->UnmountCard(m_pn);
    }
  }

  bool IsReady() const { return m_bReady; }
  PlayerNumber GetPlayer() const { return m_pn; }

  std::string GetMountPoint() const {
    if (!m_bReady) {
      return "";
    }
    return MEM_CARD_MOUNT_POINT[m_pn];
  }

 private:
  PlayerNumber m_pn;
  bool m_bMountedByUs;
  bool m_bReady;
};

ProfileSlot ProfileSlotForPlayer(PlayerNumber pn) {
  return pn == PLAYER_2 ? ProfileSlot_Player2 : ProfileSlot_Player1;
}

bool ValidateStepEditFile(const std::string& path, ProfileSlot sourceSlot) {
  if (!HasFileManager()) {
    return false;
  }
  SSCLoader loaderSSC;
  return loaderSSC.LoadEditFromFile(path, sourceSlot, false);
}

bool ValidateCourseEditFile(const std::string& path) {
  if (!HasFileManager()) {
    return false;
  }
  Course course;
  return CourseLoaderCRS::LoadFromCRSFile(path, course);
}

void CopyEditFiles(
    const std::string& sourceDir, const std::string& destDir,
    const std::string& mask, bool validateCourses, ProfileSlot sourceSlot,
    EditCopyStats& stats) {
  if (!HasFileManager()) {
    ++stats.failed;
    return;
  }
  if (!EnsureDirectory(destDir)) {
    ++stats.failed;
    return;
  }

  std::vector<std::string> files;
  if (!ListFiles(sourceDir, mask, files, false, false)) {
    ++stats.failed;
    return;
  }

  for (const std::string& file : files) {
    const std::string sourcePath = sourceDir + file;
    const std::string destPath = destDir + file;
    const bool valid =
        validateCourses ? ValidateCourseEditFile(sourcePath)
                        : ValidateStepEditFile(sourcePath, sourceSlot);
    if (!valid) {
      ++stats.ignored;
      continue;
    }

    const bool wasOverwrite = FILEMAN->IsAFile(destPath);
    if (!FileCopy(sourcePath, destPath)) {
      ++stats.failed;
      continue;
    }

    ++stats.copied;
    if (wasOverwrite) {
      ++stats.overwritten;
    }
  }
  FILEMAN->FlushDirCache(destDir);
}

EditCopyStats CopyEdits(
    const std::string& sourceProfileDir, const std::string& destProfileDir,
    ProfileSlot sourceSlot) {
  EditCopyStats stats;
  CopyEditFiles(
      EnsureTrailingSlash(sourceProfileDir) + EDIT_STEPS_SUBDIR,
      EnsureTrailingSlash(destProfileDir) + EDIT_STEPS_SUBDIR, "*.edit", false,
      sourceSlot, stats);
  CopyEditFiles(
      EnsureTrailingSlash(sourceProfileDir) + EDIT_COURSES_SUBDIR,
      EnsureTrailingSlash(destProfileDir) + EDIT_COURSES_SUBDIR, "*.crs", true,
      sourceSlot, stats);
  return stats;
}

std::string FormatCopyStats(
    const std::string& displayDir, const EditCopyStats& stats) {
  std::vector<std::string> lines;
  lines.push_back(displayDir);
  lines.push_back(
      FormatLocalizedInt(COPIED, stats.copied) + ", " +
      FormatLocalizedInt(OVERWRITTEN, stats.overwritten));
  if (stats.ignored > 0) {
    lines.push_back(FormatLocalizedInt(IGNORED, stats.ignored));
  }
  if (stats.failed > 0) {
    lines.push_back(FormatLocalizedInt(FAILED, stats.failed));
  }
  return join("\n", lines);
}

void SyncFiles(
    const std::string& sourceDir, const std::string& destDir,
    const std::string& mask, SyncFileStats& stats) {
  if (!HasFileManager()) {
    ++stats.failed;
    return;
  }
  if (!FILEMAN->IsADirectory(sourceDir)) {
    WarnServiceAction("sync source directory missing: " + sourceDir);
    ++stats.failed;
    return;
  }

  std::vector<std::string> sourceFiles;
  GetDirListing(sourceDir + mask, sourceFiles, false, false);
  if (sourceFiles.empty()) {
    WarnServiceAction(
        "sync source is empty for " + sourceDir + mask +
        "; destination deletions skipped.");
    return;
  }

  if (!EnsureDirectory(destDir)) {
    ++stats.failed;
    return;
  }

  std::vector<std::string> destFiles;
  GetDirListing(destDir + mask, destFiles, false, false);

  bool allCopiesSucceeded = true;
  for (const std::string& file : sourceFiles) {
    const std::string sourcePath = sourceDir + file;
    const std::string destPath = destDir + file;
    if (LOG != nullptr) {
      LOG->Trace("Copy \"%s\"", sourcePath.c_str());
    }
    const bool wasOverwrite = FILEMAN->IsAFile(destPath);
    if (!FileCopy(sourcePath, destPath)) {
      ++stats.failed;
      allCopiesSucceeded = false;
      continue;
    }
    if (wasOverwrite) {
      ++stats.overwritten;
    } else {
      ++stats.added;
    }
  }

  if (!allCopiesSucceeded) {
    WarnServiceAction("sync destination deletions skipped after copy failure.");
    FILEMAN->FlushDirCache(destDir);
    return;
  }

  std::vector<std::string> toDelete;
  GetAsNotInBs(destFiles, sourceFiles, toDelete);
  for (const std::string& file : toDelete) {
    const std::string path = destDir + file;
    if (LOG != nullptr) {
      LOG->Trace("Delete \"%s\"", path.c_str());
    }
    if (FILEMAN->Remove(path)) {
      ++stats.deleted;
    } else {
      ++stats.failed;
    }
  }
  FILEMAN->FlushDirCache(destDir);
}

std::string FormatSyncStats(const std::string& label, const SyncFileStats& stats) {
  std::string text = label + ": " + FormatLocalizedInt(ADDED, stats.added) +
                     ", " + FormatLocalizedInt(OVERWRITTEN, stats.overwritten);
  if (stats.deleted > 0) {
    text += ", " + FormatLocalizedInt(DELETED, stats.deleted);
  }
  if (stats.failed > 0) {
    text += "; " + FormatLocalizedInt(FAILED, stats.failed);
  }
  return text;
}

void ClearEditFiles(
    const std::string& profileDir, bool requireExistingDirs,
    int& editCount, int& errorCount) {
  editCount = 0;
  errorCount = 0;
  if (!HasFileManager()) {
    ++errorCount;
    return;
  }

  std::vector<std::string> files;
  const std::string stepsDir = EnsureTrailingSlash(profileDir) + EDIT_STEPS_SUBDIR;
  const std::string coursesDir =
      EnsureTrailingSlash(profileDir) + EDIT_COURSES_SUBDIR;
  if (!ListFiles(stepsDir, "*.edit", files, true, requireExistingDirs)) {
    ++errorCount;
  }
  std::vector<std::string> courseFiles;
  if (!ListFiles(coursesDir, "*.crs", courseFiles, true, requireExistingDirs)) {
    ++errorCount;
  }
  files.insert(files.end(), courseFiles.begin(), courseFiles.end());

  editCount = static_cast<int>(files.size());
  for (const std::string& path : files) {
    if (!FILEMAN->Remove(path)) {
      ++errorCount;
    }
  }
  FILEMAN->FlushDirCache(stepsDir);
  FILEMAN->FlushDirCache(coursesDir);
}

std::string ClearBookkeepingData() {
  if (BOOKKEEPER == nullptr) {
    return SERVICE_ACTION_UNAVAILABLE.GetValue();
  }
  BOOKKEEPER->ClearAll();
  return BOOKKEEPER->WriteToDisk() ? BOOKKEEPING_DATA_CLEARED.GetValue()
                                   : BOOKKEEPING_DATA_NOT_CLEARED.GetValue();
}

std::string ClearMachineStats() {
  if (!HasProfileManager()) {
    return MACHINE_STATS_NOT_CLEARED.GetValue();
  }
  Profile backup = *PROFILEMAN->GetMachineProfile();
  PROFILEMAN->GetMachineProfile()->ClearStats();
  if (!SaveMachineProfileWithResult()) {
    *PROFILEMAN->GetMachineProfile() = backup;
    return MACHINE_STATS_NOT_CLEARED.GetValue();
  }
  return MACHINE_STATS_CLEARED.GetValue();
}

std::string ClearMachineEdits() {
  if (!HasProfileManager()) {
    return MACHINE_EDITS_NOT_CLEARED.GetValue();
  }

  int editCount = 0;
  int errorCount = 0;
  ClearEditFiles(PROFILEMAN->GetProfileDir(ProfileSlot_Machine), false, editCount, errorCount);
  if (errorCount == 0) {
    SaveMachineProfileWithResult();
    ReloadMachineProfileIfUsable();
  }
  return FormatLocalizedTwoInts(MACHINE_EDITS_CLEARED, editCount, errorCount);
}

std::string ClearMemoryCardEdits() {
  ScopedMemoryCardMount card;
  if (!card.IsReady()) {
    return MEMORY_CARD_EDITS_NOT_CLEARED.GetValue();
  }

  std::string subdir;
  if (!GetMemoryCardProfileSubdir(subdir)) {
    return INVALID_MEMORY_CARD_PROFILE_DIR.GetValue();
  }

  int editCount = 0;
  int errorCount = 0;
  ClearEditFiles(JoinProfileDir(card.GetMountPoint(), subdir), false, editCount, errorCount);
  return FormatLocalizedTwoInts(EDITS_CLEARED, editCount, errorCount);
}

std::string TransferStatsMachineToMemoryCard() {
  if (!HasProfileManager() || !HasPrefsManager()) {
    return STATS_NOT_SAVED.GetValue();
  }

  ScopedMemoryCardMount card;
  if (!card.IsReady()) {
    return STATS_NOT_SAVED.GetValue();
  }

  const std::string dir = JoinProfileDir(card.GetMountPoint(), "MachineProfile");
  const bool saved = PROFILEMAN->GetMachineProfile()->SaveAllToDir(
      dir, PREFSMAN->m_bSignProfileData);
  return saved ? FormatCardMessage(MACHINE_STATS_SAVED, card.GetPlayer())
               : FormatCardMessage(ERROR_SAVING_MACHINE_STATS, card.GetPlayer());
}

std::string TransferStatsMemoryCardToMachine() {
  if (!HasProfileManager() || !HasPrefsManager()) {
    return STATS_NOT_LOADED.GetValue();
  }

  ScopedMemoryCardMount card;
  if (!card.IsReady()) {
    return STATS_NOT_LOADED.GetValue();
  }

  const std::string dir = JoinProfileDir(card.GetMountPoint(), "MachineProfile");
  Profile backup = *PROFILEMAN->GetMachineProfile();
  const ProfileLoadResult result = PROFILEMAN->GetMachineProfile()->LoadAllFromDir(
      dir, PREFSMAN->m_bSignProfileData);

  switch (result) {
    case ProfileLoadResult_Success:
      if (!SaveMachineProfileWithResult()) {
        *PROFILEMAN->GetMachineProfile() = backup;
        return FormatCardMessage(ERROR_LOADING_MACHINE_STATS, card.GetPlayer());
      }
      return FormatCardMessage(MACHINE_STATS_LOADED, card.GetPlayer());
    case ProfileLoadResult_FailedNoProfile:
      *PROFILEMAN->GetMachineProfile() = backup;
      return FormatCardMessage(THERE_IS_NO_PROFILE, card.GetPlayer());
    case ProfileLoadResult_FailedTampered:
      *PROFILEMAN->GetMachineProfile() = backup;
      return FormatCardMessage(PROFILE_CORRUPT, card.GetPlayer());
    default:
      *PROFILEMAN->GetMachineProfile() = backup;
      WarnServiceAction(
          "invalid profile load result " + IntToString(static_cast<int>(result)) +
          ".");
      return FormatCardMessage(ERROR_LOADING_MACHINE_STATS, card.GetPlayer());
  }
}

std::string CopyEditsMachineToMemoryCard() {
  if (!HasProfileManager()) {
    return EDITS_NOT_COPIED.GetValue();
  }

  ScopedMemoryCardMount card;
  if (!card.IsReady()) {
    return EDITS_NOT_COPIED.GetValue();
  }

  std::string subdir;
  if (!GetMemoryCardProfileSubdir(subdir)) {
    return INVALID_MEMORY_CARD_PROFILE_DIR.GetValue();
  }

  const std::string sourceDir = PROFILEMAN->GetProfileDir(ProfileSlot_Machine);
  const std::string destDir = JoinProfileDir(card.GetMountPoint(), subdir);
  const EditCopyStats stats = CopyEdits(sourceDir, destDir, ProfileSlot_Machine);

  std::vector<std::string> lines;
  lines.push_back(FormatCardMessage(COPIED_TO_CARD, card.GetPlayer()));
  lines.push_back(FormatCopyStats(subdir, stats));
  return join("\n\n", lines);
}

std::string SyncEditsMachineToMemoryCard() {
  if (!HasProfileManager()) {
    return EDITS_NOT_COPIED.GetValue();
  }

  ScopedMemoryCardMount card;
  if (!card.IsReady()) {
    return EDITS_NOT_COPIED.GetValue();
  }

  std::string subdir;
  if (!GetMemoryCardProfileSubdir(subdir)) {
    return INVALID_MEMORY_CARD_PROFILE_DIR.GetValue();
  }

  const std::string sourceDir = EnsureTrailingSlash(PROFILEMAN->GetProfileDir(ProfileSlot_Machine));
  const std::string destDir = JoinProfileDir(card.GetMountPoint(), subdir);

  SyncFileStats steps;
  SyncFileStats courses;
  SyncFiles(sourceDir + EDIT_STEPS_SUBDIR, destDir + EDIT_STEPS_SUBDIR, "*.edit", steps);
  SyncFiles(sourceDir + EDIT_COURSES_SUBDIR, destDir + EDIT_COURSES_SUBDIR, "*.crs", courses);

  std::vector<std::string> lines;
  lines.push_back(FormatCardMessage(COPIED_TO_CARD, card.GetPlayer()));
  lines.push_back(FormatSyncStats("Steps", steps));
  lines.push_back(FormatSyncStats("Courses", courses));
  return join("\n", lines);
}

std::string CopyEditsMemoryCardToMachine() {
  if (!HasProfileManager()) {
    return EDITS_NOT_COPIED.GetValue();
  }

  ScopedMemoryCardMount card;
  if (!card.IsReady()) {
    return EDITS_NOT_COPIED.GetValue();
  }

  std::vector<std::string> subdirs;
  ProfileManager::GetMemoryCardProfileDirectoriesToTry(subdirs);

  std::vector<std::string> lines;
  lines.push_back(FormatCardMessage(COPIED_FROM_CARD, card.GetPlayer()));

  bool copiedAnything = false;
  for (std::string subdir : subdirs) {
    Trim(subdir);
    if (!IsSafeRelativeProfileSubdir(subdir)) {
      WarnServiceAction("ignored unsafe memory card import subdir '" + subdir + "'.");
      continue;
    }

    const std::string sourceDir = JoinProfileDir(card.GetMountPoint(), subdir);
    if (FILEMAN == nullptr || !FILEMAN->IsADirectory(sourceDir)) {
      continue;
    }

    const EditCopyStats stats = CopyEdits(
        sourceDir, PROFILEMAN->GetProfileDir(ProfileSlot_Machine),
        ProfileSlotForPlayer(card.GetPlayer()));
    copiedAnything =
        copiedAnything || stats.copied > 0 || stats.overwritten > 0;
    lines.push_back(FormatCopyStats(subdir, stats));
  }

  if (copiedAnything) {
    SaveMachineProfileWithResult();
    ReloadMachineProfileIfUsable();
  } else {
    lines.push_back(FormatLocalizedInt(FAILED, 0));
  }

  return join("\n\n", lines);
}

std::string ResetPreferences() {
  StepMania::ResetPreferences();
  return PREFERENCES_RESET.GetValue();
}

const ServiceActionEntry* GetServiceActions() {
  static const ServiceActionEntry actions[] = {
      {"ClearBookkeepingData", ClearBookkeepingData},
      {"ClearMachineStats", ClearMachineStats},
      {"ClearMachineEdits", ClearMachineEdits},
      {"ClearMemoryCardEdits", ClearMemoryCardEdits},
      {"TransferStatsMachineToMemoryCard", TransferStatsMachineToMemoryCard},
      {"TransferStatsMemoryCardToMachine", TransferStatsMemoryCardToMachine},
      {"CopyEditsMachineToMemoryCard", CopyEditsMachineToMemoryCard},
      {"CopyEditsMemoryCardToMachine", CopyEditsMemoryCardToMachine},
      {"SyncEditsMachineToMemoryCard", SyncEditsMachineToMemoryCard},
      {"ResetPreferences", ResetPreferences},
      {nullptr, nullptr}};
  return actions;
}

ServiceActionFn GetActionByName(const std::string& name) {
  const ServiceActionEntry* actions = GetServiceActions();
  for (int i = 0; actions[i].name != nullptr; ++i) {
    if (name == actions[i].name) {
      return actions[i].fn;
    }
  }
  return nullptr;
}

std::string BuildInvalidActionMessage(const std::string& action) {
  if (action.empty()) {
    return NO_SERVICE_ACTIONS.GetValue();
  }
  return INVALID_SERVICE_ACTION.GetValue() + "\n" + action;
}

bool GetConfiguredAction(const std::string& screenName, std::string& actionOut,
                         std::string& errorOut) {
  actionOut.clear();
  errorOut.clear();
  if (THEME == nullptr || !THEME->IsThemeLoaded()) {
    errorOut = SERVICE_ACTION_UNAVAILABLE.GetValue();
    WarnServiceAction("cannot read Actions without loaded theme.");
    return false;
  }

  std::vector<std::string> actions;
  split(THEME->GetMetric(screenName, "Actions"), ",", actions);
  for (std::string& action : actions) {
    Trim(action);
    if (!action.empty()) {
      actionOut = actionOut.empty() ? action : actionOut + "," + action;
    }
  }

  if (actionOut.empty()) {
    errorOut = NO_SERVICE_ACTIONS.GetValue();
    return false;
  }
  if (actionOut.find(',') != std::string::npos) {
    errorOut = MULTIPLE_SERVICE_ACTIONS_REFUSED.GetValue() + "\n" + actionOut;
    return false;
  }
  if (GetActionByName(actionOut) == nullptr) {
    errorOut = BuildInvalidActionMessage(actionOut);
    return false;
  }
  return true;
}

std::string BuildConfirmationText(const std::string& action) {
  return SERVICE_ACTION_CONFIRM.GetValue() + "\n" + action + "\n\n" +
         SERVICE_ACTION_WARNING.GetValue();
}
}  // namespace

REGISTER_SCREEN_CLASS(ScreenServiceAction);

void ScreenServiceAction::BeginScreen() {
  std::string error;
  if (!GetConfiguredAction(m_sName, m_sPendingAction, error)) {
    ScreenPrompt::SetPromptSettings(error, PROMPT_OK);
    ScreenPrompt::BeginScreen();
    return;
  }

  ScreenPrompt::SetPromptSettings(
      BuildConfirmationText(m_sPendingAction), PROMPT_YES_NO, ANSWER_NO,
      ExecutePendingAction, CancelPendingAction, this);
  ScreenPrompt::BeginScreen();
}

void ScreenServiceAction::ExecutePendingAction(void* data) {
  ScreenServiceAction* screen = static_cast<ScreenServiceAction*>(data);
  if (screen == nullptr || screen->m_sPendingAction.empty()) {
    return;
  }

  const std::string action = screen->m_sPendingAction;
  screen->m_sPendingAction.clear();

  ServiceActionFn fn = GetActionByName(action);
  const std::string result =
      fn != nullptr ? fn() : BuildInvalidActionMessage(action);
  ScreenPrompt::Prompt(SM_None, result, PROMPT_OK);
}

void ScreenServiceAction::CancelPendingAction(void* data) {
  ScreenServiceAction* screen = static_cast<ScreenServiceAction*>(data);
  if (screen != nullptr) {
    screen->m_sPendingAction.clear();
  }
}

/*
 * (c) 2001-2005 Chris Danford
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
