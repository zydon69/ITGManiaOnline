#include "RageSoundReader_Chain.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <limits>
#include <map>
#include <memory>
#include <new>
#include <string>
#include <utility>
#include <vector>

#include "PerfDiagnostics.h"
#include "RageLog.h"
#include "RageSound.h"
#include "RageSoundConstants.h"
#include "RageSoundMixBuffer.h"
#include "RageSoundReader.h"
#include "RageSoundReader_FileReader.h"
#include "RageSoundReader_Pan.h"
#include "RageSoundReader_Preload.h"
#include "RageSoundReader_Resample_Good.h"
#include "RageUtil.h"
#include "StdString.h"
#include "global.h"

namespace {
static const unsigned MAX_CHAIN_CHANNELS = 64;

bool IsValidLoadedSoundIndex(
    const std::vector<std::unique_ptr<RageSoundReader>>& sounds, int index) {
  return index >= 0 && static_cast<size_t>(index) < sounds.size() &&
         sounds[index] != nullptr;
}

RageSoundReader* GetLoadedSound(
    const std::vector<std::unique_ptr<RageSoundReader>>& sounds, int index) {
  return IsValidLoadedSoundIndex(sounds, index)
             ? sounds[static_cast<size_t>(index)].get()
             : nullptr;
}

int SecondsToMilliseconds(float seconds) {
  if (!std::isfinite(seconds)) {
    return 0;
  }
  const double ms = static_cast<double>(seconds) * 1000.0;
  if (ms > std::numeric_limits<int>::max()) {
    return std::numeric_limits<int>::max();
  }
  if (ms < std::numeric_limits<int>::min()) {
    return std::numeric_limits<int>::min();
  }
  return static_cast<int>(std::lround(ms));
}

int SaturatingAddInt(int lhs, int rhs) {
  const int64_t sum = static_cast<int64_t>(lhs) + static_cast<int64_t>(rhs);
  if (sum > std::numeric_limits<int>::max()) {
    return std::numeric_limits<int>::max();
  }
  if (sum < std::numeric_limits<int>::min()) {
    return std::numeric_limits<int>::min();
  }
  return static_cast<int>(sum);
}

int ClampInt64ToInt(std::int64_t value) {
  if (value > std::numeric_limits<int>::max()) {
    return std::numeric_limits<int>::max();
  }
  if (value < std::numeric_limits<int>::min()) {
    return std::numeric_limits<int>::min();
  }
  return static_cast<int>(value);
}

bool AdvanceFrameCounter(std::int64_t* frame, int framesToAdvance) {
  if (frame == nullptr || framesToAdvance < 0) {
    return false;
  }
  if (*frame > std::numeric_limits<std::int64_t>::max() - framesToAdvance) {
    return false;
  }
  *frame += framesToAdvance;
  return true;
}

}  // namespace

/*
 * Keyed sounds should pass this object to SoundReader_Preload, to preprocess
 * it. Streaming more than two or three sounds is too expensive (keyed games can
 * play two dozen), and reading from disk is too latent.
 *
 * This can also be used for chained background music, which should always
 * stream, so we don't do the preloading in here.
 */
RageSoundReader_Chain::RageSoundReader_Chain() {
  // The preferred sample rate for resampling when sounds have different rates.
  m_iPreferredSampleRate = FALLBACK_SAMPLE_RATE;

  // The actual sample rate of the audio after resampling.
  // Used for timing calculations, such as sound offsets or frame positioning.
  m_iActualSampleRate = -1;

  m_iChannels = 0;
  m_iCurrentFrame = 0;
  m_iNextSound = 0;
}

RageSoundReader_Chain::~RageSoundReader_Chain() {
  /* Clear m_apActiveSounds. */
  while (!m_apActiveSounds.empty()) {
    ReleaseSound(m_apActiveSounds.front());
  }

  m_apNamedSounds.clear();
  m_apLoadedSounds.clear();
}

RageSoundReader_Chain* RageSoundReader_Chain::Copy() const {
  try {
    std::unique_ptr<RageSoundReader_Chain> copy(new RageSoundReader_Chain());
    copy->m_iPreferredSampleRate = this->m_iPreferredSampleRate;
    copy->m_iActualSampleRate = this->m_iActualSampleRate;
    copy->m_iChannels = this->m_iChannels;
    copy->m_iCurrentFrame = 0;
    copy->m_iNextSound = 0;
    copy->m_aPendingProperties = this->m_aPendingProperties;

    copy->m_apLoadedSounds.reserve(this->m_apLoadedSounds.size());
    for (const auto& it : this->m_apLoadedSounds) {
      if (it == nullptr) {
        copy->m_apLoadedSounds.emplace_back(nullptr);
        continue;
      }

      std::unique_ptr<RageSoundReader> readerCopy(it->Copy());
      if (readerCopy == nullptr) {
        SetError("failed to copy chain source reader");
        return nullptr;
      }
      copy->m_apLoadedSounds.push_back(std::move(readerCopy));
    }

    for (const auto& named : this->m_apNamedSounds) {
      auto it = std::find_if(
          this->m_apLoadedSounds.begin(), this->m_apLoadedSounds.end(),
          [&named](const std::unique_ptr<RageSoundReader>& reader) {
            return reader.get() == named.second;
          });
      if (it == this->m_apLoadedSounds.end()) {
        continue;
      }
      const size_t index = static_cast<size_t>(
          std::distance(this->m_apLoadedSounds.begin(), it));
      copy->m_apNamedSounds[named.first] =
          copy->m_apLoadedSounds[index].get();
    }

    copy->m_aSounds = this->m_aSounds;
    for (Sound& sound : copy->m_aSounds) {
      sound.pSound = nullptr;
    }
    if (copy->SetPosition(ClampInt64ToInt(this->m_iCurrentFrame)) ==
        RageSoundReader::ERROR) {
      SetError("failed to seek copied chain reader");
      return nullptr;
    }
    return copy.release();
  } catch (const std::bad_alloc&) {
    SetError("failed to allocate chain copy");
    return nullptr;
  }
}

/* The same sound may be used several times, and by several different chains.
 * Avoid loading the same sound multiple times.  We need to make a Copy() if we
 * need to read it more than once at a time. */
void RageSoundReader_Chain::AddSound(
    int iIndex, float fOffsetSecs, float fPan) {
  if (!IsValidLoadedSoundIndex(m_apLoadedSounds, iIndex)) {
    if (LOG != nullptr && iIndex != -1) {
      LOG->Warn("RageSoundReader_Chain::AddSound: invalid sound index %i",
                iIndex);
    }
    return;
  }

  Sound s;
  s.iIndex = iIndex;
  s.iOffsetMS = SecondsToMilliseconds(fOffsetSecs);
  s.fPan = std::isfinite(fPan) ? std::clamp(fPan, -1.0f, 1.0f) : 0.0f;
  s.pSound = nullptr;
  try {
    m_aSounds.push_back(s);
  } catch (const std::bad_alloc&) {
    SetError("failed to append chain sound event");
  }
}

int RageSoundReader_Chain::LoadSound(std::string sPath) {
  const std::string sOriginalPath = sPath;
  std::map<std::string, RageSoundReader*>::const_iterator it =
      m_apNamedSounds.find(sPath);
  if (it != m_apNamedSounds.end()) {
    const RageSoundReader* pReader = it->second;

    for (size_t i = 0; i < m_apLoadedSounds.size(); ++i) {
      if (m_apLoadedSounds[i].get() == pReader) {
        if (i > static_cast<size_t>(std::numeric_limits<int>::max())) {
          SetError("named sound index overflow");
          return -1;
        }
        return static_cast<int>(i);
      }
    }
    if (LOG != nullptr) {
      LOG->Warn(
          "RageSoundReader_Chain: named sound \"%s\" missing from loaded list",
          sPath.c_str());
    }
    return -1;
  }

  std::string sError;
  bool bPrebuffer;
  std::unique_ptr<RageSoundReader> pReader(
      RageSoundReader_FileReader::OpenFile(sOriginalPath, sError, &bPrebuffer));
  if (pReader == nullptr) {
    SetError(sError);
    if (LOG != nullptr) {
      LOG->Warn(
          "RageSoundReader_Chain: error opening sound \"%s\": %s",
          sOriginalPath.c_str(), sError.c_str());
    }
    return -1;
  }

  try {
    if (m_apLoadedSounds.size() >=
        static_cast<size_t>(std::numeric_limits<int>::max())) {
      SetError("too many chain sounds");
      return -1;
    }
    RageSoundReader* pRawReader = pReader.get();
    m_apLoadedSounds.push_back(std::move(pReader));
    try {
      m_apNamedSounds[sPath] = pRawReader;
    } catch (const std::bad_alloc&) {
      m_apLoadedSounds.pop_back();
      SetError("failed to cache named chain sound");
      return -1;
    }
  } catch (const std::bad_alloc&) {
    SetError("failed to store chain sound");
    return -1;
  }
  ClearError();
  return static_cast<int>(m_apLoadedSounds.size() - 1);
}

int RageSoundReader_Chain::LoadSound(RageSoundReader* pSound) {
  if (pSound == nullptr) {
    if (LOG != nullptr) {
      LOG->Warn("RageSoundReader_Chain::LoadSound: null sound reader");
    }
    return -1;
  }
  std::unique_ptr<RageSoundReader> soundOwner(pSound);
  try {
    if (m_apLoadedSounds.size() >=
        static_cast<size_t>(std::numeric_limits<int>::max())) {
      SetError("too many chain sounds");
      return -1;
    }
    m_apLoadedSounds.push_back(std::move(soundOwner));
  } catch (const std::bad_alloc&) {
    SetError("failed to store owned chain sound");
    return -1;
  }
  ClearError();
  return static_cast<int>(m_apLoadedSounds.size() - 1);
}

/* If every sound has the same sample rate, return it.  Otherwise, return -1. */
int RageSoundReader_Chain::GetSampleRateInternal() const {
  if (m_apLoadedSounds.empty()) {
    return m_iPreferredSampleRate;
  }

  int iRate = -1;
  for (const auto& it : m_apLoadedSounds) {
    if (it == nullptr) {
      continue;
    }
    if (iRate == -1) {
      iRate = it->GetSampleRate();
    } else if (iRate != it->GetSampleRate()) {
      return -1;
    }
  }
  return iRate == -1 ? m_iPreferredSampleRate : iRate;
}

int RageSoundReader_Chain::GetSampleRate() const {
  if (m_iActualSampleRate == -1) {
    return m_iPreferredSampleRate;
  }
  return m_iActualSampleRate;
}

void RageSoundReader_Chain::Finish() {
  /* Figure out how many channels we have.  All sounds must either have 1 or 2
   * channels, which will be converted as needed, or have the same number of
   * channels. */
  m_iChannels = 1;
  for (auto& it : m_apLoadedSounds) {
    if (it == nullptr) {
      continue;
    }
    if (!IsSoundTopologyUsable(it.get())) {
      RemoveNamedSoundPointersTo(it.get());
      it.reset();
      SetError("discarded invalid chain source "
               "topology");
      continue;
    }
    m_iChannels = std::max(m_iChannels, it->GetNumChannels());
  }

  if (m_iChannels > 2) {
    for (auto& it : m_apLoadedSounds) {
      if (it != nullptr && it->GetNumChannels() != m_iChannels) {
        if (LOG != nullptr) {
          LOG->Warn(
              "Discarded sound with %i channels, not %i", it->GetNumChannels(),
              m_iChannels);
        }
        RemoveNamedSoundPointersTo(it.get());
        it.reset();
      }
    }
  }

  /* Remove any sounds that don't have corresponding RageSoundReaders. */
  for (unsigned i = 0; i < m_aSounds.size();) {
    Sound& sound = m_aSounds[i];

    if (!IsValidLoadedSoundIndex(m_apLoadedSounds, sound.iIndex)) {
      m_aSounds.erase(m_aSounds.begin() + i);
      continue;
    }

    ++i;
  }

  /*
   * We might get different sample rates from our sources.  If they're all the
   * same sample rate, just leave it alone, so the whole sound can be resampled
   * as a group. If not, resample eveything to the preferred rate.  (Using the
   * preferred rate should avoid redundant resampling later.)
   */
  m_iActualSampleRate = GetSampleRateInternal();
  if (m_iActualSampleRate == -1) {
    if (m_iPreferredSampleRate <= 0) {
      m_iPreferredSampleRate = FALLBACK_SAMPLE_RATE;
    }
    for (auto& pSound : m_apLoadedSounds) {
      if (pSound == nullptr) {
        continue;
      }
      try {
        std::unique_ptr<RageSoundReader> original(std::move(pSound));
        RageSoundReader* pOldSound = original.get();
        RageSoundReader* pRawOriginal = original.release();
        std::unique_ptr<RageSoundReader> pResample;
        try {
          pResample.reset(new RageSoundReader_Resample_Good(
              pRawOriginal, m_iPreferredSampleRate));
          pRawOriginal = nullptr;
        } catch (...) {
          original.reset(pRawOriginal);
          pSound = std::move(original);
          throw;
        }
        if (!IsSoundTopologyUsable(pResample.get())) {
          SetError("chain resample wrapper has invalid "
                   "topology");
          pSound = std::move(pResample);
          ReplaceNamedSoundPointer(pOldSound, pSound.get());
          continue;
        }
        pSound = std::move(pResample);
        ReplaceNamedSoundPointer(pOldSound, pSound.get());
      } catch (const std::bad_alloc&) {
        SetError("failed to allocate chain resampler");
        continue;
      }
    }

    m_iActualSampleRate = m_iPreferredSampleRate;
  }

  /* Attempt to preload all sounds. */
  for (auto& pSound : m_apLoadedSounds) {
    if (pSound != nullptr) {
      RageSoundReader* pOldSound = pSound.get();
      RageSoundReader* pRawSound = pSound.release();
      if (!RageSoundReader_Preload::PreloadSound(pRawSound)) {
        SetError("chain preload failed");
      }
      pSound.reset(pRawSound);
      ReplaceNamedSoundPointer(pOldSound, pSound.get());
    }
  }

  /* Sort the sounds by start time. */
  sort(m_aSounds.begin(), m_aSounds.end());
}

int RageSoundReader_Chain::SetPosition(int iFrame) {
  /* Clear m_apActiveSounds. */
  while (!m_apActiveSounds.empty()) {
    ReleaseSound(m_apActiveSounds.front());
  }

  m_iCurrentFrame = std::max(0, iFrame);

  /* Run through all sounds in the chain, and activate all sounds which have
   * data at iFrame. */
  for (m_iNextSound = 0; m_iNextSound < m_aSounds.size(); ++m_iNextSound) {
    Sound* pSound = &m_aSounds[m_iNextSound];
    const std::int64_t iOffsetFrame =
        pSound->GetOffsetFrame64(GetSampleRate());

    /* If this sound is in the future, skip it. */
    if (iOffsetFrame > m_iCurrentFrame) {
      break;
    }

    /* Find the RageSoundReader. */
    if (!ActivateSound(pSound)) {
      while (!m_apActiveSounds.empty()) {
        ReleaseSound(m_apActiveSounds.front());
      }
      return RageSoundReader::ERROR;
    }
    RageSoundReader* pReader = pSound->pSound;

    const std::int64_t iOffsetFrames = m_iCurrentFrame - iOffsetFrame;
    if (pReader->SetPosition(ClampInt64ToInt(iOffsetFrames)) == 0) {
      /* We're past the end of this sound. */
      ReleaseSound(pSound);
      continue;
    }
  }

  /* If no sounds were started, and we have no sounds ahead of us, we've seeked
   * past EOF. */
  if (m_apActiveSounds.empty() && m_iNextSound == m_aSounds.size()) {
    return 0;
  }

  return 1;
}

bool RageSoundReader_Chain::ActivateSound(Sound* s) {
  if (s == nullptr || s->pSound != nullptr ||
      !IsValidLoadedSoundIndex(m_apLoadedSounds, s->iIndex)) {
    return false;
  }
  RageSoundReader* pSound = GetLoadedSound(m_apLoadedSounds, s->iIndex);
  std::unique_ptr<RageSoundReader> activeSound(pSound->Copy());
  if (activeSound == nullptr) {
    SetError("failed to copy active chain sound");
    if (LOG != nullptr) {
      LOG->Warn("RageSoundReader_Chain: failed to copy sound index %i",
                s->iIndex);
    }
    return false;
  }

  /* Add a balance filter.  If this source has the same number of channels
   * as this sound, and does not need to be panned, we can omit this. */
  if (s->fPan != 0.0f || activeSound->GetNumChannels() != this->GetNumChannels()) {
    try {
      activeSound.reset(new RageSoundReader_Pan(activeSound.release()));
    } catch (const std::bad_alloc&) {
      SetError("failed to allocate chain pan filter");
      return false;
    }
    if (!activeSound->SetProperty("Pan", s->fPan)) {
      SetError("failed to configure chain pan filter");
      return false;
    }
  }

  if (!ApplyPendingProperties(activeSound.get())) {
    return false;
  }

  try {
    m_apActiveSounds.push_back(s);
  } catch (const std::bad_alloc&) {
    SetError("failed to store active chain sound");
    return false;
  }
  s->pSound = activeSound.release();
  return true;
}

void RageSoundReader_Chain::ReleaseSound(Sound* s) {
  std::vector<Sound*>::iterator it =
      find(m_apActiveSounds.begin(), m_apActiveSounds.end(), s);
  if (it == m_apActiveSounds.end()) {
    if (LOG != nullptr) {
      LOG->Warn("RageSoundReader_Chain::ReleaseSound: sound not active");
    }
    return;
  }
  RageSoundReader*& pSound = s->pSound;

  delete pSound;
  pSound = nullptr;

  m_apActiveSounds.erase(it);
}

bool RageSoundReader_Chain::SetProperty(
    const std::string& sProperty, float fValue) {
  auto pending = std::find_if(
      m_aPendingProperties.begin(), m_aPendingProperties.end(),
      [&sProperty](const std::pair<std::string, float>& property) {
        return property.first == sProperty;
      });
  if (pending == m_aPendingProperties.end()) {
    try {
      m_aPendingProperties.emplace_back(sProperty, fValue);
    } catch (const std::bad_alloc&) {
      SetError("failed to store chain property");
      return false;
    }
  } else {
    pending->second = fValue;
  }

  for (unsigned i = 0; i < m_apActiveSounds.size(); ++i) {
    if (m_apActiveSounds[i]->pSound != nullptr) {
      m_apActiveSounds[i]->pSound->SetProperty(sProperty, fValue);
    }
  }
  ClearError();
  return true;
}

int RageSoundReader_Chain::GetNextSourceFrame() const {
  return ClampInt64ToInt(m_iCurrentFrame);
  /*	if( m_apActiveSounds.empty() )
                  return m_iCurrentFrame;

          int iPosition = m_apActiveSounds[0]->pSound->GetNextSourceFrame();
          iPosition += m_apActiveSounds[0]->GetOffsetFrame( GetSampleRate() );

          for( unsigned i = 1; i < m_apActiveSounds.size(); ++i )
          {
                  int iThisPosition =
     m_apActiveSounds[i]->pSound->GetNextSourceFrame(); iThisPosition +=
     m_apActiveSounds[i]->GetOffsetFrame( GetSampleRate() ); if( iThisPosition
     != iPosition ) LOG->Warn( "RageSoundReader_Chain: sound positions moving at
     different rates" );
          }

          return iPosition;
  */
}

std::int64_t RageSoundReader_Chain::GetNextSourceFrame64() const {
  return m_iCurrentFrame;
}

float RageSoundReader_Chain::GetStreamToSourceRatio() const {
  if (m_apActiveSounds.empty()) {
    return 1.0f;
  }

  if (m_apActiveSounds[0]->pSound == nullptr) {
    return 1.0f;
  }
  float iRate = m_apActiveSounds[0]->pSound->GetStreamToSourceRatio();
  for (unsigned i = 1; i < m_apActiveSounds.size(); ++i) {
    if (m_apActiveSounds[i]->pSound != nullptr &&
        m_apActiveSounds[i]->pSound->GetStreamToSourceRatio() != iRate) {
      if (LOG != nullptr) {
        LOG->Warn("RageSoundReader_Chain: sound rates changing differently");
      }
    }
  }

  return iRate;
}

/* As we iterate through the sound tree, we'll find that we need data from
 * different sounds; a sound may be needed by more than one other sound. */
int RageSoundReader_Chain::Read(float* pBuffer, int iFrames) {
  if (pBuffer == nullptr || iFrames < 0 || m_iChannels == 0 ||
      GetSampleRate() <= 0) {
    SetError("invalid chain read state");
    return ERROR;
  }
  if (iFrames == 0) {
    return 0;
  }
  const int iRequestedFrames = iFrames;
  for (;;) {
    while (m_iNextSound < m_aSounds.size() &&
           m_iCurrentFrame ==
               m_aSounds[m_iNextSound].GetOffsetFrame64(m_iActualSampleRate)) {
      Sound* pSound = &m_aSounds[m_iNextSound];
      if (!ActivateSound(pSound)) {
        return ERROR;
      }
      ++m_iNextSound;
    }

    if (m_iNextSound == m_aSounds.size() && m_apActiveSounds.empty()) {
      return END_OF_FILE;
    }

    /* Clamp iFrames to the beginning of the next sound we need to start. */
    iFrames = iRequestedFrames;
    if (m_iNextSound < m_aSounds.size()) {
      const std::int64_t iOffsetFrame =
          m_aSounds[m_iNextSound].GetOffsetFrame64(m_iActualSampleRate);
      std::int64_t iFramesToRead = iOffsetFrame - m_iCurrentFrame;
      if (iFramesToRead < 0) {
        SetError("chain cursor passed a pending sound");
        return ERROR;
      }
      iFrames = std::min(ClampInt64ToInt(iFramesToRead), iFrames);
    }
    if (iFrames == 0) {
      continue;
    }

    if (m_apActiveSounds.size() == 1 &&
        m_apActiveSounds.front()->pSound != nullptr &&
        m_apActiveSounds.front()->pSound->GetNumChannels() == m_iChannels &&
        m_apActiveSounds.front()->pSound->GetSampleRate() ==
            m_iActualSampleRate) {
      /* We have only one source, and it matches our target.  Don't mix; read
       * directly from the source into the destination.  This is to optimize
       * the common case of having one BGM track and no autoplay sounds. */
      const int iRead =
          m_apActiveSounds.front()->pSound->Read(pBuffer, iFrames);
      if (iRead == RageSoundReader::ERROR) {
        ReleaseSound(m_apActiveSounds.front());
        return ERROR;
      }
      if (iRead == RageSoundReader::END_OF_FILE) {
        ReleaseSound(m_apActiveSounds.front());
        continue;
      }
      if (iRead > 0 && !AdvanceFrameCounter(&m_iCurrentFrame, iRead)) {
        SetError("chain frame counter overflow");
        return ERROR;
      }
      return iRead;
    }

    // Note: this is only safe because we know pBuffer is not nullptr
    // and iFrames and m_iChannels are reasonable sizes.
    if (m_apActiveSounds.empty()) {
      /* If we have more sounds ahead of us, pretend we read the entire block,
       * since there's silence in between.  Otherwise, we're at EOF. */
      const size_t channels = static_cast<size_t>(m_iChannels);
      if (static_cast<size_t>(iFrames) >
          std::numeric_limits<size_t>::max() / channels / sizeof(float)) {
        SetError("chain silence buffer overflow");
        return ERROR;
      }
      size_t pBufferSize =
          static_cast<size_t>(iFrames) * channels * sizeof(float);
      memset(pBuffer, 0, pBufferSize);
      if (!AdvanceFrameCounter(&m_iCurrentFrame, iFrames)) {
        SetError("chain frame counter overflow");
        return ERROR;
      }
      return iFrames;
    }

    break;
  }

  RageSoundMixBuffer mix;
  /* Read iFrames from each sound. */
  float Buffer[2048];
  iFrames = std::min(iFrames, (int)(ARRAYLEN(Buffer) / m_iChannels));
  if (iFrames <= 0) {
    return ERROR;
  }
  bool bSawWouldBlock = false;
  for (unsigned i = 0; i < m_apActiveSounds.size();) {
    RageSoundReader* pSound = m_apActiveSounds[i]->pSound;
    if (pSound == nullptr) {
      ReleaseSound(m_apActiveSounds[i]);
      continue;
    }
    ASSERT(
        pSound->GetNumChannels() ==
        m_iChannels);  // guaranteed by ActivateSound and Finish

    /* If we receive less than we were asked for, keep asking for more data.
     * Most filters would simply return what they have in this situation, but we
     * want to deal transparently with separate sounds returning
     * differently-sized partial blocks. */
    int iFramesRead = 0;
    while (iFramesRead < iFrames) {
      int iGotFrames = pSound->RetriedRead(Buffer, iFrames - iFramesRead);
      if (iGotFrames == RageSoundReader::WOULD_BLOCK) {
        bSawWouldBlock = true;
        iFramesRead = iGotFrames;
        break;
      }
      if (iGotFrames < 0) {
        iFramesRead = iGotFrames;
        break;
      }
      if (iGotFrames == 0) {
        break;
      }

      const unsigned soundChannels = pSound->GetNumChannels();
      if (static_cast<unsigned>(iFramesRead) >
              static_cast<unsigned>(std::numeric_limits<int>::max()) /
                  soundChannels ||
          !mix.SetWriteOffset(
              static_cast<int>(iFramesRead * soundChannels)) ||
          !mix.write(Buffer, static_cast<size_t>(iGotFrames) * soundChannels)) {
        SetError("chain mix buffer write failed");
        LOG->Warn(
            "RageSoundReader_Chain: mix buffer write failed: %s",
            mix.GetError().c_str());
        return ERROR;
      }
      iFramesRead += iGotFrames;
    }

    if (iFramesRead == RageSoundReader::WOULD_BLOCK) {
      ++i;
    } else if (iFramesRead < 0) {
      ReleaseSound(m_apActiveSounds[i]);
    } else {
      ++i;
    }
  }

  /* Read mixed frames into the output buffer. */
  int iMaxFramesRead = ClampInt64ToInt(
      static_cast<std::int64_t>(mix.size() / m_iChannels));
  if (iMaxFramesRead <= 0) {
    if (bSawWouldBlock) {
      return RageSoundReader::WOULD_BLOCK;
    }
    if (m_apActiveSounds.empty() && m_iNextSound < m_aSounds.size()) {
      const std::int64_t nextOffset =
          m_aSounds[m_iNextSound].GetOffsetFrame64(m_iActualSampleRate);
      const std::int64_t silentFrames = nextOffset - m_iCurrentFrame;
      if (silentFrames <= 0) {
        SetError(
            "chain could not advance to pending sound");
        return ERROR;
      }
      const int framesToWrite =
          std::min(iRequestedFrames, ClampInt64ToInt(silentFrames));
      const size_t channels = static_cast<size_t>(m_iChannels);
      if (static_cast<size_t>(framesToWrite) >
          std::numeric_limits<size_t>::max() / channels / sizeof(float)) {
        SetError("chain silence buffer overflow");
        return ERROR;
      }
      memset(
          pBuffer, 0,
          static_cast<size_t>(framesToWrite) * channels * sizeof(float));
      if (!AdvanceFrameCounter(&m_iCurrentFrame, framesToWrite)) {
        SetError("chain frame counter overflow");
        return ERROR;
      }
      return framesToWrite;
    }
    if (m_apActiveSounds.empty()) {
      return RageSoundReader::END_OF_FILE;
    }
    return 0;
  }
  if (!mix.read(pBuffer)) {
    SetError("chain mix buffer read failed");
    LOG->Warn(
        "RageSoundReader_Chain: mix buffer read failed: %s",
        mix.GetError().c_str());
    return ERROR;
  }
  if (!AdvanceFrameCounter(&m_iCurrentFrame, iMaxFramesRead)) {
    SetError("chain frame counter overflow");
    return ERROR;
  }
  ClearError();

  return iMaxFramesRead;
}

void RageSoundReader_Chain::ClearError() const {
  m_sError.clear();
}

void RageSoundReader_Chain::SetError(const std::string& sError) const {
  LogRuntimeValidationDiagnostics("%s", sError.c_str());
  m_sError = sError;
}

void RageSoundReader_Chain::RemoveNamedSoundPointersTo(
    const RageSoundReader* pSound) {
  if (pSound == nullptr) {
    return;
  }
  for (auto it = m_apNamedSounds.begin(); it != m_apNamedSounds.end();) {
    if (it->second == pSound) {
      it = m_apNamedSounds.erase(it);
    } else {
      ++it;
    }
  }
}

void RageSoundReader_Chain::ReplaceNamedSoundPointer(
    const RageSoundReader* pOldSound, RageSoundReader* pNewSound) {
  if (pOldSound == nullptr || pNewSound == nullptr) {
    return;
  }
  for (auto& namedSound : m_apNamedSounds) {
    if (namedSound.second == pOldSound) {
      namedSound.second = pNewSound;
    }
  }
}

bool RageSoundReader_Chain::IsSoundTopologyUsable(
    const RageSoundReader* pSound) const {
  if (pSound == nullptr) {
    return false;
  }
  const unsigned channels = pSound->GetNumChannels();
  return pSound->GetSampleRate() > 0 && channels > 0 &&
         channels <= MAX_CHAIN_CHANNELS;
}

bool RageSoundReader_Chain::ApplyPendingProperties(RageSoundReader* pSound)
    const {
  if (pSound == nullptr) {
    return false;
  }
  for (const auto& property : m_aPendingProperties) {
    pSound->SetProperty(property.first, property.second);
  }
  return true;
}

std::string RageSoundReader_Chain::GetError() const {
  if (!m_sError.empty()) {
    return m_sError;
  }

  for (const auto& activeSound : m_apActiveSounds) {
    if (activeSound != nullptr && activeSound->pSound != nullptr) {
      const std::string error = activeSound->pSound->GetError();
      if (!error.empty()) {
        return error;
      }
    }
  }

  return "";
}

int RageSoundReader_Chain::GetLength() const {
  int iLength = 0;
  for (unsigned i = 0; i < m_aSounds.size(); ++i) {
    const Sound& sound = m_aSounds[i];
    if (!IsValidLoadedSoundIndex(m_apLoadedSounds, sound.iIndex)) {
      continue;
    }
    const RageSoundReader* pSound = m_apLoadedSounds[sound.iIndex].get();
    int iThisLength = pSound->GetLength();
    if (iThisLength) {
      iLength = std::max(
          iLength, SaturatingAddInt(iThisLength, sound.iOffsetMS));
    }
  }
  return iLength;
}

int RageSoundReader_Chain::GetLength_Fast() const {
  int iLength = 0;
  for (unsigned i = 0; i < m_aSounds.size(); ++i) {
    const Sound& sound = m_aSounds[i];
    if (!IsValidLoadedSoundIndex(m_apLoadedSounds, sound.iIndex)) {
      continue;
    }
    const RageSoundReader* pSound = m_apLoadedSounds[sound.iIndex].get();
    int iThisLength = pSound->GetLength_Fast();
    if (iThisLength) {
      iLength = std::max(
          iLength, SaturatingAddInt(iThisLength, sound.iOffsetMS));
    }
  }
  return iLength;
}

/*
 * Copyright (c) 2004-2006 Glenn Maynard
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
