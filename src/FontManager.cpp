#include "FontManager.h"

#include <algorithm>
#include <map>
#include <limits>
#include <memory>
#include <string>
#include <utility>

#include "Font.h"
#include "PerfDiagnostics.h"
#include "RageException.h"
#include "RageLog.h"
#include "RageUtil.h"
#include "global.h"

FontManager* FONT =
    nullptr;  // global and accessible from anywhere in our program

// map from file name to a texture holder
typedef std::pair<std::string, std::string> FontName;
static std::map<FontName, Font*> g_mapPathToFont;

namespace {
std::string NormalizeFontPath(std::string path) {
  FixSlashesInPlace(path);
  CollapsePath(path, true);
  return path;
}
}  // namespace

FontManager::FontManager() {}

FontManager::~FontManager() {
  for (std::map<FontName, Font*>::iterator i = g_mapPathToFont.begin();
       i != g_mapPathToFont.end(); ++i) {
    const FontName& fn = i->first;
    Font* pFont = i->second;
    if (pFont != nullptr && pFont->m_iRefCount > 0 && LOG != nullptr) {
      LOG->Trace(
          "FONT LEAK: '%s', RefCount = %d.", fn.first.c_str(),
          pFont->m_iRefCount);
    }
    delete pFont;
  }
  g_mapPathToFont.clear();
}

Font* FontManager::LoadFont(
    const std::string& sFontOrTextureFilePath, std::string sChars) {
  Font* pFont;
  /* Convert the path to lowercase so that we don't load duplicates. Really,
   * this does not solve the duplicate problem. We could have two copies of
   * the same bitmap if there are equivalent but different paths
   * (e.g. "graphics\blah.png" and "..\stepmania\graphics\blah.png" ). */

  if (LogVerboseContentLoadDiagnosticsEnabled() && LOG != nullptr) {
    LOG->Trace(
        "CONTENT_TRACE: font_cache_load path='%s'",
        sFontOrTextureFilePath.c_str());
  }
  const FontName NewName(NormalizeFontPath(sFontOrTextureFilePath), sChars);
  std::map<FontName, Font*>::iterator p = g_mapPathToFont.find(NewName);
  if (p != g_mapPathToFont.end()) {
    pFont = p->second;
    if (pFont == nullptr) {
      g_mapPathToFont.erase(p);
      return LoadFont(sFontOrTextureFilePath, std::move(sChars));
    }
    if (pFont->m_iRefCount == std::numeric_limits<int>::max()) {
      RageException::Throw(
          "Font \"%s\" reference count overflow.",
          sFontOrTextureFilePath.c_str());
    }
    pFont->m_iRefCount++;
    return pFont;
  }

  std::unique_ptr<Font> f(new Font);
  f->Load(NewName.first, sChars);
  Font* raw = f.release();
  g_mapPathToFont[NewName] = raw;
  return raw;
}

Font* FontManager::CopyFont(Font* pFont) {
  if (pFont == nullptr) {
    if (LOG != nullptr) {
      LOG->Warn("attempted to copy a null font.");
    }
    return nullptr;
  }
  const bool cached = std::any_of(
      g_mapPathToFont.begin(), g_mapPathToFont.end(),
      [pFont](const auto& entry) { return entry.second == pFont; });
  if (!cached) {
    if (LOG != nullptr) {
      LOG->Warn(
          "refused to copy an uncached font pointer "
          "%p.",
          static_cast<void*>(pFont));
    }
    return nullptr;
  }
  if (pFont->m_iRefCount == std::numeric_limits<int>::max()) {
    RageException::Throw("Font reference count overflow.");
  }
  ++pFont->m_iRefCount;
  return pFont;
}

void FontManager::UnloadFont(Font* fp) {
  if (fp == nullptr) {
    return;
  }

  for (std::map<FontName, Font*>::iterator i = g_mapPathToFont.begin();
       i != g_mapPathToFont.end(); ++i) {
    if (i->second != fp) {
      continue;
    }

    if (LogVerboseContentLoadDiagnosticsEnabled() && LOG != nullptr) {
      LOG->Trace(
          "CONTENT_TRACE: font_cache_unload path='%s'", fp->path.c_str());
    }

    if (fp->m_iRefCount <= 0) {
      if (LOG != nullptr) {
        LOG->Warn(
            "attempted to unload font '%s' with ref "
            "count %d.",
            fp->path.c_str(), fp->m_iRefCount);
      }
      return;
    }

    i->second->m_iRefCount--;

    if (fp->m_iRefCount == 0) {
      delete i->second;          // free the texture
      g_mapPathToFont.erase(i);  // and remove the key in the map
    }
    return;
  }

  if (LOG != nullptr) {
    LOG->Warn(
        "unloaded an unknown font (%p).",
        static_cast<void*>(fp));
  }
}

/*
void FontManager::PruneFonts() {
        for( std::map<FontName, Font*>::iterator i = g_mapPathToFont.begin();i
!= g_mapPathToFont.end();) { Font *fp=i->second; if(fp->m_iRefCount==0) { delete
fp; g_mapPathToFont.erase(i); i = g_mapPathToFont.end(); } else {
                        ++i;
                }
        }
}
*/

/*
 * (c) 2001-2003 Chris Danford, Glenn Maynard
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
