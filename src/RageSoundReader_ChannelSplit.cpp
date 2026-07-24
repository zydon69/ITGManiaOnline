/*
 * Output a sound from the channels of another sound.
 *
 * This is intended for splitting a FileReader, and assumes the
 * GetStreamToSourceRatio of the source is 1.0.
 *
 * If multiple readers are created, they should be read in parallel.  If their
 * source position drifts apart, the data between will be buffered to prevent
 * seeking the source.
 *
 * The resulting sounds have as many channels as the largest destination channel
 * specified; multiple sounds on the same channel are mixed together; empty
 * channels are silent.
 *
 * Create two mono sounds from one stereo sound, one playing the left channel
 * and one playing the right: RageSoundSplitter split(pSource);
 *   RageSoundReader_Split *pLeft = split.CreateSound();
 *   pLeft->AddSourceChannelToSound( 0, 0 );
 *   RageSoundReader_Split *pRight = split.CreateSound();
 *   pRight->AddSourceChannelToSound( 1, 0 );
 *
 * Convert a stereo sound to mono:
 *   RageSoundSplitter split(pSource);
 *   RageSoundReader_Split *pMono = split.CreateSound();
 *   pMono->AddSourceChannelToSound( 0, 0 );
 *   pMono->AddSourceChannelToSound( 1, 0 );
 *
 * Convert a mono sound to stereo (RageSoundReader_Pan will do this faster):
 *   RageSoundSplitter split(pSource);
 *   RageSoundReader_Split *pStereo = split.CreateSound();
 *   pStereo->AddSourceChannelToSound( 0, 0 );
 *   pStereo->AddSourceChannelToSound( 0, 1 );
 */

#include "RageSoundReader_ChannelSplit.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "RageLog.h"
#include "RageSoundMixBuffer.h"
#include "RageSoundReader.h"
#include "global.h"

class RageSoundReader_Split;

namespace {
constexpr int kMaxSplitOutputChannels = 64;

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

bool FrameRangeEnd(int iStartFrame, int iFrames, int* pEndFrame) {
  if (iStartFrame < 0 || iFrames < 0) {
    return false;
  }
  const int64_t end =
      static_cast<int64_t>(iStartFrame) + static_cast<int64_t>(iFrames);
  if (end > std::numeric_limits<int>::max()) {
    return false;
  }
  *pEndFrame = static_cast<int>(end);
  return true;
}

void WarnSafety(const char* sFinding, const std::string& sMessage) {
  if (LOG != nullptr) {
    LOG->Warn("%s: %s", sFinding, sMessage.c_str());
  }
}
}  // namespace

class RageSoundSplitterImpl {
 public:
  explicit RageSoundSplitterImpl(RageSoundReader* pSource)
      : m_pSource(pSource), m_iBufferPositionFrames(0) {
    if (pSource == nullptr) {
      SetErrorLocked("RageSoundSplitter created without a source reader");
      WarnSafety("ChannelSplit", m_sError);
    }
  }

  bool HasSourceLocked() const { return m_pSource != nullptr; }

  unsigned SourceChannelsLocked() const {
    return HasSourceLocked() ? m_pSource->GetNumChannels() : 0;
  }

  void SetErrorLocked(const std::string& sError) { m_sError = sError; }

  /* Request that m_sBuffer contain frames [iStartFrame,iStartFrame+iFrames). */
  int ReadBufferLocked();

  std::unique_ptr<RageSoundReader> m_pSource;
  mutable std::mutex m_Mutex;
  std::string m_sError;

  std::set<RageSoundReader_Split*> m_apSounds;

  /* m_sBuffer[0] corresponds to frame number m_iBufferPositionFrames. */
  int m_iBufferPositionFrames;
  std::vector<float> m_sBuffer;
};

int RageSoundReader_Split::GetLength() const {
  auto impl = m_pImpl;
  if (impl == nullptr) {
    return 0;
  }
  std::lock_guard<std::mutex> lock(impl->m_Mutex);
  return impl->HasSourceLocked() ? impl->m_pSource->GetLength() : 0;
}
int RageSoundReader_Split::GetLength_Fast() const {
  auto impl = m_pImpl;
  if (impl == nullptr) {
    return 0;
  }
  std::lock_guard<std::mutex> lock(impl->m_Mutex);
  return impl->HasSourceLocked() ? impl->m_pSource->GetLength_Fast() : 0;
}
int RageSoundReader_Split::GetSampleRate() const {
  auto impl = m_pImpl;
  if (impl == nullptr) {
    return 0;
  }
  std::lock_guard<std::mutex> lock(impl->m_Mutex);
  return impl->HasSourceLocked() ? impl->m_pSource->GetSampleRate() : 0;
}
unsigned RageSoundReader_Split::GetNumChannels() const {
  auto impl = m_pImpl;
  if (impl == nullptr) {
    return 0;
  }
  std::lock_guard<std::mutex> lock(impl->m_Mutex);
  return static_cast<unsigned>(m_iNumOutputChannels);
}
int RageSoundReader_Split::GetNextSourceFrame() const {
  auto impl = m_pImpl;
  if (impl == nullptr) {
    return 0;
  }
  std::lock_guard<std::mutex> lock(impl->m_Mutex);
  return m_iPositionFrame;
}
float RageSoundReader_Split::GetStreamToSourceRatio() const { return 1.0f; }
std::string RageSoundReader_Split::GetError() const {
  auto impl = m_pImpl;
  if (impl == nullptr) {
    return "RageSoundReader_Split has no splitter implementation";
  }
  std::lock_guard<std::mutex> lock(impl->m_Mutex);
  if (!impl->m_sError.empty()) {
    return impl->m_sError;
  }
  return impl->HasSourceLocked() ? impl->m_pSource->GetError()
                                 : "RageSoundReader_Split has no source reader";
}

RageSoundReader_Split::RageSoundReader_Split(
    std::shared_ptr<RageSoundSplitterImpl> pImpl)
    : m_pImpl(std::move(pImpl)) {
  m_iNumOutputChannels = 0;
  m_iPositionFrame = 0;
  m_iRequestFrames = 0;
  if (m_pImpl != nullptr) {
    std::lock_guard<std::mutex> lock(m_pImpl->m_Mutex);
    m_pImpl->m_apSounds.insert(this);
  }
}

RageSoundReader_Split::~RageSoundReader_Split() {
  auto impl = m_pImpl;
  if (impl != nullptr) {
    std::lock_guard<std::mutex> lock(impl->m_Mutex);
    impl->m_apSounds.erase(this);
  }
}

RageSoundReader_Split* RageSoundReader_Split::Copy() const {
  WarnSafety(
      "ChannelSplit",
      "RageSoundReader_Split cannot be copied safely because split readers "
      "share source position and buffer state.");
  return nullptr;
}

int RageSoundReader_Split::SetPosition(int iFrame) {
  auto impl = m_pImpl;
  if (impl == nullptr) {
    return RageSoundReader::ERROR;
  }
  std::lock_guard<std::mutex> lock(impl->m_Mutex);
  if (iFrame < 0) {
    impl->SetErrorLocked(
        "RageSoundReader_Split::SetPosition rejected a negative frame");
    WarnSafety("ChannelSplit", impl->m_sError);
    return RageSoundReader::ERROR;
  }
  m_iPositionFrame = iFrame;

  /* We can't tell whether we're past EOF.  We can't ReadBuffer here, because
   * the other sounds using this same source probably haven't seeked yet, so
   * seeking to the beginning of the file would buffer between there and the
   * position of those sounds.  Just return success, and we'll return EOF in
   * Read if needed. */
  return 1;
}

bool RageSoundReader_Split::SetProperty(
    const std::string& sProperty, float fValue) {
  auto impl = m_pImpl;
  if (impl == nullptr) {
    return false;
  }
  std::lock_guard<std::mutex> lock(impl->m_Mutex);
  if (!impl->HasSourceLocked()) {
    impl->SetErrorLocked(
        "RageSoundReader_Split::SetProperty has no source reader");
    WarnSafety("ChannelSplit", impl->m_sError);
    return false;
  }
  return impl->m_pSource->SetProperty(sProperty, fValue);
}

int RageSoundReader_Split::Read(float* pBuf, int iFrames) {
  auto impl = m_pImpl;
  if (impl == nullptr) {
    return RageSoundReader::ERROR;
  }
  std::lock_guard<std::mutex> lock(impl->m_Mutex);
  if (iFrames == 0) {
    m_iRequestFrames = 0;
    return 0;
  }
  if (pBuf == nullptr) {
    impl->SetErrorLocked(
        "RageSoundReader_Split::Read called with a null output buffer");
    WarnSafety("ChannelSplit", impl->m_sError);
    return RageSoundReader::ERROR;
  }
  int iEndFrame = 0;
  if (!FrameRangeEnd(m_iPositionFrame, iFrames, &iEndFrame)) {
    impl->SetErrorLocked(
        "RageSoundReader_Split::Read frame range is invalid or overflowing");
    WarnSafety("ChannelSplit", impl->m_sError);
    return RageSoundReader::ERROR;
  }
  if (!impl->HasSourceLocked()) {
    impl->SetErrorLocked("RageSoundReader_Split::Read has no source reader");
    WarnSafety("ChannelSplit", impl->m_sError);
    return RageSoundReader::ERROR;
  }
  if (m_iNumOutputChannels <= 0 || m_aChannels.empty()) {
    impl->SetErrorLocked(
        "RageSoundReader_Split::Read has no output channel mapping");
    WarnSafety("ChannelSplit", impl->m_sError);
    return RageSoundReader::ERROR;
  }

  m_iRequestFrames = iFrames;
  int iRet = impl->ReadBufferLocked();

  const unsigned sourceChannels = impl->SourceChannelsLocked();
  if (sourceChannels == 0) {
    impl->SetErrorLocked(
        "RageSoundReader_Split::Read source reports zero channels");
    WarnSafety("ChannelSplit", impl->m_sError);
    m_iRequestFrames = 0;
    return RageSoundReader::ERROR;
  }

  size_t iSamplesAvailable = impl->m_sBuffer.size();
  size_t iSkipSamples = 0;
  if (impl->m_iBufferPositionFrames < m_iPositionFrame) {
    size_t iComputedSkip = 0;
    const int iSkipFrames = m_iPositionFrame - impl->m_iBufferPositionFrames;
    if (!FramesToSamples(iSkipFrames, sourceChannels, &iComputedSkip)) {
      impl->SetErrorLocked(
          "RageSoundReader_Split::Read skip sample count overflow");
      WarnSafety("ChannelSplit", impl->m_sError);
      m_iRequestFrames = 0;
      return RageSoundReader::ERROR;
    }
    iSkipSamples = std::min(iComputedSkip, iSamplesAvailable);
    iSamplesAvailable -= iSkipSamples;
  }

  size_t iFramesAvailable = iSamplesAvailable / sourceChannels;

  /* Report any errors from Read() if we don't have any data buffered to
   * return.  If we do have data, finish returning it first. */
  if (iFramesAvailable == 0 && iRet < 0) {
    m_iRequestFrames = 0;
    return iRet;
  }
  if (iFramesAvailable == 0) {
    m_iRequestFrames = 0;
    impl->ReadBufferLocked();
    return 0;
  }

  iFramesAvailable =
      std::min(iFramesAvailable, static_cast<size_t>(iFrames));
  if (iFramesAvailable >
      static_cast<size_t>(std::numeric_limits<unsigned>::max())) {
    impl->SetErrorLocked(
        "RageSoundReader_Split::Read frame count exceeds mixer range");
    WarnSafety("ChannelSplit", impl->m_sError);
    m_iRequestFrames = 0;
    return RageSoundReader::ERROR;
  }

  const float* pSrc = impl->m_sBuffer.data() + iSkipSamples;

  {
    RageSoundMixBuffer mix;
    for (const ChannelMap& chan : m_aChannels) {
      if (chan.m_iFromChannel < 0 ||
          static_cast<unsigned>(chan.m_iFromChannel) >= sourceChannels ||
          chan.m_iToChannel < 0 || chan.m_iToChannel >= m_iNumOutputChannels) {
        impl->SetErrorLocked(
            "RageSoundReader_Split::Read found an invalid channel mapping");
        WarnSafety("ChannelSplit", impl->m_sError);
        m_iRequestFrames = 0;
        return RageSoundReader::ERROR;
      }
      const bool mixed =
          mix.SetWriteOffset(chan.m_iToChannel) &&
          mix.write(
              pSrc + chan.m_iFromChannel,
              static_cast<size_t>(iFramesAvailable), sourceChannels,
              m_iNumOutputChannels);
      if (!mixed) {
        impl->SetErrorLocked("RageSoundReader_Split::Read mix failed: " +
                             mix.GetError());
        WarnSafety("ChannelSplit", impl->m_sError);
        m_iRequestFrames = 0;
        return RageSoundReader::ERROR;
      }
    }

    if (!mix.read(pBuf)) {
      impl->SetErrorLocked("RageSoundReader_Split::Read mix output failed: " +
                           mix.GetError());
      WarnSafety("ChannelSplit", impl->m_sError);
      m_iRequestFrames = 0;
      return RageSoundReader::ERROR;
    }
  }

  m_iPositionFrame = iEndFrame - (iFrames - static_cast<int>(iFramesAvailable));

  /* We no longer need the data we requested.  Clear our request, so the
   * memory can be freed. */
  m_iRequestFrames = 0;
  impl->ReadBufferLocked();
  return static_cast<int>(iFramesAvailable);
}

int RageSoundSplitterImpl::ReadBufferLocked() {
  if (!HasSourceLocked()) {
    SetErrorLocked("RageSoundSplitterImpl::ReadBuffer has no source reader");
    WarnSafety("ChannelSplit", m_sError);
    return RageSoundReader::ERROR;
  }

  const unsigned sourceChannels = SourceChannelsLocked();
  if (sourceChannels == 0) {
    SetErrorLocked("RageSoundSplitterImpl source reports zero channels");
    WarnSafety("ChannelSplit", m_sError);
    return RageSoundReader::ERROR;
  }
  if (m_apSounds.empty()) {
    m_sBuffer.clear();
    return 1;
  }

  /* Discard any bytes that are no longer requested by any sound. */
  int64_t iMinFrameRequested = std::numeric_limits<int64_t>::max();
  int64_t iMaxFrameRequested = std::numeric_limits<int64_t>::min();
  for (RageSoundReader_Split* snd : m_apSounds) {
    int iEndFrame = 0;
    if (!FrameRangeEnd(
            snd->m_iPositionFrame, snd->m_iRequestFrames, &iEndFrame)) {
      SetErrorLocked(
          "RageSoundSplitterImpl::ReadBuffer found an invalid reader range");
      WarnSafety("ChannelSplit", m_sError);
      return RageSoundReader::ERROR;
    }
    iMinFrameRequested = std::min(
        iMinFrameRequested, static_cast<int64_t>(snd->m_iPositionFrame));
    iMaxFrameRequested =
        std::max(iMaxFrameRequested, static_cast<int64_t>(iEndFrame));
  }

  if (iMinFrameRequested > m_iBufferPositionFrames) {
    const size_t iFramesBuffered = m_sBuffer.size() / sourceChannels;
    const size_t iFramesToSkip = static_cast<size_t>(
        iMinFrameRequested - static_cast<int64_t>(m_iBufferPositionFrames));
    const size_t iEraseFrames = std::min(iFramesToSkip, iFramesBuffered);
    const size_t iEraseSamples = iEraseFrames * sourceChannels;
    m_sBuffer.erase(m_sBuffer.begin(), m_sBuffer.begin() + iEraseSamples);
    const int64_t iNewBufferPosition =
        static_cast<int64_t>(m_iBufferPositionFrames) +
        static_cast<int64_t>(iEraseFrames);
    if (iNewBufferPosition > std::numeric_limits<int>::max()) {
      SetErrorLocked("RageSoundSplitterImpl buffer position overflow");
      WarnSafety("ChannelSplit", m_sError);
      return RageSoundReader::ERROR;
    }
    m_iBufferPositionFrames = static_cast<int>(iNewBufferPosition);
  }

  if (iMinFrameRequested != m_iBufferPositionFrames) {
    if (iMinFrameRequested < 0 ||
        iMinFrameRequested > std::numeric_limits<int>::max()) {
      SetErrorLocked("RageSoundSplitterImpl cannot seek to invalid frame");
      WarnSafety("ChannelSplit", m_sError);
      return RageSoundReader::ERROR;
    }
    int iSeekRet = m_pSource->SetPosition(static_cast<int>(iMinFrameRequested));
    if (iSeekRet < 0) {
      m_sBuffer.clear();
      return iSeekRet;
    }
    m_iBufferPositionFrames = static_cast<int>(iMinFrameRequested);
    m_sBuffer.clear();
  }

  const size_t iFramesBuffered = m_sBuffer.size() / sourceChannels;

  const int64_t iBufferedEndFrame =
      static_cast<int64_t>(m_iBufferPositionFrames) +
      static_cast<int64_t>(iFramesBuffered);
  const int64_t iFramesToRead64 = iMaxFrameRequested - iBufferedEndFrame;
  if (iFramesToRead64 <= 0) {
    return 1;  // requested data already buffered
  }
  if (iFramesToRead64 > std::numeric_limits<int>::max()) {
    SetErrorLocked("RageSoundSplitterImpl read request is too large");
    WarnSafety("ChannelSplit", m_sError);
    return RageSoundReader::ERROR;
  }
  const int iFramesToRead = static_cast<int>(iFramesToRead64);

  size_t iSamplesToRead = 0;
  if (!FramesToSamples(iFramesToRead, sourceChannels, &iSamplesToRead)) {
    SetErrorLocked("RageSoundSplitterImpl read sample count overflow");
    WarnSafety("ChannelSplit", m_sError);
    return RageSoundReader::ERROR;
  }
  const size_t iOldSizeSamples = m_sBuffer.size();
  if (iSamplesToRead >
      std::numeric_limits<size_t>::max() - iOldSizeSamples) {
    SetErrorLocked("RageSoundSplitterImpl buffer resize overflow");
    WarnSafety("ChannelSplit", m_sError);
    return RageSoundReader::ERROR;
  }
  try {
    m_sBuffer.resize(iOldSizeSamples + iSamplesToRead);
  } catch (const std::bad_alloc&) {
    SetErrorLocked("RageSoundSplitterImpl could not allocate read buffer");
    WarnSafety("ChannelSplit", m_sError);
    return RageSoundReader::ERROR;
  }

  int iGotFrames = m_pSource->Read(
      m_sBuffer.data() + iOldSizeSamples, iFramesToRead);
  if (iGotFrames < 0) {
    m_sBuffer.resize(iOldSizeSamples);
    return iGotFrames;
  }
  if (iGotFrames > iFramesToRead) {
    m_sBuffer.resize(iOldSizeSamples);
    SetErrorLocked("RageSoundSplitterImpl source returned too many frames");
    WarnSafety("ChannelSplit", m_sError);
    return RageSoundReader::ERROR;
  }

  size_t iGotSamples = 0;
  if (!FramesToSamples(iGotFrames, sourceChannels, &iGotSamples)) {
    m_sBuffer.resize(iOldSizeSamples);
    SetErrorLocked("RageSoundSplitterImpl returned sample count overflow");
    WarnSafety("ChannelSplit", m_sError);
    return RageSoundReader::ERROR;
  }
  m_sBuffer.resize(iOldSizeSamples + iGotSamples);
  return 1;
}

void RageSoundReader_Split::AddSourceChannelToSound(
    int iFromChannel, int iToChannel) {
  auto impl = m_pImpl;
  if (impl == nullptr) {
    return;
  }
  std::lock_guard<std::mutex> lock(impl->m_Mutex);
  const unsigned sourceChannels = impl->SourceChannelsLocked();
  if (sourceChannels == 0 || iFromChannel < 0 ||
      static_cast<unsigned>(iFromChannel) >= sourceChannels ||
      iToChannel < 0 || iToChannel >= kMaxSplitOutputChannels) {
    impl->SetErrorLocked(
        "RageSoundReader_Split::AddSourceChannelToSound rejected an invalid "
        "channel mapping");
    WarnSafety("ChannelSplit", impl->m_sError);
    return;
  }

  m_aChannels.push_back(ChannelMap(iFromChannel, iToChannel));
  m_iNumOutputChannels = std::max(m_iNumOutputChannels, iToChannel + 1);
}

RageSoundSplitter::RageSoundSplitter(RageSoundReader* pSource) {
  m_pImpl = std::make_shared<RageSoundSplitterImpl>(pSource);
}

RageSoundSplitter::~RageSoundSplitter() {
}

RageSoundReader_Split* RageSoundSplitter::CreateSound() {
  if (m_pImpl == nullptr) {
    return nullptr;
  }
  {
    std::lock_guard<std::mutex> lock(m_pImpl->m_Mutex);
    if (!m_pImpl->HasSourceLocked()) {
      m_pImpl->SetErrorLocked("RageSoundSplitter::CreateSound has no source");
      WarnSafety("ChannelSplit", m_pImpl->m_sError);
      return nullptr;
    }
  }
  return new RageSoundReader_Split(m_pImpl);
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
