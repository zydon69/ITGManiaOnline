#include "ScreenInstallOverlay.h"

#include <algorithm>

#include "GameConstantsAndTypes.h"
#include "PerfDiagnostics.h"
#include "PlayerNumber.h"
#include "RageFileManager.h"
#include "RageUtil.h"
#include "Screen.h"
#include "ScreenManager.h"
#include "StdString.h"
#include "ThemeManager.h"
#include "global.h"
class Song;
#include <string>
#include <vector>

#include "ActorUtil.h"
#include "CommandLineActions.h"
#include "GameManager.h"
#include "GameState.h"
#include "SongManager.h"
#include "StepMania.h"

struct PlayAfterLaunchInfo {
  std::string sSongDir;
  bool bAnyContentChanged;

  PlayAfterLaunchInfo() : bAnyContentChanged(false) {}

  void OverlayWith(const PlayAfterLaunchInfo& other) {
    if (!other.sSongDir.empty()) {
      sSongDir = other.sSongDir;
    }
    bAnyContentChanged |= other.bAnyContentChanged;
  }
};

bool InstallSmzipOsArg(const std::string& sOsZipFile, PlayAfterLaunchInfo& out);
PlayAfterLaunchInfo DoInstalls(CommandLineActions::CommandLineArgs args);

static void MarkInstalledContent(
    const std::string& sDir, PlayAfterLaunchInfo& out) {
  out.bAnyContentChanged = true;
  std::vector<std::string> vsDirParts;
  split(sDir, "/", vsDirParts, true);
  if (vsDirParts.size() == 3 && EqualsNoCase(vsDirParts[0], "Songs")) {
    out.sSongDir = "/" + sDir;
  }
}

static bool IsInstallableContentPath(const std::string& path) {
  std::vector<std::string> parts;
  split(path, "/", parts, true);
  if (parts.size() < 2 || parts[0].empty()) {
    return false;
  }

  static const char* const allowedRoots[] = {
      "Announcers",
      "BGAnimations",
      "BackgroundEffects",
      "BackgroundTransitions",
      "Characters",
      "Courses",
      "NoteSkins",
      "RandomMovies",
      "Songs",
      "Themes"};
  for (const char* root : allowedRoots) {
    if (EqualsNoCase(parts[0], root)) {
      return true;
    }
  }
  return false;
}

class ScopedMount {
 public:
  ScopedMount(
      const std::string& type, const std::string& root,
      const std::string& mountPoint)
      : m_Type(type), m_Root(root), m_MountPoint(mountPoint) {
    m_Mounted = FILEMAN != nullptr && FILEMAN->Mount(type, root, mountPoint);
  }

  ~ScopedMount() {
    if (m_Mounted && FILEMAN != nullptr) {
      FILEMAN->Unmount(m_Type, m_Root, m_MountPoint);
    }
  }

  explicit operator bool() const { return m_Mounted; }

  ScopedMount(const ScopedMount&) = delete;
  ScopedMount& operator=(const ScopedMount&) = delete;

 private:
  std::string m_Type;
  std::string m_Root;
  std::string m_MountPoint;
  bool m_Mounted{false};
};

static const std::string TEMP_ZIP_MOUNT_POINT = "/@temp-zip/";
const std::string TEMP_OS_MOUNT_POINT = "/@temp-os/";

static bool InstallSmzip(
    const std::string& sZipFile, PlayAfterLaunchInfo& out) {
  ScopedMount zipMount("zip", sZipFile, TEMP_ZIP_MOUNT_POINT);
  if (!zipMount) {
    const std::string message = "Failed to mount package " + sZipFile;
    LogRuntimeValidationDiagnostics("%s", message.c_str());
    if (SCREENMAN != nullptr) {
      SCREENMAN->SystemMessage(message);
    }
    return false;
  }

  std::vector<std::string> vsFiles;
  {
    std::vector<std::string> vsRawFiles;
    GetDirListingRecursive(TEMP_ZIP_MOUNT_POINT, "*", vsRawFiles);

    for (const std::string& s : vsRawFiles) {
      if (EqualsNoCase(GetExtension(s), "ctl") || IsADirectory(s)) {
        continue;
      }

      vsFiles.push_back(s);
    }
  }

  if (vsFiles.empty()) {
    if (SCREENMAN != nullptr) {
      SCREENMAN->SystemMessage("Package contains no installable files");
    }
    return false;
  }

  for (const std::string& tmpFile : vsFiles) {
    const std::string destination =
        Right(tmpFile, tmpFile.length() - TEMP_ZIP_MOUNT_POINT.length());
    if (!IsInstallableContentPath(destination)) {
      const std::string result =
          "Package contains a forbidden path: " + destination;
      LogRuntimeValidationDiagnostics(
          "rejected package path package='%s' path='%s'",
          sZipFile.c_str(), destination.c_str());
      if (SCREENMAN != nullptr) {
        SCREENMAN->SystemMessage(result);
      }
      return false;
    }
  }

  std::string sResult = "Success installing " + sZipFile;
  bool success = true;
  for (std::string& tmpFile : vsFiles) {
    std::string sDestFile = tmpFile;
    sDestFile =
        Right(sDestFile, sDestFile.length() - TEMP_ZIP_MOUNT_POINT.length());

    std::string sDir, sThrowAway;
    splitpath(sDestFile, sDir, sThrowAway, sThrowAway);

    FILEMAN->CreateDir(sDir);

    if (!FileCopy(tmpFile, sDestFile)) {
      success = false;
      sResult = "Error extracting " + sDestFile;
      break;
    }
    MarkInstalledContent(sDir, out);
  }

  if (SCREENMAN != nullptr) {
    SCREENMAN->SystemMessage(sResult);
  }
  return success;
}

bool InstallSmzipOsArg(
    const std::string& sOsZipFile, PlayAfterLaunchInfo& out) {
  if (SCREENMAN != nullptr) {
    SCREENMAN->SystemMessage("Installing " + sOsZipFile);
  }

  std::string sOsDir, sFilename, sExt;
  splitpath(sOsZipFile, sOsDir, sFilename, sExt);

  ScopedMount osMount("dir", sOsDir, TEMP_OS_MOUNT_POINT);
  if (!osMount) {
    const std::string message = "Failed to access package directory " + sOsDir;
    LogRuntimeValidationDiagnostics("%s", message.c_str());
    if (SCREENMAN != nullptr) {
      SCREENMAN->SystemMessage(message);
    }
    return false;
  }
  return InstallSmzip(TEMP_OS_MOUNT_POINT + sFilename + sExt, out);
}

static bool IsPackageFile(const std::string& arg) {
  std::string ext = GetExtension(arg);
  return EqualsNoCase(ext, "smzip") || EqualsNoCase(ext, "zip");
}

PlayAfterLaunchInfo DoInstalls(CommandLineActions::CommandLineArgs args) {
  PlayAfterLaunchInfo ret;
  for (int i = 0; i < (int)args.argv.size(); i++) {
    std::string s = args.argv[i];
    if (IsPackageFile(s)) {
      InstallSmzipOsArg(s, ret);
    }
  }
  return ret;
}

REGISTER_SCREEN_CLASS(ScreenInstallOverlay);

ScreenInstallOverlay::~ScreenInstallOverlay() {}
void ScreenInstallOverlay::Init() {
  Screen::Init();

  m_textStatus.LoadFromFont(THEME->GetPathF("ScreenInstallOverlay", "status"));
  m_textStatus.SetName("Status");
  ActorUtil::LoadAllCommandsAndSetXY(m_textStatus, "ScreenInstallOverlay");
  this->AddChild(&m_textStatus);
}

bool ScreenInstallOverlay::Input(const InputEventPlus& input) {
  return Screen::Input(input);
}

void ScreenInstallOverlay::Update(float fDeltaTime) {
  Screen::Update(fDeltaTime);
  PlayAfterLaunchInfo playAfterLaunchInfo;
  while (CommandLineActions::ToProcess.size() > 0) {
    CommandLineActions::CommandLineArgs args =
        CommandLineActions::ToProcess.back();
    CommandLineActions::ToProcess.pop_back();
    PlayAfterLaunchInfo pali2 = DoInstalls(args);
    playAfterLaunchInfo.OverlayWith(pali2);
  }
  if (playAfterLaunchInfo.bAnyContentChanged) {
    SONGMAN->Reload(false);
  }

  if (!playAfterLaunchInfo.sSongDir.empty()) {
    Song* pSong = nullptr;
    GAMESTATE->Reset();
    std::string sInitialScreen;
    if (playAfterLaunchInfo.sSongDir.length() > 0) {
      pSong = SONGMAN->GetSongFromDir(playAfterLaunchInfo.sSongDir);
    }
    if (pSong) {
      std::vector<const Style*> vpStyle;
      GAMEMAN->GetStylesForGame(GAMESTATE->m_pCurGame, vpStyle, false);
      GAMESTATE->m_PlayMode.Set(PLAY_MODE_REGULAR);
      GAMESTATE->m_bSideIsJoined[0] = true;
      GAMESTATE->SetMasterPlayerNumber(PLAYER_1);
      GAMESTATE->SetCurrentStyle(vpStyle[0], PLAYER_1);
      GAMESTATE->m_pCurSong.Set(pSong);
      GAMESTATE->m_pPreferredSong = pSong;
      sInitialScreen = StepMania::GetSelectMusicScreen();
    } else {
      sInitialScreen = StepMania::GetInitialScreen();
    }

    Screen* curScreen = SCREENMAN->GetTopScreen();
    if (curScreen->GetScreenType() == game_menu ||
        curScreen->GetScreenType() == attract) {
      SCREENMAN->SetNewScreen(sInitialScreen);
    }
  }
}

/*
 * (c) 2001-2005 Chris Danford, Glenn Maynard
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
