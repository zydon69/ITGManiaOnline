#include "ScreenReloadSongs.h"

#include <algorithm>
#include <string>

#include "BitmapText.h"
#include "GameState.h"
#include "ImageCache.h"
#include "MemoryCardManager.h"
#include "PrefsManager.h"
#include "ProfileManager.h"
#include "RageFileManager.h"
#include "RageLog.h"
#include "RageTimer.h"
#include "RageUtil.h"
#include "Screen.h"
#include "ScreenDimensions.h"
#include "ScreenManager.h"
#include "ScreenMessage.h"
#include "SongCacheIndex.h"
#include "SongManager.h"
#include "ThemeManager.h"
#include "UnlockManager.h"
#include "arch/LoadingWindow/LoadingWindow.h"
#include "global.h"

static const int DrawFrameRate = 20;
class ScreenReloadSongsLoadingWindow : public LoadingWindow {
  RageTimer m_LastDraw;
  BitmapText& m_BitmapText;
  std::string m_sText;
  bool m_bForceNextPaint;
  bool m_bPainting;

 public:
  ScreenReloadSongsLoadingWindow(BitmapText& bt)
      : m_BitmapText(bt),
        m_sText(),
        m_bForceNextPaint(true),
        m_bPainting(false) {}

  void SetText(std::string str) override {
    m_sText = str;
    RefreshText(true);
  }

  void SetProgress(const int progress) override {
    LoadingWindow::SetProgress(progress);
    RefreshText(false);
  }

  void SetTotalWork(const int totalWork) override {
    LoadingWindow::SetTotalWork(totalWork);
    RefreshText(false);
  }

  void SetIndeterminate(bool indeterminate) override {
    LoadingWindow::SetIndeterminate(indeterminate);
    RefreshText(false);
  }

  void SetIcon(const RageSurface* pIcon) override { Paint(pIcon != nullptr); }

  void SetSplash(const RageSurface* pSplash) override {
    Paint(pSplash != nullptr);
  }

  void RefreshText(bool forcePaint) {
    std::string text = m_sText;
    if (!m_indeterminate && m_totalWork > 0) {
      const int progress = std::max(0, std::min(m_progress, m_totalWork));
      text += ssprintf(" (%d/%d)", progress, m_totalWork);
    }
    m_BitmapText.SetText(text);
    Paint(forcePaint);
  }

  void Paint(bool forcePaint = false) {
    /* We load songs much faster than we draw frames. Cap the draw rate,
     * so we don't slow down the reload. */
    if (!forcePaint && !m_bForceNextPaint &&
        m_LastDraw.Ago() < 1.0f / DrawFrameRate) {
      return;
    }
    m_LastDraw.GetDeltaTime();
    m_bForceNextPaint = false;

    if (SCREENMAN == nullptr || m_bPainting) {
      return;
    }

    m_bPainting = true;
    SCREENMAN->Draw();
    m_bPainting = false;
  }
};

namespace {
void WarnScreenReloadSongs(const std::string& message) {
  if (LOG != nullptr) {
    LOG->Warn("SRC_AUDIT_FIX ScreenReloadSongs: %s", message.c_str());
  }
}

bool IsThemeReady() { return THEME != nullptr && THEME->IsThemeLoaded(); }

bool LoadFontWithFallback(
    BitmapText& text, const std::string& group, const std::string& element) {
  if (!IsThemeReady()) {
    WarnScreenReloadSongs(
        ssprintf("refused font load %s/%s without loaded theme.",
                 group.c_str(),
                 element.c_str()));
    return false;
  }

  const std::string font = THEME->GetPathF(group, element, true);
  if (!font.empty() && text.LoadFromFont(font)) {
    return true;
  }

  const std::string fallback = THEME->GetPathF("Common", "normal", true);
  if (!fallback.empty() && text.LoadFromFont(fallback)) {
    return true;
  }

  WarnScreenReloadSongs(
      ssprintf("failed to load font %s/%s.", group.c_str(), element.c_str()));
  return false;
}

bool GetOnlyLoadAdditionsMetric(const std::string& screenName) {
  if (!IsThemeReady()) {
    WarnScreenReloadSongs("OnlyLoadAdditions fallback false without theme.");
    return false;
  }
  return THEME->GetMetricB(screenName, "OnlyLoadAdditions");
}

bool HasReloadRuntime(std::string& reasonOut) {
  if (SONGMAN == nullptr) {
    reasonOut = "missing SONGMAN";
  } else if (FILEMAN == nullptr) {
    reasonOut = "missing FILEMAN";
  } else if (PROFILEMAN == nullptr) {
    reasonOut = "missing PROFILEMAN";
  } else if (GAMESTATE == nullptr) {
    reasonOut = "missing GAMESTATE";
  } else if (PREFSMAN == nullptr) {
    reasonOut = "missing PREFSMAN";
  } else if (MEMCARDMAN == nullptr) {
    reasonOut = "missing MEMCARDMAN";
  } else if (UNLOCKMAN == nullptr) {
    reasonOut = "missing UNLOCKMAN";
  } else if (SONGINDEX == nullptr) {
    reasonOut = "missing SONGINDEX";
  } else if (IMAGECACHE == nullptr) {
    reasonOut = "missing IMAGECACHE";
  } else {
    reasonOut.clear();
    return true;
  }
  return false;
}
}  // namespace

/* This could be cleaned up: show progress, for example.  Let's not use
 * this for the initial load, since we don't want to start up the display
 * until we finish loading songs; that way, people can continue to use their
 * computer while songs load. */
REGISTER_SCREEN_CLASS(ScreenReloadSongs);

ScreenReloadSongs::ScreenReloadSongs()
    : m_iUpdates(0),
      m_bReloadStarted(false),
      m_pLoadingWindow(nullptr),
      m_Loading() {}

void ScreenReloadSongs::Init() {
  Screen::Init();

  m_iUpdates = 0;
  m_bReloadStarted = false;

  m_Loading.SetName("LoadingText");
  LoadFontWithFallback(m_Loading, m_sName, "LoadingText");
  m_Loading.SetXY(SCREEN_CENTER_X, SCREEN_CENTER_Y);
  this->AddChild(&m_Loading);

  delete m_pLoadingWindow;
  m_pLoadingWindow = new ScreenReloadSongsLoadingWindow(m_Loading);
}

ScreenReloadSongs::~ScreenReloadSongs() { delete m_pLoadingWindow; }

void ScreenReloadSongs::Update(float fDeltaTime) {
  Screen::Update(fDeltaTime);

  /* Start the reload on the second update. On the first (0), SCREENMAN->Draw
   * won't draw. */
  if (m_bReloadStarted) {
    return;
  }

  ++m_iUpdates;
  if (m_iUpdates < 2) {
    return;
  }
  m_bReloadStarted = true;

  if (m_pLoadingWindow == nullptr) {
    m_pLoadingWindow = new ScreenReloadSongsLoadingWindow(m_Loading);
  }

  std::string missingRuntime;
  if (!HasReloadRuntime(missingRuntime)) {
    WarnScreenReloadSongs("reload skipped: " + missingRuntime);
    m_pLoadingWindow->SetText("Unable to reload songs.");
    this->PostScreenMessage(SM_GoToNextScreen, 0);
    return;
  }

  const bool onlyLoadAdditions = GetOnlyLoadAdditionsMetric(m_sName);
  if (onlyLoadAdditions) {
    SONGMAN->LoadAdditions(m_pLoadingWindow);
  } else {
    SONGMAN->Reload(false, m_pLoadingWindow);
  }

  this->PostScreenMessage(SM_GoToNextScreen, 0);
}

/*
 * (c) 2003-2004 Glenn Maynard
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
