#include "SongPosition.h"

#include "LightsManager.h"
#include "Preference.h"
#include "RageLog.h"
#include "RageTimer.h"
#include "RageUtil.h"
#include "TimingData.h"
#include "global.h"

static Preference<float> g_fVisualDelaySeconds("VisualDelaySeconds", 0.0f);

void SongPosition::UpdateSongPosition(
    float fPositionSeconds, const TimingData& timing,
    const RageTimer& timestamp, float fAdditionalVisualDelay) {
  if (!timestamp.IsZero()) {
    m_LastBeatUpdate = timestamp;
  } else {
    m_LastBeatUpdate.Touch();
  }

  TimingData::GetBeatArgs beat_info;
  beat_info.elapsed_time = fPositionSeconds;
  timing.GetBeatAndBPSFromElapsedTime(beat_info);
  m_fSongBeat = beat_info.beat;
  m_fCurBPS = beat_info.bps_out;
  m_bFreeze = beat_info.freeze_out;
  m_bDelay = beat_info.delay_out;
  m_iWarpBeginRow = beat_info.warp_begin_out;
  m_fWarpDestination = beat_info.warp_dest_out;

  // Defensive guard: malformed/unstable timing state should never hard-crash a
  // live run. Keep gameplay alive and surface diagnostics in logs.
  if (m_fSongBeat <= -2000.0f) {
    LOG->Warn("SongPosition: suspicious beat %f at %f seconds, clamping to -1999.0",
              m_fSongBeat, fPositionSeconds);
    m_fSongBeat = -1999.0f;
  }

  m_fMusicSeconds = fPositionSeconds;

  m_fLightSongBeat =
      timing.GetBeatFromElapsedTime(fPositionSeconds + g_fLightsAheadSeconds);

  m_fSongBeatNoOffset = timing.GetBeatFromElapsedTimeNoOffset(fPositionSeconds);

  m_fMusicSecondsVisible =
      fPositionSeconds - g_fVisualDelaySeconds.Get() - fAdditionalVisualDelay;
  beat_info.elapsed_time = m_fMusicSecondsVisible;
  timing.GetBeatAndBPSFromElapsedTime(beat_info);
  m_fSongBeatVisible = beat_info.beat;
}

// lua start
#include "LuaBinding.h"
class LunaSongPosition : public Luna<SongPosition> {
 public:
  DEFINE_METHOD(GetMusicSecondsVisible, m_fMusicSecondsVisible);
  DEFINE_METHOD(GetSongBeatVisible, m_fSongBeatVisible);
  DEFINE_METHOD(GetMusicSeconds, m_fMusicSeconds);
  DEFINE_METHOD(GetSongBeat, m_fSongBeat);
  DEFINE_METHOD(GetSongBeatNoOffset, m_fSongBeatNoOffset);
  DEFINE_METHOD(GetCurBPS, m_fCurBPS);
  DEFINE_METHOD(GetFreeze, m_bFreeze);
  DEFINE_METHOD(GetDelay, m_bDelay);
  DEFINE_METHOD(GetWarpBeginRow, m_iWarpBeginRow);
  DEFINE_METHOD(GetWarpDestination, m_fWarpDestination);

  LunaSongPosition() {
    ADD_METHOD(GetMusicSecondsVisible);
    ADD_METHOD(GetSongBeatVisible);
    ADD_METHOD(GetMusicSeconds);
    ADD_METHOD(GetSongBeat);
    ADD_METHOD(GetSongBeatNoOffset);
    ADD_METHOD(GetCurBPS);
    ADD_METHOD(GetFreeze);
    ADD_METHOD(GetDelay);
    ADD_METHOD(GetWarpBeginRow);
    ADD_METHOD(GetWarpDestination);
  }
};

LUA_REGISTER_CLASS(SongPosition);
/**
 * @file
 * @author Thai Pangsakulyanont (c) 2011
 * @section LICENSE
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
