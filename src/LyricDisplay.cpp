#include "LyricDisplay.h"

#include <algorithm>
#include <cmath>

#include "ActorFrame.h"
#include "ActorUtil.h"
#include "GameState.h"
#include "LuaManager.h"
#include "LuaReference.h"
#include "RageLog.h"
#include "Song.h"
#include "ThemeManager.h"
#include "ThemeMetric.h"

static ThemeMetric<float> IN_LENGTH("LyricDisplay", "InLength");
static ThemeMetric<float> OUT_LENGTH("LyricDisplay", "OutLength");

namespace {
const float MAX_LYRIC_TWEEN_LENGTH_SECONDS = 60.0f;
const float MAX_LYRIC_SHOW_LENGTH_SECONDS = 600.0f;
const float FALLBACK_MUSIC_RATE = 1.0f;
const size_t MAX_LYRIC_TEXT_CHARS = 4096;

void WarnLyricDisplay(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

float SanitizeLyricTweenLength(float value) {
  if (!std::isfinite(value) || value < 0.0f) {
    return 0.0f;
  }
  return std::min(value, MAX_LYRIC_TWEEN_LENGTH_SECONDS);
}

float SanitizeLyricShowLength(float value) {
  if (!std::isfinite(value) || value < 0.0f) {
    return 0.0f;
  }
  return std::min(value, MAX_LYRIC_SHOW_LENGTH_SECONDS);
}

float SanitizeMusicRate(float value) {
  if (!std::isfinite(value) || value <= 0.0f) {
    return FALLBACK_MUSIC_RATE;
  }
  return value;
}

std::string SanitizeLyricText(const std::string& lyric) {
  if (lyric.size() <= MAX_LYRIC_TEXT_CHARS) {
    return lyric;
  }
  return lyric.substr(0, MAX_LYRIC_TEXT_CHARS);
}
}  // namespace

LyricDisplay::LyricDisplay() {
  LoadLyricActor(m_textLyrics[0], "LyricBack");
  LoadLyricActor(m_textLyrics[1], "LyricFront");
  AttachLyricActors();
  Init();
}

LyricDisplay::LyricDisplay(const LyricDisplay& cpy) : ActorFrame(cpy) {
  m_textLyrics[0] = cpy.m_textLyrics[0];
  m_textLyrics[1] = cpy.m_textLyrics[1];
  m_iCurLyricNumber = cpy.m_iCurLyricNumber;
  m_fLastSecond = cpy.m_fLastSecond;
  m_bStopped = cpy.m_bStopped;
  AttachLyricActors();
}

LyricDisplay* LyricDisplay::Copy() const { return new LyricDisplay(*this); }

void LyricDisplay::AttachLyricActors() {
  RemoveAllChildren();
  this->AddChild(&m_textLyrics[0]);
  this->AddChild(&m_textLyrics[1]);
}

void LyricDisplay::LoadLyricActor(BitmapText& text, const std::string& name) {
  text.SetName(name);
  if (THEME == nullptr) {
    WarnLyricDisplay(
        "LyricDisplay loaded without theme manager.");
    return;
  }

  ActorUtil::LoadAllCommands(text, "LyricDisplay");
  if (!text.LoadFromFont(THEME->GetPathF("LyricDisplay", "text"))) {
    WarnLyricDisplay(
        "LyricDisplay failed to load lyric font.");
  }
}

void LyricDisplay::Init() {
  for (int i = 0; i < 2; i++) {
    m_textLyrics[i].SetText("");
  }
  m_iCurLyricNumber = 0;

  m_fLastSecond = -500;
  m_bStopped = false;
}

void LyricDisplay::Stop() { m_bStopped = true; }

void LyricDisplay::Update(float fDeltaTime) {
  if (m_bStopped) {
    return;
  }

  ActorFrame::Update(fDeltaTime);

  if (GAMESTATE == nullptr || GAMESTATE->m_pCurSong == nullptr) {
    return;
  }

  const float fMusicSeconds = GAMESTATE->m_Position.m_fMusicSeconds;
  if (!std::isfinite(fMusicSeconds)) {
    WarnLyricDisplay(
        "LyricDisplay ignored non-finite music time.");
    return;
  }

  // If the song has changed (in a course), reset.
  if (fMusicSeconds < m_fLastSecond) {
    Init();
  }
  m_fLastSecond = fMusicSeconds;

  const Song* pSong = GAMESTATE->m_pCurSong;
  if (m_iCurLyricNumber >= pSong->m_LyricSegments.size()) {
    return;
  }

  const LyricSegment& seg = pSong->m_LyricSegments[m_iCurLyricNumber];
  const float fLyricStartTime = seg.m_fStartTime;
  if (!std::isfinite(fLyricStartTime)) {
    WarnLyricDisplay(
        "LyricDisplay skipped non-finite lyric "
        "segment.");
    m_iCurLyricNumber++;
    return;
  }

  const float fInLength = SanitizeLyricTweenLength(IN_LENGTH.GetValue());
  const float fOutLength = SanitizeLyricTweenLength(OUT_LENGTH.GetValue());
  const float fStartTime = fLyricStartTime - fInLength;

  if (fMusicSeconds < fStartTime) {
    return;
  }

  // Clamp this lyric to the beginning of the next or the end of the music.
  float fEndTime;
  if (m_iCurLyricNumber + 1 < pSong->m_LyricSegments.size()) {
    fEndTime = pSong->m_LyricSegments[m_iCurLyricNumber + 1].m_fStartTime;
  } else {
    fEndTime = pSong->GetLastSecond();
  }
  if (!std::isfinite(fEndTime)) {
    fEndTime = fLyricStartTime;
  }

  const float fDistance = std::max(fEndTime - fLyricStartTime, 0.0f);
  const float fTweenBufferTime = fInLength + fOutLength;

  /* If it's negative, two lyrics are so close together that there's no time
   * to tween properly. Lyrics should never be this brief, anyway, so just
   * skip it. */
  float fShowLength = SanitizeLyricShowLength(fDistance - fTweenBufferTime);

  // Make lyrics show faster for faster song rates.
  fShowLength = SanitizeLyricShowLength(
      fShowLength /
      SanitizeMusicRate(GAMESTATE->m_SongOptions.GetCurrent().m_fMusicRate));

  if (LUA == nullptr) {
    WarnLyricDisplay(
        "LyricDisplay skipped lyric without Lua "
        "manager.");
    m_iCurLyricNumber++;
    return;
  }

  LuaThreadVariable var1("LyricText", SanitizeLyricText(seg.m_sLyric));
  LuaThreadVariable var2("LyricDuration", LuaReference::Create(fShowLength));
  LuaThreadVariable var3("LyricColor", LuaReference::Create(seg.m_Color));

  PlayCommand("Changed");

  m_iCurLyricNumber++;
}

/*
 * (c) 2003-2004 Kevin Slaughter, Glenn Maynard
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
