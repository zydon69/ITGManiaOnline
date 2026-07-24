#include "ModelManager.h"

#include <map>
#include <limits>
#include <memory>
#include <string>
#include <utility>

#include "RageLog.h"
#include "RageException.h"
#include "RageModelGeometry.h"
#include "RageUtil.h"
#include "global.h"

ModelManager* MODELMAN =
    nullptr;  // global and accessible from anywhere in our program

namespace {
std::string NormalizeGeometryPath(std::string path) {
  FixSlashesInPlace(path);
  CollapsePath(path, true);
  return path;
}
}  // namespace

ModelManager::ModelManager() {}

ModelManager::~ModelManager() {
  for (std::map<GeometryCacheKey, RageModelGeometry*>::iterator i =
           m_mapFileToGeometry.begin();
       i != m_mapFileToGeometry.end(); ++i) {
    RageModelGeometry* pGeom = i->second;
    const bool referenced = pGeom != nullptr && pGeom->m_iRefCount > 0;
    if (referenced && LOG != nullptr) {
      LOG->Trace(
          "MODELMAN LEAK: '%s' normals=%d, RefCount = %d.",
          i->first.first.c_str(), i->first.second ? 1 : 0, pGeom->m_iRefCount);
    }
    if (!referenced) {
      RageUtil::SafeDelete(pGeom);
    }
  }
  m_mapFileToGeometry.clear();
}

RageModelGeometry* ModelManager::LoadMilkshapeAscii(
    const std::string& sFile, bool bNeedNormals) {
  const GeometryCacheKey key(NormalizeGeometryPath(sFile), bNeedNormals);
  std::map<GeometryCacheKey, RageModelGeometry*>::iterator p =
      m_mapFileToGeometry.find(key);
  if (p != m_mapFileToGeometry.end()) {
    /* Found the geometry.  Just increase the refcount and return it. */
    RageModelGeometry* pGeom = p->second;
    if (pGeom == nullptr) {
      m_mapFileToGeometry.erase(p);
      return LoadMilkshapeAscii(sFile, bNeedNormals);
    }
    if (pGeom->m_iRefCount == std::numeric_limits<int>::max()) {
      RageException::Throw(
          "Model geometry \"%s\" reference count overflow.", sFile.c_str());
    }
    ++pGeom->m_iRefCount;
    return pGeom;
  }

  std::unique_ptr<RageModelGeometry> pGeom(new RageModelGeometry);
  pGeom->LoadMilkshapeAscii(key.first, bNeedNormals);

  RageModelGeometry* raw = pGeom.release();
  m_mapFileToGeometry[key] = raw;
  return raw;
}

void ModelManager::UnloadModel(RageModelGeometry* m) {
  if (m == nullptr) {
    return;
  }

  std::map<GeometryCacheKey, RageModelGeometry*>::iterator cached =
      m_mapFileToGeometry.end();
  for (auto i = m_mapFileToGeometry.begin(); i != m_mapFileToGeometry.end();
       ++i) {
    if (i->second == m) {
      cached = i;
      break;
    }
  }
  if (cached == m_mapFileToGeometry.end()) {
    if (LOG != nullptr) {
      LOG->Warn(
          "ignored uncached model geometry pointer %p.",
          static_cast<void*>(m));
    }
    return;
  }

  if (m->m_iRefCount <= 0) {
    if (LOG != nullptr) {
      LOG->Warn("duplicate unload of model geometry %p.",
                static_cast<void*>(m));
    }
    return;
  }
  m->m_iRefCount--;

  if (m->m_iRefCount) {
    return; /* Can't unload models that are still referenced. */
  }

  if (m_Prefs.m_bDelayedUnload) {
    return;
  }
  m_mapFileToGeometry.erase(cached);
  RageUtil::SafeDelete(m);
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
