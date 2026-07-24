#include "SongPosition.h"

#include <algorithm>
#include <cmath>

#include "LightsManager.h"
#include "NoteTypes.h"
#include "Preference.h"
#include "RageLog.h"
#include "RageTimer.h"
#include "RageUtil.h"
#include "TimingData.h"
#include "global.h"

static Preference<float> g_fVisualDelaySeconds("VisualDelaySeconds", 0.0f);

namespace {
constexpr float kMinPlayableBeat = -1999.0f;
constexpr float kMaxPlayableBeat =
    MAX_NOTE_ROW / static_cast<float>(ROWS_PER_BEAT);
constexpr float kFallbackBPS = 1.0f;
constexpr float kMaxBPS = 100.0f;
constexpr float kMaxVisualDelaySeconds = 60.0f;

bool IsFinite(float value) {
  return std::isfinite(static_cast<double>(value));
}

void WarnSongPositionFix(const char* message) {
  if (LOG != nullptr) {
    LOG->Warn("%s", message);
  }
}

float SanitizeBeat(float value, float fallback, const char* context) {
  if (!IsFinite(value)) {
    WarnSongPositionFix(context);
    return IsFinite(fallback) ? fallback : 0.0f;
  }
  if (value < kMinPlayableBeat) {
    WarnSongPositionFix(
        "SongPosition clamped an extremely negative "
        "beat.");
    return kMinPlayableBeat;
  }
  if (value > kMaxPlayableBeat) {
    WarnSongPositionFix(
        "SongPosition clamped an extremely large "
        "beat.");
    return kMaxPlayableBeat;
  }
  return value;
}

float SanitizeBPS(float value) {
  if (!IsFinite(value) || value <= 0.0f) {
    WarnSongPositionFix(
        "SongPosition replaced invalid BPS with 1.");
    return kFallbackBPS;
  }
  if (value > kMaxBPS) {
    WarnSongPositionFix(
        "SongPosition clamped excessive BPS.");
    return kMaxBPS;
  }
  return value;
}

float SanitizeVisualDelay(float value, const char* context) {
  if (!IsFinite(value)) {
    WarnSongPositionFix(context);
    return 0.0f;
  }
  if (value < -kMaxVisualDelaySeconds || value > kMaxVisualDelaySeconds) {
    WarnSongPositionFix(
        "SongPosition clamped excessive visual "
        "delay.");
    return std::clamp(value, -kMaxVisualDelaySeconds, kMaxVisualDelaySeconds);
  }
  return value;
}

int SanitizeWarpBeginRow(int value) {
  if (value < -1) {
    WarnSongPositionFix(
        "SongPosition reset invalid warp begin row.");
    return -1;
  }
  if (value > MAX_NOTE_ROW) {
    WarnSongPositionFix(
        "SongPosition clamped excessive warp begin "
        "row.");
    return MAX_NOTE_ROW;
  }
  return value;
}

float SanitizeWarpDestination(float value) {
  if (!IsFinite(value)) {
    WarnSongPositionFix(
        "SongPosition reset invalid warp destination.");
    return -1.0f;
  }
  if (value < -1.0f) {
    WarnSongPositionFix(
        "SongPosition clamped negative warp "
        "destination.");
    return -1.0f;
  }
  if (value > kMaxPlayableBeat) {
    WarnSongPositionFix(
        "SongPosition clamped excessive warp "
        "destination.");
    return kMaxPlayableBeat;
  }
  return value;
}
}  // namespace

void SongPosition::UpdateSongPosition(
    float fPositionSeconds, const TimingData& timing,
    const RageTimer& timestamp, float fAdditionalVisualDelay) {
  if (!IsFinite(fPositionSeconds)) {
    WarnSongPositionFix(
        "SongPosition ignored non-finite music "
        "seconds.");
    return;
  }

  TimingData::GetBeatArgs beat_info;
  beat_info.elapsed_time = fPositionSeconds;
  timing.GetBeatAndBPSFromElapsedTime(beat_info);
  m_fSongBeat = SanitizeBeat(
      beat_info.beat, m_fSongBeat,
      "SongPosition replaced non-finite song beat.");
  m_fCurBPS = SanitizeBPS(beat_info.bps_out);
  m_bFreeze = beat_info.freeze_out;
  m_bDelay = beat_info.delay_out;
  m_iWarpBeginRow = SanitizeWarpBeginRow(beat_info.warp_begin_out);
  m_fWarpDestination = SanitizeWarpDestination(beat_info.warp_dest_out);

  m_fMusicSeconds = fPositionSeconds;

  const float lightsAheadSeconds = SanitizeVisualDelay(
      g_fLightsAheadSeconds.Get(),
      "SongPosition reset non-finite lights ahead "
      "seconds.");
  m_fLightSongBeat = SanitizeBeat(
      timing.GetBeatFromElapsedTime(fPositionSeconds + lightsAheadSeconds),
      m_fSongBeat,
      "SongPosition replaced non-finite light beat.");

  m_fSongBeatNoOffset = SanitizeBeat(
      timing.GetBeatFromElapsedTimeNoOffset(fPositionSeconds), m_fSongBeat,
      "SongPosition replaced non-finite no-offset "
      "beat.");

  const float visualDelaySeconds = SanitizeVisualDelay(
      g_fVisualDelaySeconds.Get(),
      "SongPosition reset non-finite visual delay.");
  const float additionalVisualDelay = SanitizeVisualDelay(
      fAdditionalVisualDelay,
      "SongPosition reset non-finite additional visual "
      "delay.");
  m_fMusicSecondsVisible =
      fPositionSeconds - visualDelaySeconds - additionalVisualDelay;
  beat_info.elapsed_time = m_fMusicSecondsVisible;
  timing.GetBeatAndBPSFromElapsedTime(beat_info);
  m_fSongBeatVisible = SanitizeBeat(
      beat_info.beat, m_fSongBeat,
      "SongPosition replaced non-finite visible beat.");

  if (!timestamp.IsZero()) {
    m_LastBeatUpdate = timestamp;
  } else {
    m_LastBeatUpdate.Touch();
  }
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
