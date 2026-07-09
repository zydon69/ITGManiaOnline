#include "RageSoundReader_SpeedChange.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstddef>
#include <cstring>
#include <limits>
#include <new>
#include <string>

#include "PerfDiagnostics.h"
#include "RageSoundReader.h"
#include "RageSoundReader_Filter.h"
#include "RageUtil.h"
#include "global.h"

static const int WINDOW_SIZE_MS = 30;
static constexpr unsigned MAX_SPEED_CHANGE_CHANNELS = 64;
static constexpr float MAX_REASONABLE_SPEED_RATIO = 64.0f;

static bool IsUsableSource(const RageSoundReader* pSource) {
  return pSource != nullptr && pSource->GetSampleRate() > 0 &&
         pSource->GetNumChannels() > 0 &&
         pSource->GetNumChannels() <= MAX_SPEED_CHANGE_CHANNELS;
}

static bool IsUsableSpeedRatio(float fRatio) {
  return std::isfinite(fRatio) && fRatio > 0.0f &&
         fRatio <= MAX_REASONABLE_SPEED_RATIO;
}

static int ClampInt64ToInt(std::int64_t value) {
  if (value > std::numeric_limits<int>::max()) {
    return std::numeric_limits<int>::max();
  }
  if (value < std::numeric_limits<int>::min()) {
    return std::numeric_limits<int>::min();
  }
  return static_cast<int>(value);
}

static bool AddInt64(std::int64_t lhs, std::int64_t rhs, std::int64_t* out) {
  if ((rhs > 0 && lhs > std::numeric_limits<std::int64_t>::max() - rhs) ||
      (rhs < 0 && lhs < std::numeric_limits<std::int64_t>::min() - rhs)) {
    return false;
  }
  *out = lhs + rhs;
  return true;
}

static bool AddNonNegativeInt(int lhs, int rhs, int* out) {
  if (lhs < 0 || rhs < 0 ||
      lhs > std::numeric_limits<int>::max() - rhs) {
    return false;
  }
  *out = lhs + rhs;
  return true;
}

RageSoundReader_SpeedChange::RageSoundReader_SpeedChange(
    RageSoundReader* pSource)
    : RageSoundReader_Filter(pSource),
      m_iDataBufferAvailFrames(0),
      m_iUncorrelatedPos(0),
      m_iPos(0),
      m_fSpeedRatio(1.0f),
      m_fTrailingSpeedRatio(1.0f),
      m_fErrorFrames(0.0f) {
  if (!IsUsableSource(pSource)) {
    SetError(
        "SRC_AUDIT_FIX SRC-2842: SpeedChange received an invalid source "
        "reader");
    return;
  }

  try {
    m_Channels.resize(pSource->GetNumChannels());
  } catch (const std::bad_alloc&) {
    SetError(
        "SRC_AUDIT_FIX SRC-2844: SpeedChange ran out of memory while "
        "initializing channel state");
    return;
  }
  Reset();
}

RageSoundReader_SpeedChange::RageSoundReader_SpeedChange(
    const RageSoundReader_SpeedChange& cpy)
    : RageSoundReader_Filter(cpy),
      m_iDataBufferAvailFrames(0),
      m_iUncorrelatedPos(0),
      m_iPos(0),
      m_fSpeedRatio(1.0f),
      m_fTrailingSpeedRatio(1.0f),
      m_fErrorFrames(0.0f) {
  {
    std::lock_guard<std::mutex> lock(cpy.m_StateMutex);
    m_iDataBufferAvailFrames = cpy.m_iDataBufferAvailFrames;
    m_Channels = cpy.m_Channels;
    m_iUncorrelatedPos = cpy.m_iUncorrelatedPos;
    m_iPos = cpy.m_iPos;
    m_fSpeedRatio = cpy.m_fSpeedRatio;
    m_fTrailingSpeedRatio = cpy.m_fTrailingSpeedRatio;
    m_fErrorFrames = cpy.m_fErrorFrames;
  }

  if (!IsTopologyUsableLocked()) {
    SetError(
        "SRC_AUDIT_FIX SRC-2849: SpeedChange copy produced an invalid "
        "reader topology");
  }
}

RageSoundReader_SpeedChange* RageSoundReader_SpeedChange::Copy() const {
  try {
    RageSoundReader_SpeedChange* pCopy =
        new RageSoundReader_SpeedChange(*this);
    bool bUsable = false;
    {
      std::lock_guard<std::mutex> lock(pCopy->m_StateMutex);
      bUsable = pCopy->IsTopologyUsableLocked();
    }
    if (!bUsable) {
      delete pCopy;
      return nullptr;
    }
    return pCopy;
  } catch (const std::bad_alloc&) {
    return nullptr;
  }
}

bool RageSoundReader_SpeedChange::SetSpeedRatio(float fRatio) {
  if (!IsUsableSpeedRatio(fRatio)) {
    SetError("SRC_AUDIT_FIX SRC-2846: SpeedChange rejected unsafe speed ratio");
    return false;
  }
  std::lock_guard<std::mutex> lock(m_StateMutex);
  m_fSpeedRatio = fRatio;

  /* If we haven't read any data yet, put the new delta into effect immediately.
   */
  if (m_iDataBufferAvailFrames == 0) {
    m_fTrailingSpeedRatio = m_fSpeedRatio;
  }
  if (IsTopologyUsableLocked()) {
    ClearError();
  }
  return true;
}

int RageSoundReader_SpeedChange::GetWindowSizeFrames() const {
  const int sampleRate = GetSampleRate();
  if (sampleRate <= 0) {
    return 1;
  }
  const std::int64_t windowFrames =
      (static_cast<std::int64_t>(WINDOW_SIZE_MS) * sampleRate) / 1000;
  return std::max(1, ClampInt64ToInt(windowFrames));
}

void RageSoundReader_SpeedChange::Reset() {
  m_fTrailingSpeedRatio = m_fSpeedRatio;
  m_iDataBufferAvailFrames = 0;
  for (size_t i = 0; i < m_Channels.size(); ++i) {
    ChannelInfo& c = m_Channels[i];
    c.m_iCorrelatedPos = 0;
    c.m_iLastCorrelatedPos = 0;
  }
  m_iUncorrelatedPos = 0;
  m_iPos = 0;
  m_fErrorFrames = 0;
}

static int FindClosestMatch(
    const float* pBuffer, int iBufferSize, const float* pCorrelateBuffer,
    int iCorrelateBufferSize, int iStride) {
  if (iBufferSize <= iCorrelateBufferSize) {
    return 0;
  }

  /* Optimization: if the buffers are the same, they always corellate at 0. */
  if (pBuffer == pCorrelateBuffer) {
    return 0;
  }

  int iBufferDistanceToSearch = iBufferSize - iCorrelateBufferSize;
  int iBestOffset = 0;
  float fBestScore = 0;
  for (int i = 0; i < iBufferDistanceToSearch; i += iStride) {
    float fScore = 0;
    const float* pFrames = pBuffer + i;
    for (int j = 0; j < iCorrelateBufferSize; j += iStride) {
      float fDiff = pFrames[j] - pCorrelateBuffer[j];
      fScore += std::abs(fDiff);
    }

    if (i == 0 || fScore < fBestScore) {
      fBestScore = fScore;
      iBestOffset = i;
    }
  }
  return iBestOffset;
}

int RageSoundReader_SpeedChange::FillData(int iMaxFrames) {
  if (iMaxFrames <= 0) {
    SetError(
        "SRC_AUDIT_FIX SRC-2848: SpeedChange FillData received an invalid "
        "frame count");
    return RageSoundReader::ERROR;
  }
  if (!IsTopologyUsableLocked()) {
    SetError(
        "SRC_AUDIT_FIX SRC-2842: SpeedChange FillData has no usable source "
        "topology");
    return RageSoundReader::ERROR;
  }

  /* SpeedChange processes source data in whole windows.  If an upstream reader
   * changes rate or frame offset mid-window, the change becomes visible at the
   * next processed block boundary. */
  while (iMaxFrames > 0) {
    int iFramesToRead = iMaxFrames - m_iDataBufferAvailFrames;
    if (iFramesToRead <= 0) {
      return m_iDataBufferAvailFrames;
    }

    const size_t channels = m_Channels.size();
    if (static_cast<size_t>(iFramesToRead) >
        std::numeric_limits<size_t>::max() / channels) {
      SetError("SRC_AUDIT_FIX SRC-2847: SpeedChange sample count overflow");
      return RageSoundReader::ERROR;
    }
    const size_t samplesToRead =
        static_cast<size_t>(iFramesToRead) * channels;
    if (samplesToRead > std::numeric_limits<size_t>::max() / sizeof(float)) {
      SetError("SRC_AUDIT_FIX SRC-2847: SpeedChange byte count overflow");
      return RageSoundReader::ERROR;
    }

    std::vector<float> tempBuffer;
    try {
      tempBuffer.resize(samplesToRead);
      for (size_t i = 0; i < m_Channels.size(); ++i) {
        ChannelInfo& c = m_Channels[i];
        if (static_cast<int>(c.m_DataBuffer.size()) < iMaxFrames) {
          c.m_DataBuffer.resize(iMaxFrames);
        }
      }
    } catch (const std::bad_alloc&) {
      SetError(
          "SRC_AUDIT_FIX SRC-2844: SpeedChange ran out of memory while "
          "preparing input buffers");
      return RageSoundReader::ERROR;
    }

    int iGotFrames = m_pSource->Read(&tempBuffer[0], iFramesToRead);
    if (iGotFrames < 0) {
      if (iGotFrames == END_OF_FILE && m_iDataBufferAvailFrames) {
        return m_iDataBufferAvailFrames;
      }
      return iGotFrames;
    }
    if (iGotFrames == 0) {
      return m_iDataBufferAvailFrames;
    }
    if (iGotFrames > iFramesToRead) {
      SetError(
          "SRC_AUDIT_FIX SRC-2848: SpeedChange source returned too many "
          "frames");
      return RageSoundReader::ERROR;
    }

    for (size_t i = 0; i < m_Channels.size(); ++i) {
      ChannelInfo& c = m_Channels[i];

      const float* pIn = &tempBuffer[0] + i;
      float* pOut = &c.m_DataBuffer[m_iDataBufferAvailFrames];
      for (int j = 0; j < iGotFrames; ++j) {
        *pOut = *pIn;
        pIn += m_Channels.size();
        ++pOut;
      }
    }

    m_iDataBufferAvailFrames += iGotFrames;
  }
  return m_iDataBufferAvailFrames;
}

void RageSoundReader_SpeedChange::EraseData(int iFramesToDelete) {
  if (iFramesToDelete <= 0) {
    return;
  }
  iFramesToDelete = std::min(iFramesToDelete, m_iDataBufferAvailFrames);
  iFramesToDelete = std::min(iFramesToDelete, m_iUncorrelatedPos);

  const int iFramesToMove = m_iDataBufferAvailFrames - iFramesToDelete;
  m_iDataBufferAvailFrames -= iFramesToDelete;
  m_iUncorrelatedPos -= iFramesToDelete;
  for (size_t i = 0; i < m_Channels.size(); ++i) {
    ChannelInfo& c = m_Channels[i];
    if (iFramesToMove && static_cast<int>(c.m_DataBuffer.size()) >=
                             m_iDataBufferAvailFrames + iFramesToDelete) {
      memmove(
          &c.m_DataBuffer[0], &c.m_DataBuffer[iFramesToDelete],
          iFramesToMove * sizeof(float));
    }
    c.m_iCorrelatedPos = std::max(0, c.m_iCorrelatedPos - iFramesToDelete);
    c.m_iLastCorrelatedPos =
        std::max(0, c.m_iLastCorrelatedPos - iFramesToDelete);
  }
}

int RageSoundReader_SpeedChange::Step() {
  if (!IsTopologyUsableLocked()) {
    SetError(
        "SRC_AUDIT_FIX SRC-2842: SpeedChange Step has no usable source "
        "topology");
    return RageSoundReader::ERROR;
  }
  if (m_iDataBufferAvailFrames == 0) {
    return FillData(GetWindowSizeFrames());
  }

  /* If m_iPos is non-zero, we just finished playing a previous block, so
   * advance forward. */
  if (m_iPos) {
    /* Advance m_iCorrelatedPos past the data that was just copied, to point to
     * the sound that we would have played if we had continued copying at that
     * point. */
    for (size_t i = 0; i < m_Channels.size(); ++i) {
      if (m_Channels[i].m_iCorrelatedPos < 0 ||
          m_Channels[i].m_iCorrelatedPos + m_iPos >
              m_iDataBufferAvailFrames) {
        SetError(
            "SRC_AUDIT_FIX SRC-2848: SpeedChange correlated position is out "
            "of range");
        return RageSoundReader::ERROR;
      }
      m_Channels[i].m_iCorrelatedPos += m_iPos;
    }

    /* Advance m_iUncorrelatedPos to the position we'd prefer to continue
     * playing from. This rounds the position, making the ratio imprecise.
     * Record the amount of error introduced here.  If we want to advance by 2.3
     * frames, we'll advance by 2.0 frames, and advance by 0.3 more the next
     * time around. */
    double fAdvanceFrames =
        static_cast<double>(GetWindowSizeFrames()) * m_fTrailingSpeedRatio;
    if (!std::isfinite(fAdvanceFrames)) {
      SetError(
          "SRC_AUDIT_FIX SRC-2846: SpeedChange produced a non-finite advance");
      return RageSoundReader::ERROR;
    }
    fAdvanceFrames += m_fErrorFrames;
    if (!std::isfinite(fAdvanceFrames) || fAdvanceFrames < 0.0 ||
        fAdvanceFrames >
            static_cast<double>(std::numeric_limits<int>::max())) {
      SetError(
          "SRC_AUDIT_FIX SRC-2847: SpeedChange advance does not fit in int");
      return RageSoundReader::ERROR;
    }
    const int iTrailingDeltaFrames =
        static_cast<int>((fAdvanceFrames) + 0.5);
    m_fErrorFrames = fAdvanceFrames - iTrailingDeltaFrames;
    if (m_iUncorrelatedPos >
        std::numeric_limits<int>::max() - iTrailingDeltaFrames) {
      SetError(
          "SRC_AUDIT_FIX SRC-2847: SpeedChange uncorrelated position overflow");
      return RageSoundReader::ERROR;
    }
    m_iUncorrelatedPos += iTrailingDeltaFrames;

    m_iPos = 0;
  }

  /* Update m_fTrailingSpeedRatio.  Do this after advancing m_iUncorrelatedPos,
   * so changes to m_iUncorrelatedPos line up with GetNextSourceFrame. */
  m_fTrailingSpeedRatio = m_fSpeedRatio;

  /* We don't need any data before the earlier of m_iUncorrelatedPos or
   * m_iCorrelatedPos. */
  int iToDelete = m_iUncorrelatedPos;
  for (size_t i = 0; i < m_Channels.size(); ++i) {
    ChannelInfo& c = m_Channels[i];
    if (c.m_iCorrelatedPos < 0 || c.m_iCorrelatedPos > m_iDataBufferAvailFrames) {
      SetError(
          "SRC_AUDIT_FIX SRC-2848: SpeedChange delete window is out of range");
      return RageSoundReader::ERROR;
    }
    iToDelete = std::min(iToDelete, c.m_iCorrelatedPos);
  }
  EraseData(iToDelete);

  /* Fill as much data as we might need to do the search and use the result. */
  {
    int iMaxPositionNeeded = 0;
    int iTmp = 0;
    if (!AddNonNegativeInt(m_iUncorrelatedPos, GetToleranceFrames(), &iTmp) ||
        !AddNonNegativeInt(iTmp, GetWindowSizeFrames(), &iMaxPositionNeeded)) {
      SetError(
          "SRC_AUDIT_FIX SRC-2847: SpeedChange search window overflow");
      return RageSoundReader::ERROR;
    }
    if (iMaxPositionNeeded <= 0) {
      SetError(
          "SRC_AUDIT_FIX SRC-2848: SpeedChange search window is invalid");
      return RageSoundReader::ERROR;
    }
    for (size_t i = 0; i < m_Channels.size(); ++i) {
      if (m_Channels[i].m_iCorrelatedPos < 0) {
        SetError(
            "SRC_AUDIT_FIX SRC-2848: SpeedChange has negative correlated "
            "position");
        return RageSoundReader::ERROR;
      }
      int iChannelMax = 0;
      if (!AddNonNegativeInt(
              m_Channels[i].m_iCorrelatedPos, GetWindowSizeFrames(),
              &iChannelMax)) {
        SetError(
            "SRC_AUDIT_FIX SRC-2847: SpeedChange correlated window overflow");
        return RageSoundReader::ERROR;
      }
      iMaxPositionNeeded = std::max(
          iMaxPositionNeeded, iChannelMax);
    }

    int iGot = FillData(iMaxPositionNeeded);
    if (iGot < 0) {
      return iGot;
    }

    if (iMaxPositionNeeded > m_iDataBufferAvailFrames) {
      /* We're at EOF.  Flush the remaining data, if any. */
      m_iUncorrelatedPos = m_Channels[0].m_iCorrelatedPos;
      return m_iDataBufferAvailFrames;
    }
  }

  /* Starting at our preferred position (m_iUncorrelatedPos), within
   * GetToleranceFrames(), search for data that looks like the sound we would
   * have continued playing if we kept going from the old position
   * (m_iCorrelatedPos). */
  int iCorrelatedToMatch = GetWindowSizeFrames() / 4;
  int iUncorrelatedToMatch =
      GetToleranceFrames() + iCorrelatedToMatch;  // maximum distance to search

  for (size_t i = 0; i < m_Channels.size(); ++i) {
    ChannelInfo& c = m_Channels[i];
    int iCorrelatedMatchEnd = 0;
    int iUncorrelatedMatchEnd = 0;
    if (c.m_iCorrelatedPos < 0 ||
        !AddNonNegativeInt(
            c.m_iCorrelatedPos, iCorrelatedToMatch, &iCorrelatedMatchEnd) ||
        iCorrelatedMatchEnd > m_iDataBufferAvailFrames ||
        m_iUncorrelatedPos < 0 ||
        !AddNonNegativeInt(
            m_iUncorrelatedPos, iUncorrelatedToMatch,
            &iUncorrelatedMatchEnd) ||
        iUncorrelatedMatchEnd > m_iDataBufferAvailFrames) {
      SetError(
          "SRC_AUDIT_FIX SRC-2848: SpeedChange correlation window is out of "
          "range");
      return RageSoundReader::ERROR;
    }

    int iBest = FindClosestMatch(
        &c.m_DataBuffer[m_iUncorrelatedPos], iUncorrelatedToMatch,
        &c.m_DataBuffer[c.m_iCorrelatedPos], iCorrelatedToMatch, 1);
    c.m_iLastCorrelatedPos = c.m_iCorrelatedPos;
    c.m_iCorrelatedPos = iBest + m_iUncorrelatedPos;
    int iMatchedWindowEnd = 0;
    if (m_Channels[i].m_iCorrelatedPos < 0 ||
        !AddNonNegativeInt(
            m_Channels[i].m_iCorrelatedPos, GetWindowSizeFrames(),
            &iMatchedWindowEnd) ||
        iMatchedWindowEnd > m_iDataBufferAvailFrames) {
      SetError(
          "SRC_AUDIT_FIX SRC-2848: SpeedChange matched window is out of range");
      return RageSoundReader::ERROR;
    }
  }
  return m_iDataBufferAvailFrames;
}

int RageSoundReader_SpeedChange::GetCursorAvail() const {
  if (m_Channels.empty()) {
    return 0;
  }
  int iCursorAvail = GetWindowSizeFrames() - m_iPos;
  for (size_t i = 0; i < m_Channels.size(); ++i) {
    int iCursorAvailForChannel =
        (m_iDataBufferAvailFrames - m_Channels[i].m_iCorrelatedPos) - m_iPos;
    iCursorAvail = std::min(iCursorAvail, iCursorAvailForChannel);
  }

  return iCursorAvail;
}

int RageSoundReader_SpeedChange::Read(float* pBuf, int iFrames) {
  if (iFrames == 0) {
    return 0;
  }
  if (pBuf == nullptr) {
    SetError("SRC_AUDIT_FIX SRC-2848: SpeedChange Read called with null buffer");
    return RageSoundReader::ERROR;
  }
  if (iFrames < 0) {
    SetError(
        "SRC_AUDIT_FIX SRC-2848: SpeedChange Read called with negative frame "
        "count");
    return RageSoundReader::ERROR;
  }
  std::lock_guard<std::mutex> lock(m_StateMutex);
  if (!IsTopologyUsableLocked()) {
    SetError(
        "SRC_AUDIT_FIX SRC-2842: SpeedChange Read has no usable source "
        "topology");
    return RageSoundReader::ERROR;
  }
  for (;;) {
    if (m_iDataBufferAvailFrames == 0 &&
        m_fTrailingSpeedRatio == m_fSpeedRatio && m_fSpeedRatio == 1.0f) {
      /* Fast path: the buffer is empty, and we're not scaling the audio.  Read
       * directly into the output buffer, to eliminate memory and copying
       * overhead. */
      int iRet = m_pSource->Read(pBuf, iFrames);
      if (iRet >= 0) {
        ClearError();
      }
      return iRet;
    }

    int iCursorAvail = GetCursorAvail();

    if (iCursorAvail == 0) {
      int iRet = Step();
      if (iRet < 0) {
        return iRet;
      }
      if (!GetCursorAvail()) {
        return END_OF_FILE;
      }
      continue;
    }

    /* copy GetWindowSizeFrames() from iCorrelatedPos */
    int iFramesLen = iFrames;
    int iFramesAvail = std::min(iCursorAvail, iFramesLen);
    if (iFramesAvail <= 0) {
      SetError(
          "SRC_AUDIT_FIX SRC-2848: SpeedChange cursor produced no frames");
      return RageSoundReader::ERROR;
    }

    iFrames -= iFramesAvail;
    int iFramesRead = iFramesAvail;

    int iWindowSizeFrames = GetWindowSizeFrames();
    while (iFramesAvail--) {
      for (size_t i = 0; i < m_Channels.size(); ++i) {
        ChannelInfo& c = m_Channels[i];
        int iCorrelatedIndex = 0;
        int iLastCorrelatedIndex = 0;
        if (!AddNonNegativeInt(c.m_iCorrelatedPos, m_iPos, &iCorrelatedIndex) ||
            !AddNonNegativeInt(
                c.m_iLastCorrelatedPos, m_iPos, &iLastCorrelatedIndex) ||
            iCorrelatedIndex >= static_cast<int>(c.m_DataBuffer.size()) ||
            iLastCorrelatedIndex >= static_cast<int>(c.m_DataBuffer.size())) {
          SetError(
              "SRC_AUDIT_FIX SRC-2848: SpeedChange read window is out of "
              "range");
          return RageSoundReader::ERROR;
        }
        float i1 = c.m_DataBuffer[iCorrelatedIndex];
        float i2 = c.m_DataBuffer[iLastCorrelatedIndex];
        *pBuf++ = SCALE(m_iPos, 0, iWindowSizeFrames, i2, i1);
      }

      ++m_iPos;
    }

    ClearError();
    return iFramesRead;
  }
}

/* We prefer to be able to seek precisely, so seeking to a position produces
 * data equal to what you'd get if you read data up to that point.  This filter
 * can't do that, because the exact selection of slices is dependent on the
 * previous selection. */
int RageSoundReader_SpeedChange::SetPosition(int iFrame) {
  std::lock_guard<std::mutex> lock(m_StateMutex);
  if (m_pSource.isNull()) {
    SetError(
        "SRC_AUDIT_FIX SRC-2848: SpeedChange rejected SetPosition without "
        "source");
    return RageSoundReader::ERROR;
  }
  /* Negative positions are valid during gameplay lead-in.  Preserve them so
   * lower readers can clamp or synthesize pre-song silence as appropriate. */
  if (iFrame < 0) {
    LogReviewSrcDiagnostics(
        "SRC_AUDIT_FIX SRC-2848: SpeedChange accepted lead-in SetPosition "
        "frame=%d",
        iFrame);
  }
  Reset();
  int iRet = RageSoundReader_Filter::SetPosition(iFrame);
  if (iRet >= 0) {
    ClearError();
  }
  return iRet;
}

bool RageSoundReader_SpeedChange::SetProperty(
    const std::string& sProperty, float fValue) {
  if (sProperty == "Speed") {
    return SetSpeedRatio(fValue);
  }

  return RageSoundReader_Filter::SetProperty(sProperty, fValue);
}

int RageSoundReader_SpeedChange::GetNextSourceFrame() const {
  return ClampSourceFrameToInt(GetNextSourceFrame64());
}

std::int64_t RageSoundReader_SpeedChange::GetNextSourceFrame64() const {
  std::lock_guard<std::mutex> lock(m_StateMutex);
  float fRatio = m_fTrailingSpeedRatio;
  if (!std::isfinite(fRatio)) {
    fRatio = 1.0f;
  }

  const std::int64_t iSourceFrame = RageSoundReader_Filter::GetNextSourceFrame64();
  const double fPos = static_cast<double>(m_iPos) * fRatio + 0.5;
  const std::int64_t iPos =
      (!std::isfinite(fPos) ||
       fPos > static_cast<double>(std::numeric_limits<std::int64_t>::max()))
          ? std::numeric_limits<std::int64_t>::max()
          : static_cast<std::int64_t>(fPos);

  std::int64_t mappedFrame = 0;
  if (!AddInt64(
          iSourceFrame, -static_cast<std::int64_t>(m_iDataBufferAvailFrames),
          &mappedFrame) ||
      !AddInt64(mappedFrame, m_iUncorrelatedPos, &mappedFrame) ||
      !AddInt64(mappedFrame, iPos, &mappedFrame)) {
    return iSourceFrame < 0 ? std::numeric_limits<std::int64_t>::min()
                            : std::numeric_limits<std::int64_t>::max();
  }
  return mappedFrame;
}

float RageSoundReader_SpeedChange::GetStreamToSourceRatio() const {
  std::lock_guard<std::mutex> lock(m_StateMutex);
  /* If the ratio has changed and GetCursorAvail() is 0, the new ratio will
   * become the real ratio on the next read.  Otherwise, we'll continue using
   * our old ratio for a bit longer. */
  const float fLocalRatio =
      GetCursorAvail() == 0 ? m_fSpeedRatio : m_fTrailingSpeedRatio;
  const float fSourceRatio = RageSoundReader_Filter::GetStreamToSourceRatio();
  const float fRatio = fLocalRatio * fSourceRatio;
  return std::isfinite(fRatio) && fRatio > 0.0f ? fRatio : 1.0f;
}

bool RageSoundReader_SpeedChange::NextReadWillStep() const {
  std::lock_guard<std::mutex> lock(m_StateMutex);
  return GetCursorAvail() == 0;
}

float RageSoundReader_SpeedChange::GetRatio() const {
  std::lock_guard<std::mutex> lock(m_StateMutex);
  return m_fSpeedRatio;
}

std::string RageSoundReader_SpeedChange::GetError() const {
  {
    std::lock_guard<std::mutex> lock(m_ErrorMutex);
    if (!m_sError.empty()) {
      return m_sError;
    }
  }
  return RageSoundReader_Filter::GetError();
}

bool RageSoundReader_SpeedChange::IsTopologyUsableLocked() const {
  if (m_pSource.isNull() || m_Channels.empty() ||
      m_Channels.size() > MAX_SPEED_CHANGE_CHANNELS ||
      m_pSource->GetSampleRate() <= 0 ||
      m_pSource->GetNumChannels() != m_Channels.size()) {
    return false;
  }
  return true;
}

void RageSoundReader_SpeedChange::ClearError() const {
  std::lock_guard<std::mutex> lock(m_ErrorMutex);
  m_sError.clear();
}

void RageSoundReader_SpeedChange::SetError(const std::string& sError) const {
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
