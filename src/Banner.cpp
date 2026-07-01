#include "Banner.h"

#include <cmath>
#include <string>

#include "Actor.h"
#include "ActorUtil.h"
#include "Character.h"
#include "CharacterManager.h"
#include "Course.h"
#include "EnumHelper.h"
#include "GameConstantsAndTypes.h"
#include "ImageCache.h"
#include "LuaManager.h"
#include "PerfDiagnostics.h"
#include "PrefsManager.h"
#include "RageLog.h"
#include "RageTextureID.h"
#include "RageTextureManager.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "Song.h"
#include "SongManager.h"
#include "Sprite.h"
#include "ThemeManager.h"
#include "ThemeMetric.h"
#include "UnlockManager.h"

REGISTER_ACTOR_CLASS(Banner);

ThemeMetric<bool> SCROLL_RANDOM("Banner", "ScrollRandom");
ThemeMetric<bool> SCROLL_ROULETTE("Banner", "ScrollRoulette");
ThemeMetric<bool> SCROLL_MODE("Banner", "ScrollMode");
ThemeMetric<bool> SCROLL_SORT_ORDER("Banner", "ScrollSortOrder");
ThemeMetric<float> SCROLL_SPEED_DIVISOR("Banner", "ScrollSpeedDivisor");

namespace {
class OddDimensionWarningGuard {
 public:
  OddDimensionWarningGuard() : m_active(TEXTUREMAN != nullptr) {
    if (m_active) {
      TEXTUREMAN->DisableOddDimensionWarning();
    }
  }

  ~OddDimensionWarningGuard() {
    if (m_active && TEXTUREMAN != nullptr) {
      TEXTUREMAN->EnableOddDimensionWarning();
    }
  }

 private:
  bool m_active;
};

bool IsFiniteFloat(float value) {
  return std::isfinite(value);
}

void WarnBannerAuditFix(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

void WarnBannerAuditFix(const std::string& message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message.c_str());
  }
}

void TraceBannerAuditFix(const std::string& message) {
  if (LOG != nullptr && LogMusicWheelDiagnosticsEnabled()) {
    LOG->Trace("%s", message.c_str());
  }
}

std::string GetBannerThemePath(
    const std::string& category, const std::string& name) {
  if (THEME == nullptr) {
    WarnBannerAuditFix(ssprintf(
        "SRC_AUDIT_FIX SRC-1046: Banner cannot resolve theme path %s/%s "
        "without THEME.",
        category.c_str(), name.c_str()));
    return std::string();
  }
  return THEME->GetPathG(category, name);
}
}  // namespace

Banner::Banner() {
  m_bScrolling = false;
  m_fPercentScrolling = 0;

  // By default, don't let banners scale their rate with tab/tilde.
  // This helps with animated/video banners.
  Actor::SetRateScalingEnabled(false);
}

// Ugly: if sIsBanner is false, we're actually loading something other than a
// banner.
void Banner::Load(RageTextureID ID, bool bIsBanner) {
  TraceBannerAuditFix(ssprintf(
      "SRC_AUDIT_FIX SRC-2693 MusicWheelTrace banner_load_raw "
      "path='%s' isBanner=%d scrolling=%d percent=%.6f",
      ID.filename.c_str(), bIsBanner, m_bScrolling, m_fPercentScrolling));
  if (ID.filename == "") {
    Sprite::Load(RageTextureID());
    return;
  }

  if (bIsBanner) {
    ID = SongBannerTexture(ID);
  }

  m_fPercentScrolling = 0;
  m_bScrolling = false;

  OddDimensionWarningGuard oddDimensionWarningGuard;
  Sprite::Load(ID);
};

void Banner::LoadFromCachedBanner(const std::string& sPath) {
  if (sPath.empty()) {
    TraceBannerAuditFix(
        "SRC_AUDIT_FIX SRC-2693 MusicWheelTrace "
        "banner_cached_empty_path fallback=1");
    LoadFallback();
    return;
  }

  RageTextureID ID;
  const bool bIsMovie = ActorUtil::GetFileType(sPath) == FT_Movie;
  const bool bLowRes =
      !bIsMovie && PREFSMAN != nullptr && IMAGECACHE != nullptr &&
      (PREFSMAN->m_ImageCache != IMGCACHE_FULL);
  TraceBannerAuditFix(ssprintf(
      "SRC_AUDIT_FIX SRC-2693 MusicWheelTrace banner_cached_begin "
      "path='%s' isMovie=%d lowRes=%d textureManager=%d imageCache=%d",
      sPath.c_str(), bIsMovie, bLowRes, TEXTUREMAN != nullptr,
      IMAGECACHE != nullptr));
  if (!bLowRes) {
    ID = Sprite::SongBannerTexture(sPath);
  } else {
    // Try to load the low quality version.
    ID = IMAGECACHE->LoadCachedImage("Banner", sPath);
  }

  if (TEXTUREMAN != nullptr && TEXTUREMAN->IsTextureRegistered(ID)) {
    TraceBannerAuditFix(ssprintf(
        "SRC_AUDIT_FIX SRC-2693 MusicWheelTrace banner_cached_registered "
        "path='%s' resolved='%s' lowRes=%d",
        sPath.c_str(), ID.filename.c_str(), bLowRes));
    Load(ID);
  } else if (IsAFile(sPath)) {
    TraceBannerAuditFix(ssprintf(
        "SRC_AUDIT_FIX SRC-2693 MusicWheelTrace banner_cached_load_file "
        "path='%s' resolved='%s'",
        sPath.c_str(), ID.filename.c_str()));
    Load(sPath);
  } else {
    TraceBannerAuditFix(ssprintf(
        "SRC_AUDIT_FIX SRC-2693 MusicWheelTrace banner_cached_missing_file "
        "path='%s' resolved='%s'",
        sPath.c_str(), ID.filename.c_str()));
    LoadFallback();
  }
}

void Banner::Update(float fDeltaTime) {
  Sprite::Update(fDeltaTime);

  if (m_bScrolling) {
    const float divisor = SCROLL_SPEED_DIVISOR;
    if (!IsFiniteFloat(divisor) || divisor <= 0.0f ||
        !IsFiniteFloat(fDeltaTime) || !IsFiniteFloat(m_fPercentScrolling)) {
      WarnBannerAuditFix(ssprintf(
          "SRC_AUDIT_FIX SRC-723: Banner disabled invalid scrolling state "
          "divisor=%.6f delta=%.6f percent=%.6f.",
          divisor, fDeltaTime, m_fPercentScrolling));
      m_bScrolling = false;
      m_fPercentScrolling = 0.0f;
      return;
    }

    m_fPercentScrolling += fDeltaTime / divisor;
    m_fPercentScrolling =
        m_fPercentScrolling - std::floor(m_fPercentScrolling);

    const RectF* pTextureRect = GetCurrentTextureCoordRect();
    if (pTextureRect == nullptr) {
      WarnBannerAuditFix(
          "SRC_AUDIT_FIX SRC-723: Banner skipped scrolling because no texture "
          "coord rect is available.");
      return;
    }

    float fTexCoords[8] = {
        0 + m_fPercentScrolling, pTextureRect->top,     // top left
        0 + m_fPercentScrolling, pTextureRect->bottom,  // bottom left
        1 + m_fPercentScrolling, pTextureRect->bottom,  // bottom right
        1 + m_fPercentScrolling, pTextureRect->top,     // top right
    };
    Sprite::SetCustomTextureCoords(fTexCoords);
  }
}

void Banner::SetScrolling(bool bScroll, float Percent) {
  TraceBannerAuditFix(ssprintf(
      "SRC_AUDIT_FIX SRC-2693 MusicWheelTrace banner_set_scrolling "
      "scroll=%d percent=%.6f previousScroll=%d previousPercent=%.6f "
      "texture='%s'",
      bScroll, Percent, m_bScrolling, m_fPercentScrolling,
      GetTexturePath().c_str()));
  m_bScrolling = bScroll;
  if (!IsFiniteFloat(Percent)) {
    WarnBannerAuditFix(ssprintf(
        "SRC_AUDIT_FIX SRC-723: Banner clamped non-finite scrolling percent "
        "%.6f.",
        Percent));
    Percent = 0.0f;
  }
  m_fPercentScrolling = Percent - std::floor(Percent);

  // Set up the texture coord rects for the current state.
  Update(0);
}

void Banner::LoadFromSong(Song* pSong)  // nullptr means no song
{
  TraceBannerAuditFix(ssprintf(
      "SRC_AUDIT_FIX SRC-2693 MusicWheelTrace banner_song "
      "songPtr=%p title='%s' dir='%s' hasBanner=%d banner='%s'",
      static_cast<void*>(pSong),
      pSong == nullptr ? "<null>" : pSong->GetDisplayFullTitle().c_str(),
      pSong == nullptr ? "" : pSong->GetSongDir().c_str(),
      pSong != nullptr && pSong->HasBanner(),
      pSong == nullptr ? "" : pSong->GetBannerPath().c_str()));
  if (pSong == nullptr) {
    LoadFallback();
  } else if (pSong->HasBanner()) {
    Load(pSong->GetBannerPath());
  } else {
    LoadFallback();
  }

  m_bScrolling = false;
}

void Banner::LoadMode() {
  Load(GetBannerThemePath("Banner", "Mode"));
  m_bScrolling = (bool)SCROLL_MODE;
}

void Banner::LoadFromSongGroup(std::string sSongGroup) {
  if (SONGMAN == nullptr) {
    WarnBannerAuditFix(ssprintf(
        "SRC_AUDIT_FIX SRC-724: Banner cannot load group '%s' without "
        "SONGMAN.",
        sSongGroup.c_str()));
    LoadGroupFallback();
    m_bScrolling = false;
    return;
  }

  std::string sGroupBannerPath = SONGMAN->GetSongGroupBannerPath(sSongGroup);
  TraceBannerAuditFix(ssprintf(
      "SRC_AUDIT_FIX SRC-2693 MusicWheelTrace banner_group "
      "group='%s' banner='%s'",
      sSongGroup.c_str(), sGroupBannerPath.c_str()));
  if (sGroupBannerPath != "") {
    Load(sGroupBannerPath);
  } else {
    LoadGroupFallback();
  }
  m_bScrolling = false;
}

void Banner::LoadFromCourse(const Course* pCourse)  // nullptr means no course
{
  TraceBannerAuditFix(ssprintf(
      "SRC_AUDIT_FIX SRC-2693 MusicWheelTrace banner_course "
      "coursePtr=%p title='%s' banner='%s'",
      static_cast<const void*>(pCourse),
      pCourse == nullptr ? "<null>" : pCourse->GetDisplayFullTitle().c_str(),
      pCourse == nullptr ? "" : pCourse->GetBannerPath().c_str()));
  if (pCourse == nullptr) {
    LoadFallback();
  } else if (pCourse->GetBannerPath() != "") {
    Load(pCourse->GetBannerPath());
  } else {
    LoadCourseFallback();
  }

  m_bScrolling = false;
}

void Banner::LoadCardFromCharacter(const Character* pCharacter) {
  if (pCharacter == nullptr) {
    LoadFallback();
  } else if (pCharacter->GetCardPath() != "") {
    Load(pCharacter->GetCardPath());
  } else {
    LoadFallback();
  }

  m_bScrolling = false;
}

void Banner::LoadIconFromCharacter(const Character* pCharacter) {
  if (pCharacter == nullptr) {
    LoadFallbackCharacterIcon();
  } else if (pCharacter->GetIconPath() != "") {
    Load(pCharacter->GetIconPath(), false);
  } else {
    LoadFallbackCharacterIcon();
  }

  m_bScrolling = false;
}

void Banner::LoadBannerFromUnlockEntry(const UnlockEntry* pUE) {
  if (pUE == nullptr) {
    LoadFallback();
  } else {
    std::string sFile = pUE->GetBannerFile();
    if (sFile.empty()) {
      LoadFallback();
    } else {
      Load(sFile);
    }
    m_bScrolling = false;
  }
}

void Banner::LoadBackgroundFromUnlockEntry(const UnlockEntry* pUE) {
  if (pUE == nullptr) {
    LoadFallbackBG();
  } else {
    std::string sFile = pUE->GetBackgroundFile();
    if (sFile.empty()) {
      LoadFallbackBG();
    } else {
      Load(sFile);
    }
    m_bScrolling = false;
  }
}

void Banner::LoadFallback() {
  TraceBannerAuditFix(
      "SRC_AUDIT_FIX SRC-2693 MusicWheelTrace banner_fallback");
  Load(GetBannerThemePath("Common", "fallback banner"));
}

void Banner::LoadFallbackBG() {
  Load(GetBannerThemePath("Common", "fallback background"));
}

void Banner::LoadGroupFallback() {
  Load(GetBannerThemePath("Banner", "group fallback"));
}

void Banner::LoadCourseFallback() {
  Load(GetBannerThemePath("Banner", "course fallback"));
}

void Banner::LoadFallbackCharacterIcon() {
  if (CHARMAN == nullptr) {
    WarnBannerAuditFix(
        "SRC_AUDIT_FIX SRC-724: Banner cannot load fallback character icon "
        "without CHARMAN.");
    LoadFallback();
    return;
  }

  Character* pCharacter = CHARMAN->GetDefaultCharacter();
  if (pCharacter && !pCharacter->GetIconPath().empty()) {
    Load(pCharacter->GetIconPath(), false);
  } else {
    LoadFallback();
  }
}

void Banner::LoadRoulette() {
  Load(GetBannerThemePath("Banner", "roulette"));
  m_bScrolling = (bool)SCROLL_ROULETTE;
}

void Banner::LoadRandom() {
  Load(GetBannerThemePath("Banner", "random"));
  m_bScrolling = (bool)SCROLL_RANDOM;
}

void Banner::LoadFromSortOrder(SortOrder so) {
  // TODO: See if the check for nullptr/PREFERRED(?) is needed.
  switch (so) {
    case SortOrder_Invalid:
      LoadFallback();
      break;
    case SORT_GROUP:
      break;
    // This is necessary to prevent multiple banners from matching for
    // SORT_RECENT and SORT_POPULARITY
    case SORT_RECENT:
    case SORT_RECENT_P1:
    case SORT_RECENT_P2:
      Load(GetBannerThemePath(
          "Banner", ssprintf("%s", SortOrderToString(SORT_RECENT).c_str())));
      break;
    case SORT_POPULARITY:
    case SORT_POPULARITY_P1:
    case SORT_POPULARITY_P2:
      Load(GetBannerThemePath(
          "Banner",
          ssprintf("%s", SortOrderToString(SORT_POPULARITY).c_str())));
      break;
    default:
      Load(GetBannerThemePath(
          "Banner", ssprintf("%s", SortOrderToString(so).c_str())));
      break;
  }
  m_bScrolling = (bool)SCROLL_SORT_ORDER;
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the Banner. */
class LunaBanner : public Luna<Banner> {
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
  static int LoadFromCachedBanner(T* p, lua_State* L) {
    p->LoadFromCachedBanner(SArg(1));
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
  static int LoadBannerFromUnlockEntry(T* p, lua_State* L) {
    if (lua_isnil(L, 1)) {
      p->LoadBannerFromUnlockEntry(nullptr);
    } else {
      UnlockEntry* pUE = Luna<UnlockEntry>::check(L, 1);
      p->LoadBannerFromUnlockEntry(pUE);
    }
    COMMON_RETURN_SELF;
  }
  static int LoadBackgroundFromUnlockEntry(T* p, lua_State* L) {
    if (lua_isnil(L, 1)) {
      p->LoadBackgroundFromUnlockEntry(nullptr);
    } else {
      UnlockEntry* pUE = Luna<UnlockEntry>::check(L, 1);
      p->LoadBackgroundFromUnlockEntry(pUE);
    }
    COMMON_RETURN_SELF;
  }
  static int LoadFromSongGroup(T* p, lua_State* L) {
    p->LoadFromSongGroup(SArg(1));
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
  static int GetScrolling(T* p, lua_State* L) {
    lua_pushboolean(L, p->GetScrolling());
    return 1;
  }
  static int SetScrolling(T* p, lua_State* L) {
    p->SetScrolling(BArg(1), FArg(2));
    COMMON_RETURN_SELF;
  }
  static int GetPercentScrolling(T* p, lua_State* L) {
    lua_pushnumber(L, p->ScrollingPercent());
    return 1;
  }

  LunaBanner() {
    ADD_METHOD(scaletoclipped);
    ADD_METHOD(ScaleToClipped);
    ADD_METHOD(LoadFromSong);
    ADD_METHOD(LoadFromCourse);
    ADD_METHOD(LoadFromCachedBanner);
    ADD_METHOD(LoadIconFromCharacter);
    ADD_METHOD(LoadCardFromCharacter);
    ADD_METHOD(LoadBannerFromUnlockEntry);
    ADD_METHOD(LoadBackgroundFromUnlockEntry);
    ADD_METHOD(LoadFromSongGroup);
    ADD_METHOD(LoadFromSortOrder);
    ADD_METHOD(GetScrolling);
    ADD_METHOD(SetScrolling);
    ADD_METHOD(GetPercentScrolling);
  }
};

LUA_REGISTER_DERIVED_CLASS(Banner, Sprite)
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
