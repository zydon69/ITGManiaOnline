/*
 * Texture garbage collection policies:
 *
 * Default: When DelayedDelete is off, delete unused textures immediately.
 *          When on, only delete textures when we change themes, on
 * DoDelayedDelete().
 *
 * Volatile: Delete unused textures once they've been used at least once. Ignore
 *           DelayedDelete.
 *
 *           This is for banners.  We don't want to load all low-quality banners
 * in memory at once, since it might be ten megs of textures, and we don't need
 * to, since we can reload them very quickly.  We don't want to keep high
 * quality textures in memory, either, although it's unlikely that a player
 * could actually view all banners long enough to transition to them all in the
 * course of one song select screen.
 *
 * If a texture is loaded as DEFAULT that was already loaded as VOLATILE,
 * DEFAULT overrides.
 */

#include "RageTextureManager.h"

#include <algorithm>
#include <cstdint>
#include <cmath>
#include <iterator>
#include <map>
#include <string>
#include <utility>
#include <vector>

#include "ActorUtil.h"
#include "PerfDiagnostics.h"
#include "Preference.h"
#include "RageBitmapTexture.h"
#include "RageDisplay.h"
#include "RageException.h"
#include "RageLog.h"
#include "RageTexture.h"
#include "RageTextureID.h"
#include "RageThreads.h"
#include "RageTimer.h"
#include "RageUtil.h"
#include "LuaManager.h"
#include "arch/MovieTexture/MovieTexture.h"
#include "global.h"

RageTextureManager* TEXTUREMAN =
    nullptr;  // global and accessible from anywhere in our program

namespace {
std::map<RageTextureID, RageTexture*> m_mapPathToTexture;
std::map<RageTextureID, RageTexture*> m_textures_to_update;
std::map<RageTexture*, RageTextureID> m_texture_ids_by_pointer;
Preference<int> g_iTextureGCMaxDeletesPerScreenChange(
    "TextureGCMaxDeletesPerScreenChange", 48);

void WarnTextureManagerAuditFix(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

bool IsValidTexturePolicy(RageTextureID::TexPolicy policy) {
  return policy == RageTextureID::TEX_DEFAULT ||
         policy == RageTextureID::TEX_VOLATILE;
}
};  // namespace

RageTextureManager::RageTextureManager()
    : m_iNoWarnAboutOddDimensions(0),
      m_TexturePolicy(RageTextureID::TEX_DEFAULT) {}

RageTextureManager::~RageTextureManager() {
  for (std::pair<const RageTextureID&, RageTexture*> i : m_mapPathToTexture) {
    RageTexture* pTexture = i.second;
    if (pTexture != nullptr && pTexture->m_iRefCount && LOG != nullptr) {
      LOG->Trace(
          "TEXTUREMAN LEAK: '%s', RefCount = %d.", i.first.filename.c_str(),
          pTexture->m_iRefCount);
    }
    RageUtil::SafeDelete(pTexture);
  }
  m_textures_to_update.clear();
  m_texture_ids_by_pointer.clear();
}

void RageTextureManager::Update(float fDeltaTime) {
  if (!std::isfinite(fDeltaTime) || fDeltaTime < 0.0f) {
    WarnTextureManagerAuditFix(
        "SRC_AUDIT_FIX SRC-1016: RageTextureManager ignored invalid update "
        "delta.");
    return;
  }

  std::vector<std::pair<RageTextureID, RageTexture*>> texturesToUpdate;
  texturesToUpdate.reserve(m_textures_to_update.size());
  for (const auto& i : m_textures_to_update) {
    texturesToUpdate.push_back(i);
  }

  for (const auto& i : texturesToUpdate) {
    auto registered = m_textures_to_update.find(i.first);
    if (registered == m_textures_to_update.end() || registered->second != i.second) {
      continue;
    }
    RageTexture* pTexture = i.second;
    if (pTexture == nullptr) {
      continue;
    }
    pTexture->Update(fDeltaTime);
  }
}

void RageTextureManager::AdjustTextureID(RageTextureID& ID) const {
  if (ID.iColorDepth == -1) {
    ID.iColorDepth = m_Prefs.m_iTextureColorDepth;
  }
  if (ID.iColorDepth != 16 && ID.iColorDepth != 32) {
    ID.iColorDepth = m_Prefs.m_iTextureColorDepth;
  }
  const int maxResolution = std::max(1, m_Prefs.m_iMaxTextureResolution);
  ID.iMaxSize = std::clamp(ID.iMaxSize, 1, maxResolution);
  if (m_Prefs.m_bMipMaps) {
    ID.bMipMaps = true;
  }
}

bool RageTextureManager::IsTextureRegistered(RageTextureID ID) const {
  AdjustTextureID(ID);
  return m_mapPathToTexture.find(ID) != m_mapPathToTexture.end();
}

/* If you've set up a texture yourself, register it here so it can be referenced
 * and deleted by ID.  This takes ownership; the texture will be freed according
 * to its GC policy. */
void RageTextureManager::RegisterTexture(
    RageTextureID ID, RageTexture* pTexture) {
  if (pTexture == nullptr) {
    WarnTextureManagerAuditFix(
        "SRC_AUDIT_FIX SRC-1017: RageTextureManager ignored null texture "
        "registration.");
    return;
  }

  AdjustTextureID(ID);

  /* Make sure we don't already have a texture with this ID.  If we do, the
   * caller should have used it. */
  std::map<RageTextureID, RageTexture*>::iterator p =
      m_mapPathToTexture.find(ID);
  if (p != m_mapPathToTexture.end()) {
    WarnTextureManagerAuditFix(
        "SRC_AUDIT_FIX SRC-1017: RageTextureManager rejected duplicate custom "
        "texture registration.");
    if (p->second != pTexture) {
      RageUtil::SafeDelete(pTexture);
    }
    return;
  }

  m_mapPathToTexture[ID] = pTexture;
  m_texture_ids_by_pointer[pTexture] = ID;
}

void RageTextureManager::RegisterTextureForUpdating(
    RageTextureID id, RageTexture* tex) {
  if (tex == nullptr) {
    m_textures_to_update.erase(id);
    WarnTextureManagerAuditFix(
        "SRC_AUDIT_FIX SRC-1018: RageTextureManager ignored null update "
        "texture.");
    return;
  }
  m_textures_to_update[id] = tex;
}

static const std::string g_sDefaultTextureName = "__blank__";
RageTextureID RageTextureManager::GetDefaultTextureID() {
  return RageTextureID(g_sDefaultTextureName);
}

static const std::string g_ScreenTextureName = "__screen__";
RageTextureID RageTextureManager::GetScreenTextureID() {
  return RageTextureID(g_ScreenTextureName);
}

RageSurface* RageTextureManager::GetScreenSurface() {
  return DISPLAY->CreateScreenshot();
}

class RageTexture_Default : public RageTexture {
 public:
  RageTexture_Default() : RageTexture(RageTextureID()), m_uTexHandle(0) {
    m_iSourceWidth = m_iSourceHeight = 1;
    m_iTextureWidth = m_iTextureHeight = 1;
    m_iImageWidth = m_iImageHeight = 1;
    CreateFrameRects();
  }
  uintptr_t GetTexHandle() const { return m_uTexHandle; }

 private:
  uintptr_t m_uTexHandle;
};

// Load and unload textures from disk.
RageTexture* RageTextureManager::LoadTextureInternal(RageTextureID ID) {
  if (LogVerboseContentLoadDiagnosticsEnabled()) {
    CHECKPOINT_M(
        ssprintf("RageTextureManager::LoadTexture(%s).", ID.filename.c_str()));
  }

  AdjustTextureID(ID);

  /* We could have two copies of the same bitmap if there are equivalent but
   * different paths, e.g. "Bitmaps\me.bmp" and "..\Rage PC
   * Edition\Bitmaps\me.bmp". */
  std::map<RageTextureID, RageTexture*>::iterator p =
      m_mapPathToTexture.find(ID);
  if (p != m_mapPathToTexture.end()) {
    /* Found the texture.  Just increase the refcount and return it. */
    RageTexture* pTexture = p->second;
    pTexture->m_iRefCount++;
    return pTexture;
  }

  // The texture is not already loaded.  Load it.

  RageTexture* pTexture;
  if (ID.filename.empty() || ID.filename == g_sDefaultTextureName) {
    pTexture = new RageTexture_Default;
  } else if (ActorUtil::GetFileType(ID.filename) == FT_Movie) {
    pTexture = RageMovieTexture::Create(ID);
  } else {
    pTexture = new RageBitmapTexture(ID);
  }
  if (pTexture == nullptr) {
    WarnTextureManagerAuditFix(
        "SRC_AUDIT_FIX SRC-1019: RageTextureManager fell back after null "
        "texture factory result.");
    pTexture = new RageTexture_Default;
  }

  m_mapPathToTexture[ID] = pTexture;
  m_texture_ids_by_pointer[pTexture] = ID;

  return pTexture;
}

/* Load a normal texture.  Use this call to actually use a texture. */
RageTexture* RageTextureManager::LoadTexture(RageTextureID ID) {
  RageTexture* pTexture = LoadTextureInternal(ID);
  if (pTexture) {
    pTexture->m_bWasUsed = true;
  }
  return pTexture;
}

RageTexture* RageTextureManager::CopyTexture(RageTexture* pCopy) {
  if (pCopy == nullptr) {
    WarnTextureManagerAuditFix(
        "SRC_AUDIT_FIX SRC-1020: RageTextureManager refused to copy null "
        "texture.");
    return nullptr;
  }
  ++pCopy->m_iRefCount;
  return pCopy;
}

void RageTextureManager::VolatileTexture(RageTextureID ID) {
  RageTexture* pTexture = LoadTextureInternal(ID);
  if (pTexture == nullptr) {
    return;
  }
  pTexture->GetPolicy() =
      std::min(pTexture->GetPolicy(), RageTextureID::TEX_VOLATILE);
  UnloadTexture(pTexture);
}

void RageTextureManager::UnloadTexture(RageTexture* t) {
  if (t == nullptr) {
    return;
  }

  if (t->m_iRefCount <= 0) {
    WarnTextureManagerAuditFix(
        "SRC_AUDIT_FIX SRC-1021: RageTextureManager refused refcount "
        "underflow during unload.");
    return;
  }
  t->m_iRefCount--;

  if (t->m_iRefCount) {
    return; /* Can't unload textures that are still referenced. */
  }

  bool bDeleteThis = false;

  /* Always unload movies, so we don't waste time decoding. */
  if (t->IsAMovie()) {
    bDeleteThis = true;
  }

  /* Delete normal textures immediately unless m_bDelayedDelete is is on. */
  if (t->GetPolicy() == RageTextureID::TEX_DEFAULT &&
      !m_Prefs.m_bDelayedDelete) {
    bDeleteThis = true;
  }

  /* Delete volatile textures after they've been used at least once. */
  if (t->GetPolicy() == RageTextureID::TEX_VOLATILE && t->m_bWasUsed) {
    bDeleteThis = true;
  }

  if (bDeleteThis) {
    DeleteTexture(t);
  }
}

void RageTextureManager::DeleteTexture(RageTexture* t) {
  if (t == nullptr) {
    return;
  }
  if (t->m_iRefCount != 0) {
    WarnTextureManagerAuditFix(
        "SRC_AUDIT_FIX SRC-1022: RageTextureManager refused to delete "
        "referenced texture.");
    return;
  }
  // LOG->Trace( "RageTextureManager: deleting '%s'.",
  // t->GetID().filename.c_str() );

  std::map<RageTexture*, RageTextureID>::iterator id_entry =
      m_texture_ids_by_pointer.find(t);
  if (id_entry != m_texture_ids_by_pointer.end()) {
    const RageTextureID id = id_entry->second;
    std::map<RageTextureID, RageTexture*>::iterator tex_entry =
        m_mapPathToTexture.find(id);
    std::map<RageTextureID, RageTexture*>::iterator tex_update_entry =
        m_textures_to_update.find(id);
    if (tex_update_entry != m_textures_to_update.end()) {
      m_textures_to_update.erase(tex_update_entry);
    }
    m_texture_ids_by_pointer.erase(id_entry);
    if (tex_entry != m_mapPathToTexture.end() && tex_entry->second == t) {
      m_mapPathToTexture.erase(tex_entry);
      RageUtil::SafeDelete(t);
      return;
    }
    WarnTextureManagerAuditFix(
        "SRC_AUDIT_FIX SRC-1022: RageTextureManager found stale texture "
        "pointer registration.");
    return;
  }

  WarnTextureManagerAuditFix(
      "SRC_AUDIT_FIX SRC-1022: RageTextureManager ignored unknown texture "
      "delete request.");
}

void RageTextureManager::GarbageCollect(GCType type) {
  // Search for old textures with refcount==0 to unload
  RageTimer gcTimer;
  const int deleteBudget =
      type == screen_changed
          ? std::max(0, g_iTextureGCMaxDeletesPerScreenChange.Get())
          : 0;
  int visited = 0;
  int deleted = 0;
  bool deferred = false;

  for (std::map<RageTextureID, RageTexture*>::iterator i =
           m_mapPathToTexture.begin();
       i != m_mapPathToTexture.end();) {
    std::map<RageTextureID, RageTexture*>::iterator j = i;
    i++;
    ++visited;

    std::string sPath = j->first.filename;
    RageTexture* t = j->second;

    if (t->m_iRefCount) {
      continue; /* Can't unload textures that are still referenced. */
    }

    bool bDeleteThis = false;
    if (type == screen_changed) {
      RageTextureID::TexPolicy policy = t->GetPolicy();
      switch (policy) {
        case RageTextureID::TEX_DEFAULT:
          /* If m_bDelayedDelete, wait until delayed_delete.  If
           * !m_bDelayedDelete, it should have been deleted when it reached no
           * references, but we might have just changed the preference. */
          if (!m_Prefs.m_bDelayedDelete) {
            bDeleteThis = true;
          }
          break;
        case RageTextureID::TEX_VOLATILE:
          bDeleteThis = true;
          break;
        default:
          WarnTextureManagerAuditFix(
              "SRC_AUDIT_FIX SRC-1023: RageTextureManager deleted texture with "
              "invalid policy.");
          bDeleteThis = true;
      }
    }

    /* This happens when we change themes; free all textures. */
    if (type == delayed_delete) {
      bDeleteThis = true;
    }

    if (bDeleteThis) {
      if (deleteBudget > 0 && deleted >= deleteBudget) {
        deferred = true;
        break;
      }
      DeleteTexture(t);
      ++deleted;
    }
  }

  const float elapsedMs = gcTimer.GetDeltaTime() * 1000.0f;
  if (PerfDiagnosticsEnabled() &&
      (deleted > 0 || deferred || elapsedMs >= 2.0f)) {
    LOG->Trace(
        "PERF_TRACE: texture_gc type=%s visited=%d deleted=%d deferred=%d "
        "budget=%d elapsed_ms=%.3f",
        type == screen_changed ? "screen_changed" : "delayed_delete", visited,
        deleted, deferred ? 1 : 0, deleteBudget, elapsedMs);
  }
}

void RageTextureManager::ReloadAll() {
  DisableOddDimensionWarning();

  /* Let's get rid of all unreferenced textures, so we don't reload a
   * ton of cached data that we're not necessarily going to use. */
  DoDelayedDelete();

  for (const auto& i : m_mapPathToTexture) {
    if (i.second != nullptr) {
      i.second->Reload();
    }
  }

  EnableOddDimensionWarning();
}

/* In some cases, changing the display mode will reset the rendering context,
 * releasing all textures.  We don't want to reload immediately if that happens,
 * since we might be changing texture preferences too, which also may have to
 * reload textures.  Instead, tell all textures that their texture ID is
 * invalid, so it doesn't try to free it later when we really do reload (since
 * that ID might be associated with a different texture).  Ack. */
void RageTextureManager::InvalidateTextures() {
  for (const auto& i : m_mapPathToTexture) {
    RageTexture* pTexture = i.second;
    if (pTexture != nullptr) {
      pTexture->Invalidate();
    }
  }
}

bool RageTextureManager::SetPrefs(RageTextureManagerPrefs prefs) {
  if (prefs.m_iTextureColorDepth != 16 && prefs.m_iTextureColorDepth != 32) {
    WarnTextureManagerAuditFix(
        "SRC_AUDIT_FIX SRC-1024: RageTextureManager clamped invalid texture "
        "color depth.");
    prefs.m_iTextureColorDepth = 32;
  }
  if (prefs.m_iMovieColorDepth != 16 && prefs.m_iMovieColorDepth != 32) {
    WarnTextureManagerAuditFix(
        "SRC_AUDIT_FIX SRC-1024: RageTextureManager clamped invalid movie color "
        "depth.");
    prefs.m_iMovieColorDepth = 32;
  }
  prefs.m_iMaxTextureResolution = std::max(1, prefs.m_iMaxTextureResolution);

  bool bNeedReload = false;
  if (m_Prefs != prefs) {
    bNeedReload = true;
  }

  m_Prefs = prefs;

  return bNeedReload;
}

void RageTextureManager::DiagnosticOutput() const {
  unsigned iCount =
      distance(m_mapPathToTexture.begin(), m_mapPathToTexture.end());
  LOG->Trace("%u textures loaded:", iCount);

  int iTotal = 0;
  for (const auto& i : m_mapPathToTexture) {
    const RageTextureID& ID = i.first;
    const RageTexture* pTex = i.second;

    std::string sDiags = DISPLAY->GetTextureDiagnostics(pTex->GetTexHandle());
    std::string sStr = ssprintf(
        "%3ix%3i (%2i)", pTex->GetTextureHeight(), pTex->GetTextureWidth(),
        pTex->m_iRefCount);

    if (sDiags != "") {
      sStr += " " + sDiags;
    }

    LOG->Trace(" %-40s %s", sStr.c_str(), Basename(ID.filename).c_str());
    iTotal += pTex->GetTextureHeight() * pTex->GetTextureWidth();
  }
  LOG->Trace("total %3i texels", iTotal);
}

void RageTextureManager::LogResourceSnapshot(const std::string& label) const {
  int totalRefs = 0;
  int defaultTextures = 0;
  int volatileTextures = 0;
  int movieTextures = 0;
  int maxRefCount = 0;
  int64_t totalTexels = 0;
  int64_t movieTexels = 0;
  std::string maxRefTexture;

  for (const auto& i : m_mapPathToTexture) {
    const RageTexture* texture = i.second;
    const int refCount = texture->m_iRefCount;
    const int64_t texels = static_cast<int64_t>(texture->GetTextureWidth()) *
                           static_cast<int64_t>(texture->GetTextureHeight());
    totalRefs += refCount;
    totalTexels += texels;

    if (texture->IsAMovie()) {
      ++movieTextures;
      movieTexels += texels;
    }

    if (texture->GetPolicy() == RageTextureID::TEX_VOLATILE) {
      ++volatileTextures;
    } else {
      ++defaultTextures;
    }

    if (refCount > maxRefCount) {
      maxRefCount = refCount;
      maxRefTexture = Basename(i.first.filename);
    }
  }

  LOG->Trace(
      "ITG Resource: label=%s textures=%zu default=%d volatile=%d "
      "movies=%d update_queue=%zu refs=%d texels=%lld movie_texels=%lld "
      "max_ref=%d max_ref_texture=%s",
      label.c_str(), m_mapPathToTexture.size(), defaultTextures,
      volatileTextures, movieTextures, m_textures_to_update.size(), totalRefs,
      static_cast<long long>(totalTexels), static_cast<long long>(movieTexels),
      maxRefCount, maxRefTexture.c_str());
}

static int LuaFunc_ITGOnlineLogResourceSnapshot(lua_State* L) {
  std::string label;
  if (!lua_isnoneornil(L, 1)) {
    label = SArg(1);
  }

  if (TEXTUREMAN != nullptr) {
    TEXTUREMAN->LogResourceSnapshot(label);
  }

  return 0;
}
LUAFUNC_REGISTER_COMMON(ITGOnlineLogResourceSnapshot)

/*
 * Copyright (c) 2001-2004 Chris Danford, Glenn Maynard
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
