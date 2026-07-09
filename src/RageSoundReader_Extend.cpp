#include "RageSoundReader_Extend.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <cstdint>
#include <limits>
#include <memory>
#include <new>
#include <string>

#include "RageLog.h"
#include "RageSoundReader.h"
#include "RageSoundReader_Filter.h"
#include "RageSoundUtil.h"
#include "RageUtil.h"
#include "global.h"

namespace {
bool FramesToSamples(int iFrames, unsigned iChannels, size_t* pSamples) {
  if (iFrames < 0 || iChannels == 0) {
    return false;
  }
  const size_t frames = static_cast<size_t>(iFrames);
  const size_t channels = static_cast<size_t>(iChannels);
  if (frames > std::numeric_limits<size_t>::max() / channels) {
    return false;
  }
  *pSamples = frames * channels;
  return true;
}

bool SecondsToFrames(float fSeconds, int iSampleRate, std::int64_t* pFrames) {
  if (!std::isfinite(fSeconds) || iSampleRate <= 0) {
    return false;
  }
  const double frames =
      static_cast<double>(fSeconds) * static_cast<double>(iSampleRate);
  if (frames < static_cast<double>(std::numeric_limits<std::int64_t>::min()) ||
      frames > static_cast<double>(std::numeric_limits<std::int64_t>::max())) {
    return false;
  }
  *pFrames = static_cast<std::int64_t>(frames + (frames >= 0.0 ? 0.5 : -0.5));
  return true;
}

bool NonNegativeSecondsToFrames(
    float fSeconds, int iSampleRate, std::int64_t* pFrames) {
  if (fSeconds < 0.0f) {
    return false;
  }
  return SecondsToFrames(fSeconds, iSampleRate, pFrames);
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

bool AddFrames(std::int64_t a, std::int64_t b, std::int64_t* pResult) {
  if (pResult == nullptr) {
    return false;
  }
  if ((b > 0 && a > std::numeric_limits<std::int64_t>::max() - b) ||
      (b < 0 && a < std::numeric_limits<std::int64_t>::min() - b)) {
    return false;
  }
  *pResult = a + b;
  return true;
}

bool SubtractFrames(std::int64_t a, std::int64_t b, std::int64_t* pResult) {
  if (b == std::numeric_limits<std::int64_t>::min()) {
    return false;
  }
  return AddFrames(a, -b, pResult);
}

bool AdvanceFrameByRatio(
    std::int64_t startFrame, int streamFrames, float ratio,
    std::int64_t* pResult) {
  if (pResult == nullptr || streamFrames < 0 ||
      !(std::isfinite(ratio) && ratio > 0.0f)) {
    return false;
  }
  const double delta = static_cast<double>(streamFrames) * ratio;
  if (!std::isfinite(delta) ||
      delta > static_cast<double>(std::numeric_limits<std::int64_t>::max())) {
    return false;
  }
  const std::int64_t rounded = static_cast<std::int64_t>(std::llround(delta));
  return AddFrames(startFrame, rounded, pResult);
}

bool FramesToMilliseconds(std::int64_t frames, int sampleRate, int* pMs) {
  if (frames < 0 || sampleRate <= 0 || pMs == nullptr) {
    return false;
  }
  const long double ms =
      static_cast<long double>(frames) * 1000.0L /
      static_cast<long double>(sampleRate);
  if (ms > static_cast<long double>(std::numeric_limits<int>::max())) {
    *pMs = std::numeric_limits<int>::max();
    return true;
  }
  *pMs = static_cast<int>(std::llround(ms));
  return true;
}

std::int64_t MillisecondsToFrames(int ms, int sampleRate) {
  if (ms <= 0 || sampleRate <= 0) {
    return 0;
  }
  return static_cast<std::int64_t>(ms) * sampleRate / 1000;
}
}  // namespace

/*
 * Add support for negative seeks (adding a delay), extending a sound
 * beyond its end (m_LengthSeconds and M_CONTINUE), looping and fading.
 * This filter is normally inserted before extended buffering, implementing
 * properties that can seek the sound; this results in buffered seeks, but
 * changes to these properties are delayed.
 */

RageSoundReader_Extend::RageSoundReader_Extend(RageSoundReader* pSource)
    : RageSoundReader_Filter(pSource) {
  if (pSource == nullptr) {
    SetError("SRC_AUDIT_FIX SRC-2751: extend reader has no source reader");
    if (LOG != nullptr) {
      LOG->Warn(
          "SRC_AUDIT_FIX SRC-2751: RageSoundReader_Extend created without "
          "a source reader.");
    }
    return;
  }

  m_iPositionFrames = pSource->GetNextSourceFrame();
}

RageSoundReader_Extend* RageSoundReader_Extend::Copy() const {
  try {
    std::unique_ptr<RageSoundReader> sourceCopy;
    if (!m_pSource.isNull()) {
      sourceCopy.reset(m_pSource->Copy());
      if (sourceCopy == nullptr) {
        SetError("SRC_AUDIT_FIX SRC-2890: failed to copy extend source reader");
        return nullptr;
      }
    }

    RageSoundReader* rawSource = sourceCopy.release();
    std::unique_ptr<RageSoundReader_Extend> copy;
    try {
      copy.reset(new RageSoundReader_Extend(rawSource));
      rawSource = nullptr;
    } catch (...) {
      sourceCopy.reset(rawSource);
      throw;
    }

    copy->m_iPositionFrames = m_iPositionFrames;
    copy->m_StopMode = m_StopMode;
    copy->m_iStartFrames = m_iStartFrames;
    copy->m_iLengthFrames = m_iLengthFrames;
    copy->m_iFadeInFrames = m_iFadeInFrames;
    copy->m_iFadeOutFrames = m_iFadeOutFrames;
    copy->m_bIgnoreFadeInFrames = m_bIgnoreFadeInFrames;
    copy->m_sError = m_sError;
    return copy.release();
  } catch (const std::bad_alloc&) {
    SetError("SRC_AUDIT_FIX SRC-2890: failed to allocate extend copy");
    return nullptr;
  } catch (...) {
    SetError("SRC_AUDIT_FIX SRC-2890: failed to copy extend reader");
    return nullptr;
  }
}

int RageSoundReader_Extend::GetLength() const {
  if (m_iLengthFrames != -1) {
    int ms = 0;
    if (!FramesToMilliseconds(m_iLengthFrames, GetSampleRate(), &ms)) {
      SetError("SRC_AUDIT_FIX SRC-2896: invalid extend length state");
      return RageSoundReader::ERROR;
    }
    return ms;
  }

  const int sourceLengthMs = RageSoundReader_Filter::GetLength();
  if (sourceLengthMs < 0) {
    return sourceLengthMs;
  }

  std::int64_t playbackFrames =
      MillisecondsToFrames(sourceLengthMs, GetSampleRate());
  if (!SubtractFrames(playbackFrames, m_iStartFrames, &playbackFrames)) {
    SetError("SRC_AUDIT_FIX SRC-2896: extend playback length overflow");
    return RageSoundReader::ERROR;
  }
  playbackFrames = std::max<std::int64_t>(0, playbackFrames);

  int ms = 0;
  if (!FramesToMilliseconds(playbackFrames, GetSampleRate(), &ms)) {
    SetError("SRC_AUDIT_FIX SRC-2896: invalid extend playback length");
    return RageSoundReader::ERROR;
  }
  return ms;
}

int RageSoundReader_Extend::GetLength_Fast() const {
  if (m_iLengthFrames != -1) {
    return GetLength();
  }

  const int sourceLengthMs = RageSoundReader_Filter::GetLength_Fast();
  if (sourceLengthMs < 0) {
    return sourceLengthMs;
  }

  std::int64_t playbackFrames =
      MillisecondsToFrames(sourceLengthMs, GetSampleRate());
  if (!SubtractFrames(playbackFrames, m_iStartFrames, &playbackFrames)) {
    SetError("SRC_AUDIT_FIX SRC-2896: extend fast length overflow");
    return RageSoundReader::ERROR;
  }
  playbackFrames = std::max<std::int64_t>(0, playbackFrames);

  int ms = 0;
  if (!FramesToMilliseconds(playbackFrames, GetSampleRate(), &ms)) {
    SetError("SRC_AUDIT_FIX SRC-2896: invalid extend fast length");
    return RageSoundReader::ERROR;
  }
  return ms;
}

int RageSoundReader_Extend::SetPosition(int iFrame) {
  if (m_pSource.isNull()) {
    SetError("SRC_AUDIT_FIX SRC-2894: extend seek has no source reader");
    return RageSoundReader::ERROR;
  }

  int iRet = m_pSource->SetPosition(std::max(iFrame, 0));
  if (iRet < 0) {
    SetError("SRC_AUDIT_FIX SRC-2891: extend source seek failed");
    return iRet;
  }

  m_bIgnoreFadeInFrames = false;
  m_iPositionFrames = iFrame;

  if (m_iLengthFrames != -1) {
    std::int64_t endFrame = -1;
    if (!GetEndFrame(&endFrame)) {
      return RageSoundReader::ERROR;
    }
    ClearError();
    return m_iPositionFrames < endFrame ? 1 : 0;
  }

  /* If we're in CONTINUE and we seek past the end of the file, don't return
   * EOF. */
  if (m_StopMode == M_CONTINUE) {
    ClearError();
    return 1;
  }

  ClearError();
  return iRet;
}

bool RageSoundReader_Extend::GetEndFrame(std::int64_t* pEndFrame) const {
  if (pEndFrame == nullptr) {
    return false;
  }
  if (m_iLengthFrames == -1) {
    *pEndFrame = -1;
    return true;
  }

  if (!AddFrames(m_iStartFrames, m_iLengthFrames, pEndFrame)) {
    SetError("SRC_AUDIT_FIX SRC-2893: extend end frame overflow");
    return false;
  }
  return true;
}

int RageSoundReader_Extend::GetData(
    float* pBuffer, int iFrames, bool* pAdvancedPosition,
    std::int64_t* pBlockStartFrame) {
  if (pAdvancedPosition != nullptr) {
    *pAdvancedPosition = false;
  }
  if (pBlockStartFrame != nullptr) {
    *pBlockStartFrame = m_iPositionFrames;
  }
  if (iFrames == 0) {
    return 0;
  }
  if (pBuffer == nullptr || iFrames < 0 || m_pSource.isNull()) {
    SetError("SRC_AUDIT_FIX SRC-2894: invalid extend data request");
    return RageSoundReader::ERROR;
  }

  int iFramesToRead = iFrames;
  if (m_iLengthFrames != -1) {
    std::int64_t endFrame = -1;
    if (!GetEndFrame(&endFrame)) {
      return RageSoundReader::ERROR;
    }
    std::int64_t iFramesLeft = 0;
    if (!SubtractFrames(endFrame, m_iPositionFrames, &iFramesLeft)) {
      SetError("SRC_AUDIT_FIX SRC-2893: extend remaining frame overflow");
      return RageSoundReader::ERROR;
    }
    iFramesLeft = std::max<std::int64_t>(0, iFramesLeft);
    iFramesToRead = static_cast<int>(
        std::min<std::int64_t>(iFramesToRead, iFramesLeft));
  }

  if (iFrames && !iFramesToRead) {
    return RageSoundReader::END_OF_FILE;
  }

  if (m_iPositionFrames < 0) {
    const std::int64_t framesUntilSource =
        m_iPositionFrames == std::numeric_limits<std::int64_t>::min()
            ? std::numeric_limits<std::int64_t>::max()
            : -m_iPositionFrames;
    iFramesToRead = static_cast<int>(
        std::min<std::int64_t>(iFramesToRead, framesUntilSource));
    size_t samples = 0;
    if (!FramesToSamples(iFramesToRead, this->GetNumChannels(), &samples) ||
        samples > std::numeric_limits<size_t>::max() / sizeof(float)) {
      SetError("SRC_AUDIT_FIX SRC-2894: extend silence sample count overflow");
      return RageSoundReader::ERROR;
    }
    memset(pBuffer, 0, samples * sizeof(float));
    return iFramesToRead;
  }

  const std::int64_t iSourceStartFrame = m_pSource->GetNextSourceFrame();
  const float fSourceRatio = m_pSource->GetStreamToSourceRatio();
  int iRet = RageSoundReader_Filter::Read(pBuffer, iFramesToRead);

  /* Update the position from the source.  If the source is at EOF, skip this,
   * so we'll extrapolate in M_CONTINUE. */
  if (iRet > 0) {
    std::int64_t nextSourceFrame = iSourceStartFrame;
    if (!AdvanceFrameByRatio(
            iSourceStartFrame, iRet, fSourceRatio, &nextSourceFrame)) {
      SetError("SRC_AUDIT_FIX SRC-2897: extend source frame advance failed");
      return RageSoundReader::ERROR;
    }
    m_iPositionFrames = nextSourceFrame;
    if (pAdvancedPosition != nullptr) {
      *pAdvancedPosition = true;
    }
  }
  return iRet;
}

int RageSoundReader_Extend::Read(float* pBuffer, int iFrames) {
  if (iFrames == 0) {
    return 0;
  }
  if (pBuffer == nullptr || iFrames < 0) {
    SetError("SRC_AUDIT_FIX SRC-2894: invalid extend read request");
    return RageSoundReader::ERROR;
  }
  bool bAdvancedPosition = false;
  std::int64_t iBlockStartFrame = m_iPositionFrames;
  int iFramesRead =
      GetData(pBuffer, iFrames, &bAdvancedPosition, &iBlockStartFrame);
  if (iFramesRead == RageSoundReader::END_OF_FILE) {
    std::int64_t endFrame = -1;
    bool bShouldContinue = m_StopMode == M_CONTINUE;
    if (m_iLengthFrames != -1) {
      if (!GetEndFrame(&endFrame)) {
        return RageSoundReader::ERROR;
      }
      bShouldContinue = bShouldContinue || m_iPositionFrames < endFrame;
    }
    if (bShouldContinue) {
      iFramesRead = iFrames;
      if (m_StopMode != M_CONTINUE) {
        std::int64_t framesToEnd = 0;
        if (!SubtractFrames(endFrame, m_iPositionFrames, &framesToEnd)) {
          SetError("SRC_AUDIT_FIX SRC-2893: extend continuation frame "
                   "overflow");
          return RageSoundReader::ERROR;
        }
        iFramesRead = static_cast<int>(std::min<std::int64_t>(
            framesToEnd, iFramesRead));
      }
      size_t samples = 0;
      if (!FramesToSamples(iFramesRead, this->GetNumChannels(), &samples) ||
          samples > std::numeric_limits<size_t>::max() / sizeof(float)) {
        SetError("SRC_AUDIT_FIX SRC-2894: extend continuation sample count "
                 "overflow");
        return RageSoundReader::ERROR;
      }
      memset(pBuffer, 0, samples * sizeof(float));
      iBlockStartFrame = m_iPositionFrames;
      bAdvancedPosition = false;
    }
  }

  if (iFramesRead > 0) {
    if (m_iFadeInFrames != 0 && !m_bIgnoreFadeInFrames) {
      std::int64_t iBlockEndFrame = iBlockStartFrame;
      if (!AddFrames(iBlockStartFrame, iFramesRead, &iBlockEndFrame)) {
        SetError("SRC_AUDIT_FIX SRC-2893: extend fade-in frame overflow");
        return RageSoundReader::ERROR;
      }
      const float fStartVolume = SCALE(
          iBlockStartFrame, 0, m_iFadeInFrames, 0.0f, 1.0f);
      const float fEndVolume =
          SCALE(iBlockEndFrame, 0, m_iFadeInFrames, 0.0f, 1.0f);
      if (!RageSoundUtil::Fade(
              pBuffer, static_cast<size_t>(iFramesRead),
              this->GetNumChannels(), fStartVolume, fEndVolume)) {
        SetError("SRC_AUDIT_FIX SRC-2909: extend fade-in failed");
        return RageSoundReader::ERROR;
      }
    }

    /* We want to fade when there's m_iFadeFrames frames left, but if
     * m_LengthFrames is -1, we don't know the length we're playing.
     * (m_LengthFrames is the length to play, not the length of the
     * source.)  If we don't know the length, don't fade. */
    if (m_iFadeOutFrames != 0 && m_iLengthFrames != -1) {
      std::int64_t iSilencePositionFrames = -1;
      if (!GetEndFrame(&iSilencePositionFrames)) {
        return RageSoundReader::ERROR;
      }
      std::int64_t iFullVolumePositionFrames = iSilencePositionFrames;
      std::int64_t iBlockEndFrame = iBlockStartFrame;
      if (!SubtractFrames(
              iSilencePositionFrames, m_iFadeOutFrames,
              &iFullVolumePositionFrames) ||
          !AddFrames(iBlockStartFrame, iFramesRead, &iBlockEndFrame)) {
        SetError("SRC_AUDIT_FIX SRC-2893: extend fade-out frame overflow");
        return RageSoundReader::ERROR;
      }
      const float fStartVolume = SCALE(
          iBlockStartFrame, iFullVolumePositionFrames, iSilencePositionFrames,
          1.0f, 0.0f);
      const float fEndVolume = SCALE(
          iBlockEndFrame, iFullVolumePositionFrames, iSilencePositionFrames,
          1.0f, 0.0f);
      if (!RageSoundUtil::Fade(
              pBuffer, static_cast<size_t>(iFramesRead),
              this->GetNumChannels(), fStartVolume, fEndVolume)) {
        SetError("SRC_AUDIT_FIX SRC-2909: extend fade-out failed");
        return RageSoundReader::ERROR;
      }
    }

    if (!bAdvancedPosition &&
        !AddFrames(m_iPositionFrames, iFramesRead, &m_iPositionFrames)) {
      SetError("SRC_AUDIT_FIX SRC-2893: extend position frame overflow");
      return RageSoundReader::ERROR;
    }
    ClearError();
  }

  if (iFramesRead == RageSoundReader::END_OF_FILE && m_StopMode == M_LOOP) {
    if (m_iStartFrames < std::numeric_limits<int>::min() ||
        m_iStartFrames > std::numeric_limits<int>::max()) {
      SetError("SRC_AUDIT_FIX SRC-2892: extend loop start is out of range");
      return RageSoundReader::ERROR;
    }
    if (this->SetPosition(ClampInt64ToInt(m_iStartFrames)) < 0) {
      SetError("SRC_AUDIT_FIX SRC-2892: extend loop restart seek failed");
      return RageSoundReader::ERROR;
    }

    /* If we're not fading out at the end, then only fade in once.  Ignore
     * m_iFadeInFrames until seeked, so we only fade in once. */
    if (m_iFadeOutFrames == 0) {
      m_bIgnoreFadeInFrames = true;
    }
    return STREAM_LOOPED;
  }

  return iFramesRead;
}

int RageSoundReader_Extend::GetNextSourceFrame() const {
  return ClampInt64ToInt(m_iPositionFrames);
}

std::int64_t RageSoundReader_Extend::GetNextSourceFrame64() const {
  return m_iPositionFrames;
}

bool RageSoundReader_Extend::SetProperty(
    const std::string& sProperty, float fValue) {
  if (sProperty == "StartSecond") {
    std::int64_t frames = 0;
    if (!SecondsToFrames(fValue, this->GetSampleRate(), &frames)) {
      SetError("SRC_AUDIT_FIX SRC-2894: invalid extend StartSecond");
      return false;
    }
    m_iStartFrames = frames;
    ClearError();
    return true;
  }

  if (sProperty == "LengthSeconds") {
    if (fValue == -1) {
      m_iLengthFrames = -1;
    } else {
      std::int64_t frames = 0;
      if (!NonNegativeSecondsToFrames(fValue, this->GetSampleRate(), &frames)) {
        SetError("SRC_AUDIT_FIX SRC-2894: invalid extend LengthSeconds");
        return false;
      }
      m_iLengthFrames = frames;
    }
    ClearError();
    return true;
  }

  if (sProperty == "Loop") {
    m_StopMode = M_LOOP;
    ClearError();
    return true;
  }

  if (sProperty == "Stop") {
    m_StopMode = M_STOP;
    ClearError();
    return true;
  }

  if (sProperty == "Continue") {
    m_StopMode = M_CONTINUE;
    ClearError();
    return true;
  }

  if (sProperty == "FadeInSeconds") {
    std::int64_t frames = 0;
    if (!NonNegativeSecondsToFrames(fValue, this->GetSampleRate(), &frames)) {
      SetError("SRC_AUDIT_FIX SRC-2894: invalid extend FadeInSeconds");
      return false;
    }
    m_iFadeInFrames = frames;
    ClearError();
    return true;
  }

  if (sProperty == "FadeSeconds" || sProperty == "FadeOutSeconds") {
    std::int64_t frames = 0;
    if (!NonNegativeSecondsToFrames(fValue, this->GetSampleRate(), &frames)) {
      SetError("SRC_AUDIT_FIX SRC-2894: invalid extend FadeOutSeconds");
      return false;
    }
    m_iFadeOutFrames = frames;
    ClearError();
    return true;
  }

  return false;
}

std::string RageSoundReader_Extend::GetError() const {
  if (!m_sError.empty()) {
    return m_sError;
  }
  return RageSoundReader_Filter::GetError();
}

void RageSoundReader_Extend::ClearError() const {
  m_sError.clear();
}

void RageSoundReader_Extend::SetError(const std::string& sError) const {
  m_sError = sError;
}

/*
 * Copyright (c) 2003-2006 Glenn Maynard
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
