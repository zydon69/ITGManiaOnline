/*
 * Implements properties:
 *   "Speed" - cause the sound to play faster or slower
 *   "Pitch" - raise or lower the pitch of the sound
 *
 * Pitch changing is implemented by combining speed changing and rate changing
 * (via resampling).  The resampler needs to be changed later than the speed
 * changer; this class just controls parameters on the other two real filters.
 */

#include "RageSoundReader_PitchChange.h"

#include <cmath>
#include <memory>
#include <new>
#include <string>

#include "PerfDiagnostics.h"
#include "Preference.h"
#include "RageSoundReader.h"
#include "RageSoundReader_Filter.h"
#include "RageSoundReader_Resample_Good.h"
#include "RageSoundReader_SpeedChange.h"

static Preference<bool> g_bRateModPreservesPitch("RateModPreservesPitch", true);
static constexpr float MAX_REASONABLE_RATIO = 64.0f;

static bool IsUsableSource(const RageSoundReader* pSource) {
  return pSource != nullptr && pSource->GetSampleRate() > 0 &&
         pSource->GetNumChannels() > 0;
}

static bool IsUsableRatio(float fRatio) {
  return std::isfinite(fRatio) && fRatio > 0.0f &&
         fRatio <= MAX_REASONABLE_RATIO;
}

RageSoundReader_PitchChange::RageSoundReader_PitchChange(
    RageSoundReader* pSource)
    : RageSoundReader_Filter(nullptr),
      m_pSpeedChange(nullptr),
      m_pResample(nullptr),
      m_bPreservePitch(g_bRateModPreservesPitch.Get()),
      m_fSpeedRatio(1.0f),
      m_fPitchRatio(1.0f),
      m_fLastSetSpeedRatio(1.0f),
      m_fLastSetPitchRatio(1.0f) {
  std::unique_ptr<RageSoundReader> pOwnedSource(pSource);
  if (!IsUsableSource(pOwnedSource.get())) {
    SetError(
        "SRC_AUDIT_FIX SRC-2825: RageSoundReader_PitchChange received an "
        "invalid source reader");
    return;
  }

  try {
    if (m_bPreservePitch) {
      RageSoundReader* pSourceRaw = pOwnedSource.get();
      std::unique_ptr<RageSoundReader_SpeedChange> pSpeedChange(
          new RageSoundReader_SpeedChange(pSourceRaw));
      pOwnedSource.release();
      if (!IsUsableSource(pSpeedChange.get())) {
        SetError(
            "SRC_AUDIT_FIX SRC-2825: RageSoundReader_PitchChange could not "
            "build a usable speed-change reader");
        return;
      }

      RageSoundReader_SpeedChange* pSpeedChangeRaw = pSpeedChange.get();
      std::unique_ptr<RageSoundReader_Resample_Good> pResample(
          new RageSoundReader_Resample_Good(
              pSpeedChangeRaw, pSpeedChangeRaw->GetSampleRate()));
      pSpeedChange.release();
      if (!IsUsableSource(pResample.get())) {
        SetError(
            "SRC_AUDIT_FIX SRC-2825: RageSoundReader_PitchChange could not "
            "build a usable resampler");
        return;
      }

      m_pSpeedChange = pSpeedChangeRaw;
      m_pResample = pResample.get();
      m_pSource = pResample.release();
      return;
    }

    const int iSourceSampleRate = pOwnedSource->GetSampleRate();
    RageSoundReader* pSourceRaw = pOwnedSource.get();
    std::unique_ptr<RageSoundReader_Resample_Good> pResample(
        new RageSoundReader_Resample_Good(
            pSourceRaw, iSourceSampleRate));
    pOwnedSource.release();
    if (!IsUsableSource(pResample.get())) {
      SetError(
          "SRC_AUDIT_FIX SRC-2825: RageSoundReader_PitchChange could not "
          "build a usable non-preserving resampler");
      return;
    }

    m_pResample = pResample.get();
    m_pSource = pResample.release();
  } catch (const std::bad_alloc&) {
    SetError(
        "SRC_AUDIT_FIX SRC-2824: RageSoundReader_PitchChange ran out of "
        "memory while building its filter chain");
  }
}

RageSoundReader_PitchChange::RageSoundReader_PitchChange(
    const RageSoundReader_PitchChange& cpy)
    : RageSoundReader_Filter(cpy),
      m_pSpeedChange(nullptr),
      m_pResample(nullptr),
      m_bPreservePitch(cpy.m_bPreservePitch),
      m_fSpeedRatio(1.0f),
      m_fPitchRatio(1.0f),
      m_fLastSetSpeedRatio(1.0f),
      m_fLastSetPitchRatio(1.0f) {
  /* The source tree has already been copied.  Our source is m_pResample; its
   * source is m_pSpeedChange (and its source is a copy of the pSource we were
   * initialized with). */
  m_pResample =
      m_pSource.isNull()
          ? nullptr
          : dynamic_cast<RageSoundReader_Resample_Good*>(&*m_pSource);
  m_pSpeedChange =
      m_pResample == nullptr
          ? nullptr
          : dynamic_cast<RageSoundReader_SpeedChange*>(m_pResample->GetSource());

  {
    std::lock_guard<std::mutex> lock(cpy.m_StateMutex);
    m_fSpeedRatio = cpy.m_fSpeedRatio;
    m_fPitchRatio = cpy.m_fPitchRatio;
    m_fLastSetSpeedRatio = cpy.m_fLastSetSpeedRatio;
    m_fLastSetPitchRatio = cpy.m_fLastSetPitchRatio;
  }

  if (!IsTopologyUsable()) {
    SetError(
        "SRC_AUDIT_FIX SRC-2826: RageSoundReader_PitchChange copy produced "
        "an invalid filter topology");
  }
}

RageSoundReader_PitchChange* RageSoundReader_PitchChange::Copy() const {
  try {
    RageSoundReader_PitchChange* pCopy =
        new RageSoundReader_PitchChange(*this);
    if (!pCopy->IsTopologyUsable()) {
      delete pCopy;
      return nullptr;
    }
    return pCopy;
  } catch (const std::bad_alloc&) {
    return nullptr;
  }
}

int RageSoundReader_PitchChange::Read(float* pBuf, int iFrames) {
  if (iFrames == 0) {
    return 0;
  }
  if (pBuf == nullptr) {
    SetError("SRC_AUDIT_FIX SRC-2827: PitchChange Read called with null buffer");
    return RageSoundReader::ERROR;
  }
  if (iFrames < 0) {
    SetError(
        "SRC_AUDIT_FIX SRC-2827: PitchChange Read called with negative frame "
        "count");
    return RageSoundReader::ERROR;
  }
  if (!IsTopologyUsable()) {
    SetError(
        "SRC_AUDIT_FIX SRC-2827: PitchChange Read has no usable filter "
        "topology");
    return RageSoundReader::ERROR;
  }

  /* m_pSpeedChange->NextReadWillStep is true if speed changes will be applied
   * immediately on the next Read().  When this is true, apply the ratio to the
   * resampler and the speed changer simultaneously, so they take effect as
   * closely together as possible. */
  {
    std::lock_guard<std::mutex> lock(m_StateMutex);
    if ((!m_bPreservePitch) ||
        ((m_fLastSetSpeedRatio != m_fSpeedRatio ||
          m_fLastSetPitchRatio != m_fPitchRatio) &&
         m_pSpeedChange != nullptr && m_pSpeedChange->NextReadWillStep())) {
      float fRate = GetStreamToSourceRatio();

    /* This is the simple way: */
    // m_pResample->SetRate( m_fPitchRatio );
    // m_pSpeedChange->SetSpeedRatio( m_fSpeedRatio / m_fPitchRatio );

    /* However, the resampler has a limited granularity due to internal fixed-
     * point math, and the actual ratio will be slightly different than what
     * we tell it to use.  The actual ratio used is fActualPitchRatio. */

      if (m_bPreservePitch) {
        m_pResample->SetRate(m_fPitchRatio);
        float fActualPitchRatio = m_pResample->GetRate();
        if (!std::isfinite(fActualPitchRatio) || fActualPitchRatio <= 0.0f ||
            m_pSpeedChange == nullptr) {
          SetError(
              "SRC_AUDIT_FIX SRC-2830: PitchChange resampler rejected pitch "
              "ratio");
          return RageSoundReader::ERROR;
        }
        float fRequestedSpeedRatio = m_fSpeedRatio / fActualPitchRatio;
        if (!m_pSpeedChange->SetSpeedRatio(fRequestedSpeedRatio)) {
          SetError(
              "SRC_AUDIT_FIX SRC-2830: PitchChange speed-change reader rejected "
              "derived speed ratio");
          return RageSoundReader::ERROR;
        }
        m_fLastSetPitchRatio = m_fPitchRatio;
        m_fLastSetSpeedRatio = m_fSpeedRatio;
      } else {
        m_pResample->SetRate(m_fSpeedRatio);
        float fActualSpeedRatio = m_pResample->GetRate();
        if (!std::isfinite(fActualSpeedRatio) || fActualSpeedRatio <= 0.0f) {
          SetError(
              "SRC_AUDIT_FIX SRC-2830: PitchChange resampler rejected speed "
              "ratio");
          return RageSoundReader::ERROR;
        }
        m_fLastSetSpeedRatio = m_fSpeedRatio;
      }

      /* If we just applied a new speed and it caused the ratio to change,
       * return no data, so the caller can see the new ratio. */
      if (fRate != GetStreamToSourceRatio()) {
        return 0;
      }
    }
  }

  ClearError();
  return RageSoundReader_Filter::Read(pBuf, iFrames);
}

bool RageSoundReader_PitchChange::SetProperty(
    const std::string& sProperty, float fValue) {
  if (sProperty == "Rate") {
    /* Don't propagate this.  m_pResample will take it, but it's under
     * our control. */
    return false;
  }
  if (sProperty == "Speed") {
    return SetSpeedRatio(fValue);
  }

  if (sProperty == "Pitch") {
    return SetPitchRatio(fValue);
  }

  return RageSoundReader_Filter::SetProperty(sProperty, fValue);
}

bool RageSoundReader_PitchChange::SetSpeedRatio(float fRatio) {
  if (!IsUsableRatio(fRatio)) {
    SetError("SRC_AUDIT_FIX SRC-2830: PitchChange rejected unsafe speed ratio");
    return false;
  }
  std::lock_guard<std::mutex> lock(m_StateMutex);
  m_fSpeedRatio = fRatio;
  ClearError();
  return true;
}

bool RageSoundReader_PitchChange::SetPitchRatio(float fRatio) {
  if (!IsUsableRatio(fRatio)) {
    SetError("SRC_AUDIT_FIX SRC-2830: PitchChange rejected unsafe pitch ratio");
    return false;
  }
  std::lock_guard<std::mutex> lock(m_StateMutex);
  m_fPitchRatio = fRatio;
  ClearError();
  return true;
}

std::string RageSoundReader_PitchChange::GetError() const {
  {
    std::lock_guard<std::mutex> lock(m_ErrorMutex);
    if (!m_sError.empty()) {
      return m_sError;
    }
  }
  return RageSoundReader_Filter::GetError();
}

bool RageSoundReader_PitchChange::IsTopologyUsable() const {
  if (m_pSource.isNull() || m_pResample == nullptr ||
      !IsUsableSource(m_pResample)) {
    return false;
  }
  if (m_bPreservePitch &&
      (m_pSpeedChange == nullptr || !IsUsableSource(m_pSpeedChange))) {
    return false;
  }
  return true;
}

void RageSoundReader_PitchChange::ClearError() const {
  std::lock_guard<std::mutex> lock(m_ErrorMutex);
  m_sError.clear();
}

void RageSoundReader_PitchChange::SetError(const std::string& sError) const {
  if (sError.find("SRC_AUDIT_FIX SRC-28") != std::string::npos) {
    LogReviewSrcDiagnostics("%s", sError.c_str());
  }
  std::lock_guard<std::mutex> lock(m_ErrorMutex);
  m_sError = sError;
}

/*
 * Copyright (c) 2006 Glenn Maynard
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
