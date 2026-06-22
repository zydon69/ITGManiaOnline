#include "ModelManager.h"

#include <map>
#include <memory>
#include <string>
#include <utility>

#include "RageLog.h"
#include "RageModelGeometry.h"
#include "RageUtil.h"
#include "global.h"

ModelManager* MODELMAN =
    nullptr;  // global and accessible from anywhere in our program

ModelManager::ModelManager() {}

ModelManager::~ModelManager() {
  for (std::map<GeometryCacheKey, RageModelGeometry*>::iterator i =
           m_mapFileToGeometry.begin();
       i != m_mapFileToGeometry.end(); ++i) {
    RageModelGeometry* pGeom = i->second;
    if (pGeom != nullptr && pGeom->m_iRefCount && LOG != nullptr) {
      LOG->Trace(
          "MODELMAN LEAK: '%s' normals=%d, RefCount = %d.",
          i->first.first.c_str(), i->first.second ? 1 : 0, pGeom->m_iRefCount);
    }
    RageUtil::SafeDelete(pGeom);
  }
  m_mapFileToGeometry.clear();
}

RageModelGeometry* ModelManager::LoadMilkshapeAscii(
    const std::string& sFile, bool bNeedNormals) {
  const GeometryCacheKey key(sFile, bNeedNormals);
  std::map<GeometryCacheKey, RageModelGeometry*>::iterator p =
      m_mapFileToGeometry.find(key);
  if (p != m_mapFileToGeometry.end()) {
    /* Found the geometry.  Just increase the refcount and return it. */
    RageModelGeometry* pGeom = p->second;
    if (pGeom == nullptr) {
      m_mapFileToGeometry.erase(p);
      return LoadMilkshapeAscii(sFile, bNeedNormals);
    }
    ++pGeom->m_iRefCount;
    return pGeom;
  }

  std::unique_ptr<RageModelGeometry> pGeom(new RageModelGeometry);
  pGeom->LoadMilkshapeAscii(sFile, bNeedNormals);

  RageModelGeometry* raw = pGeom.release();
  m_mapFileToGeometry[key] = raw;
  return raw;
}

void ModelManager::UnloadModel(RageModelGeometry* m) {
  if (m == nullptr) {
    return;
  }
  if (m->m_iRefCount <= 0) {
    if (LOG != nullptr) {
      LOG->Warn("SRC_AUDIT_FIX SRC-799: duplicate unload of model geometry %p.",
                static_cast<void*>(m));
    }
    return;
  }
  m->m_iRefCount--;

  if (m->m_iRefCount) {
    return; /* Can't unload models that are still referenced. */
  }

  for (std::map<GeometryCacheKey, RageModelGeometry*>::iterator i =
           m_mapFileToGeometry.begin();
       i != m_mapFileToGeometry.end(); ++i) {
    if (i->second == m) {
      if (m_Prefs.m_bDelayedUnload) {
        // leave this geometry loaded
        return;
      } else {
        m_mapFileToGeometry.erase(i);  // remove map entry
        RageUtil::SafeDelete(m);       // free the texture
        return;
      }
    }
  }

  if (LOG != nullptr) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-799: tried to unload uncached model geometry %p.",
        static_cast<void*>(m));
  }
}

bool ModelManager::SetPrefs(const ModelManagerPrefs& prefs) {
  m_Prefs = prefs;
  return false;
}

/*
 * (c) 2003-2004 Chris Danford
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
