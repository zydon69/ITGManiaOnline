#include "Foreground.h"

#include <algorithm>
#include <cmath>
#include <string>

#include "Actor.h"
#include "ActorFrame.h"
#include "ActorUtil.h"
#include "BackgroundUtil.h"
#include "GameState.h"
#include "MessageManager.h"
#include "PrefsManager.h"
#include "RageLog.h"
#include "RageTextureID.h"
#include "RageTextureManager.h"
#include "RageUtil.h"
#include "Song.h"

namespace {
class ForegroundTexturePolicyGuard {
 public:
  ForegroundTexturePolicyGuard()
      : m_active(TEXTUREMAN != nullptr),
        m_oldPolicy(m_active ? TEXTUREMAN->GetDefaultTexturePolicy()
                             : RageTextureID::TEX_DEFAULT) {
    if (m_active) {
      TEXTUREMAN->SetDefaultTexturePolicy(RageTextureID::TEX_VOLATILE);
    }
  }

  ~ForegroundTexturePolicyGuard() {
    if (m_active && TEXTUREMAN != nullptr) {
      TEXTUREMAN->SetDefaultTexturePolicy(m_oldPolicy);
    }
  }

 private:
  bool m_active;
  RageTextureID::TexPolicy m_oldPolicy;
};

float SafeForegroundRate() {
  if (GAMESTATE == nullptr) {
    return 1.0f;
  }

  const float rate =
      PREFSMAN != nullptr && PREFSMAN->m_bRateModsAffectTweens
          ? 1.0f
          : GAMESTATE->m_SongOptions.GetCurrent().m_fMusicRate;

  if (!std::isfinite(rate) || rate <= 0.0f) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-719: Foreground used fallback rate because music "
        "rate %.6f is invalid.",
        rate);
    return 1.0f;
  }

  return rate;
}
}  // namespace

Foreground::Foreground() : m_fLastMusicSeconds(-9999), m_pSong(nullptr) {}

Foreground::~Foreground() { Unload(); }

void Foreground::Unload() {
  RemoveAllChildren();
  for (unsigned i = 0; i < m_BGAnimations.size(); ++i) {
    delete m_BGAnimations[i].m_bga;
  }
  m_BGAnimations.clear();
  m_fLastMusicSeconds = -9999;
  m_pSong = nullptr;
}

void Foreground::LoadFromSong(const Song* pSong) {
  Unload();
  if (pSong == nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-715: Foreground ignored LoadFromSong(nullptr).");
    return;
  }

  // Song graphics can get very big; never keep them in memory.
  ForegroundTexturePolicyGuard texturePolicyGuard;

  m_pSong = pSong;
  for (const BackgroundChange& change : pSong->GetForegroundChanges()) {
    if (!std::isfinite(change.m_fStartBeat)) {
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-3106: Foreground skipped a change with "
          "non-finite start beat.");
      continue;
    }
    const std::string sBGName = change.m_def.m_sFile1;
    const std::string sForegroundPath =
        Song::GetSongAssetPath(sBGName, pSong->GetSongDir());
    if (sForegroundPath.empty()) {
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-717: Foreground rejected empty or unsafe asset "
          "'%s'.",
          sBGName.c_str());
      continue;
    }
    const std::string sLuaFile = sForegroundPath + "/default.lua";
    const std::string sXmlFile = sForegroundPath + "/default.xml";

    LoadedBGA bga;
    if (DoesFileExist(sLuaFile)) {
      bga.m_bga = ActorUtil::MakeActor(sLuaFile, this);
    } else if (PREFSMAN != nullptr && PREFSMAN->m_bQuirksMode &&
               DoesFileExist(sXmlFile)) {
      bga.m_bga = ActorUtil::MakeActor(sXmlFile, this);
    } else {
      bga.m_bga = ActorUtil::MakeActor(sForegroundPath, this);
    }
    if (bga.m_bga == nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-718: Foreground failed to create actor for '%s'.",
          sForegroundPath.c_str());
      continue;
    }
    bga.m_bga->SetName(sBGName);
    // ActorUtil::MakeActor calls LoadFromNode to load the actor, and
    // LoadFromNode takes care of running the InitCommand, so do not run the
    // InitCommand here. -Kyz
    bga.m_fStartBeat = change.m_fStartBeat;
    bga.m_fStopBeat = change.m_fStartBeat;
    bga.m_bFinished = false;

    bga.m_bga->SetVisible(false);

    this->AddChild(bga.m_bga);
    m_BGAnimations.push_back(bga);
  }

  this->SortByDrawOrder();
}

void Foreground::Update(float fDeltaTime) {
  if (m_pSong == nullptr || GAMESTATE == nullptr || !std::isfinite(fDeltaTime)) {
    return;
  }

  // Calls to Update() should *not* be scaled by music rate unless
  // RateModsAffectFGChanges is enabled. Undo it.
  const float fRate = SafeForegroundRate();

  for (unsigned i = 0; i < m_BGAnimations.size(); ++i) {
    LoadedBGA& bga = m_BGAnimations[i];
    if (bga.m_bga == nullptr) {
      continue;
    }

    if (GAMESTATE->m_Position.m_fSongBeat < bga.m_fStartBeat) {
      // The animation hasn't started yet.
      continue;
    }

    if (bga.m_bFinished) {
      continue;
    }

    /* Update the actor even if we're about to hide it, so queued commands
     * are always run. */
    float lDeltaTime;
    if (!bga.m_bga->GetVisible()) {
      bga.m_bga->SetVisible(true);
      bga.m_bga->PlayCommand("On");

      const float fStartSecond =
          m_pSong->m_SongTiming.GetElapsedTimeFromBeat(bga.m_fStartBeat);
      const float tweenTime = bga.m_bga->GetTweenTimeLeft();
      if (!std::isfinite(fStartSecond) || !std::isfinite(tweenTime) ||
          tweenTime < 0.0f) {
        LOG->Warn(
            "SRC_AUDIT_FIX SRC-3106: Foreground disabled '%s' because its "
            "timing is invalid.",
            bga.m_bga->GetName().c_str());
        bga.m_bga->SetVisible(false);
        bga.m_bFinished = true;
        continue;
      }
      const float fStopSecond = fStartSecond + tweenTime;
      bga.m_fStopBeat =
          m_pSong->m_SongTiming.GetBeatFromElapsedTime(fStopSecond);
      if (!std::isfinite(bga.m_fStopBeat)) {
        LOG->Warn(
            "SRC_AUDIT_FIX SRC-3106: Foreground disabled '%s' because its "
            "stop beat is invalid.",
            bga.m_bga->GetName().c_str());
        bga.m_bga->SetVisible(false);
        bga.m_bFinished = true;
        continue;
      }

      lDeltaTime = GAMESTATE->m_Position.m_fMusicSeconds - fStartSecond;
    } else {
      lDeltaTime = GAMESTATE->m_Position.m_fMusicSeconds - m_fLastMusicSeconds;
    }

    // This shouldn't go down, but be safe:
    lDeltaTime = std::max(lDeltaTime, 0.0f);
    if (!std::isfinite(lDeltaTime)) {
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-719: Foreground clamped non-finite delta time.");
      lDeltaTime = 0.0f;
    }

    bga.m_bga->Update(lDeltaTime / fRate);

    if (GAMESTATE->m_Position.m_fSongBeat > bga.m_fStopBeat) {
      // Finished.
      bga.m_bga->SetVisible(false);
      bga.m_bFinished = true;
      continue;
    }
  }

  m_fLastMusicSeconds = GAMESTATE->m_Position.m_fMusicSeconds;
}

void Foreground::HandleMessage(const Message& msg) {
  // We want foregrounds to behave as if their On command happens at the
  // starting beat, not when the Foreground object receives an On command.
  // So don't propagate that; we'll call it ourselves.
  if (msg.GetName() == "On") {
    Actor::HandleMessage(msg);
  } else {
    ActorFrame::HandleMessage(msg);
  }
}

/*
 * (c) 2004 Glenn Maynard
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
