#include "FadingBanner.h"

#include <cmath>
#include <string>

#include "Actor.h"
#include "ActorFrame.h"
#include "ActorUtil.h"
#include "Banner.h"
#include "Course.h"
#include "EnumHelper.h"
#include "GameConstantsAndTypes.h"
#include "ImageCache.h"
#include "LuaManager.h"
#include "PerfDiagnostics.h"
#include "PrefsManager.h"
#include "RageLog.h"
#include "RageTexture.h"
#include "RageTextureID.h"
#include "RageTextureManager.h"
#include "RageUtil.h"
#include "Song.h"
#include "SongManager.h"
#include "Sprite.h"
#include "ThemeManager.h"

REGISTER_ACTOR_CLASS(FadingBanner);

namespace {
bool IsFiniteFloat(float value) {
  return std::isfinite(value);
}

void WarnFadingBannerAuditFix(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

void WarnFadingBannerAuditFix(const std::string& message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message.c_str());
  }
}

void TraceFadingBannerAuditFix(const std::string& message) {
  if (LOG != nullptr && LogMusicWheelDiagnosticsEnabled()) {
    LOG->Trace("%s", message.c_str());
  }
}

std::string GetFadingBannerThemePath(
    const std::string& category, const std::string& name) {
  if (THEME == nullptr) {
    WarnFadingBannerAuditFix(ssprintf(
        "SRC_AUDIT_FIX SRC-1048: FadingBanner cannot resolve theme path %s/%s "
        "without THEME.",
        category.c_str(), name.c_str()));
    return std::string();
  }
  return THEME->GetPathG(category, name);
}
}  // namespace

/* Allow fading from one banner to another. We can handle two fades at once;
 * this is used to fade from an old banner to a low-quality banner to a high-
 * quality banner smoothly.
 *
 * m_iIndexLatest is the latest banner loaded, and the one that we'll end up
 * displaying when the fades stop. */
FadingBanner::FadingBanner() {
  m_bMovingFast = false;
  m_bSkipNextBannerUpdate = false;
  m_iIndexLatest = 0;
  for (int i = 0; i < NUM_BANNERS; i++) {
    m_Banner[i].SetName("Banner");
    ActorUtil::LoadAllCommandsAndOnCommand(m_Banner[i], "FadingBanner");
    this->AddChild(&m_Banner[i]);
  }
}

void FadingBanner::ScaleToClipped(float fWidth, float fHeight) {
  const bool validWidth = fWidth == -1.0f || fWidth > 0.0f;
  const bool validHeight = fHeight == -1.0f || fHeight > 0.0f;
  if (!IsFiniteFloat(fWidth) || !IsFiniteFloat(fHeight) || !validWidth ||
      !validHeight) {
    WarnFadingBannerAuditFix(ssprintf(
        "SRC_AUDIT_FIX SRC-1047: FadingBanner ignored invalid clip size "
        "%.6fx%.6f.",
        fWidth, fHeight));
    return;
  }
  for (int i = 0; i < NUM_BANNERS; i++) {
    m_Banner[i].ScaleToClipped(fWidth, fHeight);
  }
}

void FadingBanner::UpdateInternal(float fDeltaTime) {
  if (!IsFiniteFloat(fDeltaTime)) {
    WarnFadingBannerAuditFix(
        "SRC_AUDIT_FIX SRC-1047: FadingBanner ignored non-finite delta.");
    return;
  }
  // update children manually
  // ActorFrame::UpdateInternal( fDeltaTime );
  Actor::UpdateInternal(fDeltaTime);

  if (!m_bSkipNextBannerUpdate) {
    for (int i = 0; i < NUM_BANNERS; ++i) {
      m_Banner[i].Update(fDeltaTime);
    }
  }

  m_bSkipNextBannerUpdate = false;
}

void FadingBanner::DrawPrimitives() {
  // draw manually
  //	ActorFrame::DrawPrimitives();

  // Render the latest banner first.
  for (int i = 0; i < NUM_BANNERS; ++i) {
    int index = m_iIndexLatest - i;
    wrap(index, NUM_BANNERS);
    m_Banner[index].Draw();
  }
}

void FadingBanner::Load(RageTextureID ID, bool bLowResToHighRes) {
  TraceFadingBannerAuditFix(ssprintf(
      "SRC_AUDIT_FIX SRC-2693 MusicWheelTrace fading_banner_load "
      "path='%s' lowResToHighRes=%d latestIndex=%d movingFast=%d "
      "skipNextUpdate=%d",
      ID.filename.c_str(), bLowResToHighRes, m_iIndexLatest, m_bMovingFast,
      m_bSkipNextBannerUpdate));
  BeforeChange(bLowResToHighRes);
  m_Banner[m_iIndexLatest].Load(ID);

  /* XXX: Hack to keep movies from updating multiple times.
   * We need to either completely disallow movies in banners or support
   * them. There are a number of files that use them currently in the
   * wild. If we wanted to support them, then perhaps we should use an
   * all-black texture for the low quality texture. */
  RageTexture* pTexture = m_Banner[m_iIndexLatest].GetTexture();
  if (!pTexture || !pTexture->IsAMovie()) {
    return;
  }
  m_Banner[m_iIndexLatest].SetSecondsIntoAnimation(0.f);
  for (int i = 1; i < NUM_BANNERS; ++i) {
    int index = m_iIndexLatest - i;
    wrap(index, NUM_BANNERS);
    if (m_Banner[index].GetTexturePath() == ID.filename) {
      m_Banner[index].UnloadTexture();
    }
  }
}

/* If bLowResToHighRes is true, we're fading from a low-res banner to the
 * corresponding high-res banner. */
void FadingBanner::BeforeChange(bool bLowResToHighRes) {
  std::string sCommand;
  if (bLowResToHighRes) {
    sCommand = "FadeFromCached";
  } else {
    sCommand = "FadeOff";
  }

  TraceFadingBannerAuditFix(ssprintf(
      "SRC_AUDIT_FIX SRC-2693 MusicWheelTrace fading_banner_before_change "
      "command='%s' latestIndexBefore=%d movingFast=%d skipNextUpdate=%d",
      sCommand.c_str(), m_iIndexLatest, m_bMovingFast,
      m_bSkipNextBannerUpdate));

  m_Banner[m_iIndexLatest].PlayCommand(sCommand);
  ++m_iIndexLatest;
  wrap(m_iIndexLatest, NUM_BANNERS);

  m_Banner[m_iIndexLatest].PlayCommand("ResetFade");

  /* We're about to load a banner. It'll probably cause a frame skip or two.
   * Skip an update, so the fade-in doesn't skip. */
  m_bSkipNextBannerUpdate = true;
}

/* If this returns true, a low-resolution banner was loaded, and the full-res
 * banner should be loaded later. */
bool FadingBanner::LoadFromCachedBanner(const std::string& path) {
  // If we're already on the given banner, don't fade again.
  if (path != "" && m_Banner[m_iIndexLatest].GetTexturePath() == path) {
    TraceFadingBannerAuditFix(ssprintf(
        "SRC_AUDIT_FIX SRC-2693 MusicWheelTrace "
        "fading_banner_cached_noop path='%s' latestIndex=%d texture='%s'",
        path.c_str(), m_iIndexLatest,
        m_Banner[m_iIndexLatest].GetTexturePath().c_str()));
    return false;
  }

  if (path == "") {
    TraceFadingBannerAuditFix(
        "SRC_AUDIT_FIX SRC-2693 MusicWheelTrace "
        "fading_banner_cached_empty_path fallback=1");
    LoadFallback();
    return false;
  }

  /* If we're currently fading to the given banner, go through this again,
   * which will cause the fade-in to be further delayed. */

  RageTextureID ID;
  const bool bIsMovie = ActorUtil::GetFileType(path) == FT_Movie;
  const bool bLowRes =
      !bIsMovie && PREFSMAN != nullptr && IMAGECACHE != nullptr &&
      (PREFSMAN->m_ImageCache != IMGCACHE_FULL);
  TraceFadingBannerAuditFix(ssprintf(
      "SRC_AUDIT_FIX SRC-2693 MusicWheelTrace fading_banner_cached_begin "
      "path='%s' isMovie=%d lowRes=%d movingFast=%d latestIndex=%d "
      "textureManager=%d imageCache=%d",
      path.c_str(), bIsMovie, bLowRes, m_bMovingFast, m_iIndexLatest,
      TEXTUREMAN != nullptr, IMAGECACHE != nullptr));
  if (!bLowRes) {
    ID = Sprite::SongBannerTexture(path);
  } else {
    // Try to load the low quality version.
    ID = IMAGECACHE->LoadCachedImage("Banner", path);
  }

  if (TEXTUREMAN == nullptr || !TEXTUREMAN->IsTextureRegistered(ID)) {
    /* Oops. We couldn't load a banner quickly. We can load the actual
     * banner, but that's slow, so we don't want to do that when we're moving
     * fast on the music wheel. In that case, we should just keep the banner
     * that's there (or load a "moving fast" banner). Once we settle down,
     * we'll get called again and load the real banner. */

    if (m_bMovingFast) {
      TraceFadingBannerAuditFix(ssprintf(
          "SRC_AUDIT_FIX SRC-727: FadingBanner deferred uncached banner '%s' "
          "while moving fast.",
          path.c_str()));
      TraceFadingBannerAuditFix(ssprintf(
          "SRC_AUDIT_FIX SRC-2693 MusicWheelTrace "
          "fading_banner_cached_deferred path='%s' resolved='%s' "
          "movingFast=%d textureManager=%d",
          path.c_str(), ID.filename.c_str(), m_bMovingFast,
          TEXTUREMAN != nullptr));
      return false;
    }

    if (IsAFile(path)) {
      TraceFadingBannerAuditFix(ssprintf(
          "SRC_AUDIT_FIX SRC-2693 MusicWheelTrace "
          "fading_banner_cached_load_file path='%s' resolved='%s'",
          path.c_str(), ID.filename.c_str()));
      Load(path);
    } else {
      TraceFadingBannerAuditFix(ssprintf(
          "SRC_AUDIT_FIX SRC-2693 MusicWheelTrace "
          "fading_banner_cached_missing_file path='%s' resolved='%s'",
          path.c_str(), ID.filename.c_str()));
      LoadFallback();
    }

    return false;
  }

  TraceFadingBannerAuditFix(ssprintf(
      "SRC_AUDIT_FIX SRC-2693 MusicWheelTrace "
      "fading_banner_cached_registered path='%s' resolved='%s' lowRes=%d",
      path.c_str(), ID.filename.c_str(), bLowRes));
  Load(ID);

  return bLowRes;
}

void FadingBanner::LoadFromSong(const Song* pSong) {
  if (pSong == nullptr) {
    TraceFadingBannerAuditFix(
        "SRC_AUDIT_FIX SRC-2693 MusicWheelTrace "
        "fading_banner_song song=<null> fallback=1");
    LoadFallback();
    return;
  }

  /* Don't call HasBanner. That'll do disk access and cause the music wheel
   * to skip. */
  std::string sPath = pSong->GetBannerPath();
  TraceFadingBannerAuditFix(ssprintf(
      "SRC_AUDIT_FIX SRC-2693 MusicWheelTrace fading_banner_song "
      "songPtr=%p title='%s' dir='%s' banner='%s' movingFast=%d",
      static_cast<const void*>(pSong), pSong->GetDisplayFullTitle().c_str(),
      pSong->GetSongDir().c_str(), sPath.c_str(), m_bMovingFast));
  if (sPath.empty()) {
    LoadFallback();
  } else {
    LoadFromCachedBanner(sPath);
  }
}

void FadingBanner::LoadMode() {
  TraceFadingBannerAuditFix(
      "SRC_AUDIT_FIX SRC-2693 MusicWheelTrace fading_banner_mode");
  BeforeChange();
  m_Banner[m_iIndexLatest].LoadMode();
}

void FadingBanner::LoadFromSongGroup(std::string sSongGroup) {
  if (SONGMAN == nullptr) {
    WarnFadingBannerAuditFix(ssprintf(
        "SRC_AUDIT_FIX SRC-728: FadingBanner cannot load group '%s' without "
        "SONGMAN.",
        sSongGroup.c_str()));
    LoadFallback();
    return;
  }

  const std::string sGroupBannerPath =
      SONGMAN->GetSongGroupBannerPath(sSongGroup);
  TraceFadingBannerAuditFix(ssprintf(
      "SRC_AUDIT_FIX SRC-2693 MusicWheelTrace fading_banner_group "
      "group='%s' banner='%s'",
      sSongGroup.c_str(), sGroupBannerPath.c_str()));
  LoadFromCachedBanner(sGroupBannerPath);
}

void FadingBanner::LoadFromCourse(const Course* pCourse) {
  if (pCourse == nullptr) {
    LoadFallback();
    return;
  }

  /* Don't call HasBanner. That'll do disk access and cause the music wheel
   * to skip. */
  std::string sPath = pCourse->GetBannerPath();
  if (sPath.empty()) {
    LoadCourseFallback();
  } else {
    LoadFromCachedBanner(sPath);
  }
}

void FadingBanner::LoadIconFromCharacter(Character* pCharacter) {
  BeforeChange();
  m_Banner[m_iIndexLatest].LoadIconFromCharacter(pCharacter);
}

void FadingBanner::LoadCardFromCharacter(Character* pCharacter) {
  BeforeChange();
  m_Banner[m_iIndexLatest].LoadCardFromCharacter(pCharacter);
}

void FadingBanner::LoadBannerFromUnlockEntry(const UnlockEntry* pUE) {
  BeforeChange();
  m_Banner[m_iIndexLatest].LoadBannerFromUnlockEntry(pUE);
}

void FadingBanner::LoadRoulette() {
  BeforeChange();
  m_Banner[m_iIndexLatest].LoadRoulette();
  m_Banner[m_iIndexLatest].PlayCommand("Roulette");
}

void FadingBanner::LoadRandom() {
  BeforeChange();
  m_Banner[m_iIndexLatest].LoadRandom();
  m_Banner[m_iIndexLatest].PlayCommand("Random");
}

void FadingBanner::LoadFromSortOrder(SortOrder so) {
  BeforeChange();
  m_Banner[m_iIndexLatest].LoadFromSortOrder(so);
}

void FadingBanner::LoadFallback() {
  BeforeChange();
  m_Banner[m_iIndexLatest].LoadFallback();
}

void FadingBanner::LoadCourseFallback() {
  BeforeChange();
  m_Banner[m_iIndexLatest].LoadCourseFallback();
}

void FadingBanner::LoadCustom(std::string sBanner) {
  if (sBanner.empty()) {
    WarnFadingBannerAuditFix(ssprintf(
        "SRC_AUDIT_FIX SRC-728: FadingBanner refused custom banner '%s'.",
        sBanner.c_str()));
    LoadFallback();
    return;
  }

  const std::string path = GetFadingBannerThemePath("Banner", sBanner);
  if (path.empty()) {
    WarnFadingBannerAuditFix(ssprintf(
        "SRC_AUDIT_FIX SRC-3111: FadingBanner could not resolve custom banner "
        "'%s'.",
        sBanner.c_str()));
    LoadFallback();
    return;
  }

  BeforeChange();
  Banner& banner = m_Banner[m_iIndexLatest];
  banner.Load(path);
  if (banner.HasCommand(sBanner)) {
    banner.PlayCommand(sBanner);
  } else {
    TraceFadingBannerAuditFix(ssprintf(
        "SRC_AUDIT_FIX SRC-3111: FadingBanner custom command '%s' is absent.",
        sBanner.c_str()));
  }
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the FadingBanner. */
class LunaFadingBanner : public Luna<FadingBanner> {
 public:
  static int scaletoclipped(T* p, lua_State* L) {
    p->ScaleToClipped(FArg(1), FArg(2));
    COMMON_RETURN_SELF;
  }
  static int ScaleToClipped(T* p, lua_State* L) {
    p->ScaleToClipped(FArg(1), FArg(2));
    COMMON_RETURN_SELF;
  }
  static int LoadFromSong(T* p, lua_State* L) {
    if (lua_isnil(L, 1)) {
      p->LoadFromSong(nullptr);
    } else {
      Song* pS = Luna<Song>::check(L, 1);
      p->LoadFromSong(pS);
    }
    COMMON_RETURN_SELF;
  }
  static int LoadFromCourse(T* p, lua_State* L) {
    if (lua_isnil(L, 1)) {
      p->LoadFromCourse(nullptr);
    } else {
      Course* pC = Luna<Course>::check(L, 1);
      p->LoadFromCourse(pC);
    }
    COMMON_RETURN_SELF;
  }
  static int LoadIconFromCharacter(T* p, lua_State* L) {
    if (lua_isnil(L, 1)) {
      p->LoadIconFromCharacter(nullptr);
    } else {
      Character* pC = Luna<Character>::check(L, 1);
      p->LoadIconFromCharacter(pC);
    }
    COMMON_RETURN_SELF;
  }
  static int LoadCardFromCharacter(T* p, lua_State* L) {
    if (lua_isnil(L, 1)) {
      p->LoadCardFromCharacter(nullptr);
    } else {
      Character* pC = Luna<Character>::check(L, 1);
      p->LoadCardFromCharacter(pC);
    }
    COMMON_RETURN_SELF;
  }
  static int LoadFromSongGroup(T* p, lua_State* L) {
    p->LoadFromSongGroup(SArg(1));
    COMMON_RETURN_SELF;
  }
  static int LoadRandom(T* p, lua_State* L) {
    p->LoadRandom();
    COMMON_RETURN_SELF;
  }
  static int LoadRoulette(T* p, lua_State* L) {
    p->LoadRoulette();
    COMMON_RETURN_SELF;
  }
  static int LoadCourseFallback(T* p, lua_State* L) {
    p->LoadCourseFallback();
    COMMON_RETURN_SELF;
  }
  static int LoadFallback(T* p, lua_State* L) {
    p->LoadFallback();
    COMMON_RETURN_SELF;
  }
  static int LoadFromSortOrder(T* p, lua_State* L) {
    if (lua_isnil(L, 1)) {
      p->LoadFromSortOrder(SortOrder_Invalid);
    } else {
      SortOrder so = Enum::Check<SortOrder>(L, 1);
      p->LoadFromSortOrder(so);
    }
    COMMON_RETURN_SELF;
  }
  static int GetLatestIndex(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetLatestIndex());
    return 1;
  }

  LunaFadingBanner() {
    ADD_METHOD(scaletoclipped);
    ADD_METHOD(ScaleToClipped);
    ADD_METHOD(LoadFromSong);
    ADD_METHOD(LoadFromSongGroup);
    ADD_METHOD(LoadFromCourse);
    ADD_METHOD(LoadIconFromCharacter);
    ADD_METHOD(LoadCardFromCharacter);
    ADD_METHOD(LoadRandom);
    ADD_METHOD(LoadRoulette);
    ADD_METHOD(LoadCourseFallback);
    ADD_METHOD(LoadFallback);
    ADD_METHOD(LoadFromSortOrder);
    ADD_METHOD(GetLatestIndex);
    // ADD_METHOD( GetBanner );
  }
};

LUA_REGISTER_DERIVED_CLASS(FadingBanner, ActorFrame)
// lua end

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
