#include "ScreenTestSound.h"

#include <algorithm>
#include <array>
#include <string>
#include <vector>

#include "InputEventPlus.h"
#include "InputFilter.h"
#include "RageLog.h"
#include "RageInputDevice.h"
#include "RageSoundManager.h"
#include "RageUtil.h"
#include "Screen.h"
#include "ScreenManager.h"
#include "ThemeManager.h"

REGISTER_SCREEN_CLASS(ScreenTestSound);

namespace {
struct TestSoundPath {
  const char* group;
  const char* element;
};

const std::array<TestSoundPath, 5> TEST_SOUND_PATHS = {{
    {"Common", "start"},
    {"Common", "cancel"},
    {"Common", "invalid"},
    {"Common", "coin"},
    {"ScreenTitleMenu", "change"},
}};

bool HasLoadedTheme() { return THEME != nullptr && THEME->IsThemeLoaded(); }

bool LoadCommonFont(BitmapText& text) {
  return HasLoadedTheme() &&
         text.LoadFromFont(THEME->GetPathF("Common", "normal", true));
}

std::string GetOptionalSoundPath(const TestSoundPath& path) {
  if (!HasLoadedTheme()) {
    return "";
  }
  return THEME->GetPathS(path.group, path.element, true);
}
}  // namespace

void ScreenTestSound::Init() {
  Screen::Init();

  m_helpReady = false;
  m_textReady.fill(false);
  for (size_t i = 0; i < m_sounds.size(); ++i) {
    m_soundCopies[i].clear();
    m_sounds[i].s.Unload();
  }

  m_help.SetXY(450, 400);
  m_helpReady = LoadCommonFont(m_help);
  if (m_helpReady) {
    this->AddChild(&m_help);
    m_help.SetZoom(.5f);
    m_help.SetText(
        "p  Play\n"
        "s  Stop\n"
        "l  Set looping\n"
        "a  Set autostop\n"
        "c  Set continue\n"
        "Back  Exit");
  }

  for (size_t i = 0; i < m_sounds.size(); ++i) {
    m_textReady[i] = LoadCommonFont(m_sounds[i].txt);
    if (m_textReady[i]) {
      this->AddChild(&m_sounds[i].txt);
      m_sounds[i].txt.SetZoom(.5f);
    }
  }

  m_sounds[0].txt.SetXY(150, 100);
  m_sounds[1].txt.SetXY(450, 100);
  m_sounds[2].txt.SetXY(150, 250);
  m_sounds[3].txt.SetXY(450, 250);
  m_sounds[4].txt.SetXY(150, 400);

  for (size_t i = 0; i < m_sounds.size(); ++i) {
    const std::string path = GetOptionalSoundPath(TEST_SOUND_PATHS[i]);
    if (path.empty() || !m_sounds[i].s.Load(path)) {
      if (LOG == nullptr) {
        continue;
      }
      LOG->Warn(
          "ScreenTestSound: failed to load optional test sound %s/%s path='%s'",
          TEST_SOUND_PATHS[i].group,
          TEST_SOUND_PATHS[i].element,
          path.c_str());
    }
  }

  // s[0].s.SetStartSeconds(45);
  // s[0].s.SetPositionSeconds();
  //  s[4].s.SetLengthSeconds(1);
  RageSoundParams p;
  p.StopMode = RageSoundParams::M_STOP;
  // p.m_fRate = 1.20f;
  for (auto& sound : m_sounds) {
    sound.s.SetParams(p);
  }

  // s[0].s.SetStopMode(RageSound::M_LOOP);
  // s[0].s.Play(false);

  m_selected = 0;
  for (size_t i = 0; i < m_sounds.size(); ++i) {
    UpdateText(i);
  }
}

ScreenTestSound::~ScreenTestSound() = default;

bool ScreenTestSound::IsValidSoundIndex(int n) const {
  return n >= 0 && n < static_cast<int>(m_sounds.size());
}

void ScreenTestSound::UpdateText(size_t n) {
  if (n >= m_sounds.size() || !m_textReady[n]) {
    return;
  }

  std::string fn = Basename(m_sounds[n].s.GetLoadedFilePath());
  if (fn.empty()) {
    fn = "(not loaded)";
  }

  auto& snds = m_soundCopies[n];

  std::string pos;
  for (size_t p = 0; p < snds.size(); ++p) {
    if (snds[p] == nullptr) {
      continue;
    }
    if (p) {
      pos += ", ";
    }
    pos += ssprintf("%.3f", snds[p]->GetPositionSeconds());
  }

  m_sounds[n].txt.SetText(ssprintf(
      "%i: %s\n"
      "%s\n"
      "%s\n"
      "(%s)\n"
      "%s",
      static_cast<int>(n + 1), fn.c_str(),
      m_sounds[n].s.IsPlaying() ? "Playing" : "Stopped",
      m_sounds[n].s.GetParams().StopMode == RageSoundParams::M_STOP
          ? "Stop when finished"
      : m_sounds[n].s.GetParams().StopMode == RageSoundParams::M_CONTINUE
          ? "Continue until stopped"
          : "Loop",
      pos.size() ? pos.c_str() : "none playing",
      m_selected == static_cast<int>(n) ? "^^^^^^" : ""));
}

void ScreenTestSound::Update(float f) {
  Screen::Update(f);

  for (size_t i = 0; i < m_sounds.size(); ++i) {
    UpdateText(i);

    /* Delete copied sounds that have finished playing. */
    auto& snds = m_soundCopies[i];
    for (auto it = snds.begin(); it != snds.end();) {
      if (*it != nullptr && (*it)->IsPlaying()) {
        ++it;
      } else {
        it = snds.erase(it);
      }
    }
  }
}

bool ScreenTestSound::Input(const InputEventPlus& input) {
  if (Screen::Input(input)) {
    return true;
  }

  if (input.type != IET_FIRST_PRESS) {
    return false;  // ignore
  }

  bool handled = false;
  switch (input.DeviceI.device) {
    case DEVICE_KEYBOARD:
      switch (input.DeviceI.button) {
        case '1':
        case '2':
        case '3':
        case '4':
        case '5':
          m_selected = input.DeviceI.button - '0' - 1;
          handled = true;
          break;
        case 'p': {
          if (!IsValidSoundIndex(m_selected)) {
            return false;
          }
          if (!m_sounds[m_selected].s.LoadSucceeded()) {
            if (LOG != nullptr) {
              LOG->Warn(
                  "ScreenTestSound: ignored play for unloaded sound index %d",
                  m_selected);
            }
            return true;
          }
          auto& copies = m_soundCopies[m_selected];
          copies.erase(
              std::remove_if(
                  copies.begin(), copies.end(),
                  [](const std::unique_ptr<RageSound>& sound) {
                    return sound == nullptr || !sound->IsPlaying();
                  }),
              copies.end());
          if (copies.size() >= MAX_SIMULTANEOUS_COPIES) {
            if (LOG != nullptr) {
              LOG->Warn(
                  "ScreenTestSound: simultaneous copy limit reached for "
                  "sound index %d",
                  m_selected);
            }
            return true;
          }
          /* We want to be able to read the position of copied sounds; if we let
           * RageSound copy itself, then the copy will be owned by
           * RageSoundManager and we won't be allowed to touch it.  Copy it
           * ourself. */
          auto copy = std::make_unique<RageSound>(m_sounds[m_selected].s);
          copy->Play(false);
          copies.push_back(std::move(copy));
          handled = true;
          break;
        }
        case 's': {
          for (auto& snds : m_soundCopies) {
            /* Stop copied sounds. */
            for (auto& snd : snds) {
              if (snd != nullptr) {
                snd->Stop();
              }
            }
          }
          handled = true;
          break;
        }
        case 'l': {
          if (!IsValidSoundIndex(m_selected)) {
            return false;
          }
          RageSoundParams p = m_sounds[m_selected].s.GetParams();
          p.StopMode = RageSoundParams::M_LOOP;
          m_sounds[m_selected].s.SetParams(p);
          handled = true;
          break;
        }
        case 'a': {
          if (!IsValidSoundIndex(m_selected)) {
            return false;
          }
          RageSoundParams p = m_sounds[m_selected].s.GetParams();
          p.StopMode = RageSoundParams::M_STOP;
          m_sounds[m_selected].s.SetParams(p);
          handled = true;
          break;
        }
        case 'c': {
          if (!IsValidSoundIndex(m_selected)) {
            return false;
          }
          RageSoundParams p = m_sounds[m_selected].s.GetParams();
          p.StopMode = RageSoundParams::M_CONTINUE;
          m_sounds[m_selected].s.SetParams(p);
          handled = true;
          break;
        }
          /*			case KEY_LEFT:
                                          obj.SetX(obj.GetX() - 10);
                                          break;
                                  case KEY_RIGHT:
                                          obj.SetX(obj.GetX() + 10);
                                          break;
                                  case KEY_UP:
                                          obj.SetY(obj.GetY() - 10);
                                          break;
                                  case KEY_DOWN:
                                          obj.SetY(obj.GetY() + 10);
                                          break;
          */
        default:
          break;
      }
      break;
    default:
      break;
  }

  return handled;
}

bool ScreenTestSound::MenuBack(const InputEventPlus& input) {
  if (input.type != IET_FIRST_PRESS || SCREENMAN == nullptr) {
    return false;
  }
  if (HasLoadedTheme() && THEME->HasMetric(m_sName, "PrevScreen") &&
      !GetPrevScreen().empty()) {
    SCREENMAN->PlayStartSound();
    PostScreenMessage(SM_GoToPrevScreen, 0);
    return true;
  }
  if (SCREENMAN->IsStackedScreen(this)) {
    SCREENMAN->PlayStartSound();
    SCREENMAN->PopTopScreen(SM_None);
    return true;
  }
  return false;
}

/*
 * (c) 2003 Glenn Maynard
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
