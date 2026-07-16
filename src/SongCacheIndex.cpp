#include "SongCacheIndex.h"

#include <cctype>
#include <cstddef>
#include <string>
#include <vector>

#include "CommonMetrics.h"
#include "CryptManager.h"
#include "RageFileManager.h"
#include "RageLog.h"
#include "RageThreads.h"
#include "RageUtil.h"
#include "Song.h"
#include "SpecialFiles.h"
#include "StdString.h"
#include "global.h"

/*
 * A quick explanation of song cache hashes: Each song has two hashes; a hash of
 * the song path, and a hash of the song directory.  The former is
 * Song::GetCacheFilePath; it stays the same if the contents of the directory
 * change.  The latter is GetHashForDirectory(m_sSongDir), and changes on each
 * modification.
 *
 * The file hash is used as the cache filename.  We don't want to use the
 * directory hash: if we do that, then we'll write a new cache file every time
 * the song changes, and they'll accumulate or we'll have to be careful to
 * delete them.
 *
 * The directory hash is stored in here, indexed by the song path, and used to
 * determine if a song has changed.
 *
 * Another advantage of this system is that we can load songs from cache given
 * only their path; we don't have to actually look in the directory (to find out
 * the directory hash) in order to find the cache file.
 */
#define CACHE_INDEX SpecialFiles::CACHE_DIR + "index.cache"

SongCacheIndex*
    SONGINDEX;  // global and accessible from anywhere in our program

static std::string NormalizeCacheKeyPath(std::string sPath) {
  FixSlashesInPlace(sPath);
  CollapsePath(sPath, true);

  if (sPath.size() > 1 && sPath[0] == '/') {
    sPath.erase(0, 1);
  }
  while (sPath.size() > 1 && sPath[sPath.size() - 1] == '/') {
    sPath.erase(sPath.size() - 1);
  }

  return sPath;
}

static std::string NormalizeCacheGroupName(const std::string& sGroup) {
  std::string sNormalized;
  sNormalized.reserve(sGroup.size());

  for (char c : sGroup) {
    const unsigned char uc = static_cast<unsigned char>(c);
    if (std::isalnum(uc) || c == '_' || c == '-') {
      sNormalized.push_back(c);
    } else {
      sNormalized.push_back('_');
    }
  }

  if (sNormalized.empty()) {
    sNormalized = "General";
  }
  if (sNormalized != sGroup) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-633: sanitized cache group '%s' to '%s'.",
        sGroup.c_str(), sNormalized.c_str());
  }

  return sNormalized;
}

std::string SongCacheIndex::GetCacheFilePath(
    const std::string& sGroup, const std::string& sPath) {
  /* Don't use GetHashForFile, since we don't want to spend time
   * checking the file size and date. */
  const std::string s = NormalizeCacheKeyPath(sPath);

  // Cache filenames must be a lossless mapping from song/course/image paths.
  // Replacing separators with '_' makes paths like foo/bar_baz and foo_bar/baz
  // collide, so use a stable filename-safe digest of the normalized path.
  const std::string sCacheName =
      BinaryToHex(CryptManager::GetSHA1ForString(s));
  const std::string sSafeGroup = NormalizeCacheGroupName(sGroup);
  // CACHE_DIR ends with a /.
  return ssprintf(
      "%s%s/%s", SpecialFiles::CACHE_DIR.c_str(), sSafeGroup.c_str(),
      sCacheName.c_str());
}

SongCacheIndex::SongCacheIndex()
    : Mutex("SongCacheIndex"), m_bDelaySaveCache(false) {
  LOG->Trace(
      "SRC_AUDIT_FIX: SongCacheIndex initialized with SHA1 cache key mapping "
      "and delay_save_cache=false.");
  ReadCacheIndex();
}

SongCacheIndex::~SongCacheIndex() {
  if (LOG) {
    LOG->Trace("SongCacheIndex::~SongCacheIndex begin");
  }
  if (LOG) {
    LOG->Trace("SongCacheIndex::~SongCacheIndex end");
  }
}

void SongCacheIndex::ReadFromDisk() { ReadCacheIndex(); }

static void EmptyDir(std::string dir) {
  if (FILEMAN == nullptr) {
    LOG->Warn("SRC_AUDIT_FIX: refused to purge cache without FileManager.");
    return;
  }
  if (dir.empty()) {
    LOG->Warn("SRC_AUDIT_FIX SRC-634: refused to empty an empty cache path.");
    return;
  }
  FixSlashesInPlace(dir);
  if (dir[dir.size() - 1] != '/') {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-634: cache path '%s' lacked trailing slash; "
        "normalizing before purge.",
        dir.c_str());
    dir += '/';
  }

  std::vector<std::string> asCacheFileNames;
  GetDirListing(dir, asCacheFileNames);
  for (unsigned i = 0; i < asCacheFileNames.size(); i++) {
    const std::string sCachePath = dir + asCacheFileNames[i];
    if (!IsADirectory(sCachePath) && !FILEMAN->Remove(sCachePath)) {
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-635: failed to remove stale cache file '%s'.",
          sCachePath.c_str());
    }
  }
}

void SongCacheIndex::ReadCacheIndex() {
  LockMutex L(Mutex);

  const std::string sCacheIndexPath = CACHE_INDEX;
  CacheIndex.Clear();
  const bool bCacheIndexExists = DoesFileExist(sCacheIndexPath);
  if (!CacheIndex.ReadFile(sCacheIndexPath)) {
    LOG->Trace(
        "SRC_AUDIT_FIX SRC-630: cache index '%s' could not be read%s%s.",
        sCacheIndexPath.c_str(), bCacheIndexExists ? ": " : "",
        bCacheIndexExists ? CacheIndex.GetError().c_str()
                          : " because it does not exist yet");
    if (bCacheIndexExists) {
      LOG->Warn(
          "SRC_AUDIT_FIX: preserving cache files after unreadable cache "
          "index '%s'.",
          sCacheIndexPath.c_str());
      return;
    }
  }

  int iCacheVersion = -1;
  CacheIndex.GetValue("Cache", "CacheVersion", iCacheVersion);
  if (iCacheVersion == FILE_CACHE_VERSION) {
    return;  // OK
  }

  LOG->Trace("Cache format is out of date.  Deleting all cache files.");
  EmptyDir(SpecialFiles::CACHE_DIR);
  EmptyDir(SpecialFiles::CACHE_DIR + "Songs/");
  EmptyDir(SpecialFiles::CACHE_DIR + "Courses/");

  std::vector<std::string> ImageDir;
  split(CommonMetrics::IMAGES_TO_CACHE, ",", ImageDir);
  for (unsigned c = 0; c < ImageDir.size(); c++) {
    EmptyDir(
        SpecialFiles::CACHE_DIR + NormalizeCacheGroupName(ImageDir[c]) + "/");
  }

  CacheIndex.Clear();
  /* This is right now in place because our song file paths are apparently being
   * cached in two distinct areas, and songs were loading from paths in FILEMAN.
   * This is admittedly a hack for now, but this does bring up a good question
   * on whether we really need a dedicated cache for future versions of
   * StepMania.
   */
  FILEMAN->FlushDirCache();
}

void SongCacheIndex::SaveCacheIndex() {
  LockMutex L(Mutex);
  const std::string sCacheIndexPath = CACHE_INDEX;
  if (!CacheIndex.WriteFile(sCacheIndexPath)) {
    LOG->Warn(
        "SRC_AUDIT_FIX SRC-631: failed to save cache index '%s': %s",
        sCacheIndexPath.c_str(), CacheIndex.GetError().c_str());
  }
}

void SongCacheIndex::AddCacheIndex(const std::string& path, unsigned hash) {
  LockMutex L(Mutex);
  if (hash == 0) {
    ++hash; /* no 0 hash values */
  }
  CacheIndex.SetValue("Cache", "CacheVersion", FILE_CACHE_VERSION);
  CacheIndex.SetValue("Cache", MangleName(path), hash);
  if (!m_bDelaySaveCache) {
    const std::string sCacheIndexPath = CACHE_INDEX;
    if (!CacheIndex.WriteFile(sCacheIndexPath)) {
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-631: failed to save cache index '%s' after "
          "adding '%s': %s",
          sCacheIndexPath.c_str(), path.c_str(), CacheIndex.GetError().c_str());
    }
  }
}

unsigned SongCacheIndex::GetCacheHash(const std::string& path) const {
  LockMutex L(Mutex);
  unsigned iDirHash = 0;
  if (!CacheIndex.GetValue("Cache", MangleName(path), iDirHash)) {
    return 0;
  }
  if (iDirHash == 0) {
    ++iDirHash; /* no 0 hash values */
  }
  return iDirHash;
}

bool SongCacheIndex::GetDelaySaveCache() const {
  LockMutex L(Mutex);
  return m_bDelaySaveCache;
}

void SongCacheIndex::SetDelaySaveCache(bool bDelay) {
  LockMutex L(Mutex);
  m_bDelaySaveCache = bDelay;
}

std::string SongCacheIndex::MangleName(const std::string& Name) {
  // Store cache index paths under filename-safe, collision-resistant INI keys.
  return BinaryToHex(
      CryptManager::GetSHA1ForString(NormalizeCacheKeyPath(Name)));
}

/*
 * (c) 2002-2003 Glenn Maynard
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
