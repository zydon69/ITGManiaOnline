#include "GameSoundManager.h"

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cmath>
#include <cstddef>
#include <limits>
#include <map>
#include <memory>
#include <new>
#include <set>
#include <string>
#include <unordered_set>
#include <utility>
#include <vector>

#include "AnnouncerManager.h"
#include "EnumHelper.h"
#include "GameConstantsAndTypes.h"
#include "GameState.h"
#include "LightsManager.h"
#include "LuaManager.h"
#include "MessageManager.h"
#include "NoteData.h"
#include "NoteTypes.h"
#include "NotesLoaderSM.h"
#include "NotesLoaderSSC.h"
#include "PerfDiagnostics.h"
#include "PlayerNumber.h"
#include "Preference.h"
#include "PrefsManager.h"
#include "RageDisplay.h"
#include "RageFileManager.h"
#include "RageLog.h"
#include "RageSound.h"
#include "RageSoundManager.h"
#include "RageTimer.h"
#include "RageThreads.h"
#include "RageUtil.h"
#include "RageUtil/RandomNumbers.h"
#include "Song.h"
#include "SongUtil.h"
#include "StdString.h"
#include "Steps.h"
#include "Style.h"
#include "TimingData.h"
#include "TimingSegments.h"
#include "arch/Sound/RageSoundDriver.h"
#include "global.h"

GameSoundManager* SOUND = nullptr;

/*
 * When playing music, automatically search for an SM file for timing data.  If
 * one is found, automatically handle GAMESTATE->m_fSongBeat, etc.
 *
 * std::modf(GAMESTATE->m_fSongBeat) should always be continuously moving from 0
 * to 1.  To do this, wait before starting a sound until the fractional portion
 * of the beat will be the same.
 *
 * If PlayMusic(fLengthSeconds) is set, peek at the beat, and extend the length
 * so we'll be on the same fractional beat when we loop.
 */

/* Lock this before touching g_UpdatingTimer or g_Playing. */
static RageEvent* g_Mutex;
static bool g_UpdatingTimer;
static std::atomic<bool> g_Shutdown{true};
static bool g_bFlushing = false;

enum FadeState { FADE_NONE, FADE_OUT, FADE_WAIT, FADE_IN };
static FadeState g_FadeState = FADE_NONE;
static float g_fDimVolume = 1.0f;
static float g_fOriginalVolume = 1.0f;
static float g_fDimDurationRemaining = 0.0f;
static bool g_bWasPlayingOnLastUpdate = false;

struct MusicPlaying {
  bool m_bTimingDelayed;
  bool m_bHasTiming;
  bool m_bApplyMusicRate;
  // The timing data that we're currently using.
  TimingData m_Timing;
  NoteData m_Lights;

  /* If m_bTimingDelayed is true, this will be the timing data for the
   * song that's starting. We'll copy it to m_Timing once sound is heard. */
  TimingData m_NewTiming;
  RageSound* m_Music;
  MusicPlaying(RageSound* Music) {
    m_Timing.AddSegment(BPMSegment(0, 120));
    m_NewTiming.AddSegment(BPMSegment(0, 120));
    m_bHasTiming = false;
    m_bTimingDelayed = false;
    m_bApplyMusicRate = false;
    m_Music = Music;
  }

  ~MusicPlaying() {
    if (LOG && LogPlayOnceDiagnosticsEnabled()) {
      LOG->Trace(
        "MusicPlaying::~MusicPlaying begin ptr=%p music_ptr=%p loaded=%d "
        "playing=%d path='%s'",
        static_cast<void*>(this), static_cast<void*>(m_Music),
        m_Music != nullptr && m_Music->IsLoaded() ? 1 : 0,
        m_Music != nullptr && m_Music->IsPlaying() ? 1 : 0,
        m_Music != nullptr ? m_Music->GetLoadedFilePath().c_str() : "");
    }
    delete m_Music;
    if (LOG && LogPlayOnceDiagnosticsEnabled()) {
      LOG->Trace(
          "MusicPlaying::~MusicPlaying end ptr=%p", static_cast<void*>(this));
    }
  }
};

static MusicPlaying* g_Playing;

static RageThread MusicThread;

std::vector<std::string> g_SoundsToPlayOnce;
std::vector<std::string> g_SoundsToPlayOnceFromDir;
std::vector<std::string> g_SoundsToPlayOnceFromAnnouncer;
// This should get updated to unordered_map when once C++11 is supported
std::map<std::string, std::vector<int>> g_DirSoundOrder;
std::map<std::string, std::vector<RageSound*>> g_PlayOnceSoundPool;
std::map<std::string, uint64_t> g_PlayOnceSoundLastUse;
std::map<std::string, size_t> g_PlayOnceSoundEstimatedBytes;
std::set<RageSound*> g_PlayOnceReservedSounds;

struct PlayOnceInvalidPathEntry {
  uint64_t useCounter = 0;
  uint64_t timestampUsec = 0;
  int fileSize = -1;
};
std::map<std::string, PlayOnceInvalidPathEntry> g_PlayOnceSoundInvalidPath;

static Preference<int> g_iPlayOncePoolVoices("PlayOncePoolVoices", 8);
static Preference<int> g_iPlayOnceMaxPools("PlayOnceMaxPools", 96);
static Preference<int> g_iPlayOnceMaxCacheMB("PlayOnceMaxCacheMB", 96);
constexpr size_t kPlayOnceInvalidPathMaxEntries = 256;
constexpr uint64_t kPlayOnceInvalidPathTtlUses = 2000;
constexpr uint64_t kPlayOnceInvalidPathTtlUsec = 5000000;
constexpr size_t kPlayOnceVoiceOverheadBytes = 32 * 1024;
constexpr size_t kMaxQueuedSounds = 4096;
constexpr size_t kMaxQueuedPathLength = 4096;
constexpr float kMaxDimVolume = 16.0f;

static bool HasSoundQueueRuntime() {
  return g_Mutex != nullptr && !g_Shutdown.load(std::memory_order_acquire);
}

static bool HasCurrentMusic() {
  return g_Playing != nullptr && g_Playing->m_Music != nullptr;
}

static float SanitizeNonNegativeSeconds(float value, float fallback = 0.0f) {
  if (!std::isfinite(value)) {
    return fallback;
  }
  return std::max(0.0f, value);
}

static float SanitizeLengthSeconds(float value) {
  if (!std::isfinite(value) || value < 0.0f) {
    return -1.0f;
  }
  return value;
}

static float SanitizeVolume(float value, float fallback = 1.0f) {
  if (!std::isfinite(value)) {
    return fallback;
  }
  return std::max(0.0f, std::min(kMaxDimVolume, value));
}

template <class T>
static bool EnqueueBounded(std::vector<T>& queue, const T& value) {
  if (!HasSoundQueueRuntime()) {
    return false;
  }
  if (queue.size() >= kMaxQueuedSounds) {
    if (LOG != nullptr) {
      LOG->Warn("GameSoundManager queue full; dropping queued sound request");
    }
    return false;
  }
  queue.push_back(value);
  g_Mutex->Broadcast();
  return true;
}

static uint64_t g_PlayOnceDroppedBusyCount = 0;
static uint64_t g_PlayOnceDroppedPoolFullCount = 0;
static uint64_t g_PlayOnceDroppedMemoryBudgetCount = 0;
static uint64_t g_PlayOnceEvictedPoolCount = 0;
static uint64_t g_PlayOnceInvalidLoadCount = 0;
static size_t g_PlayOnceEstimatedCacheBytes = 0;
static float g_PlayOnceStatsLogTimer = 0.0f;

static std::string g_PlayOnceThemeCacheKey;
static std::string g_PlayOnceAnnouncerCacheKey;
static RageMutex g_PlayOnceDataMutex("PlayOnceData");
static bool g_bPlayOnceDebugToolsEnabled = false;
static bool g_bLoggedPlayOnceDebugToolsDenied = false;

static size_t GetPlayOnceMaxCacheBytes() {
  const int maxCacheMb = std::max(1, g_iPlayOnceMaxCacheMB.Get());
  return static_cast<size_t>(maxCacheMb) * 1024 * 1024;
}

static int GetPlayOnceFileSize(const std::string& path) {
  return FILEMAN != nullptr ? FILEMAN->GetFileSizeInBytes(path) : -1;
}

static bool IsKnownSilentPlaceholderSound(const std::string& path) {
  std::string basename = Basename(path);
  MakeLower(basename);
  return basename == "_silence" || basename == "_silence.ogg" ||
         basename == "_silence.wav" || basename == "silence" ||
         basename == "silence.ogg" || basename == "silence.wav";
}

static void DeleteSoundWithShutdownTrace(
    RageSound* sound, const char* context, size_t index, size_t total);

static void DeleteUnregisteredSoundPool(std::vector<RageSound*>& pool) {
  std::unordered_set<RageSound*> deletedSounds;
  for (size_t i = 0; i < pool.size(); ++i) {
    RageSound* sound = pool[i];
    if (sound == nullptr) {
      continue;
    }
    if (!deletedSounds.insert(sound).second) {
      if (LOG != nullptr) {
        LOG->Warn(
            "skipped duplicate unregistered PlayOnce sound %p.",
            static_cast<void*>(sound));
      }
      continue;
    }
    DeleteSoundWithShutdownTrace(
        sound, "unregistered_pool", i + 1, pool.size());
  }
  pool.clear();
}

static void DeleteSoundWithShutdownTrace(
    RageSound* sound, const char* context, size_t index, size_t total) {
  const bool trace = LogPlayOnceDiagnosticsEnabled();
  if (sound == nullptr) {
    if (trace) {
      if (LOG != nullptr) {
        LOG->Trace(
            "GameSoundManager shutdown delete sound skipped null context=%s "
            "index=%zu/%zu",
            context, index, total);
      }
    }
    return;
  }

  if (trace && LOG != nullptr) {
    LOG->Trace(
        "GameSoundManager shutdown delete sound begin context=%s index=%zu/%zu "
        "ptr=%p loaded=%d playing=%d path='%s'",
        context, index, total, static_cast<void*>(sound),
        sound->IsLoaded() ? 1 : 0, sound->IsPlaying() ? 1 : 0,
        sound->GetLoadedFilePath().c_str());
  }
  delete sound;
  if (trace && LOG != nullptr) {
    LOG->Trace(
        "GameSoundManager shutdown delete sound end context=%s index=%zu/%zu",
        context, index, total);
  }
}

static void DeleteRegisteredSoundPool(std::vector<RageSound*>& pool) {
  // Caller must hold g_PlayOnceDataMutex because registered pools can have
  // entries in g_PlayOnceReservedSounds.
  std::unordered_set<RageSound*> deletedSounds;
  for (size_t i = 0; i < pool.size(); ++i) {
    RageSound* sound = pool[i];
    if (sound == nullptr) {
      continue;
    }
    if (!deletedSounds.insert(sound).second) {
      if (LOG != nullptr) {
        LOG->Warn(
            "skipped duplicate registered PlayOnce sound %p.",
            static_cast<void*>(sound));
      }
      continue;
    }
    g_PlayOnceReservedSounds.erase(sound);
    DeleteSoundWithShutdownTrace(sound, "registered_pool", i + 1, pool.size());
  }
  pool.clear();
}

static std::vector<RageSound*> DetachPlayOnceCacheForShutdown() {
  std::vector<RageSound*> soundsToDelete;
  std::unordered_set<RageSound*> queuedSounds;

  LockMutex playOnceLock(g_PlayOnceDataMutex);
  if (LOG != nullptr && LogPlayOnceDiagnosticsEnabled()) {
    LOG->Trace(
        "GameSoundManager shutdown PlayOnce detach begin pools=%zu reserved=%zu "
        "estimated_bytes=%zu invalid_cache=%zu",
        g_PlayOnceSoundPool.size(), g_PlayOnceReservedSounds.size(),
        g_PlayOnceEstimatedCacheBytes, g_PlayOnceSoundInvalidPath.size());
  }

  for (auto& pathAndPool : g_PlayOnceSoundPool) {
    for (RageSound* sound : pathAndPool.second) {
      if (sound == nullptr) {
        continue;
      }
      if (queuedSounds.insert(sound).second) {
        soundsToDelete.push_back(sound);
      } else {
        if (LOG != nullptr) {
          LOG->Warn(
              "skipped duplicate PlayOnce sound %p while "
              "detaching shutdown cache path='%s'.",
              static_cast<void*>(sound), pathAndPool.first.c_str());
        }
      }
    }
    pathAndPool.second.clear();
  }

  g_PlayOnceSoundPool.clear();
  g_PlayOnceSoundLastUse.clear();
  g_PlayOnceSoundEstimatedBytes.clear();
  g_PlayOnceReservedSounds.clear();
  g_PlayOnceSoundInvalidPath.clear();
  g_DirSoundOrder.clear();
  g_PlayOnceEstimatedCacheBytes = 0;

  if (LOG != nullptr && LogPlayOnceDiagnosticsEnabled()) {
    LOG->Trace(
        "GameSoundManager shutdown PlayOnce detach end sounds_to_delete=%zu",
        soundsToDelete.size());
  }
  return soundsToDelete;
}

static bool IsPoolIdle(const std::vector<RageSound*>& pool) {
  for (RageSound* sound : pool) {
    if (g_PlayOnceReservedSounds.find(sound) != g_PlayOnceReservedSounds.end()) {
      return false;
    }
    if (sound != nullptr && sound->IsPlayingThreadSafe()) {
      return false;
    }
  }
  return true;
}

static bool EvictOldestIdlePlayOncePool() {
  // Caller must hold g_PlayOnceDataMutex.
  std::string pathToEvict;
  uint64_t oldestUse = UINT64_MAX;
  for (const auto& pathAndPool : g_PlayOnceSoundPool) {
    if (!IsPoolIdle(pathAndPool.second)) {
      continue;
    }
    const auto useIt = g_PlayOnceSoundLastUse.find(pathAndPool.first);
    const uint64_t lastUse = (useIt == g_PlayOnceSoundLastUse.end())
                                 ? 0
                                 : useIt->second;
    if (lastUse < oldestUse) {
      oldestUse = lastUse;
      pathToEvict = pathAndPool.first;
    }
  }

  if (pathToEvict.empty()) {
    return false;
  }

  auto poolIt = g_PlayOnceSoundPool.find(pathToEvict);
  if (poolIt != g_PlayOnceSoundPool.end()) {
    const auto bytesIt = g_PlayOnceSoundEstimatedBytes.find(pathToEvict);
    if (bytesIt != g_PlayOnceSoundEstimatedBytes.end()) {
      g_PlayOnceEstimatedCacheBytes -=
          std::min(g_PlayOnceEstimatedCacheBytes, bytesIt->second);
      g_PlayOnceSoundEstimatedBytes.erase(bytesIt);
    }
    DeleteRegisteredSoundPool(poolIt->second);
    g_PlayOnceSoundPool.erase(poolIt);
    ++g_PlayOnceEvictedPoolCount;
  }
  g_PlayOnceSoundLastUse.erase(pathToEvict);
  return true;
}

static size_t CountEmptyPlayOncePools() {
  // Caller must hold g_PlayOnceDataMutex.
  size_t emptyPools = 0;
  for (const auto& pathAndPool : g_PlayOnceSoundPool) {
    if (pathAndPool.second.empty()) {
      ++emptyPools;
    }
  }
  return emptyPools;
}

static void RemovePlayOncePoolAccounting(const std::string& path) {
  // Caller must hold g_PlayOnceDataMutex.
  const auto bytesIt = g_PlayOnceSoundEstimatedBytes.find(path);
  if (bytesIt != g_PlayOnceSoundEstimatedBytes.end()) {
    g_PlayOnceEstimatedCacheBytes -=
        std::min(g_PlayOnceEstimatedCacheBytes, bytesIt->second);
    g_PlayOnceSoundEstimatedBytes.erase(bytesIt);
  }
  g_PlayOnceSoundLastUse.erase(path);
}

static void PruneInvalidPathCache(uint64_t useCounter) {
  // Caller must hold g_PlayOnceDataMutex.
  const uint64_t nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
  for (auto it = g_PlayOnceSoundInvalidPath.begin();
       it != g_PlayOnceSoundInvalidPath.end();) {
    if ((useCounter > it->second.useCounter &&
         useCounter - it->second.useCounter > kPlayOnceInvalidPathTtlUses) ||
        nowUsec - it->second.timestampUsec > kPlayOnceInvalidPathTtlUsec) {
      it = g_PlayOnceSoundInvalidPath.erase(it);
    } else {
      ++it;
    }
  }

  while (g_PlayOnceSoundInvalidPath.size() > kPlayOnceInvalidPathMaxEntries) {
    auto oldestIt = g_PlayOnceSoundInvalidPath.begin();
    for (auto it = g_PlayOnceSoundInvalidPath.begin();
         it != g_PlayOnceSoundInvalidPath.end(); ++it) {
      if (it->second.timestampUsec < oldestIt->second.timestampUsec) {
        oldestIt = it;
      }
    }
    g_PlayOnceSoundInvalidPath.erase(oldestIt);
  }
}

static bool IsInvalidPathCached(const std::string& path, uint64_t useCounter) {
  // Caller must hold g_PlayOnceDataMutex.
  const auto it = g_PlayOnceSoundInvalidPath.find(path);
  if (it == g_PlayOnceSoundInvalidPath.end()) {
    return false;
  }

  const int currentFileSize = GetPlayOnceFileSize(path);
  const bool fileAppearedOrChanged =
      currentFileSize >= 0 && currentFileSize != it->second.fileSize;
  const uint64_t nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
  if (fileAppearedOrChanged ||
      (useCounter > it->second.useCounter &&
       useCounter - it->second.useCounter > kPlayOnceInvalidPathTtlUses) ||
      nowUsec - it->second.timestampUsec > kPlayOnceInvalidPathTtlUsec) {
    g_PlayOnceSoundInvalidPath.erase(it);
    return false;
  }
  return true;
}

static void MarkInvalidPath(const std::string& path, uint64_t useCounter) {
  // Caller must hold g_PlayOnceDataMutex.
  PlayOnceInvalidPathEntry entry;
  entry.useCounter = useCounter;
  entry.timestampUsec = RageTimer::GetTimeSinceStartMicroseconds();
  entry.fileSize = GetPlayOnceFileSize(path);
  g_PlayOnceSoundInvalidPath[path] = entry;
  ++g_PlayOnceInvalidLoadCount;
  PruneInvalidPathCache(useCounter);
}

static size_t EstimatePlayOncePoolBytes(
    const std::string& path, const std::vector<RageSound*>& pool) {
  size_t decodedBytes = 0;
  if (!pool.empty() && pool[0] != nullptr) {
    const float lengthSeconds = pool[0]->GetLengthSeconds();
    if (lengthSeconds > 0.0f && SOUNDMAN != nullptr) {
      const double frames =
          static_cast<double>(lengthSeconds) * SOUNDMAN->GetDriverSampleRate();
      const double bytes = frames * 2.0 * sizeof(float);
      if (bytes > 0.0 &&
          bytes < static_cast<double>(std::numeric_limits<size_t>::max())) {
        decodedBytes = static_cast<size_t>(bytes);
      }
    }
  }

  const int fileBytes = GetPlayOnceFileSize(path);
  if (fileBytes > 0) {
    decodedBytes = std::max(decodedBytes, static_cast<size_t>(fileBytes));
  }

  if (decodedBytes == 0) {
    decodedBytes = 256 * 1024;
  }

  return decodedBytes + pool.size() * kPlayOnceVoiceOverheadBytes;
}

static void RefreshPlayOnceRuntimeCacheKeys() {
  // Caller must hold g_PlayOnceDataMutex.
  const std::string curTheme = THEME ? THEME->GetCurThemeName() : "";
  const std::string curAnnouncer = ANNOUNCER ? ANNOUNCER->GetCurAnnouncerName()
                                             : "";
  if (curTheme != g_PlayOnceThemeCacheKey ||
      curAnnouncer != g_PlayOnceAnnouncerCacheKey) {
    g_PlayOnceThemeCacheKey = curTheme;
    g_PlayOnceAnnouncerCacheKey = curAnnouncer;
    g_PlayOnceSoundInvalidPath.clear();
  }
}

struct MusicToPlay {
  std::string m_sFile, m_sTimingFile;
  bool HasTiming;
  TimingData m_TimingData;
  NoteData m_LightsData;
  bool bForceLoop;
  float fStartSecond, fLengthSeconds, fFadeInLengthSeconds,
      fFadeOutLengthSeconds;
  bool bAlignBeat, bApplyMusicRate;
  MusicToPlay()
      : HasTiming(false),
        bForceLoop(false),
        fStartSecond(0.0f),
        fLengthSeconds(-1.0f),
        fFadeInLengthSeconds(0.0f),
        fFadeOutLengthSeconds(0.0f),
        bAlignBeat(true),
        bApplyMusicRate(false) {}
};
std::vector<MusicToPlay> g_MusicsToPlay;
static GameSoundManager::PlayMusicParams g_FallbackMusicParams;

static void StartMusic(MusicToPlay& ToPlay) {
  if (!HasSoundQueueRuntime() || !HasCurrentMusic()) {
    return;
  }

  ToPlay.fStartSecond = SanitizeNonNegativeSeconds(ToPlay.fStartSecond);
  ToPlay.fLengthSeconds = SanitizeLengthSeconds(ToPlay.fLengthSeconds);
  ToPlay.fFadeInLengthSeconds =
      SanitizeNonNegativeSeconds(ToPlay.fFadeInLengthSeconds);
  ToPlay.fFadeOutLengthSeconds =
      SanitizeNonNegativeSeconds(ToPlay.fFadeOutLengthSeconds);

  g_Mutex->Lock();
  if (!HasCurrentMusic()) {
    g_Mutex->Unlock();
    return;
  }
  if (g_Playing->m_Music->IsPlaying() &&
      EqualsNoCase(g_Playing->m_Music->GetLoadedFilePath(), ToPlay.m_sFile)) {
    g_Mutex->Unlock();
    return;
  }

  /* We're changing or stopping the music.  If we were dimming, reset. */
  g_FadeState = FADE_NONE;

  if (ToPlay.m_sFile.empty()) {
    /* StopPlaying() can take a while, so don't hold the lock while we stop the
     * sound. Be sure to leave the rest of g_Playing in place. */
    RageSound* pOldSound = g_Playing->m_Music;
    g_Playing->m_Music = new RageSound;
    g_Mutex->Unlock();

    delete pOldSound;
    return;
  }

  /* Unlock, load the sound here, and relock.  Loading may take a while if we're
   * reading from CD and we have to seek far, which can throw off the timing
   * below. */
  std::unique_ptr<MusicPlaying> NewMusic;
  {
    g_Mutex->Unlock();
    std::unique_ptr<RageSound> pSound(new RageSound);
    RageSoundLoadParams params;
    params.m_bSupportRateChanging = ToPlay.bApplyMusicRate;
    if (!pSound->Load(ToPlay.m_sFile, false, &params)) {
      if (LOG != nullptr) {
        LOG->Warn(
            "Music load failed; refusing to start silent fallback: '%s' "
            "error='%s'",
            ToPlay.m_sFile.c_str(), pSound->GetError().c_str());
      }
      return;
    }
    std::unique_ptr<MusicPlaying> loadedMusic(
        new MusicPlaying(pSound.release()));

    /* Parsing a simfile can perform filesystem IO.  Keep it outside the global
     * sound queue lock, just like the audio load above. */
    if (!ToPlay.HasTiming && IsAFile(ToPlay.m_sTimingFile)) {
      if (LOG != nullptr) {
        LOG->Trace("Found '%s'", ToPlay.m_sTimingFile.c_str());
      }
      Song song;
      SSCLoader loaderSSC;
      SMLoader loaderSM;
      if (GetExtension(ToPlay.m_sTimingFile) == ".ssc" &&
          loaderSSC.LoadFromSimfile(ToPlay.m_sTimingFile, song)) {
        ToPlay.HasTiming = true;
        ToPlay.m_TimingData = song.m_SongTiming;
        Steps* pStepsCabinetLights =
            SongUtil::GetOneSteps(&song, StepsType_lights_cabinet);
        if (pStepsCabinetLights) {
          pStepsCabinetLights->GetNoteData(ToPlay.m_LightsData);
        }
      } else if (
          GetExtension(ToPlay.m_sTimingFile) == ".sm" &&
          loaderSM.LoadFromSimfile(ToPlay.m_sTimingFile, song)) {
        ToPlay.HasTiming = true;
        ToPlay.m_TimingData = song.m_SongTiming;
        Steps* pStepsCabinetLights =
            SongUtil::GetOneSteps(&song, StepsType_lights_cabinet);
        if (pStepsCabinetLights) {
          pStepsCabinetLights->GetNoteData(ToPlay.m_LightsData);
        }
      }
    }

    g_Mutex->Lock();
    NewMusic = std::move(loadedMusic);
    if (!HasCurrentMusic()) {
      g_Mutex->Unlock();
      return;
    }
  }

  NewMusic->m_Timing = g_Playing->m_Timing;
  NewMusic->m_Lights = g_Playing->m_Lights;

  if (ToPlay.HasTiming) {
    NewMusic->m_NewTiming = ToPlay.m_TimingData;
    NewMusic->m_Lights = ToPlay.m_LightsData;
  }

  if (ToPlay.bAlignBeat && ToPlay.HasTiming && ToPlay.bForceLoop &&
      ToPlay.fLengthSeconds != -1) {
    /* Extend the loop period so it always starts and ends on the same
     * fractional beat.  That is, if it starts on beat 1.5, and ends on
     * beat 10.2, extend it to end on beat 10.5.  This way, effects always loop
     * cleanly. */
    float fStartBeat = NewMusic->m_NewTiming.GetBeatFromElapsedTimeNoOffset(
        ToPlay.fStartSecond);
    float fEndSec = ToPlay.fStartSecond + ToPlay.fLengthSeconds;
    float fEndBeat =
        NewMusic->m_NewTiming.GetBeatFromElapsedTimeNoOffset(fEndSec);

    const float fStartBeatFraction = fmodfp(fStartBeat, 1);
    const float fEndBeatFraction = fmodfp(fEndBeat, 1);

    float fBeatDifference = fStartBeatFraction - fEndBeatFraction;
    if (fBeatDifference < 0) {
      fBeatDifference += 1.0f; /* unwrap */
    }

    fEndBeat += fBeatDifference;

    const float fRealEndSec =
        NewMusic->m_NewTiming.GetElapsedTimeFromBeatNoOffset(fEndBeat);
    const float fNewLengthSec = fRealEndSec - ToPlay.fStartSecond;

    /* Extend fFadeOutLengthSeconds, so the added time is faded out. */
    ToPlay.fFadeOutLengthSeconds += fNewLengthSec - ToPlay.fLengthSeconds;
    ToPlay.fLengthSeconds = fNewLengthSec;
  }

  bool StartImmediately = false;
  if (!ToPlay.HasTiming) {
    /* This song has no real timing data.  The offset is arbitrary.  Change it
     * so the beat will line up to where we are now, so we don't have to delay.
     */
    if (GAMESTATE != nullptr) {
      float fDestBeat = fmodfp(GAMESTATE->m_Position.m_fSongBeatNoOffset, 1);
      float fTime =
          NewMusic->m_NewTiming.GetElapsedTimeFromBeatNoOffset(fDestBeat);

      NewMusic->m_NewTiming.m_fBeat0OffsetInSeconds = fTime;
    }

    StartImmediately = true;
  }

  /* If we have an active timer, try to start on the next update.  Otherwise,
   * start now. */
  if (!g_Playing->m_bHasTiming && !g_UpdatingTimer) {
    StartImmediately = true;
  }
  if (!ToPlay.bAlignBeat) {
    StartImmediately = true;
  }

  RageTimer when; /* zero */
  if (!StartImmediately && GAMESTATE != nullptr && SOUNDMAN != nullptr &&
      HasCurrentMusic()) {
    /* GetPlayLatency returns the minimum time until a sound starts.  That's
     * common when starting a precached sound, but our sound isn't, so it'll
     * probably take a little longer.  Nudge the latency up. */
    const float fPresumedLatency = SOUNDMAN->GetPlayLatency() + 0.040f;
    const float fCurSecond =
        GAMESTATE->m_Position.m_fMusicSeconds + fPresumedLatency;
    const float fCurBeat =
        g_Playing->m_Timing.GetBeatFromElapsedTimeNoOffset(fCurSecond);

    /* The beat that the new sound will start on. */
    const float fStartBeat =
        NewMusic->m_NewTiming.GetBeatFromElapsedTimeNoOffset(
            ToPlay.fStartSecond);
    const float fStartBeatFraction = fmodfp(fStartBeat, 1);

    float fCurBeatToStartOn = std::trunc(fCurBeat) + fStartBeatFraction;
    if (fCurBeatToStartOn < fCurBeat) {
      fCurBeatToStartOn += 1.0f;
    }

    const float fSecondToStartOn =
        g_Playing->m_Timing.GetElapsedTimeFromBeatNoOffset(fCurBeatToStartOn);
    const float fMaximumDistance = 2;
    const float fDistance = std::min(
        fSecondToStartOn - GAMESTATE->m_Position.m_fMusicSeconds,
        fMaximumDistance);

    when = GAMESTATE->m_Position.m_LastBeatUpdate + fDistance;
  } else if (!StartImmediately) {
    StartImmediately = true;
  }

  /* Important: don't hold the mutex while we load and seek the actual sound. */
  g_Mutex->Unlock();
  {
    NewMusic->m_bHasTiming = ToPlay.HasTiming;
    if (ToPlay.HasTiming) {
      NewMusic->m_NewTiming = ToPlay.m_TimingData;
    }
    NewMusic->m_bTimingDelayed = true;
    NewMusic->m_bApplyMusicRate = ToPlay.bApplyMusicRate;
    //		NewMusic->m_Music->Load( ToPlay.m_sFile, false );

    RageSoundParams p;
    p.m_StartSecond = ToPlay.fStartSecond;
    p.m_LengthSeconds = ToPlay.fLengthSeconds;
    p.m_fFadeInSeconds = ToPlay.fFadeInLengthSeconds;
    p.m_fFadeOutSeconds = ToPlay.fFadeOutLengthSeconds;
    p.m_StartTime = when;
    if (ToPlay.bForceLoop) {
      p.StopMode = RageSoundParams::M_LOOP;
    }
    NewMusic->m_Music->SetParams(p);
    NewMusic->m_Music->SetPrefersStrongPrebuffer(true);
    if (!NewMusic->m_Music->StartPlaying()) {
      if (LOG != nullptr) {
        LOG->Warn("Music start failed for '%s'", ToPlay.m_sFile.c_str());
      }
      return;
    }
  }

  LockMut(*g_Mutex);
  if (HasCurrentMusic()) {
    delete g_Playing;
    g_Playing = NewMusic.release();
  }
}

static void DoPlayOnceWithRetry(std::string sPath, bool allowRetry) {
  if (sPath.empty()) {
    return;
  }

  static uint64_t s_PlayOnceUseCounter = 0;
  uint64_t useCounter = 0;
  size_t maxPools = 0;
  int poolVoices = 0;
  bool needsPoolCreate = false;
  {
    LockMutex playOnceLock(g_PlayOnceDataMutex);
    ++s_PlayOnceUseCounter;
    useCounter = s_PlayOnceUseCounter;
    RefreshPlayOnceRuntimeCacheKeys();
    PruneInvalidPathCache(useCounter);
    if (IsInvalidPathCached(sPath, useCounter)) {
      return;
    }

    maxPools = static_cast<size_t>(std::max(1, g_iPlayOnceMaxPools.Get()));
    poolVoices = std::max(1, g_iPlayOncePoolVoices.Get());
    needsPoolCreate =
        (g_PlayOnceSoundPool.find(sPath) == g_PlayOnceSoundPool.end());
  }

  if (FILEMAN != nullptr && !FILEMAN->IsAFile(sPath)) {
    if (LOG != nullptr) {
      LOG->Warn("PlayOnce sound file missing: '%s'", sPath.c_str());
    }
    LockMutex playOnceLock(g_PlayOnceDataMutex);
    MarkInvalidPath(sPath, useCounter);
    return;
  }

  std::vector<RageSound*> newPool;
  size_t newPoolEstimatedBytes = 0;
  if (needsPoolCreate) {
    newPool.reserve(poolVoices);
    for (int i = 0; i < poolVoices; ++i) {
      RageSound* pSound = new RageSound;
      if (!pSound->Load(sPath, true)) {
        if (LOG != nullptr) {
          LOG->Warn("PlayOnce sound preload failed for '%s': %s", sPath.c_str(),
                    pSound->GetError().c_str());
        }
        delete pSound;
        DeleteUnregisteredSoundPool(newPool);
        LockMutex playOnceLock(g_PlayOnceDataMutex);
        MarkInvalidPath(sPath, useCounter);
        return;
      }
      if (pSound->GetLengthSeconds() <= 0.0f &&
          !IsKnownSilentPlaceholderSound(sPath)) {
        if (LOG != nullptr) {
          LOG->Warn(
              "PlayOnce sound rejected because it has no playable audio: '%s'",
              sPath.c_str());
        }
        delete pSound;
        DeleteUnregisteredSoundPool(newPool);
        LockMutex playOnceLock(g_PlayOnceDataMutex);
        MarkInvalidPath(sPath, useCounter);
        return;
      }
      if (pSound->GetLengthSeconds() <= 0.0f) {
        if (LOG != nullptr) {
          LOG->Trace(
              "PlayOnce accepted known silent placeholder: '%s'", sPath.c_str());
        }
      }
      newPool.push_back(pSound);
    }
    newPoolEstimatedBytes = EstimatePlayOncePoolBytes(sPath, newPool);
  }

  LockMutex playOnceLock(g_PlayOnceDataMutex);
  RefreshPlayOnceRuntimeCacheKeys();
  PruneInvalidPathCache(useCounter);
  if (IsInvalidPathCached(sPath, useCounter)) {
    DeleteUnregisteredSoundPool(newPool);
    return;
  }

  auto it = g_PlayOnceSoundPool.find(sPath);
  if (it == g_PlayOnceSoundPool.end()) {
    if (newPool.empty()) {
      // The pool existed during the first check, then was evicted before we
      // could reserve a voice. Retry once so we never insert a permanently empty
      // pool for this path.
      if (allowRetry) {
        playOnceLock.Unlock();
        DoPlayOnceWithRetry(std::move(sPath), false);
        return;
      }

      ++g_PlayOnceDroppedPoolFullCount;
      if (LOG != nullptr) {
        LOG->Warn(
            "PlayOnce pool disappeared before use and retry failed: path='%s'",
            sPath.c_str());
      }
      return;
    }

    const size_t maxCacheBytes = GetPlayOnceMaxCacheBytes();
    if (newPoolEstimatedBytes > maxCacheBytes) {
      ++g_PlayOnceDroppedMemoryBudgetCount;
      if (LOG != nullptr) {
        LOG->Warn(
            "PlayOnce pool rejected by memory budget: path='%s' estimate=%zu "
            "max=%zu",
            sPath.c_str(), newPoolEstimatedBytes, maxCacheBytes);
      }
      DeleteUnregisteredSoundPool(newPool);
      return;
    }

    while (g_PlayOnceSoundPool.size() >= maxPools ||
           g_PlayOnceEstimatedCacheBytes >
               maxCacheBytes - newPoolEstimatedBytes) {
      if (!EvictOldestIdlePlayOncePool()) {
        if (g_PlayOnceSoundPool.size() >= maxPools) {
          ++g_PlayOnceDroppedPoolFullCount;
        } else {
          ++g_PlayOnceDroppedMemoryBudgetCount;
        }
        DeleteUnregisteredSoundPool(newPool);
        return;
      }
    }
    it = g_PlayOnceSoundPool.insert({sPath, std::move(newPool)}).first;
    g_PlayOnceSoundEstimatedBytes[sPath] = newPoolEstimatedBytes;
    g_PlayOnceEstimatedCacheBytes += newPoolEstimatedBytes;
  } else {
    DeleteUnregisteredSoundPool(newPool);
  }

  std::vector<RageSound*>& pool = it->second;
  if (pool.empty()) {
    ++g_PlayOnceDroppedPoolFullCount;
    if (LOG != nullptr) {
      LOG->Warn("PlayOnce invariant violation: empty registered pool for '%s'",
                sPath.c_str());
    }
    RemovePlayOncePoolAccounting(sPath);
    g_PlayOnceSoundPool.erase(it);
    return;
  }

  RageSound* chosen = nullptr;
  for (RageSound* candidate : pool) {
    if (g_PlayOnceReservedSounds.find(candidate) ==
            g_PlayOnceReservedSounds.end() &&
        !candidate->IsPlayingThreadSafe()) {
      chosen = candidate;
      break;
    }
  }

  // All voices are busy: drop this trigger instead of force-stealing a voice.
  if (chosen == nullptr) {
    ++g_PlayOnceDroppedBusyCount;
    g_PlayOnceSoundLastUse[sPath] = useCounter;
    return;
  }

  g_PlayOnceReservedSounds.insert(chosen);
  g_PlayOnceSoundLastUse[sPath] = useCounter;
  playOnceLock.Unlock();

  chosen->Play(false);

  LockMutex releaseLock(g_PlayOnceDataMutex);
  g_PlayOnceReservedSounds.erase(chosen);
}

static void DoPlayOnce(std::string sPath) {
  DoPlayOnceWithRetry(std::move(sPath), true);
}

static void DoPlayOnceFromDir(std::string sPath) {
  if (sPath == "") {
    return;
  }

  // make sure there's a slash at the end of this path
  if (Right(sPath, 1) != "/") {
    sPath += "/";
  }

  std::vector<std::string> arraySoundFiles;
  GetDirListing(sPath + "*.mp3", arraySoundFiles);
  GetDirListing(sPath + "*.wav", arraySoundFiles);
  GetDirListing(sPath + "*.ogg", arraySoundFiles);
  GetDirListing(sPath + "*.oga", arraySoundFiles);

  std::sort(arraySoundFiles.begin(), arraySoundFiles.end());
  arraySoundFiles.erase(
      std::unique(arraySoundFiles.begin(), arraySoundFiles.end()),
      arraySoundFiles.end());

  if (arraySoundFiles.empty()) {
    return;
  } else if (arraySoundFiles.size() == 1) {
    DoPlayOnce(sPath + arraySoundFiles[0]);
    return;
  }

  int index = -1;
  {
    LockMutex playOnceLock(g_PlayOnceDataMutex);
    std::vector<int>& order =
        g_DirSoundOrder.insert({sPath, std::vector<int>()}).first->second;
    order.erase(
        std::remove_if(
            order.begin(), order.end(),
            [&arraySoundFiles](int candidate) {
              return candidate < 0 ||
                     static_cast<size_t>(candidate) >= arraySoundFiles.size();
            }),
        order.end());

    // If order is exhausted, repopulate and reshuffle.
    if (order.empty()) {
      for (int i = 0; i < (int)arraySoundFiles.size(); ++i) {
        order.push_back(i);
      }
      std::shuffle(order.begin(), order.end(), g_RandomNumberGenerator);
    }

    if (order.empty()) {
      return;
    }

    index = order.back();
    order.pop_back();
  }

  if (index >= 0 && static_cast<size_t>(index) < arraySoundFiles.size()) {
    DoPlayOnce(sPath + arraySoundFiles[index]);
  }
}

static bool SoundWaiting() {
  return !g_SoundsToPlayOnce.empty() || !g_SoundsToPlayOnceFromDir.empty() ||
         !g_SoundsToPlayOnceFromAnnouncer.empty() || !g_MusicsToPlay.empty();
}

static void StartQueuedSounds() {
  if (!HasSoundQueueRuntime()) {
    return;
  }
  std::vector<std::string> aSoundsToPlayOnce;
  std::vector<std::string> aSoundsToPlayOnceFromDir;
  std::vector<std::string> aSoundsToPlayOnceFromAnnouncer;
  std::vector<MusicToPlay> aMusicsToPlay;
  {
    LockMut(*g_Mutex);
    aSoundsToPlayOnce.swap(g_SoundsToPlayOnce);
    aSoundsToPlayOnceFromDir.swap(g_SoundsToPlayOnceFromDir);
    aSoundsToPlayOnceFromAnnouncer.swap(g_SoundsToPlayOnceFromAnnouncer);
    aMusicsToPlay.swap(g_MusicsToPlay);
  }

  for (unsigned i = 0; i < aSoundsToPlayOnce.size(); ++i) {
    if (aSoundsToPlayOnce[i] != "") {
      DoPlayOnce(aSoundsToPlayOnce[i]);
    }
  }

  for (unsigned i = 0; i < aSoundsToPlayOnceFromDir.size(); ++i) {
    DoPlayOnceFromDir(aSoundsToPlayOnceFromDir[i]);
  }

  for (unsigned i = 0; i < aSoundsToPlayOnceFromAnnouncer.size(); ++i) {
    std::string sPath = aSoundsToPlayOnceFromAnnouncer[i];
    if (sPath != "" && ANNOUNCER != nullptr) {
      sPath = ANNOUNCER->GetPathTo(sPath);
      DoPlayOnceFromDir(sPath);
    }
  }

  for (unsigned i = 0; i < aMusicsToPlay.size(); ++i) {
    /* Don't bother starting this music if there's another one in the queue
     * after it. */
    /* Actually, it's a little trickier: the editor gives us a stop and then a
     * sound in quick succession; if we ignore the stop, we won't rewind the
     * sound if it was already playing.  We don't want to waste time loading a
     * sound if it's going to be replaced immediately, though.  So, if we have
     * more music in the queue, then forcibly stop the current sound. */
    if (i + 1 == aMusicsToPlay.size()) {
      StartMusic(aMusicsToPlay[i]);
    } else {
      CHECKPOINT_M(ssprintf("Removing old sound at index %d", i));
      /* StopPlaying() can take a while, so don't hold the lock while we stop
       * the sound. */
      std::unique_ptr<RageSound> replacement(new (std::nothrow) RageSound);
      if (!replacement) {
        if (LOG != nullptr) {
          LOG->Warn("GameSoundManager could not allocate a replacement sound");
        }
        continue;
      }

      RageSound* pOldSound = nullptr;
      {
        LockMut(*g_Mutex);
        if (g_Playing != nullptr) {
          pOldSound = g_Playing->m_Music;
          g_Playing->m_Music = replacement.release();
        }
      }

      delete pOldSound;
    }
  }
}

void GameSoundManager::Flush() {
  if (g_Mutex == nullptr) {
    return;
  }
  g_Mutex->Lock();
  if (g_Shutdown.load(std::memory_order_acquire)) {
    g_Mutex->Unlock();
    return;
  }
  g_bFlushing = true;

  g_Mutex->Broadcast();

  RageTimer timeout;
  timeout += 5.0f;
  while (g_bFlushing && !g_Shutdown.load(std::memory_order_acquire)) {
    if (!g_Mutex->Wait(&timeout)) {
      if (LOG != nullptr) {
        LOG->Warn("GameSoundManager::Flush timed out");
      }
      g_bFlushing = false;
      break;
    }
  }
  g_Mutex->Unlock();
}

int MusicThread_start(void* p) {
  while (!g_Shutdown.load(std::memory_order_acquire)) {
    if (g_Mutex == nullptr) {
      break;
    }
    g_Mutex->Lock();
    while (!SoundWaiting() &&
           !g_Shutdown.load(std::memory_order_acquire) && !g_bFlushing) {
      g_Mutex->Wait();
    }
    g_Mutex->Unlock();

    /* This is a little hack: we want to make sure that we go through
     * StartQueuedSounds after Flush() is called, to be sure we're flushed,
     * so check g_bFlushing before calling.  This won't work if more than
     * one thread might call Flush(), but only the main thread is allowed
     * to make SOUND calls. */
    g_Mutex->Lock();
    bool bFlushing = g_bFlushing;
    g_Mutex->Unlock();

    StartQueuedSounds();

    if (bFlushing) {
      g_Mutex->Lock();
      g_Mutex->Signal();
      g_bFlushing = false;
      g_Mutex->Unlock();
    }
  }

  return 0;
}

GameSoundManager::GameSoundManager() {
  /* Init RageSoundMan first: */
  if (SOUNDMAN == nullptr && LOG != nullptr) {
    LOG->Warn("GameSoundManager created before SOUNDMAN was initialized");
  }

  // Force runtime PlayOnce pool settings by default, with an explicit
  // command-line escape hatch for tuning sessions.
  if (!GetCommandlineArgument("no-force-playonce-config")) {
    g_iPlayOncePoolVoices.Set(8);
    g_iPlayOnceMaxPools.Set(96);
    g_iPlayOnceMaxCacheMB.Set(96);
    if (LOG != nullptr) {
      LOG->Info(
          "Forcing PlayOnce runtime config: voices=%d max_pools=%d "
          "max_cache_mb=%d",
          g_iPlayOncePoolVoices.Get(), g_iPlayOnceMaxPools.Get(),
          g_iPlayOnceMaxCacheMB.Get());
    }
  } else {
    if (LOG != nullptr) {
      LOG->Info(
          "PlayOnce runtime forcing disabled via --no-force-playonce-config");
    }
  }

  g_Mutex = new RageEvent("GameSoundManager");
  g_Playing = new MusicPlaying(new RageSound);

  g_UpdatingTimer = true;
  g_PlayOnceDroppedBusyCount = 0;
  g_PlayOnceDroppedPoolFullCount = 0;
  g_PlayOnceDroppedMemoryBudgetCount = 0;
  g_PlayOnceEvictedPoolCount = 0;
  g_PlayOnceInvalidLoadCount = 0;
  g_PlayOnceEstimatedCacheBytes = 0;
  g_PlayOnceStatsLogTimer = 0.0f;
  g_PlayOnceThemeCacheKey = THEME ? THEME->GetCurThemeName() : "";
  g_PlayOnceAnnouncerCacheKey = ANNOUNCER ? ANNOUNCER->GetCurAnnouncerName()
                                          : "";

  g_Shutdown.store(false, std::memory_order_release);
  MusicThread.SetName("Music thread");
  MusicThread.Create(MusicThread_start, this);

  // Register with Lua.
  if (LUA != nullptr) {
    Lua* L = LUA->Get();
    lua_pushstring(L, "SOUND");
    this->PushSelf(L);
    lua_settable(L, LUA_GLOBALSINDEX);
    LUA->Release(L);
  }
}

GameSoundManager::~GameSoundManager() {
  const bool trace = LogPlayOnceDiagnosticsEnabled();
  if (trace && LOG != nullptr) {
    LOG->Trace("GameSoundManager::~GameSoundManager begin");
  }
  // Unregister with Lua.
  if (LUA != nullptr) {
    LUA->UnsetGlobal("SOUND");
  }

  /* Signal the mixing thread to quit. */
  if (trace && LOG != nullptr) {
    LOG->Trace("Shutting down music start thread ...");
  }
  if (g_Mutex != nullptr) {
    g_Mutex->Lock();
    g_Shutdown.store(true, std::memory_order_release);
    g_bFlushing = false;
    g_Mutex->Broadcast();
    g_Mutex->Unlock();
    MusicThread.Wait();
  }
  if (trace && LOG != nullptr) {
    LOG->Trace("Music start thread shut down.");
  }

  if (g_Mutex != nullptr) {
    g_Mutex->Lock();
    g_SoundsToPlayOnce.clear();
    g_SoundsToPlayOnceFromDir.clear();
    g_SoundsToPlayOnceFromAnnouncer.clear();
    g_MusicsToPlay.clear();
    g_bFlushing = false;
    g_Mutex->Unlock();
  }

  if (trace && LOG != nullptr) {
    LOG->Trace("GameSoundManager shutdown detach PlayOnce cache call begin");
  }
  std::vector<RageSound*> playOnceSoundsToDelete =
      DetachPlayOnceCacheForShutdown();
  if (trace && LOG != nullptr) {
    LOG->Trace("GameSoundManager shutdown detach PlayOnce cache call end");
    LOG->Trace(
        "GameSoundManager shutdown PlayOnce delete begin count=%zu",
        playOnceSoundsToDelete.size());
  }
  for (size_t i = 0; i < playOnceSoundsToDelete.size(); ++i) {
    DeleteSoundWithShutdownTrace(
        playOnceSoundsToDelete[i], "playonce_cache", i + 1,
        playOnceSoundsToDelete.size());
  }
  playOnceSoundsToDelete.clear();
  if (trace && LOG != nullptr) {
    LOG->Trace("GameSoundManager shutdown PlayOnce delete end");
  }

  if (trace && LOG != nullptr) {
    LOG->Trace(
        "GameSoundManager shutdown current music delete begin playing_ptr=%p "
        "music_ptr=%p",
        static_cast<void*>(g_Playing),
        g_Playing != nullptr ? static_cast<void*>(g_Playing->m_Music) : nullptr);
  }
  RageUtil::SafeDelete(g_Playing);
  if (trace && LOG != nullptr) {
    LOG->Trace("GameSoundManager shutdown current music delete end");
    LOG->Trace("GameSoundManager shutdown mutex delete begin mutex_ptr=%p",
               static_cast<void*>(g_Mutex));
  }
  RageUtil::SafeDelete(g_Mutex);
  if (trace && LOG != nullptr) {
    LOG->Trace("GameSoundManager shutdown mutex delete end");
    LOG->Trace("GameSoundManager::~GameSoundManager end");
  }
}

float GameSoundManager::GetFrameTimingAdjustment(float fDeltaTime) {
  /*
   * We get one update per frame, and we're updated early, almost immediately
   * after vsync, near the beginning of the game loop.  However, it's very
   * likely that we'll lose the scheduler while waiting for vsync, and some
   * other thread will be working.  Especially with a low-resolution scheduler
   * (Linux 2.4, Win9x), we may not get the scheduler back immediately after the
   * vsync; there may be up to a ~10ms delay.  This can cause jitter in the
   * rendered arrows.
   *
   * Compensate.  If vsync is enabled, and we're maintaining the refresh rate
   * consistently, we should have a very precise game loop interval.  If we have
   * that, but we're off by a small amount (less than the interval), adjust the
   * time to line it up.  As long as we adjust both the sound time and the
   * timestamp, this won't adversely affect input timing. If we're off by more
   * than that, we probably had a frame skip, in which case we have bigger skip
   * problems, so don't adjust.
  */
  static int iLastFPS = 0;
  if (DISPLAY == nullptr || !std::isfinite(fDeltaTime)) {
    return 0;
  }
  int iThisFPS = DISPLAY->GetFPS();
  if (iThisFPS <= 0) {
    return 0;
  }

  if (iThisFPS != DISPLAY->GetActualVideoModeParams().rate ||
      iThisFPS != iLastFPS) {
    iLastFPS = iThisFPS;
    return 0;
  }

  const float fExpectedDelay = 1.0f / iThisFPS;
  const float fExtraDelay = fDeltaTime - fExpectedDelay;
  if (std::abs(fExtraDelay) >= fExpectedDelay / 2) {
    return 0;
  }

  /* Subtract the extra delay. */
  return std::min(-fExtraDelay, 0.0f);
}

void GameSoundManager::Update(float fDeltaTime) {
  if (!std::isfinite(fDeltaTime) || fDeltaTime < 0.0f) {
    fDeltaTime = 0.0f;
  }
  if (g_Mutex == nullptr || g_Playing == nullptr || GAMESTATE == nullptr) {
    return;
  }
  static uint64_t sLastDroppedBusy = 0;
  static uint64_t sLastDroppedPoolFull = 0;
  static uint64_t sLastDroppedMemoryBudget = 0;
  static uint64_t sLastEvictedPools = 0;
  static uint64_t sLastInvalidLoads = 0;

  if (LogPlayOnceDiagnosticsEnabled()) {
    g_PlayOnceStatsLogTimer += fDeltaTime;
  } else {
    g_PlayOnceStatsLogTimer = 0.0f;
  }
  if (g_PlayOnceStatsLogTimer >= 10.0f) {
    g_PlayOnceStatsLogTimer = 0.0f;
    size_t poolCount = 0;
    size_t invalidCacheCount = 0;
    size_t emptyPoolCount = 0;
    size_t estimatedCacheBytes = 0;
    size_t maxCacheBytes = 0;
    uint64_t droppedBusy = 0;
    uint64_t droppedPoolFull = 0;
    uint64_t droppedMemoryBudget = 0;
    uint64_t evictedPools = 0;
    uint64_t invalidLoads = 0;
    {
      LockMutex playOnceLock(g_PlayOnceDataMutex);
      poolCount = g_PlayOnceSoundPool.size();
      invalidCacheCount = g_PlayOnceSoundInvalidPath.size();
      emptyPoolCount = CountEmptyPlayOncePools();
      estimatedCacheBytes = g_PlayOnceEstimatedCacheBytes;
      maxCacheBytes = GetPlayOnceMaxCacheBytes();
      droppedBusy = g_PlayOnceDroppedBusyCount;
      droppedPoolFull = g_PlayOnceDroppedPoolFullCount;
      droppedMemoryBudget = g_PlayOnceDroppedMemoryBudgetCount;
      evictedPools = g_PlayOnceEvictedPoolCount;
      invalidLoads = g_PlayOnceInvalidLoadCount;
    }
    if (droppedBusy != sLastDroppedBusy ||
        droppedPoolFull != sLastDroppedPoolFull ||
        droppedMemoryBudget != sLastDroppedMemoryBudget ||
        evictedPools != sLastEvictedPools ||
        invalidLoads != sLastInvalidLoads) {
      if (LOG != nullptr) {
        LOG->Trace(
            "PlayOnce pool stats: pools=%zu invalid_cache=%zu "
            "empty_pools=%zu estimated_cache=%zu/%zu drops_busy=%llu "
            "drops_pool_full=%llu drops_memory_budget=%llu evictions=%llu "
            "invalid_loads=%llu",
            poolCount, invalidCacheCount, emptyPoolCount, estimatedCacheBytes,
            maxCacheBytes,
            static_cast<unsigned long long>(droppedBusy),
            static_cast<unsigned long long>(droppedPoolFull),
            static_cast<unsigned long long>(droppedMemoryBudget),
            static_cast<unsigned long long>(evictedPools),
            static_cast<unsigned long long>(invalidLoads));
      }
      sLastDroppedBusy = droppedBusy;
      sLastDroppedPoolFull = droppedPoolFull;
      sLastDroppedMemoryBudget = droppedMemoryBudget;
      sLastEvictedPools = evictedPools;
      sLastInvalidLoads = invalidLoads;
    }
  }

  {
    g_Mutex->Lock();
    if (HasCurrentMusic() && g_Playing->m_bApplyMusicRate) {
      RageSoundParams p = g_Playing->m_Music->GetParams();
      float fRate = GAMESTATE->m_SongOptions.GetPreferred().m_fMusicRate;
      if (!std::isfinite(fRate) || fRate <= 0.0f) {
        fRate = 1.0f;
      }
      if (p.m_fSpeed != fRate) {
        p.m_fSpeed = fRate;
        g_Playing->m_Music->SetParams(p);
      }
    }

    bool bIsPlaying = HasCurrentMusic() && g_Playing->m_Music->IsPlaying();
    g_Mutex->Unlock();
    if (!bIsPlaying && g_bWasPlayingOnLastUpdate &&
        !g_FallbackMusicParams.sFile.empty()) {
      PlayMusic(g_FallbackMusicParams);

      g_FallbackMusicParams.sFile = "";
    }
    g_bWasPlayingOnLastUpdate = bIsPlaying;
  }

  LockMut(*g_Mutex);

  {
    /* Duration of the fade-in and fade-out: */
    // const float fFadeInSpeed = 1.5f;
    // const float fFadeOutSpeed = 0.3f;
    float fFadeInSpeed = g_Playing->m_Music->GetParams().m_fFadeInSeconds;
    float fFadeOutSpeed = g_Playing->m_Music->GetParams().m_fFadeOutSeconds;
    float fVolume =
        SanitizeVolume(g_Playing->m_Music->GetParams().m_Volume);
    switch (g_FadeState) {
      case FADE_NONE:
        break;
      case FADE_OUT:
        if (fFadeOutSpeed > 0.0) {
          fapproach(fVolume, g_fDimVolume, fDeltaTime / fFadeOutSpeed);
        } else {
          // Treat an invalid fade speed as instant
          fVolume = g_fDimVolume;
        }
        if (std::abs(fVolume - g_fDimVolume) < 0.001f) {
          g_FadeState = FADE_WAIT;
        }
        break;
      case FADE_WAIT:
        g_fDimDurationRemaining -= fDeltaTime;
        if (g_fDimDurationRemaining <= 0) {
          g_FadeState = FADE_IN;
        }
        break;
      case FADE_IN:
        if (fFadeInSpeed > 0.0) {
          fapproach(fVolume, g_fOriginalVolume, fDeltaTime / fFadeInSpeed);
        } else {
          // Treat an invalid fade speed as instant
          fVolume = g_fOriginalVolume;
        }
        if (std::abs(fVolume - g_fOriginalVolume) < 0.001f) {
          g_FadeState = FADE_NONE;
        }
        break;
    }

    RageSoundParams p = g_Playing->m_Music->GetParams();
    if (p.m_Volume != fVolume) {
      p.m_Volume = fVolume;
      g_Playing->m_Music->SetParams(p);
    }
  }

  if (!g_UpdatingTimer) {
    return;
  }

  const float fAdjust = GetFrameTimingAdjustment(fDeltaTime);
  if (!HasCurrentMusic() || !g_Playing->m_Music->IsPlaying()) {
    /* There's no song playing.  Fake it. */
    GAMESTATE->UpdateSongPosition(
        GAMESTATE->m_Position.m_fMusicSeconds +
            fDeltaTime * g_Playing->m_Music->GetPlaybackRate(),
        g_Playing->m_Timing);
    return;
  }

  /* There's a delay between us calling Play() and the sound actually playing.
   * Keep using the previous timing data until we get a non-approximate time,
   * indicating that the sound has actually started playing. */
  RageTimer tm;
  const float fSeconds = g_Playing->m_Music->GetPositionSeconds(&tm);

  // Check for song timing skips.
  if (PREFSMAN != nullptr && PREFSMAN->m_bLogSkips &&
      !g_Playing->m_bTimingDelayed) {
    const float fExpectedTimePassed =
        (tm - GAMESTATE->m_Position.m_LastBeatUpdate) *
        g_Playing->m_Music->GetPlaybackRate();
    const float fSoundTimePassed =
        fSeconds - GAMESTATE->m_Position.m_fMusicSeconds;
    const float fDiff = fExpectedTimePassed - fSoundTimePassed;

    static std::string sLastFile = "";
    static RageTimer sLastSkipLog;
    static int sSuppressedSkipLogs = 0;
    const std::string ThisFile = g_Playing->m_Music->GetLoadedFilePath();

    /* If fSoundTimePassed < 0, the sound has probably looped. */
    if (sLastFile == ThisFile && fSoundTimePassed >= 0 &&
        std::abs(fDiff) > 0.003f) {
      // A paused preview can report the same position every frame. Preserve
      // diagnostics without allowing that expected state to flood the log.
      if (LOG != nullptr && sLastSkipLog.Ago() >= 1.0f) {
        LOG->Trace(
            "Song position skip in %s: expected %.3f, got %.3f (cur %f, prev %f) "
            "(%.3f difference, coalesced=%d)",
            Basename(ThisFile).c_str(), fExpectedTimePassed, fSoundTimePassed,
            fSeconds, GAMESTATE->m_Position.m_fMusicSeconds, fDiff,
            sSuppressedSkipLogs);
        sSuppressedSkipLogs = 0;
        sLastSkipLog.Touch();
      } else {
        ++sSuppressedSkipLogs;
      }
    }
    sLastFile = ThisFile;
  }

  // If g_Playing->m_bTimingDelayed, we're waiting for the new music to actually
  // start playing.
  if (g_Playing->m_bTimingDelayed) {
    /* Load up the new timing data. */
    g_Playing->m_Timing = g_Playing->m_NewTiming;
    g_Playing->m_bTimingDelayed = false;
  }

  if (g_Playing->m_bTimingDelayed) {
    /* We're still waiting for the new sound to start playing, so keep using the
     * old timing data and fake the time. */
    GAMESTATE->UpdateSongPosition(
        GAMESTATE->m_Position.m_fMusicSeconds + fDeltaTime,
        g_Playing->m_Timing);
  } else {
    GAMESTATE->UpdateSongPosition(
        fSeconds + fAdjust, g_Playing->m_Timing, tm + fAdjust);
  }

  // Send crossed messages
  if (GAMESTATE->m_pCurSong && MESSAGEMAN != nullptr) {
    static int iBeatLastCrossed = 0;
    static const Song* pLastCrossedSong = nullptr;

    float fSongBeat = GAMESTATE->m_Position.m_fSongBeat;

    int iRowNow = BeatToNoteRowNotRounded(fSongBeat);
    iRowNow = std::max(0, iRowNow);

    int iBeatNow = iRowNow / ROWS_PER_BEAT;
    if (pLastCrossedSong != GAMESTATE->m_pCurSong ||
        iBeatNow < iBeatLastCrossed) {
      iBeatLastCrossed = iBeatNow;
      pLastCrossedSong = GAMESTATE->m_pCurSong;
    }

    for (int iBeat = iBeatLastCrossed + 1; iBeat <= iBeatNow; ++iBeat) {
      Message msg("CrossedBeat");
      msg.SetParam("Beat", iBeat);
      MESSAGEMAN->Broadcast(msg);
    }

    iBeatLastCrossed = iBeatNow;
  }

  // Update lights
  NoteData& lights = g_Playing->m_Lights;
  if (lights.GetNumTracks() > 0 && LIGHTSMAN != nullptr)  // lights data was loaded
  {
    const float fSongBeat = GAMESTATE->m_Position.m_fLightSongBeat;
    const int iSongRow = BeatToNoteRowNotRounded(fSongBeat);

    static int iRowLastCrossed = 0;
    if (iSongRow < iRowLastCrossed) {
      iRowLastCrossed = iSongRow;
    }

    FOREACH_CabinetLight(cl) {
      // Are we "holding" the light?
      if (lights.IsHoldNoteAtRow(cl, iSongRow)) {
        LIGHTSMAN->BlinkCabinetLight(cl);
        continue;
      }

      // Otherwise, for each index we crossed since the last update:
      FOREACH_NONEMPTY_ROW_IN_TRACK_RANGE(
          lights, cl, r, iRowLastCrossed + 1, iSongRow + 1) {
        if (lights.GetTapNote(cl, r).type != TapNoteType_Empty) {
          LIGHTSMAN->BlinkCabinetLight(cl);
          break;
        }
      }
    }

    iRowLastCrossed = iSongRow;
  }
}

std::string GameSoundManager::GetMusicPath() const {
  if (g_Mutex == nullptr) {
    return "";
  }
  LockMut(*g_Mutex);
  return HasCurrentMusic() ? g_Playing->m_Music->GetLoadedFilePath() : "";
}

void GameSoundManager::PlayMusic(
    std::string sFile, const TimingData* pTiming, bool bForceLoop,
    float fStartSecond, float fLengthSeconds, float fFadeInLengthSeconds,
    float fFadeOutLengthSeconds, bool bAlignBeat, bool bApplyMusicRate) {
  PlayMusicParams params;
  params.sFile = sFile;
  params.pTiming = pTiming;
  params.bForceLoop = bForceLoop;
  params.fStartSecond = fStartSecond;
  params.fLengthSeconds = fLengthSeconds;
  params.fFadeInLengthSeconds = fFadeInLengthSeconds;
  params.fFadeOutLengthSeconds = fFadeOutLengthSeconds;
  params.bAlignBeat = bAlignBeat;
  params.bApplyMusicRate = bApplyMusicRate;
  PlayMusic(params);
}

void GameSoundManager::PlayMusic(
    PlayMusicParams params, PlayMusicParams FallbackMusicParams) {
  if (!HasSoundQueueRuntime()) {
    return;
  }
  g_FallbackMusicParams = FallbackMusicParams;

  //	LOG->Trace("play '%s' (current '%s')", file.c_str(),
  // g_Playing->m_Music->GetLoadedFilePath().c_str());

  MusicToPlay ToPlay;

  ToPlay.m_sFile = params.sFile;
  if (params.pTiming) {
    ToPlay.HasTiming = true;
    ToPlay.m_TimingData = *params.pTiming;
  } else {
    /* If no timing data was provided, look for it in the same place as the
     * music file. */
    // todo: allow loading .ssc files as well -aj
    ToPlay.m_sTimingFile = SetExtension(params.sFile, "sm");
  }

  ToPlay.bForceLoop = params.bForceLoop;
  ToPlay.fStartSecond = SanitizeNonNegativeSeconds(params.fStartSecond);
  ToPlay.fLengthSeconds = SanitizeLengthSeconds(params.fLengthSeconds);
  ToPlay.fFadeInLengthSeconds =
      SanitizeNonNegativeSeconds(params.fFadeInLengthSeconds);
  ToPlay.fFadeOutLengthSeconds =
      SanitizeNonNegativeSeconds(params.fFadeOutLengthSeconds);
  ToPlay.bAlignBeat = params.bAlignBeat;
  ToPlay.bApplyMusicRate = params.bApplyMusicRate;

  /* Add the MusicToPlay to the g_MusicsToPlay queue. */
  g_Mutex->Lock();
  EnqueueBounded(g_MusicsToPlay, ToPlay);
  g_Mutex->Unlock();
}

void GameSoundManager::DimMusic(float fVolume, float fDurationSeconds) {
  if (g_Mutex == nullptr || !HasCurrentMusic()) {
    return;
  }
  LockMut(*g_Mutex);

  if (g_FadeState == FADE_NONE) {
    g_fOriginalVolume = g_Playing->m_Music->GetParams().m_Volume;
  }
  // otherwise, g_fOriginalVolume is already set and m_Volume will be the
  // current state, not the original state

  g_fDimDurationRemaining = SanitizeNonNegativeSeconds(fDurationSeconds);
  g_fDimVolume = SanitizeVolume(fVolume);
  g_FadeState = FADE_OUT;
}

void GameSoundManager::HandleSongTimer(bool on) {
  if (g_Mutex == nullptr) {
    return;
  }
  LockMut(*g_Mutex);
  g_UpdatingTimer = on;
}

void GameSoundManager::PlayOnce(std::string sPath) {
  if (sPath.empty() || sPath.size() > kMaxQueuedPathLength ||
      !HasSoundQueueRuntime()) {
    return;
  }
  /* Add the sound to the g_SoundsToPlayOnce queue. */
  g_Mutex->Lock();
  EnqueueBounded(g_SoundsToPlayOnce, sPath);
  g_Mutex->Unlock();
}

void GameSoundManager::PlayOnceFromDir(std::string sPath) {
  if (sPath.empty() || sPath.size() > kMaxQueuedPathLength ||
      !HasSoundQueueRuntime()) {
    return;
  }
  /* Add the path to the g_SoundsToPlayOnceFromDir queue. */
  g_Mutex->Lock();
  EnqueueBounded(g_SoundsToPlayOnceFromDir, sPath);
  g_Mutex->Unlock();
}

void GameSoundManager::PlayOnceFromAnnouncer(std::string sPath) {
  if (sPath.empty() || sPath.size() > kMaxQueuedPathLength ||
      !HasSoundQueueRuntime()) {
    return;
  }
  /* Add the path to the g_SoundsToPlayOnceFromAnnouncer queue. */
  g_Mutex->Lock();
  EnqueueBounded(g_SoundsToPlayOnceFromAnnouncer, sPath);
  g_Mutex->Unlock();
}

void GameSoundManager::SetPlayOnceDebugToolsEnabled(bool enabled) {
  LockMutex playOnceLock(g_PlayOnceDataMutex);
  g_bPlayOnceDebugToolsEnabled = enabled;
  g_bLoggedPlayOnceDebugToolsDenied = false;
}

void GameSoundManager::StressTestPlayOnce(std::string sPath, int iCount) {
  {
    LockMutex playOnceLock(g_PlayOnceDataMutex);
    if (!g_bPlayOnceDebugToolsEnabled) {
      if (!g_bLoggedPlayOnceDebugToolsDenied) {
        if (LOG != nullptr) {
          LOG->Warn(
              "PlayOnce stress tools are disabled (enable via --playonce-stress "
              "or --playonce-debug-tools).");
        }
        g_bLoggedPlayOnceDebugToolsDenied = true;
      }
      return;
    }
  }

  const int clampedCount = std::max(1, std::min(iCount, 5000));
  if (LOG != nullptr) {
    LOG->Info(
        "PlayOnce stress test start: path='%s', requested=%d, queued=%d",
        sPath.c_str(), iCount, clampedCount);
  }
  for (int i = 0; i < clampedCount; ++i) {
    PlayOnce(sPath);
  }
}

GameSoundManager::PlayOnceDiagnosticsSnapshot
GameSoundManager::GetPlayOnceDiagnosticsSnapshot() const {
  PlayOnceDiagnosticsSnapshot snapshot;
  LockMutex playOnceLock(g_PlayOnceDataMutex);
  snapshot.poolCount = g_PlayOnceSoundPool.size();
  snapshot.invalidCacheCount = g_PlayOnceSoundInvalidPath.size();
  snapshot.emptyPoolCount = CountEmptyPlayOncePools();
  snapshot.estimatedCacheBytes = g_PlayOnceEstimatedCacheBytes;
  snapshot.maxCacheBytes = GetPlayOnceMaxCacheBytes();
  snapshot.droppedBusyCount = g_PlayOnceDroppedBusyCount;
  snapshot.droppedPoolFullCount = g_PlayOnceDroppedPoolFullCount;
  snapshot.droppedMemoryBudgetCount = g_PlayOnceDroppedMemoryBudgetCount;
  snapshot.evictedPoolCount = g_PlayOnceEvictedPoolCount;
  snapshot.invalidLoadCount = g_PlayOnceInvalidLoadCount;
  return snapshot;
}

bool GameSoundManager::RunPlayOnceRuntimeSmokeTest(
    std::string sPath, int iCount) {
  SetPlayOnceDebugToolsEnabled(true);

  const int clampedCount = std::max(1, std::min(iCount, 5000));
  const int forcedVoiceCount = std::max(1, g_iPlayOncePoolVoices.Get());
  const PlayOnceDiagnosticsSnapshot before = GetPlayOnceDiagnosticsSnapshot();

  LogPlayOnceDiagnostics("runtime_smoke_before");
  if (LOG != nullptr) {
    LOG->Info(
        "PlayOnce runtime smoke start: path='%s', requested=%d, direct_calls=%d",
        sPath.c_str(), iCount, clampedCount);
  }
  for (int i = 0; i < clampedCount; ++i) {
    DoPlayOnce(sPath);
  }

  const PlayOnceDiagnosticsSnapshot after = GetPlayOnceDiagnosticsSnapshot();
  LogPlayOnceDiagnostics("runtime_smoke_after");

  const uint64_t newInvalidLoads = after.invalidLoadCount - before.invalidLoadCount;
  const uint64_t newPoolFullDrops =
      after.droppedPoolFullCount - before.droppedPoolFullCount;
  const uint64_t newMemoryDrops =
      after.droppedMemoryBudgetCount - before.droppedMemoryBudgetCount;
  const uint64_t newBusyDrops =
      after.droppedBusyCount - before.droppedBusyCount;
  const bool busyDropIsFailure = clampedCount <= forcedVoiceCount;

  const bool ok = after.poolCount > 0 && after.emptyPoolCount == 0 &&
                  newInvalidLoads == 0 && newPoolFullDrops == 0 &&
                  newMemoryDrops == 0 &&
                  (!busyDropIsFailure || newBusyDrops == 0);
  if (LOG != nullptr) {
    LOG->Info(
        "PlayOnce runtime smoke %s: path='%s' count=%d voices=%d pools=%zu "
        "empty_pools=%zu invalid_delta=%llu busy_delta=%llu "
        "pool_full_delta=%llu memory_delta=%llu",
        ok ? "PASS" : "FAIL", sPath.c_str(), clampedCount, forcedVoiceCount,
        after.poolCount, after.emptyPoolCount,
        static_cast<unsigned long long>(newInvalidLoads),
        static_cast<unsigned long long>(newBusyDrops),
        static_cast<unsigned long long>(newPoolFullDrops),
        static_cast<unsigned long long>(newMemoryDrops));
  }

  return ok;
}

void GameSoundManager::LogPlayOnceDiagnostics(const std::string& reason) {
  {
    LockMutex playOnceLock(g_PlayOnceDataMutex);
    if (!g_bPlayOnceDebugToolsEnabled && !LogPlayOnceDiagnosticsEnabled()) {
      if (!g_bLoggedPlayOnceDebugToolsDenied) {
        if (LOG != nullptr) {
          LOG->Warn(
              "PlayOnce diagnostics are disabled (enable via --playonce-stress "
              "or --playonce-debug-tools).");
        }
        g_bLoggedPlayOnceDebugToolsDenied = true;
      }
      return;
    }
  }

  const PlayOnceDiagnosticsSnapshot snapshot = GetPlayOnceDiagnosticsSnapshot();
  if (LOG != nullptr) {
    LOG->Info(
        "PlayOnce diagnostics (%s): pools=%zu invalid_cache=%zu "
        "empty_pools=%zu estimated_cache=%zu/%zu drops_busy=%llu "
        "drops_pool_full=%llu drops_memory_budget=%llu evictions=%llu "
        "invalid_loads=%llu",
        reason.c_str(), snapshot.poolCount, snapshot.invalidCacheCount,
        snapshot.emptyPoolCount, snapshot.estimatedCacheBytes,
        snapshot.maxCacheBytes,
        static_cast<unsigned long long>(snapshot.droppedBusyCount),
        static_cast<unsigned long long>(snapshot.droppedPoolFullCount),
        static_cast<unsigned long long>(snapshot.droppedMemoryBudgetCount),
        static_cast<unsigned long long>(snapshot.evictedPoolCount),
        static_cast<unsigned long long>(snapshot.invalidLoadCount));
  }
}

float GameSoundManager::GetPlayerBalance(PlayerNumber pn) {
  if (GAMESTATE != nullptr && pn >= PLAYER_1 && pn < NUM_PlayerNumber) {
    const PlayerNumber master = GAMESTATE->GetMasterPlayerNumber();
    const Style* style =
        master >= PLAYER_1 && master < NUM_PlayerNumber
            ? GAMESTATE->GetCurrentStyle(master)
            : nullptr;
    if (style != nullptr &&
        style->m_StyleType == StyleType_TwoPlayersSharedSides) {
      return 0.0f;
    }
  }
  /* If two players are active, play sounds on each players' side. */
  if (GAMESTATE != nullptr && pn >= PLAYER_1 && pn < NUM_PlayerNumber &&
      GAMESTATE->GetNumPlayersEnabled() == 2) {
    return (pn == PLAYER_1) ? -1.0f : 1.0f;
  } else {
    return 0;
  }
}

#include "LuaBinding.h"

/** @brief Allow Lua to have access to the GameSoundManager. */
class LunaGameSoundManager : public Luna<GameSoundManager> {
 public:
  static int DimMusic(T* p, lua_State* L) {
    float fVolume = FArg(1);
    float fDurationSeconds = FArg(2);
    p->DimMusic(fVolume, fDurationSeconds);
    COMMON_RETURN_SELF;
  }
  static int PlayOnce(T* p, lua_State* L) {
    std::string sPath = SArg(1);
    if (lua_toboolean(L, 2) && PREFSMAN != nullptr &&
        PREFSMAN->m_MuteActions) {
      COMMON_RETURN_SELF;
    }
    p->PlayOnce(sPath);
    COMMON_RETURN_SELF;
  }
  static int PlayAnnouncer(T* p, lua_State* L) {
    std::string sPath = SArg(1);
    p->PlayOnceFromAnnouncer(sPath);
    COMMON_RETURN_SELF;
  }
  static int GetPlayerBalance(T* p, lua_State* L) {
    PlayerNumber pn = Enum::Check<PlayerNumber>(L, 1);
    lua_pushnumber(L, p->GetPlayerBalance(pn));
    return 1;
  }
  static int PlayMusicPart(T* p, lua_State* L) {
    std::string musicPath = SArg(1);
    float musicStart = FArg(2);
    float musicLength = FArg(3);
    float fadeIn = 0;
    float fadeOut = 0;
    bool loop = false;
    bool applyRate = false;
    bool alignBeat = true;
    if (!lua_isnoneornil(L, 4)) {
      fadeIn = FArg(4);
    }
    if (!lua_isnoneornil(L, 5)) {
      fadeOut = FArg(5);
    }
    if (!lua_isnoneornil(L, 6)) {
      loop = BArg(6);
    }
    if (!lua_isnoneornil(L, 7)) {
      applyRate = BArg(7);
    }
    if (!lua_isnoneornil(L, 8)) {
      alignBeat = BArg(8);
    }
    p->PlayMusic(
        musicPath, nullptr, loop, musicStart, musicLength, fadeIn, fadeOut,
        alignBeat, applyRate);
    COMMON_RETURN_SELF;
  }

  static int StopMusic(T* p, lua_State* L) {
    p->StopMusic();
    COMMON_RETURN_SELF;
  }
  static int IsTimingDelayed(T* p, lua_State* L) {
    lua_pushboolean(L, g_Playing != nullptr && g_Playing->m_bTimingDelayed);
    return 1;
  }
  static int LogPlayOnceStats(T* p, lua_State* L) {
    std::string reason = "lua";
    if (!lua_isnoneornil(L, 1)) {
      reason = SArg(1);
    }
    p->LogPlayOnceDiagnostics(reason);
    COMMON_RETURN_SELF;
  }

  LunaGameSoundManager() {
    ADD_METHOD(DimMusic);
    ADD_METHOD(PlayOnce);
    ADD_METHOD(PlayAnnouncer);
    ADD_METHOD(GetPlayerBalance);
    ADD_METHOD(PlayMusicPart);
    ADD_METHOD(StopMusic);
    ADD_METHOD(IsTimingDelayed);
    ADD_METHOD(LogPlayOnceStats);
  }
};

LUA_REGISTER_CLASS(GameSoundManager);

int LuaFunc_get_sound_driver_list(lua_State* L);
int LuaFunc_get_sound_driver_list(lua_State* L) {
  std::vector<std::string> driver_names = RageSoundDriver::GetSoundDriverList();
  lua_createtable(L, driver_names.size(), 0);
  for (size_t n = 0; n < driver_names.size(); ++n) {
    lua_pushstring(L, driver_names[n].c_str());
    lua_rawseti(L, -2, n + 1);
  }
  return 1;
}
LUAFUNC_REGISTER_COMMON(get_sound_driver_list);

/*
 * Copyright (c) 2003-2005 Glenn Maynard
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
