#include <algorithm>
#include <atomic>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <mutex>

#include "PerfDiagnostics.h"
#include "RageLog.h"
#include "RageSound.h"
#include "RageSoundDriver.h"
#include "RageSoundMixBuffer.h"
#include "RageSoundReader.h"
#include "RageThreads.h"
#include "RageUtil.h"
#include "Screen.h"
#include "ScreenManager.h"
#include "config.hpp"
#include "global.h"

#ifdef HAVE_UNISTD_H
#include <unistd.h>
#endif

#if defined(_MSC_VER) && !defined(PRIu64)
#define PRIu64 "I64u"
#endif
/* Note(sukibaby): If you need to activate a log method
 * below, and it's casting a variable to int instead of
 * using the correct format specifier, please modify it
 * to use PRId64 for int64_t, or PRIu64 for uint64_t */

static const int channels = 2;

static int frames_to_buffer;

/* 512 is about 10ms, which is big enough for the tolerance of most schedulers.
 */
static int chunksize() { return 512; }

static int ClampDecodeBufferFrames(int frames) {
  const int framesPerBlock = samples_per_block / channels;
  const int maxFrames = framesPerBlock * 1024;
  return std::clamp(frames, framesPerBlock, maxFrames);
}

static int underruns = 0, logged_underruns = 0;
static std::atomic<bool> g_bUnderrunTraceEnabled{false};
static std::once_flag g_UnderrunTraceInitOnce;
static std::atomic<int> g_iUnderrunScreenContext{0};
static std::atomic<int> g_iUnderrunScreenType{ScreenType_Invalid};
static std::atomic<uint64_t> g_iUnderrunScreenContextUsec{0};
static std::atomic<uint64_t> g_iSoundDebugSerial{0};
static constexpr unsigned kDecodeLowWatermarkBlocks = 2;
static constexpr unsigned kDecodeRefillTargetBlocks = 16;
static constexpr unsigned kDecodeStartPrebufferTargetBlocks = 16;
static constexpr unsigned kDecodeStrongStartMinimumBlocks = 4;
static constexpr unsigned kDecodeShortSoundPrebufferTargetBlocks = 4;
static constexpr int kDecodeEmergencySleepUsec = 125;
static constexpr int kDecodeLowWatermarkSleepUsec = 250;
static constexpr uint64_t kDecodeEmergencyModeMaxUsec = 200000;
static constexpr int kDecodeEmergencyRecoverySleepUsec = 500;
static constexpr uint64_t kDecodeSchedulerStatsLogPeriodUsec = 3000000;
static constexpr int kDecodeThreadWouldBlockRetries = 0;
// Strong music prebuffering is synchronous in StartMixing by design. Keep these
// bounds high enough to avoid start-of-song underruns, and treat ScreenInit
// spikes as a separate UX optimization problem.
static constexpr int kStartPrebufferWouldBlockRetries = 240;
static constexpr int kStartPrebufferRetrySleepUsec = 1000;
static constexpr int kStrongStartLastChanceWouldBlockRetries = 500;
static constexpr uint64_t kMixerStarvationTracePeriodUsec = 250000;

enum UnderrunScreenContext {
  UNDERRUN_SCREEN_UNKNOWN = 0,
  UNDERRUN_SCREEN_NONE,
  UNDERRUN_SCREEN_GAMEPLAY,
  UNDERRUN_SCREEN_EVALUATION,
  UNDERRUN_SCREEN_SELECT_MUSIC,
  UNDERRUN_SCREEN_PLAYER_OPTIONS,
  UNDERRUN_SCREEN_SELECT_STYLE,
  UNDERRUN_SCREEN_MENU,
  UNDERRUN_SCREEN_ATTRACT,
  UNDERRUN_SCREEN_SYSTEM,
  UNDERRUN_SCREEN_OTHER
};

static const char* UnderrunScreenContextName(int context) {
  switch (context) {
    case UNDERRUN_SCREEN_NONE:
      return "none";
    case UNDERRUN_SCREEN_GAMEPLAY:
      return "gameplay";
    case UNDERRUN_SCREEN_EVALUATION:
      return "evaluation";
    case UNDERRUN_SCREEN_SELECT_MUSIC:
      return "select_music";
    case UNDERRUN_SCREEN_PLAYER_OPTIONS:
      return "player_options";
    case UNDERRUN_SCREEN_SELECT_STYLE:
      return "select_style";
    case UNDERRUN_SCREEN_MENU:
      return "menu";
    case UNDERRUN_SCREEN_ATTRACT:
      return "attract";
    case UNDERRUN_SCREEN_SYSTEM:
      return "system";
    case UNDERRUN_SCREEN_OTHER:
      return "other";
    default:
      return "unknown";
  }
}

static int ClassifyUnderrunScreenContext(
    const std::string& screenName, ScreenType screenType) {
  if (screenName.empty()) {
    return UNDERRUN_SCREEN_NONE;
  }
  if (screenType == gameplay) {
    return UNDERRUN_SCREEN_GAMEPLAY;
  }
  if (BeginsWith(screenName, "ScreenEvaluation")) {
    return UNDERRUN_SCREEN_EVALUATION;
  }
  if (screenName == "ScreenSelectMusic") {
    return UNDERRUN_SCREEN_SELECT_MUSIC;
  }
  if (screenName == "ScreenPlayerOptions") {
    return UNDERRUN_SCREEN_PLAYER_OPTIONS;
  }
  if (screenName == "ScreenSelectStyle") {
    return UNDERRUN_SCREEN_SELECT_STYLE;
  }
  if (screenType == game_menu) {
    return UNDERRUN_SCREEN_MENU;
  }
  if (screenType == attract) {
    return UNDERRUN_SCREEN_ATTRACT;
  }
  if (screenType == system_menu) {
    return UNDERRUN_SCREEN_SYSTEM;
  }
  return UNDERRUN_SCREEN_OTHER;
}

static void UpdateUnderrunScreenContext() {
  int context = UNDERRUN_SCREEN_NONE;
  int screenType = ScreenType_Invalid;

  if (SCREENMAN != nullptr) {
    Screen* topScreen = SCREENMAN->GetTopScreen();
    if (topScreen != nullptr) {
      const ScreenType topScreenType = topScreen->GetScreenType();
      context =
          ClassifyUnderrunScreenContext(topScreen->GetName(), topScreenType);
      screenType = topScreenType;
    }
  }

  g_iUnderrunScreenType.store(screenType, std::memory_order_release);
  g_iUnderrunScreenContext.store(context, std::memory_order_release);
  g_iUnderrunScreenContextUsec.store(
      RageTimer::GetTimeSinceStartMicroseconds(), std::memory_order_release);
}

static void EnsureUnderrunTraceInitialized() {
  std::call_once(g_UnderrunTraceInitOnce, []() {
    const bool enabled = GetCommandlineArgument("audio-underrun-trace");
    g_bUnderrunTraceEnabled.store(enabled, std::memory_order_release);
    if (enabled) {
      LOG->Info("Audio underrun forensic tracing enabled.");
    }
  });
}

static bool IsUnderrunTraceEnabled() {
  EnsureUnderrunTraceInitialized();
  return g_bUnderrunTraceEnabled.load(std::memory_order_acquire) ||
         LogAudioUnderrunDiagnosticsEnabled();
}

RageSoundDriver::Sound::Sound() {
  m_pSound = nullptr;
  ClearDebugIdentity();
  SetState(AVAILABLE, std::memory_order_relaxed);
  m_bPaused = false;
}

void RageSoundDriver::Sound::ClearDebugIdentity() {
  m_szDebugPath[0] = '\0';
  m_iDebugSerial = 0;
  m_iDebugStartUsec = 0;
  m_iDebugPrebufferTarget = 0;
  m_iDebugPrebufferReadable = 0;
  m_iDebugPrebufferWritable = 0;
  m_bDebugStrongPrebuffer = false;
}

void RageSoundDriver::Sound::SetDebugIdentity(
    const std::string& path, uint64_t serial, uint64_t startUsec) {
  std::snprintf(
      m_szDebugPath, ARRAYLEN(m_szDebugPath), "%s",
      path.empty() ? "<empty-path>" : path.c_str());
  m_iDebugSerial = serial;
  m_iDebugStartUsec = startUsec;
  m_iDebugPrebufferTarget = 0;
  m_iDebugPrebufferReadable = 0;
  m_iDebugPrebufferWritable = 0;
  m_bDebugStrongPrebuffer = false;
}

const char* RageSoundDriver::Sound::GetDebugPath() const {
  return m_szDebugPath[0] == '\0' ? "<unassigned-slot>" : m_szDebugPath;
}

void RageSoundDriver::Sound::Allocate(int iFrames) {
  /* Reserve enough blocks in the buffer to hold the buffer.  Add one, to
   * account for the fact that we may have a partial block due to a previous
   * Mix() call. */
  const int iFramesPerBlock = samples_per_block / channels;
  iFrames = ClampDecodeBufferFrames(iFrames);
  const int iBlocksToPrebuffer =
      (iFrames + iFramesPerBlock - 1) / iFramesPerBlock;
  m_Buffer.reserve(iBlocksToPrebuffer + 1);
  m_PosMapQueue.reserve(32);
}

void RageSoundDriver::Sound::Deallocate() {
  m_Buffer.reserve(0);
  m_PosMapQueue.reserve(0);
}

int RageSoundDriver::DecodeThread_start(void* p) {
  ((RageSoundDriver*)p)->DecodeThread();
  return 0;
}

RageSoundMixBuffer& RageSoundDriver::MixIntoBuffer(
    int iFrames, int64_t iFrameNumber, int64_t iCurrentFrame) {
  ASSERT_M(
      m_DecodeThread.IsCreated(),
      "RageSoundDriver::StartDecodeThread() was never called");

  RageSoundMixBuffer& mix = *m_pMixBuffer;
  const bool traceEnabled = IsUnderrunTraceEnabled();

  for (unsigned i = 0; i < ARRAYLEN(m_Sounds); ++i) {
    /* s.m_pSound can not safely be accessed from here. */
    Sound& s = m_Sounds[i];
    const Sound::State state = s.GetState();
    if (state == Sound::HALTING) {
      /* This indicates that this stream can be reused. */
      s.m_bPaused = false;
      s.SetState(Sound::STOPPED);

      //			LOG->Trace("set %p from HALTING to STOPPED",
      // m_Sounds[i].m_pSound);
      continue;
    }

    if (state != Sound::STOPPING && state != Sound::PLAYING) {
      continue;
    }

    /* STOPPING or PLAYING.  Read sound data. */
    if (m_Sounds[i].m_bPaused) {
      continue;
    }

    int iGotFrames = 0;
    int iFramesLeft = iFrames;

    /* Does the sound have a start time? */
    if (!s.m_StartTime.IsZero() && iCurrentFrame != -1) {
      /* If the sound is supposed to start at a time past this buffer, insert
       * silence. */
      const int64_t iFramesUntilThisBuffer = iFrameNumber - iCurrentFrame;
      const float fSecondsBeforeStart = -s.m_StartTime.Ago();
      const int64_t iFramesBeforeStart =
          int64_t(fSecondsBeforeStart * GetSampleRate());
      const int64_t silentFrames =
          iFramesBeforeStart - iFramesUntilThisBuffer;
      const int iSilentFramesInThisBuffer =
          static_cast<int>(
              std::clamp<int64_t>(silentFrames, 0, iFramesLeft));

      iGotFrames += iSilentFramesInThisBuffer;
      iFramesLeft -= iSilentFramesInThisBuffer;

      /* If we didn't completely fill the buffer, then we've written all of the
       * silence. */
      if (iFramesLeft) {
        s.m_StartTime.SetZero();
      }
    }

    /* Fill actual data. */
    sound_block* p[2];
    unsigned pSize[2];
    s.m_Buffer.get_read_pointers(p, pSize);

    while (iFramesLeft && pSize[0]) {
      if (!p[0]->m_FramesInBuffer) {
        /* We've processed all of the sound in this block.  Mark it read. */
        s.m_Buffer.advance_read_pointer(1);
        ++p[0];
        --pSize[0];

        /* If we have more data in p[0], keep going. */
        if (pSize[0]) {
          continue;  // more data
        }

        /* We've used up p[0].  Try p[1]. */
        std::swap(p[0], p[1]);
        std::swap(pSize[0], pSize[1]);
        continue;
      }

      /* Note that, until we call advance_read_pointer, we can safely write to
       * p[0]. */
      const int frames_to_read = std::min(iFramesLeft, p[0]->m_FramesInBuffer);
      mix.SetWriteOffset(iGotFrames * channels);
      mix.write(p[0]->m_BufferNext, frames_to_read * channels);

      {
        Sound::QueuedPosMap pos;
        pos.iStreamFrame = iFrameNumber + iGotFrames;
        pos.iHardwareFrame = p[0]->m_iPosition;
        pos.iFrames = frames_to_read;

        s.m_PosMapQueue.write(&pos, 1);
      }

      p[0]->m_BufferNext += frames_to_read * channels;
      p[0]->m_FramesInBuffer -= frames_to_read;
      p[0]->m_iPosition += frames_to_read;

      //			LOG->Trace( "incr fr rd += %i (state %i) (%p)",
      //				(int) frames_to_read, s.m_State,
      // s.m_pSound );

      iGotFrames += frames_to_read;
      iFramesLeft -= frames_to_read;
    }

    /* If we don't have enough to fill the buffer, we've underrun. */
    if (iGotFrames < iFrames && s.GetState() == Sound::PLAYING) {
      ++underruns;
      static uint64_t sLastUnderrunTraceUsec = 0;
      const uint64_t nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
      if (traceEnabled &&
          (sLastUnderrunTraceUsec == 0 ||
           nowUsec - sLastUnderrunTraceUsec >=
               kMixerStarvationTracePeriodUsec)) {
        sLastUnderrunTraceUsec = nowUsec;
        const int context =
            g_iUnderrunScreenContext.load(std::memory_order_acquire);
        const int screenType =
            g_iUnderrunScreenType.load(std::memory_order_acquire);
        const uint64_t contextUsec =
            g_iUnderrunScreenContextUsec.load(std::memory_order_acquire);
        const uint64_t contextAgeUsec =
            contextUsec == 0 || nowUsec < contextUsec ? 0 : nowUsec - contextUsec;
        unsigned activeSounds = 0;
        std::string activeSlotSummary;
        for (unsigned activeIndex = 0; activeIndex < ARRAYLEN(m_Sounds);
             ++activeIndex) {
          const Sound::State activeState = m_Sounds[activeIndex].GetState();
          if (activeState == Sound::PLAYING ||
              activeState == Sound::STOPPING ||
              activeState == Sound::BUFFERING) {
            ++activeSounds;
            if (activeSlotSummary.size() < 900) {
              if (!activeSlotSummary.empty()) {
                activeSlotSummary += "|";
              }
              activeSlotSummary += ssprintf(
                  "%u#%" PRIu64 ":s%d:r%u:w%u:%s", activeIndex,
                  m_Sounds[activeIndex].m_iDebugSerial, activeState,
                  m_Sounds[activeIndex].m_Buffer.num_readable(),
                  m_Sounds[activeIndex].m_Buffer.num_writable(),
                  m_Sounds[activeIndex].GetDebugPath());
            }
          }
        }
        LOG->Warn(
            "UNDERRUN_TRACE: mixer_starvation sound='%s' slot=%u serial=%" PRIu64
            " state=%d "
            "context=%s screen_type=%d context_age_us=%" PRIu64
            " got=%d need=%d missing=%d frames_left=%d readable_blocks=%u "
            "writable_blocks=%u active_sounds=%u sample_rate=%d "
            "prebuffer_target=%u prebuffer_readable=%u prebuffer_writable=%u "
            "strong_prebuffer=%d slot_age_us=%" PRIu64
            " mix_frame=%" PRId64 " hw_frame=%" PRId64
            " verbose=%d active_slots='%s'",
            s.GetDebugPath(), i, s.m_iDebugSerial,
            static_cast<int>(s.GetState()),
            UnderrunScreenContextName(context), screenType, contextAgeUsec,
            iGotFrames, iFrames, iFrames - iGotFrames, iFramesLeft,
            s.m_Buffer.num_readable(), s.m_Buffer.num_writable(), activeSounds,
            GetSampleRate(), s.m_iDebugPrebufferTarget,
            s.m_iDebugPrebufferReadable, s.m_iDebugPrebufferWritable,
            s.m_bDebugStrongPrebuffer ? 1 : 0,
            s.m_iDebugStartUsec == 0 || nowUsec < s.m_iDebugStartUsec
                ? 0
                : nowUsec - s.m_iDebugStartUsec,
            iFrameNumber, iCurrentFrame, traceEnabled ? 1 : 0,
            activeSlotSummary.c_str());
      }
    }
  }

  return mix;
}

void RageSoundDriver::Mix(
    int16_t* pBuf, int iFrames, int64_t iFrameNumber, int64_t iCurrentFrame) {
  if (pBuf == nullptr || iFrames <= 0) {
    return;
  }
  memset(pBuf, 0, iFrames * channels * sizeof(int16_t));
  MixIntoBuffer(iFrames, iFrameNumber, iCurrentFrame).read(pBuf);
}

void RageSoundDriver::Mix(
    float* pBuf, int iFrames, int64_t iFrameNumber, int64_t iCurrentFrame) {
  if (pBuf == nullptr || iFrames <= 0) {
    return;
  }
  memset(pBuf, 0, iFrames * channels * sizeof(float));
  MixIntoBuffer(iFrames, iFrameNumber, iCurrentFrame).read(pBuf);
}

void RageSoundDriver::MixDeinterlaced(
    float** pBufs, int iChannels, int iFrames, int64_t iFrameNumber,
    int64_t iCurrentFrame) {
  if (pBufs == nullptr || iChannels <= 0 || iFrames <= 0) {
    return;
  }
  for (int i = 0; i < iChannels; ++i) {
    if (pBufs[i] == nullptr) {
      return;
    }
    memset(pBufs[i], 0, iFrames * sizeof(float));
  }
  MixIntoBuffer(iFrames, iFrameNumber, iCurrentFrame)
      .read_deinterlace(pBufs, iChannels);
}

void RageSoundDriver::DecodeThread() {
  SetupDecodingThread();
  const bool traceEnabled = IsUnderrunTraceEnabled();
  int idle_decode_spin_count = 0;
  uint64_t critical_starvation_since_usec = 0;
  bool was_in_critical_starvation = false;
  uint64_t emergency_entries = 0;
  uint64_t emergency_capped_recoveries = 0;
  uint64_t low_watermark_cycles = 0;
  uint64_t decode_stall_cycles = 0;
  uint64_t scheduler_loops = 0;
  uint64_t last_scheduler_stats_log_usec = 0;

  while (!m_bShutdownDecodeThread.load(std::memory_order_acquire)) {
    ++scheduler_loops;
    bool has_active_sound = false;
    bool wrote_any_data = false;
    bool still_needs_decode = false;
    bool has_critical_starvation = false;
    bool has_low_watermark = false;
    RefillTrace decodeRefillTrace;
    bool hasDecodeRefillTrace = false;

    {
      LockMut(m_Mutex);
      //		LOG->Trace("begin mix");

      for (unsigned i = 0; i < ARRAYLEN(m_Sounds); ++i) {
        const Sound::State state = m_Sounds[i].GetState();
        if (state != Sound::PLAYING && state != Sound::BUFFERING &&
            state != Sound::STOPPING) {
          continue;
        }

        has_active_sound = true;
        if (state != Sound::PLAYING) {
          continue;
        }
        Sound* pSound = &m_Sounds[i];
        const unsigned readableBeforeDecode = pSound->m_Buffer.num_readable();
        const unsigned writableBeforeDecode = pSound->m_Buffer.num_writable();

        if (!pSound->m_bPaused) {
          if (readableBeforeDecode == 0 && writableBeforeDecode > 0) {
            has_critical_starvation = true;
          } else if (readableBeforeDecode <= kDecodeLowWatermarkBlocks &&
                     writableBeforeDecode > 0) {
            has_low_watermark = true;
          }
        }

        RefillTrace refillTrace;
        const bool refilled = RefillSoundBufferToTarget(
            *pSound, kDecodeRefillTargetBlocks, "decode_thread",
            kDecodeThreadWouldBlockRetries, 0,
            traceEnabled ? &refillTrace : nullptr);
        wrote_any_data = refilled || wrote_any_data;
        if (traceEnabled && refillTrace.shouldLog && !hasDecodeRefillTrace) {
          decodeRefillTrace = refillTrace;
          hasDecodeRefillTrace = true;
        }

        const unsigned readableAfterDecode = pSound->m_Buffer.num_readable();
        const unsigned writableAfterDecode = pSound->m_Buffer.num_writable();
        if (pSound->GetState() == Sound::PLAYING &&
            writableAfterDecode > 0 &&
            readableAfterDecode < kDecodeRefillTargetBlocks) {
          still_needs_decode = true;
        }

        if (pSound->GetState() == Sound::PLAYING && !pSound->m_bPaused) {
          if (readableAfterDecode == 0 && writableAfterDecode > 0) {
            has_critical_starvation = true;
          } else if (readableAfterDecode <= kDecodeLowWatermarkBlocks &&
                     writableAfterDecode > 0) {
            has_low_watermark = true;
          }
        }
      }
      //		LOG->Trace("end mix");
    }

    if (hasDecodeRefillTrace) {
      LOG->Info(
          "UNDERRUN_TRACE: refill reason=decode_thread sound='%s' "
          "readable=%u->%u writable=%u->%u target=%u writes=%d "
          "would_block=%d target_reached=%d terminal_ret=%d elapsed_us=%" PRIu64
          " state=%d",
          decodeRefillTrace.path.c_str(), decodeRefillTrace.readableBefore,
          decodeRefillTrace.readableAfter, decodeRefillTrace.writableBefore,
          decodeRefillTrace.writableAfter, decodeRefillTrace.target,
          decodeRefillTrace.writes, decodeRefillTrace.wouldBlocks,
          decodeRefillTrace.targetReached ? 1 : 0, decodeRefillTrace.terminalRet,
          decodeRefillTrace.elapsedUsec, decodeRefillTrace.state);
    }

    int iSampleRate = GetSampleRate();
    if (iSampleRate <= 0) {
      iSampleRate = FALLBACK_SAMPLE_RATE;
    }

    // Adaptive sleep strategy:
    // - Aggressive wakeups when buffers still need decode (underrun prevention).
    // - Moderate wakeups when actively playing and writing.
    // - Relaxed wakeups when idle.
    int iUsecs = (1000000 * chunksize() / iSampleRate) / 2;
    if (!has_active_sound) {
      idle_decode_spin_count = 0;
      critical_starvation_since_usec = 0;
      iUsecs = std::max(iUsecs, 2000);
    } else if (has_critical_starvation) {
      // A PLAYING stream ran out of readable blocks. Poll aggressively until
      // we refill, otherwise the mixer can consume silence before decode wakes.
      const uint64_t nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
      if (critical_starvation_since_usec == 0) {
        critical_starvation_since_usec = nowUsec;
        ++emergency_entries;
        if (traceEnabled) {
          LOG->Warn(
              "UNDERRUN_TRACE: decode_emergency_enter sample_rate=%d",
              iSampleRate);
        }
      }
      idle_decode_spin_count = 0;
      if (nowUsec - critical_starvation_since_usec <=
          kDecodeEmergencyModeMaxUsec) {
        iUsecs = kDecodeEmergencySleepUsec;
      } else {
        ++emergency_capped_recoveries;
        if (traceEnabled) {
          static uint64_t sLastEmergencyCapTraceUsec = 0;
          if (sLastEmergencyCapTraceUsec == 0 ||
              nowUsec - sLastEmergencyCapTraceUsec >= 500000) {
            sLastEmergencyCapTraceUsec = nowUsec;
            LOG->Warn(
                "UNDERRUN_TRACE: decode_emergency_capped "
                "duration_us=%" PRIu64 " recovery_sleep_us=%d",
                nowUsec - critical_starvation_since_usec,
                kDecodeEmergencyRecoverySleepUsec);
          }
        }
        iUsecs = kDecodeEmergencyRecoverySleepUsec;
      }
      was_in_critical_starvation = true;
    } else if (has_low_watermark) {
      // Keep a small but safe lead in decode buffers to prevent starvation.
      ++low_watermark_cycles;
      critical_starvation_since_usec = 0;
      idle_decode_spin_count = std::max(idle_decode_spin_count - 1, 0);
      iUsecs = std::min(iUsecs, kDecodeLowWatermarkSleepUsec);
    } else if (still_needs_decode) {
      critical_starvation_since_usec = 0;
      if (wrote_any_data) {
        idle_decode_spin_count = std::max(idle_decode_spin_count - 1, 0);
        iUsecs = 250;
      } else {
        // If decode can't progress right now, back off progressively to avoid
        // a hot spin loop while still retrying quickly.
        ++decode_stall_cycles;
        idle_decode_spin_count = std::min(idle_decode_spin_count + 1, 8);
        const int backoffUsecs = 250 + idle_decode_spin_count * 250;
        iUsecs = std::max(iUsecs / 4, backoffUsecs);
        if (traceEnabled) {
          static uint64_t sLastDecodeStallTraceUsec = 0;
          const uint64_t nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
          if (sLastDecodeStallTraceUsec == 0 ||
              nowUsec - sLastDecodeStallTraceUsec >= 500000) {
            sLastDecodeStallTraceUsec = nowUsec;
            LOG->Warn(
                "UNDERRUN_TRACE: decode_stall active=1 needs_decode=1 "
                "wrote_any=0 spin=%d sleep_us=%d sample_rate=%d",
                idle_decode_spin_count, iUsecs, iSampleRate);
          }
        }
      }
    } else if (wrote_any_data) {
      critical_starvation_since_usec = 0;
      idle_decode_spin_count = std::max(idle_decode_spin_count - 1, 0);
      iUsecs = std::max(iUsecs / 3, 500);
    } else {
      critical_starvation_since_usec = 0;
      idle_decode_spin_count = std::min(idle_decode_spin_count + 1, 8);
      iUsecs = std::max(iUsecs / 2, 1000);
    }

    {
      const uint64_t nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
      if (was_in_critical_starvation && !has_critical_starvation) {
        was_in_critical_starvation = false;
        if (traceEnabled) {
          LOG->Warn("UNDERRUN_TRACE: decode_emergency_exit");
        }
      }

      if (traceEnabled &&
          (last_scheduler_stats_log_usec == 0 ||
           nowUsec - last_scheduler_stats_log_usec >=
               kDecodeSchedulerStatsLogPeriodUsec)) {
        last_scheduler_stats_log_usec = nowUsec;
        LOG->Info(
            "UNDERRUN_TRACE: decode_scheduler_stats loops=%" PRIu64
            " emergency_entries=%" PRIu64 " emergency_capped=%" PRIu64
            " low_watermark_cycles=%" PRIu64 " decode_stall_cycles=%" PRIu64
            " active=%d needs_decode=%d wrote_any=%d sleep_us=%d",
            scheduler_loops, emergency_entries, emergency_capped_recoveries,
            low_watermark_cycles, decode_stall_cycles, has_active_sound ? 1 : 0,
            still_needs_decode ? 1 : 0, wrote_any_data ? 1 : 0, iUsecs);
      }
    }
    usleep(iUsecs);
  }
}

/* Buffer a block of sound data for the given sound.  Return the number of
 * frames buffered, or a RageSoundReader return code. */
int RageSoundDriver::GetDataForSound(Sound& s) {
  sound_block* p[2];
  unsigned psize[2];
  s.m_Buffer.get_write_pointers(p, psize);

  /* If we have no open buffer slot, we have a buffer overflow. */
  if (psize[0] == 0 || p[0] == nullptr || s.m_pSound == nullptr) {
    return RageSoundReader::WOULD_BLOCK;
  }

  sound_block* pBlock = p[0];
  int size = ARRAYLEN(pBlock->m_Buffer) / channels;
  if (size <= 0) {
    return RageSoundReader::ERROR;
  }
  int iRet = s.m_pSound->GetDataToPlay(
      pBlock->m_Buffer, size, pBlock->m_iPosition, pBlock->m_FramesInBuffer);
  if (iRet > 0) {
    pBlock->m_BufferNext = pBlock->m_Buffer;
    s.m_Buffer.advance_write_pointer(1);
  }

  //	LOG->Trace( "incr fr wr %i (state %i) (%p)",
  //		(int) pBlock->m_FramesInBuffer, s.m_State, s.m_pSound );

  return iRet;
}

bool RageSoundDriver::RefillSoundBufferToTarget(
    Sound& s, unsigned readableTargetBlocks, const char* reason,
    int maxWouldBlockRetries, int retrySleepUsec, RefillTrace* trace) {
  const bool traceEnabled = IsUnderrunTraceEnabled();
  const unsigned readableBefore = s.m_Buffer.num_readable();
  const unsigned writableBefore = s.m_Buffer.num_writable();
  const unsigned maxReadableBlocks =
      s.m_Buffer.capacity() > 0 ? s.m_Buffer.capacity() - 1 : 0;
  const unsigned target =
      std::min(readableTargetBlocks, maxReadableBlocks);
  const uint64_t startUsec = RageTimer::GetTimeSinceStartMicroseconds();
  int writes = 0;
  int wouldBlocks = 0;
  int terminalRet = 0;
  bool wroteAnyData = false;

  while ((s.GetState() == Sound::PLAYING ||
          s.GetState() == Sound::BUFFERING) &&
         s.m_Buffer.num_readable() < target && s.m_Buffer.num_writable() > 0) {
    const int iWrote = GetDataForSound(s);
    if (iWrote == RageSoundReader::WOULD_BLOCK) {
      ++wouldBlocks;
      terminalRet = iWrote;
      if (maxWouldBlockRetries <= 0) {
        break;
      }
      --maxWouldBlockRetries;
      if (retrySleepUsec > 0) {
        usleep(retrySleepUsec);
      }
      continue;
    }

    if (iWrote < 0) {
      terminalRet = iWrote;
      s.SetState(Sound::STOPPING);
      break;
    }

    if (iWrote > 0) {
      ++writes;
      wroteAnyData = true;
      terminalRet = iWrote;
    } else {
      terminalRet = iWrote;
      break;
    }
  }

  if (trace != nullptr || traceEnabled) {
    const uint64_t nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
    const unsigned readableAfter = s.m_Buffer.num_readable();
    const unsigned writableAfter = s.m_Buffer.num_writable();
    const bool targetReached = readableAfter >= target;
    const bool shouldLog = wouldBlocks > 0 || !targetReached ||
                           readableBefore <= kDecodeLowWatermarkBlocks;

    const std::string loadedPath = s.GetDebugPath();
    if (trace != nullptr) {
      trace->path = loadedPath;
      trace->readableBefore = readableBefore;
      trace->readableAfter = readableAfter;
      trace->writableBefore = writableBefore;
      trace->writableAfter = writableAfter;
      trace->target = target;
      trace->elapsedUsec = nowUsec - startUsec;
      trace->writes = writes;
      trace->wouldBlocks = wouldBlocks;
      trace->terminalRet = terminalRet;
      trace->state = static_cast<int>(s.GetState());
      trace->targetReached = targetReached;
      trace->shouldLog = traceEnabled && shouldLog;
    }

    if (traceEnabled && strcmp(reason, "decode_thread") != 0 && shouldLog) {
      LOG->Info(
          "UNDERRUN_TRACE: refill reason=%s sound='%s' readable=%u->%u "
          "writable=%u->%u target=%u writes=%d would_block=%d "
          "target_reached=%d terminal_ret=%d elapsed_us=%" PRIu64 " state=%d",
          reason, loadedPath.c_str(), readableBefore, readableAfter,
          writableBefore, writableAfter, target, writes, wouldBlocks,
          targetReached ? 1 : 0, terminalRet, nowUsec - startUsec,
          static_cast<int>(s.GetState()));
    }
  }

  return wroteAnyData;
}

void RageSoundDriver::Update() {
  UpdateUnderrunScreenContext();

  m_Mutex.Lock();
  for (unsigned i = 0; i < ARRAYLEN(m_Sounds); ++i) {
    {
      Sound::QueuedPosMap p;
      while (m_Sounds[i].m_PosMapQueue.read(&p, 1)) {
        RageSoundBase* pSound = m_Sounds[i].m_pSound;
        if (pSound != nullptr) {
          pSound->CommitPlayingPosition(
              p.iStreamFrame, p.iHardwareFrame, p.iFrames);
        }
      }
    }

    switch (m_Sounds[i].GetState()) {
      case Sound::STOPPED:
        m_Sounds[i].Deallocate();
        m_Sounds[i].ClearDebugIdentity();
        m_Sounds[i].SetState(Sound::AVAILABLE);
        continue;
      case Sound::STOPPING:
        break;
      default:
        continue;
    }

    if (m_Sounds[i].m_Buffer.num_readable() != 0) {
      continue;
    }

    //		LOG->Trace("finishing sound %i", i);

    RageSoundBase* pFinishedSound = m_Sounds[i].m_pSound;
    if (pFinishedSound != nullptr) {
      pFinishedSound->SoundIsFinishedPlaying();
      m_Sounds[i].m_pSound = nullptr;
    }

    /* This sound is done.  Set it to HALTING, since the mixer thread might
     * be accessing it; it'll change it back to STOPPED once it's ready to
     * be used again. */
    m_Sounds[i].SetState(Sound::HALTING);
    //		LOG->Trace("set (#%i) %p from STOPPING to HALTING", i,
    // m_Sounds[i].m_pSound);
  }

  constexpr uint64_t iUsecs = 10000000;
  static uint64_t fNextUsecs = 0;
  if (RageTimer::GetTimeSinceStartMicroseconds() >= fNextUsecs) {
    /* Lockless: only Mix() can write to underruns. */
    int current_underruns = underruns;
    bool has_active_playback = false;
    for (unsigned i = 0; i < ARRAYLEN(m_Sounds); ++i) {
      const Sound::State state = m_Sounds[i].GetState();
      if (state == Sound::PLAYING || state == Sound::STOPPING ||
          state == Sound::BUFFERING) {
        has_active_playback = true;
        break;
      }
    }

    if (!has_active_playback) {
      // Ignore startup/shutdown underruns when nothing is actively playing.
      logged_underruns = current_underruns;
    } else if (current_underruns > logged_underruns) {
      if (IsUnderrunTraceEnabled()) {
        LOG->MapLog(
            "GenericMixingUnderruns", "Mixing underruns: %i",
            current_underruns - logged_underruns);
        LOG->Trace(
            "Mixing underruns: %i", current_underruns - logged_underruns);
      }
      logged_underruns = current_underruns;

      /* Don't log again for at least 10 seconds, or we'll burst output
       * and possibly cause more underruns. */
      fNextUsecs = RageTimer::GetTimeSinceStartMicroseconds() + iUsecs;
    }
  }

  m_Mutex.Unlock();
}

void RageSoundDriver::StartMixing(RageSoundBase* pSound) {
  if (pSound == nullptr) {
    if (LOG != nullptr) {
      LOG->Warn("RageSoundDriver::StartMixing: null sound");
    }
    return;
  }
  const bool traceEnabled = IsUnderrunTraceEnabled();
  /* Lock available m_Sounds[], and reserve a slot. */
  m_SoundListMutex.Lock();

  unsigned i;
  for (i = 0; i < ARRAYLEN(m_Sounds); ++i) {
    if (m_Sounds[i].GetState() == Sound::AVAILABLE) {
      break;
    }
  }
  if (i == ARRAYLEN(m_Sounds)) {
    m_SoundListMutex.Unlock();
    if (traceEnabled) {
      LOG->Warn("UNDERRUN_TRACE: start_mixing_no_available_slot");
    }
    return;
  }

  Sound& s = m_Sounds[i];
  s.SetState(Sound::BUFFERING);

  /* We've reserved our slot; we can safely unlock now.  Don't hold onto it
   * longer than needed, since prebuffering might take some time. */
  m_SoundListMutex.Unlock();

  s.m_pSound = pSound;
  std::string loadedPath = pSound->GetLoadedFilePath();
  if (loadedPath.empty()) {
    loadedPath = ssprintf("<empty-path:%p>", static_cast<void*>(pSound));
  }
  s.SetDebugIdentity(
      loadedPath, g_iSoundDebugSerial.fetch_add(1, std::memory_order_relaxed) + 1,
      RageTimer::GetTimeSinceStartMicroseconds());
  s.m_StartTime = pSound->GetStartTime();
  s.m_Buffer.clear();

  /* Initialize the sound buffer. */
  int BufferSize = frames_to_buffer;

  s.Allocate(BufferSize);

  //	LOG->Trace("StartMixing(%s) (%p)",
  // s.m_pSound->GetLoadedFilePath().c_str(), s.m_pSound );

  const bool useStrongPrebuffer = s.m_pSound->PrefersStrongPrebuffer();
  const unsigned prebufferTarget = useStrongPrebuffer
                                       ? kDecodeStartPrebufferTargetBlocks
                                       : kDecodeShortSoundPrebufferTargetBlocks;
  const unsigned strongStartMinimum =
      useStrongPrebuffer
          ? std::min(kDecodeStrongStartMinimumBlocks, prebufferTarget)
          : 0;
  const int wouldBlockRetries =
      useStrongPrebuffer ? kStartPrebufferWouldBlockRetries : 0;
  const int retrySleepUsec =
      useStrongPrebuffer ? kStartPrebufferRetrySleepUsec : 0;

  RefillSoundBufferToTarget(
      s, prebufferTarget, "start_mixing", wouldBlockRetries, retrySleepUsec);

  s.m_iDebugPrebufferTarget = prebufferTarget;
  s.m_iDebugPrebufferReadable = s.m_Buffer.num_readable();
  s.m_iDebugPrebufferWritable = s.m_Buffer.num_writable();
  s.m_bDebugStrongPrebuffer = useStrongPrebuffer;

  if (useStrongPrebuffer && s.GetState() == Sound::BUFFERING &&
      s.m_Buffer.num_readable() < strongStartMinimum &&
      s.m_Buffer.num_writable() > 0) {
    if (traceEnabled) {
      LOG->Warn(
          "UNDERRUN_TRACE: start_mixing_strong_prebuffer_wait sound='%s' "
          "slot=%u serial=%" PRIu64
          " readable_blocks=%u writable_blocks=%u target=%u "
          "minimum=%u retries=%d retry_sleep_us=%d",
          s.GetDebugPath(), i, s.m_iDebugSerial, s.m_Buffer.num_readable(),
          s.m_Buffer.num_writable(), prebufferTarget, strongStartMinimum,
          kStrongStartLastChanceWouldBlockRetries,
          kStartPrebufferRetrySleepUsec);
    }

    RefillSoundBufferToTarget(
        s, prebufferTarget, "start_mixing_strong_last_chance",
        kStrongStartLastChanceWouldBlockRetries, kStartPrebufferRetrySleepUsec);

    s.m_iDebugPrebufferReadable = s.m_Buffer.num_readable();
    s.m_iDebugPrebufferWritable = s.m_Buffer.num_writable();

    if (s.GetState() == Sound::BUFFERING &&
        s.m_Buffer.num_readable() < strongStartMinimum &&
        s.m_Buffer.num_writable() > 0) {
      if (traceEnabled) {
        LOG->Warn(
            "UNDERRUN_TRACE: start_mixing_strong_prebuffer_timeout sound='%s' "
            "slot=%u serial=%" PRIu64
            " readable_blocks=%u writable_blocks=%u target=%u minimum=%u",
            s.GetDebugPath(), i, s.m_iDebugSerial, s.m_Buffer.num_readable(),
            s.m_Buffer.num_writable(), prebufferTarget, strongStartMinimum);
      }
    }
  }

  if (s.GetState() == Sound::BUFFERING) {
    s.SetState(Sound::PLAYING);
  }

  if (traceEnabled) {
    LOG->Info(
        "UNDERRUN_TRACE: start_mixing_ready sound='%s' slot=%u serial=%" PRIu64
        " state=%d "
        "readable_blocks=%u writable_blocks=%u prebuffer_target=%u "
        "minimum_blocks=%u "
        "strong_prebuffer=%d retries=%d retry_sleep_us=%d",
        s.GetDebugPath(), i, s.m_iDebugSerial,
        static_cast<int>(s.GetState()),
        s.m_Buffer.num_readable(), s.m_Buffer.num_writable(), prebufferTarget,
        strongStartMinimum, useStrongPrebuffer ? 1 : 0, wouldBlockRetries,
        retrySleepUsec);
  }

  //	LOG->Trace("StartMixing: (#%i) finished prebuffering(%s) (%p)", i,
  // s.m_pSound->GetLoadedFilePath().c_str(), s.m_pSound );
}

void RageSoundDriver::StopMixing(RageSoundBase* pSound) {
  if (pSound == nullptr) {
    if (LOG != nullptr) {
      LOG->Trace("not stopping a null sound");
    }
    return;
  }
  /* Lock, to make sure the decoder thread isn't running on this sound while we
   * do this. */
  m_Mutex.Lock();

  /* Find the sound. */
  unsigned i;
  for (i = 0; i < ARRAYLEN(m_Sounds); ++i) {
    if (m_Sounds[i].GetState() != Sound::AVAILABLE &&
        m_Sounds[i].m_pSound == pSound) {
      break;
    }
  }
  if (i == ARRAYLEN(m_Sounds)) {
    m_Mutex.Unlock();
    if (LOG != nullptr) {
      LOG->Trace("not stopping a sound because it's not playing");
    }
    return;
  }

  /* If we're already in STOPPED, there's nothing to do. */
  if (m_Sounds[i].GetState() == Sound::STOPPED) {
    m_Mutex.Unlock();
    if (LOG != nullptr) {
      LOG->Trace("not stopping a sound because it's already in STOPPED");
    }
    return;
  }

  //	LOG->Trace("StopMixing: set %p (%s) to HALTING", m_Sounds[i].m_pSound,
  // m_Sounds[i].m_pSound->GetLoadedFilePath().c_str());

  /* Tell the mixing thread to flush the buffer.  We don't have to worry about
   * the decoding thread, since we've locked m_Mutex. */
  m_Sounds[i].SetState(Sound::HALTING);

  /* Invalidate the m_pSound pointer to guarantee we don't make any further
   * references to it.  Once this call returns, the sound may no longer exist.
   */
  m_Sounds[i].m_pSound = nullptr;
  //	LOG->Trace("end StopMixing");

  m_Mutex.Unlock();

  pSound->SoundIsFinishedPlaying();
}

bool RageSoundDriver::PauseMixing(RageSoundBase* pSound, bool bStop) {
  if (pSound == nullptr) {
    return false;
  }
  LockMut(m_Mutex);

  /* Find the sound. */
  unsigned i;
  for (i = 0; i < ARRAYLEN(m_Sounds); ++i) {
    if (m_Sounds[i].GetState() != Sound::AVAILABLE &&
        m_Sounds[i].m_pSound == pSound) {
      break;
    }
  }

  /* A sound can be paused in PLAYING or STOPPING.  (STOPPING means the sound
   * has been decoded to the end, and we're waiting for that data to finish, so
   * externally it looks and acts like PLAYING.) */
  if (i == ARRAYLEN(m_Sounds) ||
      (m_Sounds[i].GetState() != Sound::PLAYING &&
       m_Sounds[i].GetState() != Sound::STOPPING)) {
    if (LOG != nullptr) {
      LOG->Trace("not pausing a sound because it's not playing");
    }
    return false;
  }

  m_Sounds[i].m_bPaused = bStop;

  return true;
}

void RageSoundDriver::StartDecodeThread() {
  ASSERT(!m_DecodeThread.IsCreated());

  m_DecodeThread.Create(DecodeThread_start, this);
}

void RageSoundDriver::SetDecodeBufferSize(int iFrames) {
  ASSERT(!m_DecodeThread.IsCreated());

  frames_to_buffer = ClampDecodeBufferFrames(iFrames);
}

RageSoundDriver::RageSoundDriver()
    : m_Mutex("RageSoundDriver"), m_SoundListMutex("SoundListMutex") {
  m_bShutdownDecodeThread.store(false, std::memory_order_relaxed);
  m_pMixBuffer = new RageSoundMixBuffer;
  m_iMaxHardwareFrame = 0;
  m_iVMaxHardwareFrame = 0;
  SetDecodeBufferSize(4096);
  m_DecodeThread.SetName("Decode thread");
}

RageSoundDriver::~RageSoundDriver() {
  /* Signal the decoding thread to quit. */
  if (m_DecodeThread.IsCreated()) {
    m_bShutdownDecodeThread.store(true, std::memory_order_release);
    if (LOG != nullptr) {
      LOG->Trace("Shutting down decode thread ...");
      LOG->Flush();
    }
    m_DecodeThread.Wait();
    if (LOG != nullptr) {
      LOG->Trace("Decode thread shut down.");
      LOG->Flush();
    }
  }
  delete m_pMixBuffer;
  m_pMixBuffer = nullptr;
}

int64_t RageSoundDriver::ClampHardwareFrame(int64_t iHardwareFrame) const {
  /* It's sometimes possible for the hardware position to move backwards,
   * usually on underrun.  We can try to prevent this in each driver, but it's
   * an obscure error, so let's clamp the result here instead. */
  if (iHardwareFrame < m_iMaxHardwareFrame) {
    /* Clamp the output to one per second, so one underruns don't cascade due to
     * output spam. */
    static int64_t lastTime = 0;
    int64_t currentTime = RageTimer::GetTimeSinceStartMicroseconds();
    if (lastTime == 0 || (currentTime - lastTime) > 1000000) {
      if (LOG != nullptr) {
        LOG->Trace(
            "RageSoundDriver: driver returned a lesser position (%" PRId64
            " < %" PRId64 ")",
            iHardwareFrame, m_iMaxHardwareFrame);
      }
      lastTime = currentTime;
    }
    return m_iMaxHardwareFrame;
  }
  if (iHardwareFrame > m_iMaxHardwareFrame) {
    m_iMaxHardwareFrame = iHardwareFrame;
  }
  return m_iMaxHardwareFrame;
}

int64_t RageSoundDriver::GetHardwareFrame(
    RageTimer* pTimestamp = nullptr) const {
  if (pTimestamp == nullptr) {
    return ClampHardwareFrame(GetPosition());
  }

  /*
   * We may have unpredictable scheduling delays between updating the timestamp
   * and reading the sound position.  If we're preempted while doing this and
   * it may have caused the timestamp to not match the returned time, retry.
   *
   * As a failsafe, only allow a few attempts.  If this has to try more than
   * a few times, then probably we have thread contention that's causing more
   * severe performance problems, anyway.
   */
  int iTries = 3;
  int64_t iPositionFrames;
  uint64_t iStartTime;
  const uint64_t iThreshold = 2000ULL;

  do {
    iStartTime = RageTimer::GetTimeSinceStartMicroseconds();
    iPositionFrames = GetPosition();
    pTimestamp->Touch();
    uint64_t elapsedTime =
        RageTimer::GetTimeSinceStartMicroseconds() - iStartTime;
    if (elapsedTime <= iThreshold) {
      break;
    }
  } while (--iTries);

  if (iTries == 0) {
    static bool bLogged = false;
    if (!bLogged) {
      bLogged = true;
      if (LOG != nullptr) {
        LOG->Warn("RageSoundDriver::GetHardwareFrame: too many tries");
      }
    }
  }

  return ClampHardwareFrame(iPositionFrames);
}

/*
 * (c) 2002-2004 Glenn Maynard
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
