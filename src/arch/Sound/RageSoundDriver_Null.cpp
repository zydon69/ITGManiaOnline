#include "RageSoundDriver_Null.h"

#include <cstdint>

#include "PrefsManager.h"
#include "RageSoundConstants.h"
#include "RageTimer.h"
#include "arch/Sound/RageSoundDriver.h"

REGISTER_SOUND_DRIVER_CLASS(Null);

const int channels = 2;
const int kMaxNullMixFramesPerUpdate = 4096;

void RageSoundDriver_Null::Update() {
  /* "Play" frames. */
  const int64_t targetPosition = GetPosition() + 1024 * 4;
  int mixedFrames = 0;
  while (m_iLastCursorPos < targetPosition &&
         mixedFrames < kMaxNullMixFramesPerUpdate) {
    int16_t buf[256 * channels];
    this->Mix(buf, 256, m_iLastCursorPos, GetPosition());
    m_iLastCursorPos += 256;
    mixedFrames += 256;
  }
  if (m_iLastCursorPos < targetPosition) {
    m_iLastCursorPos = targetPosition;
  }

  RageSoundDriver::Update();
}

int64_t RageSoundDriver_Null::GetPosition() const {
  if (m_iSampleRate <= 0) {
    return 0;
  }
  return (RageTimer::GetTimeSinceStartMicroseconds() * m_iSampleRate) / 1000000;
}

RageSoundDriver_Null::RageSoundDriver_Null() {
  m_iSampleRate =
      PREFSMAN != nullptr ? PREFSMAN->m_iSoundPreferredSampleRate.Get() : 0;
  if (m_iSampleRate <= 0) {
    m_iSampleRate = FALLBACK_SAMPLE_RATE;
  }
  m_iLastCursorPos = GetPosition();
  StartDecodeThread();
}

int RageSoundDriver_Null::GetSampleRate() const { return m_iSampleRate; }

/*
 * (c) 2002-2004 Glenn Maynard, Aaron VonderHaar
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
