/* Handle loading and decoding of sounds.
 *
 * For small files, pre-decode the entire file into a regular buffer.  We
 * might want to play many samples at once, and we don't want to have to decode
 * 5-10 mp3s simultaneously during play.
 *
 * For larger files, decode them on the fly.  These are usually music, and
 * there's usually only one of those playing at a time.  When we get updates,
 * decode data at the same rate we're playing it.  If we don't do this, and
 * we're being read in large chunks, we're forced to decode in larger chunks as
 * well, which can cause framerate problems.
 *
 * Error handling:
 * Decoding errors (eg. CRC failures) will be recovered from when possible.
 *
 * When they can't be recovered, the sound will stop (unless loop or !autostop)
 * and the error will be available in GetError().
 *
 * Seeking past the end of the file will throw a warning and rewind.
 */

#include "RageSound.h"

#include <algorithm>
#include <climits>
#include <cmath>
#include <cstdint>
#include <memory>
#include <string>

#include "LuaManager.h"
#include "PerfDiagnostics.h"
#include "PrefsManager.h"
#include "RageLog.h"
#include "RageSoundConstants.h"
#include "RageSoundManager.h"
#include "RageSoundReader_Extend.h"
#include "RageSoundReader_FileReader.h"
#include "RageSoundReader_Pan.h"
#include "RageSoundReader_PitchChange.h"
#include "RageSoundReader_PostBuffering.h"
#include "RageSoundReader_Preload.h"
#include "RageSoundReader_Resample_Good.h"
#include "RageSoundReader_ThreadedBuffer.h"
#include "RageSoundUtil.h"
#include "RageThreads.h"
#include "RageTimer.h"
#include "RageUtil.h"
#include "global.h"

namespace {
constexpr float kMinPlaybackRate = 0.01f;
constexpr float kMaxPlaybackRate = 100.0f;
constexpr float kMaxSoundVolume = 16.0f;

float ClampFinite(float value, float fallback, float minimum, float maximum) {
  if (!std::isfinite(value)) {
    return fallback;
  }
  return std::max(minimum, std::min(maximum, value));
}

float ClampFiniteMin(float value, float fallback, float minimum) {
  if (!std::isfinite(value)) {
    return fallback;
  }
  return std::max(minimum, value);
}

RageSoundParams NormalizeSoundParams(RageSoundParams params) {
  params.m_StartSecond = ClampFiniteMin(params.m_StartSecond, 0.0f, 0.0f);

  if (!std::isfinite(params.m_LengthSeconds) ||
      params.m_LengthSeconds < 0.0f) {
    params.m_LengthSeconds = -1.0f;
  }

  params.m_fFadeInSeconds =
      ClampFiniteMin(params.m_fFadeInSeconds, 0.0f, 0.0f);
  params.m_fFadeOutSeconds =
      ClampFiniteMin(params.m_fFadeOutSeconds, 0.0f, 0.0f);
  params.m_Volume =
      ClampFinite(params.m_Volume, 1.0f, 0.0f, kMaxSoundVolume);
  params.m_fAttractVolume =
      ClampFinite(params.m_fAttractVolume, 1.0f, 0.0f, kMaxSoundVolume);
  params.m_fPitch =
      ClampFinite(params.m_fPitch, 1.0f, kMinPlaybackRate, kMaxPlaybackRate);
  params.m_fSpeed =
      ClampFinite(params.m_fSpeed, 1.0f, kMinPlaybackRate, kMaxPlaybackRate);

  if (params.StopMode < RageSoundParams::M_STOP ||
      params.StopMode > RageSoundParams::M_AUTO) {
    params.StopMode = RageSoundParams::M_AUTO;
  }

  return params;
}
}  // namespace

RageSoundParams::RageSoundParams()
    : m_StartSecond(0),
      m_LengthSeconds(-1),
      m_fFadeInSeconds(0),
      m_fFadeOutSeconds(0),
      m_Volume(1.0f),
      m_fAttractVolume(1.0f),
      m_fPitch(1.0f),
      m_fSpeed(1.0f),
      m_StartTime(RageZeroTimer),
      StopMode(M_AUTO),
      m_bIsCriticalSound(false) {}

RageSoundLoadParams::RageSoundLoadParams()
    : m_bSupportRateChanging(false), m_bSupportPan(false) {}

RageSound::RageSound()
    : m_Mutex("RageSound"),
      m_pSource(nullptr),
      m_sFilePath(""),
      m_Param(),
      m_iStreamFrame(0),
      m_iStoppedSourceFrame(0),
      m_bPlaying(false),
      m_bDeleteWhenFinished(false),
      m_bPreferStrongPrebuffer(false),
      m_sError("") {
  if (SOUNDMAN == nullptr && LOG != nullptr) {
    LOG->Warn("RageSound created before SOUNDMAN was initialized");
  }
}

RageSound::~RageSound() {
  if (LOG && LogPlayOnceDiagnosticsEnabled()) {
    LOG->Trace(
        "RageSound::~RageSound begin ptr=%p source=%p loaded=%d playing=%d "
        "delete_when_finished=%d path='%s'",
        static_cast<void*>(this), static_cast<void*>(m_pSource),
        m_pSource != nullptr ? 1 : 0, IsPlaying() ? 1 : 0,
        m_bDeleteWhenFinished ? 1 : 0, m_sFilePath.c_str());
  }
  Unload();
  if (LOG && LogPlayOnceDiagnosticsEnabled()) {
    LOG->Trace("RageSound::~RageSound end ptr=%p", static_cast<void*>(this));
  }
}

RageSound::RageSound(const RageSound& cpy)
    : RageSoundBase(cpy),
      m_Mutex("RageSound"),
      m_pSource(nullptr),
      m_bPlaying(false) {
  if (SOUNDMAN == nullptr && LOG != nullptr) {
    LOG->Warn("RageSound copied before SOUNDMAN was initialized");
  }

  *this = cpy;
}

RageSound& RageSound::operator=(const RageSound& cpy) {
  LockMut(cpy.m_Mutex);

  /* If m_bDeleteWhenFinished, then nobody that has a reference to the sound
   * should be making copies. */
  ASSERT(!cpy.m_bDeleteWhenFinished);

  m_Param = cpy.m_Param;
  m_iStreamFrame = cpy.m_iStreamFrame;
  m_iStoppedSourceFrame = cpy.m_iStoppedSourceFrame;
  m_bPlaying.store(false, std::memory_order_release);
  m_bDeleteWhenFinished = false;
  m_bPreferStrongPrebuffer = cpy.m_bPreferStrongPrebuffer;

  if (m_pSource != nullptr) {
    delete m_pSource;
  }
  if (cpy.m_pSource) {
    m_pSource = cpy.m_pSource->Copy();
    if (m_pSource == nullptr) {
      m_sError = "Copying sound reader failed";
      if (LOG != nullptr) {
        LOG->Warn(
            "RageSound::operator=: failed to copy sound \"%s\"",
            cpy.m_sFilePath.c_str());
      }
    }
  } else {
    m_pSource = nullptr;
  }

  m_sFilePath = cpy.m_sFilePath;

  return *this;
}

void RageSound::Unload() {
  if (LOG && LogPlayOnceDiagnosticsEnabled()) {
    LOG->Trace(
        "RageSound::Unload begin ptr=%p source=%p loaded=%d playing=%d "
        "delete_when_finished=%d path='%s'",
        static_cast<void*>(this), static_cast<void*>(m_pSource),
        m_pSource != nullptr ? 1 : 0, IsPlaying() ? 1 : 0,
        m_bDeleteWhenFinished ? 1 : 0, m_sFilePath.c_str());
  }
  if (IsPlaying()) {
    if (LOG && LogPlayOnceDiagnosticsEnabled()) {
      LOG->Trace(
          "RageSound::Unload stop_playing_begin ptr=%p path='%s'",
          static_cast<void*>(this), m_sFilePath.c_str());
    }
    StopPlaying();
    if (LOG && LogPlayOnceDiagnosticsEnabled()) {
      LOG->Trace(
          "RageSound::Unload stop_playing_end ptr=%p path='%s'",
          static_cast<void*>(this), m_sFilePath.c_str());
    }
  }

  if (LOG && LogPlayOnceDiagnosticsEnabled()) {
    LOG->Trace("RageSound::Unload lock_begin ptr=%p", static_cast<void*>(this));
  }
  LockMut(m_Mutex);
  if (LOG && LogPlayOnceDiagnosticsEnabled()) {
    LOG->Trace("RageSound::Unload lock_acquired ptr=%p", static_cast<void*>(this));
  }
  m_bPlaying.store(false, std::memory_order_release);
  m_bDeleteWhenFinished = false;
  m_HardwareToStreamMap.Clear();
  m_StreamToSourceMap.Clear();

  if (m_pSource != nullptr) {
    if (LOG && LogPlayOnceDiagnosticsEnabled()) {
      LOG->Trace(
          "RageSound::Unload delete_source_begin ptr=%p source=%p path='%s'",
          static_cast<void*>(this), static_cast<void*>(m_pSource),
          m_sFilePath.c_str());
    }
    delete m_pSource;
    if (LOG && LogPlayOnceDiagnosticsEnabled()) {
      LOG->Trace(
          "RageSound::Unload delete_source_end ptr=%p", static_cast<void*>(this));
    }
  }
  m_pSource = nullptr;

  m_sFilePath = "";
  m_bPreferStrongPrebuffer = false;
  if (LOG && LogPlayOnceDiagnosticsEnabled()) {
    LOG->Trace("RageSound::Unload end ptr=%p", static_cast<void*>(this));
  }
}

/* The sound will self-delete itself when it stops playing. If the sound is not
 * playing, the sound will be deleted immediately. The caller loses ownership
 * of the sound. */
void RageSound::DeleteSelfWhenFinishedPlaying() {
  m_Mutex.Lock();

  if (!IsPlaying()) {
    m_Mutex.Unlock();
    delete this;
    return;
  }

  m_bDeleteWhenFinished = true;
  m_Mutex.Unlock();
}

bool RageSound::IsLoaded() const { return m_pSource != nullptr; }

class RageSoundReader_Silence : public RageSoundReader {
 public:
  int GetLength() const { return 0; }
  int GetLength_Fast() const { return 0; }
  int SetPosition(int iFrame) { return 1; }
  int Read(float* pBuf, int iFrames) { return RageSoundReader::END_OF_FILE; }
  RageSoundReader* Copy() const { return new RageSoundReader_Silence; }
  int GetSampleRate() const { return FALLBACK_SAMPLE_RATE; }
  unsigned GetNumChannels() const { return 1; }
  int GetNextSourceFrame() const { return 0; }
  float GetStreamToSourceRatio() const { return 1.0f; }
  std::string GetError() const { return ""; }
};

bool RageSound::Load(std::string sSoundFilePath) {
  /* Automatically determine whether to precache */
  /* TODO: Hook this up to a pref? */
  return Load(sSoundFilePath, false);
}

bool RageSound::Load(
    std::string sSoundFilePath, bool bPrecache,
    const RageSoundLoadParams* pParams) {
  if (LOG != nullptr) {
    LOG->Trace(
        "RageSound: Load \"%s\" (precache: %i)", sSoundFilePath.c_str(),
        bPrecache);
  }

  if (pParams == nullptr) {
    static const RageSoundLoadParams Defaults;
    pParams = &Defaults;
  }
  m_sError = "";

  if (SOUNDMAN == nullptr) {
    m_sError = "Sound manager is not initialized";
    if (LOG != nullptr) {
      LOG->Warn(
          "RageSound::Load: cannot load \"%s\" before SOUNDMAN exists",
          sSoundFilePath.c_str());
    }
    LoadSoundReader(new RageSoundReader_Silence, sSoundFilePath);
    return false;
  }

  /* If this sound is already preloaded and held by SOUNDMAN, just make a copy
   * of that.  Since RageSoundReader_Preload is refcounted, this is cheap. */
  RageSoundReader* pSound = SOUNDMAN->GetLoadedSound(sSoundFilePath);
  bool bNeedBuffer = true;
  if (pSound == nullptr) {
    std::string error;
    bool bPrebuffer = false;
    bool bLoaded = true;
    pSound = RageSoundReader_FileReader::OpenFile(
        sSoundFilePath, error, &bPrebuffer);
    if (pSound == nullptr) {
      bLoaded = false;
      m_sError = error;
      if (LOG != nullptr) {
        LOG->Warn(
            "RageSound::Load: error opening sound \"%s\": %s",
            sSoundFilePath.c_str(), error.c_str());
      }

      pSound = new RageSoundReader_Silence;
    }

    /* If the sound is prebuffered into memory, we don't need to buffer reads.
     */
    if (bLoaded && bPrebuffer) {
      bNeedBuffer = false;
    }
  } else {
    /* The sound we were given from SOUNDMAN is already preloaded. */
    bPrecache = false;
    bNeedBuffer = false;
    m_sError = "";
  }

  LoadSoundReader(pSound);
  if (m_pSource == nullptr) {
    if (m_sError.empty()) {
      m_sError = "Sound reader setup failed";
    }
    return false;
  }

  /* Try to precache.  Do this after calling LoadSoundReader() to put the
   * sound in this->m_pSource, so we preload after resampling. */
  if (bPrecache && m_sError.empty()) {
    if (RageSoundReader_Preload::PreloadSound(m_pSource)) {
      /* We've preloaded the sound.  Pass it to SOUNDMAN, for reuse. */
      if (SOUNDMAN != nullptr) {
        SOUNDMAN->AddLoadedSound(
            sSoundFilePath, (RageSoundReader_Preload*)m_pSource);
      }
    } else {
      const std::string preloadError = m_pSource->GetError();
      if (!preloadError.empty()) {
        m_sError = preloadError;
        if (LOG != nullptr) {
          LOG->Warn(
              "RageSound::Load: error preloading sound \"%s\": %s",
              sSoundFilePath.c_str(), m_sError.c_str());
        }
      }
    }
    bNeedBuffer = false;
  }

  m_pSource = new RageSoundReader_Extend(m_pSource);
  if (bNeedBuffer) {
    m_pSource = new RageSoundReader_ThreadedBuffer(m_pSource);
  }
  m_pSource = new RageSoundReader_PostBuffering(m_pSource);

  if (pParams->m_bSupportRateChanging) {
    RageSoundReader_PitchChange* pRate =
        new RageSoundReader_PitchChange(m_pSource);
    m_pSource = pRate;
  }

  if (pParams->m_bSupportPan) {
    m_pSource = new RageSoundReader_Pan(m_pSource);
  }

  m_sFilePath = sSoundFilePath;

  m_Mutex.SetName(ssprintf("RageSound (%s)", Basename(sSoundFilePath).c_str()));

  return m_sError.empty();
}

void RageSound::LoadSoundReader(RageSoundReader* pSound) {
  LoadSoundReader(pSound, "");
}

void RageSound::LoadSoundReader(
    RageSoundReader* pSound, const std::string& sDebugFilePath) {
  Unload();

  m_iStreamFrame = m_iStoppedSourceFrame = 0;

  if (pSound == nullptr) {
    m_sError = "Sound reader is null";
    if (LOG != nullptr) {
      LOG->Warn("RageSound::LoadSoundReader: null reader for \"%s\"",
                sDebugFilePath.c_str());
    }
    pSound = new RageSoundReader_Silence;
  }

  const int readerSampleRate = pSound->GetSampleRate();
  const unsigned readerChannels = pSound->GetNumChannels();
  if (readerSampleRate <= 0 || (readerChannels != 1 && readerChannels != 2)) {
    if (m_sError.empty()) {
      m_sError = ssprintf(
          "Invalid sound reader format: sample_rate=%d channels=%u",
          readerSampleRate, readerChannels);
    }
    if (LOG != nullptr) {
      LOG->Warn(
          "RageSound::LoadSoundReader: invalid reader for \"%s\" "
          "(sample_rate=%d channels=%u)",
          sDebugFilePath.c_str(), readerSampleRate, readerChannels);
    }
    delete pSound;
    pSound = new RageSoundReader_Silence;
  }

  const int iNeededRate =
      SOUNDMAN != nullptr ? SOUNDMAN->GetDriverSampleRate()
                          : FALLBACK_SAMPLE_RATE;
  bool bSupportRateChange = false;
  if (iNeededRate > 0 &&
      (iNeededRate != pSound->GetSampleRate() || bSupportRateChange)) {
    RageSoundReader_Resample_Good* Resample =
        new RageSoundReader_Resample_Good(pSound, iNeededRate);
    pSound = Resample;
  }

  m_pSource = pSound;
  m_sFilePath = sDebugFilePath;
  if (!m_sFilePath.empty()) {
    m_Mutex.SetName(ssprintf("RageSound (%s)", Basename(m_sFilePath).c_str()));
  }
}

/*
 * Retrieve audio data, for mixing.  At the time of this call, the frameno at
 * which the sound will be played doesn't have to be known.  Once committed, and
 * the frameno is known, call CommitPCMData.
 *
 * RageSound::GetDataToPlay and RageSound::FillBuf are the main threaded API.
 * These need to execute without blocking other threads from calling eg.
 * GetPositionSeconds, since they may take some time to run.
 *
 * On underrun, if no data was read, returns WOULD_BLOCK.  On end of file, if no
 * data was read, returns END_OF_FILE.  If any data is read, it is returned;
 * these conditions are masked and will be seen on the next call.  Otherwise,
 * the requested number of frames will always be returned.
 */
int RageSound::GetDataToPlay(
    float* pBuffer, int iFrames, int64_t& iStreamFrame, int& iFramesStored) {
  /* We only update m_iStreamFrame; only take a shared lock, so we don't block
   * the main thread. */
  //	LockMut(m_Mutex);

  iFramesStored = 0;
  iStreamFrame = m_iStreamFrame;
  if (!IsPlaying() || m_pSource == nullptr || pBuffer == nullptr ||
      iFrames <= 0) {
    return RageSoundReader::END_OF_FILE;
  }

  const unsigned channels = m_pSource->GetNumChannels();
  if (channels != 1 && channels != 2) {
    if (LOG != nullptr) {
      LOG->Warn(
          "RageSound::GetDataToPlay: invalid channel count %u for \"%s\"",
          channels, GetLoadedFilePath().c_str());
    }
    return RageSoundReader::ERROR;
  }

  while (iFrames > 0) {
    float fRate = 1.0f;
    int iSourceFrame = 0;

    /* Read data from our source. */
    int iGotFrames = m_pSource->RetriedRead(
        pBuffer + (iFramesStored * m_pSource->GetNumChannels()), iFrames,
        &iSourceFrame, &fRate);

    if (iGotFrames == RageSoundReader::ERROR) {
      m_sError = m_pSource->GetError();
      // This error probably indicates an I/O error, rather than a decoding
      // error.
      if (LOG != nullptr) {
        LOG->Warn(
            "Decoding %s failed: %s", GetLoadedFilePath().c_str(),
            m_sError.c_str());
      }
    }

    if (iGotFrames < 0) {
      if (!iFramesStored) {
        return iGotFrames;
      } else {
        break;
      }
    }

    // Scoped global audio mutex lock while updating the position maps.
    {
      LockMut(m_Mutex);
      m_StreamToSourceMap.Insert(
          m_iStreamFrame, iGotFrames, iSourceFrame, fRate);
      m_iStreamFrame += iGotFrames;
    }

    iFramesStored += iGotFrames;
    iFrames -= iGotFrames;
  }
  if (m_pSource->GetNumChannels() == 1) {
    RageSoundUtil::ConvertMonoToStereoInPlace(pBuffer, iFramesStored);
  }

  return iFramesStored;
}

/* Indicate that a block of audio data has been written to the device. */
void RageSound::CommitPlayingPosition(
    int64_t iHardwareFrame, int64_t iStreamFrame, int iGotFrames) {
  if (iHardwareFrame < 0 || iStreamFrame < 0 || iGotFrames <= 0) {
    return;
  }
  m_Mutex.Lock();
  m_HardwareToStreamMap.Insert(iHardwareFrame, iGotFrames, iStreamFrame);
  m_Mutex.Unlock();
}

/* Start playing from the current position. */
bool RageSound::StartPlaying() {
  if (IsPlaying()) {
    return false;
  }
  if (m_pSource == nullptr) {
    if (LOG != nullptr) {
      LOG->Warn("RageSound::StartPlaying: sound not loaded");
    }
    return false;
  }
  const int sampleRate = m_pSource->GetSampleRate();
  if (sampleRate <= 0 || SOUNDMAN == nullptr) {
    if (LOG != nullptr) {
      LOG->Warn(
          "RageSound::StartPlaying: invalid state for \"%s\" "
          "(sample_rate=%d soundman=%p)",
          GetLoadedFilePath().c_str(), sampleRate,
          static_cast<void*>(SOUNDMAN));
    }
    return false;
  }
  m_Param = NormalizeSoundParams(m_Param);

  // Move to the start position.
  const double startFrame = m_Param.m_StartSecond * sampleRate + 0.5;
  if (!std::isfinite(startFrame) || startFrame > INT_MAX) {
    if (LOG != nullptr) {
      LOG->Warn(
          "RageSound::StartPlaying: invalid start frame for \"%s\"",
          GetLoadedFilePath().c_str());
    }
    return false;
  }
  if (!SetPositionFrames(static_cast<int>(startFrame))) {
    return false;
  }

  /* If m_StartTime is in the past, then we probably set a start time but took
   * too long loading.  We don't want that; log it, since it can be unobvious.
   */
  if (!m_Param.m_StartTime.IsZero() && m_Param.m_StartTime.Ago() > 0) {
    if (LOG != nullptr) {
      LOG->Trace(
          "Sound \"%s\" has a start time %f seconds in the past",
          GetLoadedFilePath().c_str(), m_Param.m_StartTime.Ago());
    }
  }

  /* Tell the sound manager to start mixing us. */
  //	LOG->Trace("set playing true for %p (StartPlaying) (%s)", this,
  // this->GetLoadedFilePath().c_str());

  m_bPlaying.store(true, std::memory_order_release);

  /* Save the attract volume, so changes don't affect previously played
   * sounds. */
  m_Param.m_fAttractVolume = SOUNDMAN->GetVolumeOfNonCriticalSounds();
  ApplyParams();

  /* Don't lock while calling SOUNDMAN driver calls. */
  ASSERT(!m_Mutex.IsLockedByThisThread());

  SOUNDMAN->StartMixing(this);

  //	LOG->Trace("StartPlaying %p finished (%s)", this,
  // this->GetLoadedFilePath().c_str());
  return true;
}

void RageSound::StopPlaying() {
  /* Don't lock while calling SOUNDMAN driver calls. */
  ASSERT(!m_Mutex.IsLockedByThisThread());

  /* Tell the sound driver to stop mixing this sound. */
  if (SOUNDMAN != nullptr) {
    SOUNDMAN->StopMixing(this);
  }
}

/* This is called by sound drivers when we're done playing. */
void RageSound::SoundIsFinishedPlaying() {
  if (!IsPlaying()) {
    return;
  }

  // Get current hardware position to update stopped source frame when sound
  // finishes playing.
  int64_t iCurrentHardwareFrame =
      SOUNDMAN != nullptr ? SOUNDMAN->GetPosition(nullptr) : 0;

  // Make the decision to delete while inside the lock.
  // Do the actual deletion after releasing the mutex.
  bool bDeleteThis = false;
  {
    // Global sound mutex
    LockMut(m_Mutex);

    // Update the stopped source frame using the current hardware frame,
    // but only if the hardware-to-stream and stream-to-source maps are not
    // empty. This branch handles normal cleanup when the sound is not scheduled
    // for deletion. If the maps are empty, we leave m_iStoppedSourceFrame
    // untouched.
    if (m_bDeleteWhenFinished) {
      m_bDeleteWhenFinished = false;
      bDeleteThis = true;
      m_bPlaying.store(false, std::memory_order_release);
      m_HardwareToStreamMap.Clear();
      m_StreamToSourceMap.Clear();
    } else {
      if (!m_HardwareToStreamMap.IsEmpty() && !m_StreamToSourceMap.IsEmpty()) {
        // Update stopped position only if maps are available; otherwise,
        // preserve existing value.
        m_iStoppedSourceFrame = static_cast<int>(
            GetSourceFrameFromHardwareFrame(iCurrentHardwareFrame));
      }

      m_bPlaying.store(false, std::memory_order_release);
      m_HardwareToStreamMap.Clear();
      m_StreamToSourceMap.Clear();
    }
  }

  if (bDeleteThis) {
    delete this;
    return;
  }
}

void RageSound::Play(bool is_action, const RageSoundParams* pParams) {
  if (m_pSource == nullptr) {
    if (LOG != nullptr) {
      LOG->Warn("RageSound::Play: sound not loaded");
    }
    return;
  }
  if (is_action && PREFSMAN != nullptr && PREFSMAN->m_MuteActions) {
    return;
  }

  if (IsPlaying()) {
    PlayCopy(is_action, pParams);
    return;
  }

  if (pParams) {
    SetParams(*pParams);
  }

  StartPlaying();
}

void RageSound::PlayCopy(bool is_action, const RageSoundParams* pParams) const {
  if (is_action && PREFSMAN != nullptr && PREFSMAN->m_MuteActions) {
    return;
  }
  if (m_pSource == nullptr) {
    if (LOG != nullptr) {
      LOG->Warn("RageSound::PlayCopy: sound not loaded");
    }
    return;
  }
  std::unique_ptr<RageSound> pSound(new RageSound(*this));
  if (!pSound->IsLoaded()) {
    return;
  }

  if (pParams) {
    pSound->SetParams(*pParams);
  }

  if (pSound->StartPlaying()) {
    pSound.release()->DeleteSelfWhenFinishedPlaying();
  }
}

void RageSound::Stop() { StopPlaying(); }

bool RageSound::IsPlayingThreadSafe() const {
  return IsPlaying();
}

bool RageSound::PrefersStrongPrebuffer() const {
  LockMut(m_Mutex);
  return m_bPreferStrongPrebuffer;
}

bool RageSound::Pause(bool bPause) {
  if (m_pSource == nullptr) {
    if (LOG != nullptr) {
      LOG->Warn("RageSound::Pause: sound not loaded");
    }
    return false;
  }

  return SOUNDMAN != nullptr && SOUNDMAN->Pause(this, bPause);
}

float RageSound::GetLengthSeconds() {
  if (m_pSource == nullptr) {
    if (LOG != nullptr) {
      LOG->Warn("RageSound::GetLengthSeconds: sound not loaded");
    }
    return -1;
  }

  int iLength = m_pSource->GetLength();

  if (iLength < 0) {
    if (LOG != nullptr) {
      LOG->Warn(
          "GetLengthSeconds failed on %s: %s", GetLoadedFilePath().c_str(),
          m_pSource->GetError().c_str());
    }
    return -1;
  }

  return iLength / 1000.f;  // ms -> secs
}

int RageSound::GetSourceFrameFromHardwareFrame(int64_t iHardwareFrame) const {
  if (m_HardwareToStreamMap.IsEmpty() || m_StreamToSourceMap.IsEmpty()) {
    return 0;
  }

  const int driverSampleRate =
      SOUNDMAN != nullptr ? SOUNDMAN->GetDriverSampleRate()
                          : FALLBACK_SAMPLE_RATE;
  const int sourceSampleRate =
      m_pSource != nullptr ? m_pSource->GetSampleRate() : 0;
  if (driverSampleRate <= 0 || sourceSampleRate <= 0) {
    return m_iStoppedSourceFrame;
  }
  int64_t iStreamFrame =
      m_HardwareToStreamMap.Search(iHardwareFrame, driverSampleRate);
  return static_cast<int>(
      m_StreamToSourceMap.Search(iStreamFrame, sourceSampleRate));
}

/* If non-nullptr, approximate is set to true if the returned time is
 * approximated because of underrun, the sound not having started (after Play())
 * or finished (after EOF) yet.
 *
 * If non-nullptr, Timestamp is set to the real clock time associated with the
 * returned sound position.  We might take a variable amount of time before
 * grabbing the timestamp (to lock SOUNDMAN); we might lose the scheduler after
 * grabbing it, when releasing SOUNDMAN.
 */
float RageSound::GetPositionSeconds(RageTimer* pTimestamp) const {
  if (m_pSource == nullptr) {
    return 0.0f;
  }
  const int sampleRate = m_pSource->GetSampleRate();
  if (sampleRate <= 0) {
    return 0.0f;
  }

  // Get our current hardware position.
  int64_t iCurrentHardwareFrame =
      SOUNDMAN != nullptr ? SOUNDMAN->GetPosition(pTimestamp) : 0;

  // cast the sample rate to be used for the remainder of the function.
  float fSampleRate = static_cast<float>(sampleRate);

  // Quick check without lock
  if (!IsPlaying()) {
    return static_cast<float>(m_iStoppedSourceFrame) / fSampleRate;
  }

  // If we don't have position information, CommitPlayingPosition hasn't been
  // called yet
  LockMut(m_Mutex);

  if (m_HardwareToStreamMap.IsEmpty() || m_StreamToSourceMap.IsEmpty()) {
    return static_cast<float>(m_iStoppedSourceFrame) / fSampleRate;
  }

  int iSourceFrame = GetSourceFrameFromHardwareFrame(iCurrentHardwareFrame);
  return static_cast<float>(iSourceFrame) / fSampleRate;
}

bool RageSound::SetPositionFrames(int iFrames) {
  LockMut(m_Mutex);

  if (m_pSource == nullptr) {
    if (LOG != nullptr) {
      LOG->Warn("RageSound::SetPositionFrames(%d): sound not loaded", iFrames);
    }
    return false;
  }
  if (iFrames < 0) {
    iFrames = 0;
  }

  int iRet = m_pSource->SetPosition(iFrames);
  std::string filePath = GetLoadedFilePath();
  if (iRet == -1) {
    m_sError = m_pSource->GetError();
    if (LOG != nullptr) {
      LOG->Warn(
          "SetPositionFrames: seek %s failed: %s", filePath.c_str(),
          m_sError.c_str());
    }
  } else if (iRet == 0) {
    /* Seeked past EOF. */
    if (LOG != nullptr) {
      LOG->Warn(
          "SetPositionFrames: %i samples is beyond EOF in %s", iFrames,
          filePath.c_str());
    }
  } else {
    m_iStoppedSourceFrame = iFrames;
  }

  return iRet == 1;
}

float RageSound::GetPlaybackRate() const { return m_Param.m_fSpeed; }

RageTimer RageSound::GetStartTime() const { return m_Param.m_StartTime; }

void RageSound::SetParams(const RageSoundParams& p) {
  m_Param = NormalizeSoundParams(p);
  ApplyParams();
}

void RageSound::SetPrefersStrongPrebuffer(bool prefer) {
  LockMut(m_Mutex);
  m_bPreferStrongPrebuffer = prefer;
}

void RageSound::ApplyParams() {
  if (m_pSource == nullptr) {
    return;
  }

  RageSoundParams params = NormalizeSoundParams(m_Param);
  m_Param = params;

  m_pSource->SetProperty("Pitch", params.m_fPitch);
  m_pSource->SetProperty("Speed", params.m_fSpeed);
  m_pSource->SetProperty("StartSecond", params.m_StartSecond);
  m_pSource->SetProperty("LengthSeconds", params.m_LengthSeconds);
  m_pSource->SetProperty("FadeInSeconds", params.m_fFadeInSeconds);
  m_pSource->SetProperty("FadeSeconds", params.m_fFadeOutSeconds);

  float fVolume = params.m_Volume;
  if (!params.m_bIsCriticalSound) {
    fVolume *= params.m_fAttractVolume;
  }
  fVolume = ClampFinite(fVolume, 1.0f, 0.0f, kMaxSoundVolume);
  m_pSource->SetProperty("Volume", fVolume);

  switch (GetStopMode()) {
    case RageSoundParams::M_LOOP:
      m_pSource->SetProperty("Loop", 1.0f);
      break;
    case RageSoundParams::M_STOP:
      m_pSource->SetProperty("Stop", 1.0f);
      break;
    case RageSoundParams::M_CONTINUE:
      m_pSource->SetProperty("Continue", 1.0f);
      break;
    default:
      break;
  }
}

bool RageSound::SetProperty(const std::string& sProperty, float fValue) {
  if (m_pSource == nullptr || !std::isfinite(fValue)) {
    return false;
  }
  return m_pSource->SetProperty(sProperty, fValue);
}

bool RageSound::SetPositionSeconds(float seconds) {
  if (m_pSource == nullptr || m_pSource->GetSampleRate() <= 0 ||
      !std::isfinite(seconds)) {
    return false;
  }

  seconds = std::max(0.0f, seconds);
  const double frameDouble = seconds * m_pSource->GetSampleRate() + 0.5;
  if (!std::isfinite(frameDouble) || frameDouble > INT_MAX) {
    return false;
  }
  const int frame = static_cast<int>(frameDouble);
  return SetPositionFrames(frame);
}

RageSoundParams::StopMode_t RageSound::GetStopMode() const {
  if (m_Param.StopMode != RageSoundParams::M_AUTO) {
    return m_Param.StopMode;
  }

  if (m_sFilePath.find("loop") != std::string::npos) {
    return RageSoundParams::M_LOOP;
  } else {
    return RageSoundParams::M_STOP;
  }
}

void RageSound::SetStopModeFromString(const std::string& sStopMode) {
  std::string mode = sStopMode;
  MakeLower(mode);
  Trim(mode);
  if (mode == "stop") {
    m_Param.StopMode = RageSoundParams::M_STOP;
  } else if (mode == "loop") {
    m_Param.StopMode = RageSoundParams::M_LOOP;
  } else if (mode == "continue") {
    m_Param.StopMode = RageSoundParams::M_CONTINUE;
  } else if (mode == "auto") {
    m_Param.StopMode = RageSoundParams::M_AUTO;
  } else {
    if (LOG != nullptr) {
      LOG->Warn(
          "Invalid stop mode \"%s\" for sound \"%s\"", sStopMode.c_str(),
          m_sFilePath.c_str());
    }
  }
}

// lua start
#include "LuaBinding.h"

/** @brief Allow Lua to have access to the RageSound. */
class LunaRageSound : public Luna<RageSound> {
 public:
  static int get_length(T* p, lua_State* L) {
    RageSoundReader* reader = p->GetSoundReader();
    if (reader == nullptr) {
      lua_pushnumber(L, -1.0f);
    } else {
      lua_pushnumber(L, reader->GetLength() / 1000.0f);
    }
    return 1;
  }
  static int pitch(T* p, lua_State* L) {
    RageSoundParams params(p->GetParams());
    params.m_fPitch = FArg(1);
    p->SetParams(params);
    COMMON_RETURN_SELF;
  }

  static int speed(T* p, lua_State* L) {
    RageSoundParams params(p->GetParams());
    params.m_fSpeed = FArg(1);
    p->SetParams(params);
    COMMON_RETURN_SELF;
  }

  static int volume(T* p, lua_State* L) {
    RageSoundParams params(p->GetParams());
    params.m_Volume = FArg(1);
    p->SetParams(params);
    COMMON_RETURN_SELF;
  }

  static int SetProperty(T* p, lua_State* L) {
    LuaHelpers::Push(L, p->SetProperty(SArg(1), FArg(2)));
    return 1;
  }

  // Rename me and deprecate the above one? -DaisuMaster
  static int SetParam(T* p, lua_State* L) {
    RageSoundParams params(p->GetParams());

    std::string val = SArg(1);
    if (val == "StartSecond") {
      params.m_StartSecond = FArg(2);
    } else if (val == "LengthSeconds") {
      params.m_LengthSeconds = FArg(2);
    } else if (val == "FadeInSeconds") {
      params.m_fFadeInSeconds = FArg(2);
    } else if (val == "FadeSeconds") {
      params.m_fFadeOutSeconds = FArg(2);
    } else if (val == "Pitch") {
      params.m_fPitch = FArg(2);
    } else if (val == "Speed") {
      params.m_fSpeed = FArg(2);
    } else if (val == "Volume") {
      params.m_Volume = FArg(2);
    }

    p->SetParams(params);
    COMMON_RETURN_SELF;
  }

  /*
  static int SetStopMode( T* p, lua_State *L )
  {
          LuaHelpers::Push( L, p->SetStopModeFromString(SArg(1)) );
          return 1;
  }
  */

  LunaRageSound() {
    ADD_METHOD(get_length);
    ADD_METHOD(pitch);
    ADD_METHOD(speed);
    ADD_METHOD(volume);
    ADD_METHOD(SetProperty);
    ADD_METHOD(SetParam);
    // ADD_METHOD( SetStopMode );
  }
};

LUA_REGISTER_CLASS(RageSound)
// lua end

/*
 * Copyright (c) 2002-2004 Glenn Maynard
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
