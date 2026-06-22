#include "WheelNotifyIcon.h"

#include <algorithm>
#include <cmath>

#include "RageLog.h"
#include "RageUtil.h"
#include "Sprite.h"
#include "ThemeManager.h"
#include "ThemeMetric.h"
#include "WheelNotifyIcon.h"
#include "global.h"

/* todo: replace this entire thing with a set of AutoActors and a Scroller.
 * In reality, everything except the Beginner/Training icon can be replicated
 * in Lua (in stock StepMania 4), so I'm not sure if we even need this... -aj
 */

static ThemeMetric<bool> SHOW_TRAINING("WheelNotifyIcon", "ShowTraining");
static ThemeMetric<bool> BLINK_BEST_ICON("WheelNotifyIcon", "BlinkPlayersBest");
static ThemeMetric<int> NUM_ICONS_TO_SHOW("WheelNotifyIcon", "NumIconsToShow");

namespace {
const float ICON_CYCLE_SECONDS = 0.25f;
const unsigned MAX_WHEEL_NOTIFY_ICONS = 8;

void WarnWheelNotifyIcon(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

bool GetWheelNotifyMetricBool(const ThemeMetric<bool>& metric) {
  if (THEME == nullptr) {
    return false;
  }
  return metric.GetValue();
}

unsigned GetMaxIconsToShow() {
  if (THEME == nullptr) {
    return 0;
  }
  const int numIcons = NUM_ICONS_TO_SHOW.GetValue();
  if (numIcons <= 0) {
    return 0;
  }
  return std::min<unsigned>(
      static_cast<unsigned>(numIcons), MAX_WHEEL_NOTIFY_ICONS);
}
}  // namespace

WheelNotifyIcon::WheelNotifyIcon() : m_fCycleTime(0), m_iCurrentIcon(0) {
  // Load( THEME->GetPathG("MusicWheelItem","WheelNotifyIcon") );
  if (THEME == nullptr) {
    WarnWheelNotifyIcon(
        "SRC_AUDIT_FIX SRC-1273: WheelNotifyIcon loaded without theme "
        "manager.");
    return;
  }
  const std::string path = THEME->GetPathG("WheelNotifyIcon", "icons 4x2");
  if (!path.empty()) {
    Load(path);
  }
  StopAnimating();
}

WheelNotifyIcon::WheelNotifyIcon(const WheelNotifyIcon& cpy)
    : Sprite(cpy),
      m_vIconsToShow(cpy.m_vIconsToShow),
      m_fCycleTime(0),
      m_iCurrentIcon(0) {}

void WheelNotifyIcon::SetFlags(Flags flags) {
  m_vIconsToShow.clear();
  m_fCycleTime = 0;
  m_iCurrentIcon = 0;

  // push onto vector in highest to lowest priority

  switch (flags.iPlayersBestNumber) {
    case 1:
      m_vIconsToShow.push_back(best1);
      break;
    case 2:
      m_vIconsToShow.push_back(best2);
      break;
    case 3:
      m_vIconsToShow.push_back(best3);
      break;
  }

  if (flags.bEdits) {
    m_vIconsToShow.push_back(edits);
  }

  if (flags.iStagesForSong == 2) {
    m_vIconsToShow.push_back(long_ver);
  } else if (flags.iStagesForSong >= 3) {
    m_vIconsToShow.push_back(marathon);
  } else if (flags.iStagesForSong < 0) {
    WarnWheelNotifyIcon(
        "SRC_AUDIT_FIX SRC-1274: WheelNotifyIcon ignored negative stage "
        "count.");
  }

  if (flags.bHasBeginnerOr1Meter && GetWheelNotifyMetricBool(SHOW_TRAINING)) {
    m_vIconsToShow.push_back(training);
  }

  // If BLINK_BEST_ICON, make player's best icon blink if it's the only icon.
  if (m_vIconsToShow.size() == 1 &&
      GetWheelNotifyMetricBool(BLINK_BEST_ICON)) {
    if (m_vIconsToShow[0] >= best1 && m_vIconsToShow[0] <= best3) {
      m_vIconsToShow.push_back(empty);
    }
  }

  const unsigned int newSize =
      std::min<unsigned int>(m_vIconsToShow.size(), GetMaxIconsToShow());
  m_vIconsToShow.resize(newSize);

  // Broadcast Set message so items can react. (futures) -aj
  // Message msg("Set");
  // this->HandleMessage( msg );

  /* Make sure the right icon is selected, since we might be drawn before
   * we get another update. */
  Update(0);
}

bool WheelNotifyIcon::EarlyAbortDraw() const {
  if (m_vIconsToShow.empty()) {
    return true;
  }
  return Sprite::EarlyAbortDraw();
}

void WheelNotifyIcon::Update(float fDeltaTime) {
  if (m_vIconsToShow.size() > 0 && GetNumStates() > 0) {
    /* We should probably end up parsing the vector and then dynamically
     * insert flag icons based on "priority". Easy to do, hopefully
            - Midiman */
    if (std::isfinite(fDeltaTime) && fDeltaTime > 0) {
      m_fCycleTime += fDeltaTime;
    }
    while (m_fCycleTime >= ICON_CYCLE_SECONDS && m_vIconsToShow.size() > 1) {
      m_fCycleTime -= ICON_CYCLE_SECONDS;
      m_iCurrentIcon = (m_iCurrentIcon + 1) % m_vIconsToShow.size();
    }
    if (m_iCurrentIcon >= m_vIconsToShow.size()) {
      m_iCurrentIcon = 0;
    }
    const int state = static_cast<int>(m_vIconsToShow[m_iCurrentIcon]);
    if (state >= 0 && state < GetNumStates()) {
      Sprite::SetState(state);
    }
  }

  Sprite::Update(fDeltaTime);
}

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
