#import "LowLevelWindow_MacOSX.h"
#import "DisplaySpec.h"
#import "MacOSFramePacing.h"
#import "Preference.h"
#import "RageDisplay_OGL_Helpers.h"
#import "RageLog.h"
#import "RageThreads.h"
#import "RageTimer.h"
#import "RageUtil.h"
#import "arch/ArchHooks/ArchHooks.h"
#import "global.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <dlfcn.h>
#include <mutex>
#include <thread>

#import <Cocoa/Cocoa.h>
#import <CoreVideo/CoreVideo.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl.h>
#include <mach/mach_time.h>

// Bad header!
extern "C" {
#include <IOKit/graphics/IOGraphicsLib.h>
}

static const unsigned int g_iStyleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                         NSWindowStyleMaskMiniaturizable |
                                         NSWindowStyleMaskResizable;
static bool g_bResized;
static int g_iWidth;
static int g_iHeight;
static RageMutex g_ResizeLock("Window resize lock.");
constexpr float kMacOSFramePacingDisplayLinkTimeoutMs = 33.0f;
constexpr float kMacOSFramePacingDisplayLinkPresentLeadMs = 2.0f;
constexpr float kMacOSFramePacingDisplayLinkLateToleranceMs = 1.0f;
constexpr float kMacOSFramePacingDisplayLinkFinalSleepChunkMs = 1.0f;
constexpr float kMacOSFramePacingDisplayLinkFinalYieldMs = 2.0f;
constexpr float kMacOSFramePacingDisplayLinkFinalSpinMs = 1.0f;
static Preference<float> g_fPerfTraceSlowMacSwapBuffersMs(
    "PerfTraceSlowMacSwapBuffersMs", 20.0f);
static Preference<bool> g_bMacOSFramePacingOwnsSwapInterval(
    "MacOSFramePacingOwnsSwapInterval", true);
static Preference<bool> g_bMacOSFramePacingUseDisplayLink(
    "MacOSFramePacingUseDisplayLink", true);
static Preference<float> g_fMacOSFramePacingDisplayLinkTimeoutMs(
    "MacOSFramePacingDisplayLinkTimeoutMs", 33.0f);
static Preference<float> g_fMacOSFramePacingDisplayLinkPresentLeadMs(
    "MacOSFramePacingDisplayLinkPresentLeadMs", 2.0f);
static Preference<float> g_fMacOSFramePacingDisplayLinkLateToleranceMs(
    "MacOSFramePacingDisplayLinkLateToleranceMs", 1.0f);
static Preference<float> g_fMacOSFramePacingDisplayLinkFinalSleepChunkMs(
    "MacOSFramePacingDisplayLinkFinalSleepChunkMs", 1.0f);
static Preference<float> g_fMacOSFramePacingDisplayLinkFinalYieldMs(
    "MacOSFramePacingDisplayLinkFinalYieldMs", 2.0f);
static Preference<float> g_fMacOSFramePacingDisplayLinkFinalSpinMs(
    "MacOSFramePacingDisplayLinkFinalSpinMs", 1.0f);

extern Preference<float> g_fFramePacingTargetHz;

namespace {
float MacOSFramePacingDisplayLinkTimeoutMs() {
  return kMacOSFramePacingDisplayLinkTimeoutMs;
}

float MacOSFramePacingDisplayLinkPresentLeadMs() {
  return kMacOSFramePacingDisplayLinkPresentLeadMs;
}

float MacOSFramePacingDisplayLinkLateToleranceMs() {
  return kMacOSFramePacingDisplayLinkLateToleranceMs;
}

float MacOSFramePacingDisplayLinkFinalSleepChunkMs() {
  return kMacOSFramePacingDisplayLinkFinalSleepChunkMs;
}

float MacOSFramePacingDisplayLinkFinalYieldMs() {
  return kMacOSFramePacingDisplayLinkFinalYieldMs;
}

float MacOSFramePacingDisplayLinkFinalSpinMs() {
  return kMacOSFramePacingDisplayLinkFinalSpinMs;
}
}  // namespace

namespace {
uint64_t HostTimeToUsec(uint64_t hostTime) {
  static mach_timebase_info_data_t timebase = {0, 0};
  if (timebase.denom == 0) {
    mach_timebase_info(&timebase);
  }
  if (timebase.numer == 0 || timebase.denom == 0) {
    return 0;
  }

  const double usec =
      static_cast<double>(hostTime) * static_cast<double>(timebase.numer) /
      (1000.0 * static_cast<double>(timebase.denom));
  return static_cast<uint64_t>(std::max(0.0, usec));
}

uint64_t UsecToHostTime(uint64_t hostUsec) {
  static mach_timebase_info_data_t timebase = {0, 0};
  if (timebase.denom == 0) {
    mach_timebase_info(&timebase);
  }
  if (timebase.numer == 0 || timebase.denom == 0) {
    return 0;
  }

  const double ticks =
      static_cast<double>(hostUsec) * 1000.0 *
      static_cast<double>(timebase.denom) /
      static_cast<double>(timebase.numer);
  return static_cast<uint64_t>(
      std::max<long long>(1, std::llround(ticks)));
}

uint64_t RageStartHostUsec() {
  const int64_t hostNowUsec = ArchHooks::GetSystemTimeInMicroseconds();
  const uint64_t rageNowUsec = RageTimer::GetTimeSinceStartMicroseconds();
  if (hostNowUsec <= 0 ||
      static_cast<uint64_t>(hostNowUsec) <= rageNowUsec) {
    return 0;
  }
  return static_cast<uint64_t>(hostNowUsec) - rageNowUsec;
}

void WaitUntilRageUsec(uint64_t targetRageUsec) {
  const uint64_t nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
  if (targetRageUsec <= nowUsec) {
    return;
  }

  const uint64_t startHostUsec = RageStartHostUsec();
  if (startHostUsec == 0) {
    std::this_thread::sleep_for(
        std::chrono::microseconds(targetRageUsec - nowUsec));
    return;
  }

  const uint64_t targetHostTime =
      UsecToHostTime(startHostUsec + targetRageUsec);
  if (targetHostTime == 0) {
    std::this_thread::sleep_for(
        std::chrono::microseconds(targetRageUsec - nowUsec));
    return;
  }

  mach_wait_until(targetHostTime);
}

uint64_t ClampedDisplayLinkUsecPreference(
    float requestedMs, uint64_t fallbackUsec, uint64_t minimumUsec,
    uint64_t maximumUsec) {
  uint64_t requestedUsec = fallbackUsec;
  if (std::isfinite(requestedMs) && requestedMs >= 0.0f) {
    requestedUsec =
        static_cast<uint64_t>(std::llround(requestedMs * 1000.0f));
  }
  return std::clamp<uint64_t>(
      requestedUsec, minimumUsec, std::max(minimumUsec, maximumUsec));
}

struct DisplayLinkFinalWaitStats {
  uint64_t total_usec = 0;
  uint64_t sleep_usec = 0;
  uint64_t yield_usec = 0;
  uint64_t spin_usec = 0;
  uint64_t overshoot_usec = 0;
  int sleep_chunks = 0;
  int yields = 0;
};

uint64_t DisplayLinkFinalSleepChunkUsec(uint64_t intervalUsec) {
  return ClampedDisplayLinkUsecPreference(
      MacOSFramePacingDisplayLinkFinalSleepChunkMs(), 1000, 100,
      std::max<uint64_t>(100, std::min<uint64_t>(2000, intervalUsec / 2)));
}

uint64_t DisplayLinkFinalYieldWindowUsec(
    uint64_t periodUsec, uint64_t intervalUsec) {
  const uint64_t effectivePeriodUsec =
      periodUsec != 0 ? periodUsec : intervalUsec;
  return ClampedDisplayLinkUsecPreference(
      MacOSFramePacingDisplayLinkFinalYieldMs(), 2000, 250,
      std::max<uint64_t>(250, std::min<uint64_t>(4000,
                                                 effectivePeriodUsec / 2)));
}

uint64_t DisplayLinkFinalSpinWindowUsec(
    uint64_t periodUsec, uint64_t intervalUsec,
    uint64_t yieldWindowUsec) {
  const uint64_t effectivePeriodUsec =
      periodUsec != 0 ? periodUsec : intervalUsec;
  const uint64_t maxSpinUsec = std::min<uint64_t>(
      std::max<uint64_t>(100, yieldWindowUsec),
      std::max<uint64_t>(100, std::min<uint64_t>(1000,
                                                 effectivePeriodUsec / 8)));
  return ClampedDisplayLinkUsecPreference(
      MacOSFramePacingDisplayLinkFinalSpinMs(), 250, 0,
      maxSpinUsec);
}

DisplayLinkFinalWaitStats WaitUntilDisplayLinkPresentUsec(
    uint64_t targetUsec, uint64_t periodUsec, uint64_t intervalUsec) {
  DisplayLinkFinalWaitStats stats;
  const uint64_t startUsec = RageTimer::GetTimeSinceStartMicroseconds();
  uint64_t nowUsec = startUsec;
  if (targetUsec <= nowUsec) {
    return stats;
  }

  const uint64_t yieldWindowUsec =
      DisplayLinkFinalYieldWindowUsec(periodUsec, intervalUsec);
  const uint64_t spinWindowUsec =
      DisplayLinkFinalSpinWindowUsec(
          periodUsec, intervalUsec, yieldWindowUsec);
  const uint64_t sleepChunkUsec =
      DisplayLinkFinalSleepChunkUsec(intervalUsec);

  while (nowUsec < targetUsec) {
    const uint64_t remainingUsec = targetUsec - nowUsec;
    if (remainingUsec > yieldWindowUsec) {
      const uint64_t sleepLimitUsec = targetUsec - yieldWindowUsec;
      const uint64_t sleepTargetUsec =
          std::min<uint64_t>(nowUsec + sleepChunkUsec, sleepLimitUsec);
      const uint64_t sleepStartUsec = nowUsec;
      WaitUntilRageUsec(sleepTargetUsec);
      nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
      stats.sleep_usec += nowUsec - sleepStartUsec;
      ++stats.sleep_chunks;
      continue;
    }

    if (remainingUsec > spinWindowUsec) {
      const uint64_t yieldStartUsec = nowUsec;
      std::this_thread::yield();
      nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
      stats.yield_usec += nowUsec - yieldStartUsec;
      ++stats.yields;
      continue;
    }

    const uint64_t spinStartUsec = nowUsec;
    do {
      nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
    } while (nowUsec < targetUsec);
    stats.spin_usec += nowUsec - spinStartUsec;
    break;
  }

  stats.total_usec = nowUsec - startUsec;
  if (nowUsec > targetUsec) {
    stats.overshoot_usec = nowUsec - targetUsec;
  }
  return stats;
}

uint64_t HostTimeToRageUsec(uint64_t hostTime) {
  const uint64_t hostUsec = HostTimeToUsec(hostTime);
  const uint64_t startHostUsec = RageStartHostUsec();
  if (hostUsec == 0 || startHostUsec == 0 || hostUsec <= startHostUsec) {
    return RageTimer::GetTimeSinceStartMicroseconds();
  }
  return hostUsec - startHostUsec;
}

uint64_t PeriodFromTimestampUsec(const CVTimeStamp* outputTime) {
  if (outputTime == nullptr || outputTime->videoTimeScale <= 0 ||
      outputTime->videoRefreshPeriod <= 0) {
    return 0;
  }

  const double periodUsec =
      (static_cast<double>(outputTime->videoRefreshPeriod) * 1000000.0) /
      static_cast<double>(outputTime->videoTimeScale);
  if (!std::isfinite(periodUsec) || periodUsec <= 0.0) {
    return 0;
  }
  return static_cast<uint64_t>(std::llround(periodUsec));
}

uint64_t DisplayLinkTimeoutUsec(uint64_t intervalUsec) {
  const float timeoutMs = MacOSFramePacingDisplayLinkTimeoutMs();
  uint64_t requestedUsec = 33000;
  if (std::isfinite(timeoutMs) && timeoutMs > 0.0f) {
    requestedUsec =
        static_cast<uint64_t>(std::llround(timeoutMs * 1000.0f));
  }
  return std::clamp<uint64_t>(
      requestedUsec, std::max<uint64_t>(1000, intervalUsec / 2),
      std::max<uint64_t>(5000, intervalUsec * 4));
}

uint64_t DisplayLinkPresentLeadUsec(
    uint64_t periodUsec, uint64_t intervalUsec,
    uint64_t overrideUsec) {
  uint64_t requestedUsec = overrideUsec;
  if (requestedUsec == 0) {
    const float requestedMs =
        MacOSFramePacingDisplayLinkPresentLeadMs();
    requestedUsec = 2000;
    if (std::isfinite(requestedMs) && requestedMs >= 0.0f) {
      requestedUsec =
          static_cast<uint64_t>(std::llround(requestedMs * 1000.0f));
    }
  }

  const uint64_t effectivePeriodUsec =
      periodUsec != 0 ? periodUsec : intervalUsec;
  const uint64_t maxLeadUsec =
      overrideUsec != 0
          ? std::min<uint64_t>(
                8000, std::max<uint64_t>(
                          500, (effectivePeriodUsec * 3) / 4))
          : std::min<uint64_t>(
                5000,
                std::max<uint64_t>(500, effectivePeriodUsec / 2));
  return std::clamp<uint64_t>(requestedUsec, 0, maxLeadUsec);
}

uint64_t DisplayLinkPhaseToleranceUsec(
    uint64_t periodUsec, uint64_t intervalUsec) {
  const uint64_t effectivePeriodUsec =
      periodUsec != 0 ? periodUsec : intervalUsec;
  return std::clamp<uint64_t>(
      effectivePeriodUsec / 2, 500,
      std::max<uint64_t>(500, effectivePeriodUsec));
}

uint64_t DisplayLinkLateToleranceUsec(
    uint64_t periodUsec, uint64_t intervalUsec) {
  const float requestedMs =
      MacOSFramePacingDisplayLinkLateToleranceMs();
  uint64_t requestedUsec = 1000;
  if (std::isfinite(requestedMs) && requestedMs >= 0.0f) {
    requestedUsec =
        static_cast<uint64_t>(std::llround(requestedMs * 1000.0f));
  }

  const uint64_t effectivePeriodUsec =
      periodUsec != 0 ? periodUsec : intervalUsec;
  const uint64_t maxToleranceUsec =
      std::max<uint64_t>(500, std::min(effectivePeriodUsec / 2,
                                       std::max<uint64_t>(500,
                                                          intervalUsec / 4)));
  return std::clamp<uint64_t>(requestedUsec, 0, maxToleranceUsec);
}

uint64_t CappedDisplayLinkDesiredPresentUsec(
    uint64_t desiredPresentUsec, uint64_t latestPresentUsec,
    bool* capped) {
  if (capped != nullptr) {
    *capped = false;
  }
  if (desiredPresentUsec > latestPresentUsec) {
    if (capped != nullptr) {
      *capped = true;
    }
    return latestPresentUsec;
  }
  return desiredPresentUsec;
}

bool DisplayLinkUseOutputAlignedPresent(
    uint64_t periodUsec, uint64_t intervalUsec) {
  if (periodUsec == 0 || intervalUsec == 0) {
    return false;
  }

  const uint64_t toleranceUsec =
      std::max<uint64_t>(500, std::min<uint64_t>(periodUsec / 8, 1500));
  return intervalUsec + toleranceUsec >= periodUsec &&
         intervalUsec <= periodUsec + toleranceUsec;
}

uint64_t AbsDeltaUsec(uint64_t a, uint64_t b) {
  return a > b ? a - b : b - a;
}

struct DisplayLinkOutputPhase {
  uint64_t output_usec = 0;
  int64_t output_to_target_usec = 0;
  const char* source = "none";
  bool valid = false;
  bool phase_accepted = false;
};

void ConsiderDisplayLinkOutputCandidate(
    uint64_t candidateUsec, const char* source, uint64_t targetPresentUsec,
    uint64_t phaseToleranceUsec, DisplayLinkOutputPhase* best) {
  if (candidateUsec == 0 || best == nullptr) {
    return;
  }

  const uint64_t candidateDelta =
      AbsDeltaUsec(candidateUsec, targetPresentUsec);
  const uint64_t bestDelta =
      best->valid ? AbsDeltaUsec(best->output_usec, targetPresentUsec)
                  : UINT64_MAX;
  const bool candidateIsFutureOrTarget =
      candidateUsec >= targetPresentUsec;
  const bool bestIsFutureOrTarget =
      best->valid && best->output_usec >= targetPresentUsec;
  if (!best->valid || candidateDelta < bestDelta ||
      (candidateDelta == bestDelta &&
       candidateIsFutureOrTarget && !bestIsFutureOrTarget)) {
    best->output_usec = candidateUsec;
    best->output_to_target_usec =
        static_cast<int64_t>(candidateUsec) -
        static_cast<int64_t>(targetPresentUsec);
    best->source = source;
    best->valid = true;
    best->phase_accepted = candidateDelta <= phaseToleranceUsec;
  }
}

DisplayLinkOutputPhase SelectDisplayLinkOutputForTarget(
    uint64_t lastOutputUsec, uint64_t targetPresentUsec,
    uint64_t periodUsec, uint64_t phaseToleranceUsec) {
  DisplayLinkOutputPhase best;
  if (lastOutputUsec == 0) {
    return best;
  }

  if (periodUsec != 0 && lastOutputUsec > periodUsec) {
    ConsiderDisplayLinkOutputCandidate(
        lastOutputUsec - periodUsec, "previous", targetPresentUsec,
        phaseToleranceUsec, &best);
  }
  ConsiderDisplayLinkOutputCandidate(
      lastOutputUsec, "current", targetPresentUsec, phaseToleranceUsec,
      &best);
  if (periodUsec != 0 && lastOutputUsec <= UINT64_MAX - periodUsec) {
    ConsiderDisplayLinkOutputCandidate(
        lastOutputUsec + periodUsec, "next", targetPresentUsec,
        phaseToleranceUsec, &best);
  }
  return best;
}

class MacOSDisplayLinkPacer {
 public:
  ~MacOSDisplayLinkPacer() {
    std::lock_guard<std::mutex> lock(m_Mutex);
    if (m_DisplayLink != nullptr) {
      CVDisplayLinkStop(m_DisplayLink);
      CVDisplayLinkRelease(m_DisplayLink);
      m_DisplayLink = nullptr;
      m_Started = false;
    }
  }

  bool WaitForTarget(
      uint64_t targetPresentUsec, uint64_t intervalUsec, bool appHasFocus,
      uint64_t presentLeadOverrideUsec,
      MacOSFramePacingDisplayLinkStats* stats) {
    FillBaseStats(stats);
    if (!g_bMacOSFramePacingUseDisplayLink.Get()) {
      if (stats != nullptr) {
        stats->status = "disabled";
      }
      return false;
    }
    if (!appHasFocus) {
      if (stats != nullptr) {
        stats->status = "not_focused";
      }
      return false;
    }
    if (!EnsureStarted()) {
      if (stats != nullptr) {
        FillBaseStats(stats);
      }
      return false;
    }

    CGLContextObj currentContext = CGLGetCurrentContext();
    BindCurrentContext(currentContext);

    const uint64_t startUsec = RageTimer::GetTimeSinceStartMicroseconds();
    const uint64_t timeoutUsec = DisplayLinkTimeoutUsec(intervalUsec);
    const uint64_t timeoutDeadlineUsec =
        startUsec + std::max<uint64_t>(timeoutUsec, intervalUsec / 2);

    std::unique_lock<std::mutex> lock(m_Mutex);
    const uint64_t startTick = m_TickCount;
    const uint64_t initialPeriodUsec =
        m_LastPeriodUsec != 0 ? m_LastPeriodUsec : intervalUsec;
    const uint64_t initialPresentLeadUsec =
        DisplayLinkPresentLeadUsec(
            initialPeriodUsec, intervalUsec, presentLeadOverrideUsec);
    const uint64_t initialLateToleranceUsec =
        DisplayLinkLateToleranceUsec(initialPeriodUsec, intervalUsec);
    const bool initialOutputAlignedPresent =
        DisplayLinkUseOutputAlignedPresent(initialPeriodUsec, intervalUsec);
    const uint64_t latestAllowedUsec =
        (targetPresentUsec > initialPresentLeadUsec
             ? targetPresentUsec - initialPresentLeadUsec
             : targetPresentUsec) +
        initialLateToleranceUsec;
    bool timedOut = false;
    const char* status = "ok";
    for (;;) {
      const bool hasFreshTick = m_TickCount > startTick;
      const uint64_t currentPeriodUsec =
          m_LastPeriodUsec != 0 ? m_LastPeriodUsec : intervalUsec;
      const uint64_t phaseToleranceUsec =
          DisplayLinkPhaseToleranceUsec(currentPeriodUsec, intervalUsec);
      const bool outputAlignedPresent =
          DisplayLinkUseOutputAlignedPresent(currentPeriodUsec, intervalUsec);
      const DisplayLinkOutputPhase outputPhase =
          SelectDisplayLinkOutputForTarget(
              m_LastOutputRageUsec, targetPresentUsec,
              currentPeriodUsec, phaseToleranceUsec);

      if (outputAlignedPresent && outputPhase.phase_accepted) {
        status = "output_aligned";
        break;
      }
      if (hasFreshTick && outputPhase.phase_accepted) {
        break;
      }

      const uint64_t nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
      if (!initialOutputAlignedPresent && nowUsec >= latestAllowedUsec) {
        status = "target_cap";
        break;
      }
      if (nowUsec >= timeoutDeadlineUsec) {
        timedOut = true;
        status = "timeout";
        break;
      }

      const uint64_t effectiveDeadlineUsec =
          initialOutputAlignedPresent
              ? timeoutDeadlineUsec
              : std::min<uint64_t>(timeoutDeadlineUsec,
                                   latestAllowedUsec);
      const uint64_t waitUsec =
          std::min<uint64_t>(effectiveDeadlineUsec - nowUsec, 1000);
      m_Cond.wait_for(lock, std::chrono::microseconds(waitUsec));
    }

    const uint64_t tickCount = m_TickCount;
    const uint64_t ticksDuringWait = tickCount - startTick;
    const uint64_t lastOutputUsec = m_LastOutputRageUsec;
    const uint64_t periodUsec =
        m_LastPeriodUsec != 0 ? m_LastPeriodUsec : intervalUsec;
    lock.unlock();

    const uint64_t presentLeadUsec =
        DisplayLinkPresentLeadUsec(
            periodUsec, intervalUsec, presentLeadOverrideUsec);
    const uint64_t phaseToleranceUsec =
        DisplayLinkPhaseToleranceUsec(periodUsec, intervalUsec);
    const uint64_t lateToleranceUsec =
        DisplayLinkLateToleranceUsec(periodUsec, intervalUsec);
    const uint64_t latestPresentUsec =
        (targetPresentUsec > presentLeadUsec
             ? targetPresentUsec - presentLeadUsec
             : targetPresentUsec) +
        lateToleranceUsec;
    const DisplayLinkOutputPhase outputPhase =
        SelectDisplayLinkOutputForTarget(
            lastOutputUsec, targetPresentUsec, periodUsec,
            phaseToleranceUsec);
    const bool outputAlignedPresent =
        DisplayLinkUseOutputAlignedPresent(periodUsec, intervalUsec) &&
        outputPhase.phase_accepted;
    const bool selectedOutputPhaseAccepted =
        outputPhase.phase_accepted;
    uint64_t desiredPresentUsec =
        selectedOutputPhaseAccepted && outputPhase.output_usec > presentLeadUsec
            ? outputPhase.output_usec - presentLeadUsec
            : targetPresentUsec > presentLeadUsec
                  ? targetPresentUsec - presentLeadUsec
                  : targetPresentUsec;
    bool finalWaitCapped = false;
    desiredPresentUsec = CappedDisplayLinkDesiredPresentUsec(
        desiredPresentUsec, latestPresentUsec, &finalWaitCapped);
    if (!timedOut && outputAlignedPresent) {
      status = "output_aligned";
    } else if (!timedOut && !selectedOutputPhaseAccepted &&
        std::strcmp(status, "target_cap") != 0) {
      status = "phase_miss";
    }
    const uint64_t finalWaitStartUsec =
        RageTimer::GetTimeSinceStartMicroseconds();
    DisplayLinkFinalWaitStats finalWaitStats;
    if (!timedOut &&
        desiredPresentUsec > finalWaitStartUsec) {
      finalWaitStats = WaitUntilDisplayLinkPresentUsec(
          desiredPresentUsec, periodUsec, intervalUsec);
    }

    const uint64_t afterUsec = RageTimer::GetTimeSinceStartMicroseconds();
    if (stats != nullptr) {
      FillBaseStats(stats);
      stats->waited = true;
      stats->timed_out = timedOut;
      stats->tick_count = tickCount;
      stats->ticks_during_wait = ticksDuringWait;
      stats->period_usec = periodUsec;
      stats->wait_requested_usec =
          desiredPresentUsec > startUsec ? desiredPresentUsec - startUsec : 0;
      stats->wait_actual_usec = afterUsec - startUsec;
      stats->final_wait_usec = finalWaitStats.total_usec;
      stats->final_wait_sleep_usec = finalWaitStats.sleep_usec;
      stats->final_wait_yield_usec = finalWaitStats.yield_usec;
      stats->final_wait_spin_usec = finalWaitStats.spin_usec;
      stats->final_wait_overshoot_usec = finalWaitStats.overshoot_usec;
      stats->final_wait_sleep_chunks = finalWaitStats.sleep_chunks;
      stats->final_wait_yields = finalWaitStats.yields;
      stats->present_lead_usec = presentLeadUsec;
      stats->late_tolerance_usec = lateToleranceUsec;
      stats->phase_tolerance_usec = phaseToleranceUsec;
      stats->target_present_usec = targetPresentUsec;
      stats->desired_present_usec = desiredPresentUsec;
      stats->latest_present_usec = latestPresentUsec;
      stats->last_output_usec = lastOutputUsec;
      stats->selected_output_usec = outputPhase.output_usec;
      stats->output_to_target_usec =
          lastOutputUsec == 0
              ? 0
              : static_cast<int64_t>(lastOutputUsec) -
                    static_cast<int64_t>(targetPresentUsec);
      stats->selected_output_to_target_usec =
          outputPhase.valid ? outputPhase.output_to_target_usec : 0;
      stats->output_late_usec =
          outputPhase.output_usec == 0
              ? 0
              : static_cast<int64_t>(afterUsec) -
                    static_cast<int64_t>(outputPhase.output_usec);
      stats->final_wait_capped = finalWaitCapped;
      stats->output_phase_accepted = selectedOutputPhaseAccepted;
      stats->output_aligned_present = outputAlignedPresent;
      stats->selected_output_source = outputPhase.source;
      stats->status = status;
    }
    return true;
  }

  void Reset(const char* reason) {
    std::lock_guard<std::mutex> lock(m_Mutex);
    m_TickCount = 0;
    m_LastOutputRageUsec = 0;
    LOG->Trace(
        "MACOS_DISPLAY_LINK: reset reason=%s started=%d failed=%d",
        reason != nullptr ? reason : "manual", m_Started ? 1 : 0,
        m_Failed ? 1 : 0);
  }

  bool Enabled() const { return g_bMacOSFramePacingUseDisplayLink.Get(); }

 private:
  static CVReturn Callback(
      CVDisplayLinkRef displayLink, const CVTimeStamp* now,
      const CVTimeStamp* outputTime, CVOptionFlags flagsIn,
      CVOptionFlags* flagsOut, void* displayLinkContext) {
    (void)displayLink;
    (void)now;
    (void)flagsIn;
    (void)flagsOut;
    auto* pacer =
        static_cast<MacOSDisplayLinkPacer*>(displayLinkContext);
    pacer->OnTick(outputTime);
    return kCVReturnSuccess;
  }

  void OnTick(const CVTimeStamp* outputTime) {
    uint64_t outputRageUsec = RageTimer::GetTimeSinceStartMicroseconds();
    uint64_t periodUsec = 0;
    if (outputTime != nullptr && outputTime->hostTime != 0) {
      outputRageUsec = HostTimeToRageUsec(outputTime->hostTime);
      periodUsec = PeriodFromTimestampUsec(outputTime);
    }

    std::lock_guard<std::mutex> lock(m_Mutex);
    ++m_TickCount;
    m_LastOutputRageUsec = outputRageUsec;
    if (periodUsec != 0) {
      m_LastPeriodUsec = periodUsec;
    }
    m_Cond.notify_all();
  }

  bool EnsureStarted() {
    std::lock_guard<std::mutex> lock(m_Mutex);
    if (m_Started) {
      return true;
    }
    if (m_Failed) {
      return false;
    }

    CVDisplayLinkRef displayLink = nullptr;
    CVReturn result = CVDisplayLinkCreateWithActiveCGDisplays(&displayLink);
    if (result != kCVReturnSuccess || displayLink == nullptr) {
      m_Failed = true;
      LOG->Warn(
          "MACOS_DISPLAY_LINK: create_failed result=%d",
          static_cast<int>(result));
      return false;
    }

    result = CVDisplayLinkSetOutputCallback(
        displayLink, &MacOSDisplayLinkPacer::Callback, this);
    if (result != kCVReturnSuccess) {
      CVDisplayLinkRelease(displayLink);
      m_Failed = true;
      LOG->Warn(
          "MACOS_DISPLAY_LINK: callback_failed result=%d",
          static_cast<int>(result));
      return false;
    }

    BindCurrentContextLocked(displayLink, CGLGetCurrentContext());

    result = CVDisplayLinkStart(displayLink);
    if (result != kCVReturnSuccess) {
      CVDisplayLinkRelease(displayLink);
      m_Failed = true;
      LOG->Warn(
          "MACOS_DISPLAY_LINK: start_failed result=%d",
          static_cast<int>(result));
      return false;
    }

    m_DisplayLink = displayLink;
    m_Started = true;
    double actualPeriod = CVDisplayLinkGetActualOutputVideoRefreshPeriod(
        m_DisplayLink);
    uint64_t actualPeriodUsec = 0;
    if (std::isfinite(actualPeriod) && actualPeriod > 0.0) {
      actualPeriodUsec =
          static_cast<uint64_t>(std::llround(actualPeriod * 1000000.0));
      m_LastPeriodUsec = actualPeriodUsec;
    }
    LOG->Trace(
        "MACOS_DISPLAY_LINK: started actual_period_us=%llu "
        "current_context=%p bind_result=%d",
        static_cast<unsigned long long>(actualPeriodUsec),
        m_BoundContext, static_cast<int>(m_LastBindResult));
    return true;
  }

  void BindCurrentContext(CGLContextObj currentContext) {
    std::lock_guard<std::mutex> lock(m_Mutex);
    if (!m_Started || m_DisplayLink == nullptr ||
        currentContext == m_BoundContext) {
      return;
    }
    BindCurrentContextLocked(m_DisplayLink, currentContext);
  }

  void BindCurrentContextLocked(
      CVDisplayLinkRef displayLink, CGLContextObj currentContext) {
    if (displayLink == nullptr || currentContext == nullptr) {
      return;
    }

    CGLPixelFormatObj pixelFormat = CGLGetPixelFormat(currentContext);
    if (pixelFormat == nullptr) {
      return;
    }

    m_LastBindResult = CVDisplayLinkSetCurrentCGDisplayFromOpenGLContext(
        displayLink, currentContext, pixelFormat);
    m_BoundContext = currentContext;
    LOG->Trace(
        "MACOS_DISPLAY_LINK: bound_context context=%p result=%d",
        currentContext, static_cast<int>(m_LastBindResult));
  }

  void FillBaseStats(MacOSFramePacingDisplayLinkStats* stats) const {
    if (stats == nullptr) {
      return;
    }
    stats->available = true;
    stats->enabled = g_bMacOSFramePacingUseDisplayLink.Get();
    stats->started = m_Started;
    stats->status =
        !stats->enabled ? "disabled" : m_Failed ? "failed" : "available";
  }

  std::mutex m_Mutex;
  std::condition_variable m_Cond;
  CVDisplayLinkRef m_DisplayLink = nullptr;
  CGLContextObj m_BoundContext = nullptr;
  CVReturn m_LastBindResult = kCVReturnSuccess;
  uint64_t m_TickCount = 0;
  uint64_t m_LastOutputRageUsec = 0;
  uint64_t m_LastPeriodUsec = 0;
  bool m_Started = false;
  bool m_Failed = false;
};

MacOSDisplayLinkPacer& DisplayLinkPacer() {
  static MacOSDisplayLinkPacer pacer;
  return pacer;
}
}  // namespace

bool MacOSFramePacingDisplayLinkEnabled() {
  return DisplayLinkPacer().Enabled();
}

bool MacOSFramePacingWaitForDisplayLink(
    uint64_t targetPresentUsec, uint64_t intervalUsec, bool appHasFocus,
    uint64_t presentLeadOverrideUsec,
    MacOSFramePacingDisplayLinkStats* stats) {
  return DisplayLinkPacer().WaitForTarget(
      targetPresentUsec, intervalUsec, appHasFocus,
      presentLeadOverrideUsec, stats);
}

void MacOSFramePacingResetDisplayLink(const char* reason) {
  DisplayLinkPacer().Reset(reason);
}

static float ExpectedFrameMsForRate(int rate) {
  return rate > 0 ? 1000.0f / static_cast<float>(rate) : 0.0f;
}

static int MissedIntervalsForElapsedMs(float elapsedMs, float expectedMs) {
  if (expectedMs <= 0.0f || elapsedMs <= 0.0f) {
    return 0;
  }
  return std::max(0, static_cast<int>(std::ceil(elapsedMs / expectedMs)) - 1);
}

static bool MacOSFramePacingOwnsSwapInterval() {
  const float targetHz = g_fFramePacingTargetHz.Get();
  return g_bMacOSFramePacingOwnsSwapInterval.Get() &&
         std::isfinite(targetHz) && targetHz > 0.0f;
}

static GLint DesiredMacOSSwapInterval(const VideoModeParams& params) {
  if (!params.vsync) {
    return 0;
  }
  return MacOSFramePacingOwnsSwapInterval() ? 0 : 1;
}

static GLint CurrentMacOSSwapInterval(NSOpenGLContext* context) {
  if (context == nil) {
    return -1;
  }

  GLint swap = -1;
  if (CGLGetParameter([context CGLContextObj], kCGLCPSwapInterval, &swap) !=
      kCGLNoError) {
    return -1;
  }
  return swap;
}

static GLint ApplyMacOSSwapInterval(
    NSOpenGLContext* context, const VideoModeParams& params, bool windowed) {
  const GLint previousSwap = CurrentMacOSSwapInterval(context);
  GLint desiredSwap = DesiredMacOSSwapInterval(params);
  const CGLError error =
      CGLSetParameter([context CGLContextObj], kCGLCPSwapInterval, &desiredSwap);
  const GLint actualSwap = CurrentMacOSSwapInterval(context);
  LOG->Trace(
      "MacOS swap interval configured: requested_vsync=%d "
      "desired_swap_interval=%d actual_swap_interval=%d "
      "previous_swap_interval=%d frame_pacing_owns_swap=%d "
      "frame_pacing_target_hz=%.3f windowed=%d error=%d",
      params.vsync ? 1 : 0, desiredSwap, actualSwap, previousSwap,
      MacOSFramePacingOwnsSwapInterval() ? 1 : 0,
      g_fFramePacingTargetHz.Get(), windowed ? 1 : 0,
      static_cast<int>(error));
  return actualSwap;
}

// Simple helper class
class AutoreleasePool {
  AutoreleasePool(const AutoreleasePool&);
  AutoreleasePool& operator=(const AutoreleasePool&);
  NSAutoreleasePool* m_Pool;

 public:
  AutoreleasePool() { m_Pool = [[NSAutoreleasePool alloc] init]; }
  ~AutoreleasePool() { [m_Pool release]; }
};

#define POOL AutoreleasePool SM_UNIQUE_NAME(pool)

// Window delegate class
@interface SMWindowDelegate : NSObject {
 @public
  NSWindow* m_Window;
}
- (void)windowDidBecomeKey:(NSNotification*)aNotification;
- (void)windowDidResignKey:(NSNotification*)aNotification;
- (void)windowWillClose:(NSNotification*)aNotification;
- (void)windowDidResize:(NSNotification*)aNotification;
// XXX maybe use whichever screen contains the window? Hard for me to test though.
//- (void) windowDidChangeScreen:(NSNotification *)aNotification;

// Helper methods to perform actions on the main thread.
- (void)setupWindow;
- (void)closeWindow;
- (void)setParams:(NSValue*)params;
@end

@implementation SMWindowDelegate

- (void)windowDidBecomeKey:(NSNotification*)aNotification {
  HOOKS->SetHasFocus(true);
}

- (void)windowDidResignKey:(NSNotification*)aNotification {
  HOOKS->SetHasFocus(false);
}

- (void)windowWillClose:(NSNotification*)aNotification {
  ArchHooks::SetUserQuit();
}

- (void)windowDidResize:(NSNotification*)aNotification {
  id window = [aNotification object];
  NSSize size = [NSWindow contentRectForFrameRect:[window frame] styleMask:g_iStyleMask].size;

  LockMut(g_ResizeLock);
  g_bResized = true;
  g_iWidth = int(size.width);
  g_iHeight = int(size.height);
}

- (void)setupWindow {
  NSRect rect = NSMakeRect(0, 0, 0, 0);
  m_Window = [[NSWindow alloc] initWithContentRect:rect
                                         styleMask:g_iStyleMask
                                           backing:NSBackingStoreBuffered
                                             defer:YES];

  [m_Window setExcludedFromWindowsMenu:YES];
  [m_Window setReleasedWhenClosed:NO];
  [m_Window setDelegate:static_cast<id<NSWindowDelegate> >(self)];
}

- (void)closeWindow {
  [m_Window setDelegate:nil];
  [m_Window close];
  [m_Window release];
}

- (void)setParams:(NSValue*)params {
  const VideoModeParams& p = *(const VideoModeParams*)[params pointerValue];
  NSRect contentRect = {{0, 0}, {static_cast<CGFloat>(p.width), static_cast<CGFloat>(p.height)}};

  [m_Window setContentSize:contentRect.size];
  [m_Window setTitle:[NSString stringWithUTF8String:p.sWindowTitle.c_str()]];
  [m_Window center];
  [m_Window makeKeyAndOrderFront:nil];
}
@end

enum GLContextType { WINDOWED, FULL_SCREEN, PIXEL_BUFFER };

static NSOpenGLContext* CreateOGLContext(
    GLContextType type, int iColorSize, int iAlphaSize, int iDepthSize, NSOpenGLContext* share,
    bool& bShared) {
  NSOpenGLPixelFormatAttribute attrs[] = {
      NSOpenGLPFANoRecovery,  // so we can share with the full screen context
      NSOpenGLPFAAccelerated, NSOpenGLPFAMinimumPolicy, NSOpenGLPFAColorSize,
      NSOpenGLPixelFormatAttribute(iColorSize), NSOpenGLPFAAlphaSize,
      NSOpenGLPixelFormatAttribute(iAlphaSize), NSOpenGLPFADepthSize,
      NSOpenGLPixelFormatAttribute(iDepthSize),
      /*
                      NSOpenGLPFAMultisample,
                      NSOpenGLPFASampleBuffers, (NSOpenGLPixelFormatAttribute)1,
                      NSOpenGLPFASamples, (NSOpenGLPixelFormatAttribute)4,
      */
      NSOpenGLPixelFormatAttribute(0),  // 9
      NSOpenGLPixelFormatAttribute(0),  // 10
      NSOpenGLPixelFormatAttribute(0),  // 11
      NSOpenGLPixelFormatAttribute(0),  // 12
      NSOpenGLPixelFormatAttribute(0)   // Must be at the end.
  };
  const int n = 9;  // The first noncommon index.

  switch (type) {
    case WINDOWED:
      attrs[n + 0] = NSOpenGLPFAWindow;
      attrs[n + 1] = NSOpenGLPFADoubleBuffer;
      break;
    case FULL_SCREEN:
      attrs[n + 0] = NSOpenGLPFAFullScreen;
      attrs[n + 1] = NSOpenGLPFADoubleBuffer;
      attrs[n + 2] = NSOpenGLPFAScreenMask;
      attrs[n + 3] =
          NSOpenGLPixelFormatAttribute(CGDisplayIDToOpenGLDisplayMask(kCGDirectMainDisplay));
      break;
    case PIXEL_BUFFER:
      attrs[n + 0] = NSOpenGLPFAOffScreen;
      attrs[n + 1] = NSOpenGLPFAPixelBuffer;
      break;
  }

  NSOpenGLPixelFormat* pixelFormat = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];

  if (!pixelFormat) {
    return nil;
  }

  NSOpenGLContext* context = [[NSOpenGLContext alloc] initWithFormat:pixelFormat
                                                        shareContext:share];

  bShared = share && context;
  if (!context) {
    context = [[NSOpenGLContext alloc] initWithFormat:pixelFormat shareContext:nil];
  }

  [pixelFormat release];

  return context;
}

class RenderTarget_MacOSX : public RenderTarget {
 public:
  RenderTarget_MacOSX(id shareContext);
  ~RenderTarget_MacOSX();
  void Create(const RenderTargetParam& param, int& iTextureWidthOut, int& iTextureHeightOut);
  uintptr_t GetTexture() const { return static_cast<uintptr_t>(m_iTexHandle); }
  void StartRenderingTo();
  void FinishRenderingTo();

 private:
  NSOpenGLContext *m_ShareContext, *m_OldContext, *m_PBufferContext;
  GLuint m_iTexHandle;
  int m_iWidth, m_iHeight;
};

RenderTarget_MacOSX::RenderTarget_MacOSX(id shareContext) {
  m_ShareContext = shareContext;
  m_OldContext = nil;
  m_PBufferContext = nil;
  m_iTexHandle = 0;
  m_iWidth = 0;
  m_iHeight = 0;
}

RenderTarget_MacOSX::~RenderTarget_MacOSX() {
  POOL;
  [m_PBufferContext release];
  if (m_iTexHandle) {
    glDeleteTextures(1, &m_iTexHandle);
  }
}

void RenderTarget_MacOSX::Create(
    const RenderTargetParam& param, int& iTextureWidthOut, int& iTextureHeightOut) {
  POOL;
  m_iWidth = param.iWidth;
  m_iHeight = param.iHeight;

  // PBuffer needs to be a power of 2.
  int iTextureWidth = power_of_two(param.iWidth);
  int iTextureHeight = power_of_two(param.iHeight);

  // Create the PBuffer.
  unsigned long format = param.bWithAlpha ? GL_RGBA : GL_RGB;
  NSOpenGLPixelBuffer* PBuffer = [[NSOpenGLPixelBuffer alloc] initWithTextureTarget:GL_TEXTURE_2D
                                                              textureInternalFormat:format
                                                              textureMaxMipMapLevel:0  // No idea.
                                                                         pixelsWide:iTextureWidth
                                                                         pixelsHigh:iTextureHeight];
  DEBUG_ASSERT(PBuffer);

  // Create an OGL context.
  bool bShared = false;
  m_PBufferContext = CreateOGLContext(
      PIXEL_BUFFER, 24, param.bWithAlpha ? 8 : 0, param.bWithDepthBuffer ? 16 : 0, m_ShareContext,
      bShared);
  DEBUG_ASSERT(m_PBufferContext);
  DEBUG_ASSERT(bShared);
  [m_PBufferContext setPixelBuffer:PBuffer
                       cubeMapFace:0
                       mipMapLevel:0
              currentVirtualScreen:[m_ShareContext currentVirtualScreen]];
  [PBuffer release];  // XXX: Hopefully this is retained by the PBufferContext.

  glGenTextures(1, &m_iTexHandle);
  glBindTexture(GL_TEXTURE_2D, m_iTexHandle);

  while (glGetError() != GL_NO_ERROR);

  iTextureWidthOut = iTextureWidth;
  iTextureHeightOut = iTextureHeight;

  glTexImage2D(
      GL_TEXTURE_2D, 0, param.bWithAlpha ? GL_RGBA8 : GL_RGB8, iTextureWidth, iTextureHeight, 0,
      param.bWithAlpha ? GL_RGBA : GL_RGB, GL_UNSIGNED_BYTE, nil);
  GLenum error = glGetError();
  ASSERT_M(error == GL_NO_ERROR, RageDisplay_Legacy_Helpers::GLToString(error));

  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}

void RenderTarget_MacOSX::StartRenderingTo() {
  DEBUG_ASSERT(!m_OldContext);
  m_OldContext = [NSOpenGLContext currentContext];
  [m_PBufferContext makeCurrentContext];
  glViewport(0, 0, m_iWidth, m_iHeight);
}

void RenderTarget_MacOSX::FinishRenderingTo() {
  DEBUG_ASSERT(m_OldContext);
  glBindTexture(GL_TEXTURE_2D, m_iTexHandle);

  while (glGetError() != GL_NO_ERROR);

  glCopyTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 0, 0, m_iWidth, m_iHeight);

  GLenum error = glGetError();
  ASSERT_M(error == GL_NO_ERROR, RageDisplay_Legacy_Helpers::GLToString(error));

  glBindTexture(GL_TEXTURE_2D, 0);

  [m_OldContext makeCurrentContext];
  m_OldContext = nil;
}

LowLevelWindow_MacOSX::LowLevelWindow_MacOSX()
    : m_Context(nil), m_BGContext(nil), m_CurrentDisplayMode(nil), m_DisplayID(0) {
  POOL;
  m_WindowDelegate = [[SMWindowDelegate alloc] init];
  [m_WindowDelegate performSelectorOnMainThread:@selector(setupWindow)
                                     withObject:nil
                                  waitUntilDone:YES];

  m_CurrentParams.windowed = true;  // We are essentially windowed to begin with.
  SetActualParamsFromMode(CGDisplayCurrentMode(kCGDirectMainDisplay));
  dispatch_sync(dispatch_get_main_queue(), ^{
    HOOKS->SetHasFocus([NSApp isActive]);
    ;
  });
}

LowLevelWindow_MacOSX::~LowLevelWindow_MacOSX() {
  POOL;
  ShutDownFullScreen();

  [m_Context clearDrawable];
  [m_Context release];
  [m_BGContext clearDrawable];
  [m_BGContext release];
  [m_WindowDelegate performSelectorOnMainThread:@selector(closeWindow)
                                     withObject:nil
                                  waitUntilDone:YES];
  [m_WindowDelegate release];
}

void* LowLevelWindow_MacOSX::GetProcAddress(std::string s) {
  // dlsym returns NULL if symbol not found
  static void* glHandle = nullptr;
  if (!glHandle) {
    glHandle =
        dlopen("/System/Library/Frameworks/OpenGL.framework/Versions/Current/OpenGL", RTLD_LAZY);
  }
  return dlsym(glHandle, s.c_str());
}

std::string LowLevelWindow_MacOSX::TryVideoMode(const VideoModeParams& p, bool& newDeviceOut) {
  // Always set these params.
  m_CurrentParams.bSmoothLines = p.bSmoothLines;
  m_CurrentParams.bTrilinearFiltering = p.bTrilinearFiltering;
  m_CurrentParams.bAnisotropicFiltering = p.bAnisotropicFiltering;
  m_CurrentParams.interlaced = p.interlaced;
  m_CurrentParams.PAL = p.PAL;
  m_CurrentParams.fDisplayAspectRatio = p.fDisplayAspectRatio;

#define X(x) p.x != m_CurrentParams.x
  const bool bRebuildContext = X(bpp) || X(windowed) || !m_Context;
  const bool bChangeMode = X(width) || X(height) || X(rate) || bRebuildContext;
#undef X
  const GLint desiredSwapInterval = DesiredMacOSSwapInterval(p);
  const GLint currentSwapInterval = CurrentMacOSSwapInterval(m_Context);
  const bool bChangeVsync =
      bRebuildContext || currentSwapInterval != desiredSwapInterval;

  if (!bChangeMode && !bChangeVsync) {
    return std::string();
  }

  POOL;
  newDeviceOut = false;

  ASSERT(p.bpp == 16 || p.bpp == 32);

  // If we don't have focus, we cannot be full screen.
  if (p.windowed || !HOOKS->AppHasFocus()) {
    if (bRebuildContext) {
      bool bShared;
      NSOpenGLContext* newContext = CreateOGLContext(
          WINDOWED, p.bpp == 16 ? 16 : 24, p.bpp == 16 ? 1 : 8, 16, m_Context, bShared);

      if (!newContext) {
        return "Failed to create OGL context.";
      }
      ShutDownFullScreen();
      [m_Context release];
      m_Context = newContext;
      newDeviceOut = !bShared;
      m_CurrentParams.bpp = p.bpp;
      [m_BGContext release];
      m_BGContext = nil;
      m_BGContext = CreateOGLContext(
          WINDOWED, p.bpp == 16 ? 16 : 24, p.bpp == 16 ? 1 : 8, 16, m_Context, bShared);

      if (m_BGContext && !bShared) {
        [m_BGContext release];
        m_BGContext = nil;
      }
    }

    [m_WindowDelegate performSelectorOnMainThread:@selector(setParams:)
                                       withObject:[NSValue valueWithPointer:&p]
                                    waitUntilDone:YES];
    dispatch_sync(dispatch_get_main_queue(), ^{
      [m_Context setView:[((SMWindowDelegate*)m_WindowDelegate)->m_Window contentView]];
      [m_Context update];
    });
    [m_Context makeCurrentContext];
    m_CurrentParams.windowed = true;
    SetActualParamsFromMode(CGDisplayCurrentMode(kCGDirectMainDisplay));
    if (p.rate != REFRESH_DEFAULT) {
      if (m_CurrentParams.rate != p.rate) {
        LOG->Trace(
            "Windowed refresh pacing override: display_rate=%d requested_rate=%d",
            m_CurrentParams.rate, p.rate);
      }
      m_CurrentParams.rate = p.rate;
    }

    if (bChangeVsync) {
      const GLint actualSwap =
          ApplyMacOSSwapInterval(m_Context, p, true);
      m_CurrentParams.vsync = actualSwap != 0;
    }

    return std::string();
  }
  if (bChangeMode) {
    int result = ChangeDisplayMode(p);

    if (result) {
      return ssprintf(
          "Failed to switch to full screen:%d x %d @ %d. Error %d.", p.width, p.height, p.rate,
          result);
    }
  }

  if (bRebuildContext) {
    bool bShared;
    NSOpenGLContext* newContext = CreateOGLContext(
        FULL_SCREEN, p.bpp == 16 ? 16 : 24, p.bpp == 16 ? 1 : 8, 16, m_Context, bShared);

    if (!newContext) {
      return "Failed to create full screen OGL context.";
    }
    [m_Context clearDrawable];
    [m_Context release];
    m_Context = newContext;
    newDeviceOut = !bShared;
    m_CurrentParams.bpp = p.bpp;
    [m_BGContext release];
    m_BGContext = CreateOGLContext(
        FULL_SCREEN, p.bpp == 16 ? 16 : 24, p.bpp == 16 ? 1 : 8, 16, m_Context, bShared);

    if (m_BGContext && !bShared) {
      [m_BGContext release];
      m_BGContext = nil;
    }
  }
  dispatch_sync(dispatch_get_main_queue(), ^{
    [m_Context setFullScreen];
    [m_Context update];
  });
  [m_Context makeCurrentContext];

  if (bChangeVsync) {
    const GLint actualSwap =
        ApplyMacOSSwapInterval(m_Context, p, false);
    m_CurrentParams.vsync = actualSwap != 0;
  }

  return std::string();
}

void LowLevelWindow_MacOSX::ShutDownFullScreen() {
  if (m_CurrentParams.windowed) {
    return;
  }
  ASSERT(m_CurrentDisplayMode);

  // Clear the front and back framebuffers before switching out of FullScreen mode.
  // (This is not strictly necessary, but avoids an untidy flash of garbage.)
  glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
  glClear(GL_COLOR_BUFFER_BIT);
  [m_Context flushBuffer];
  glClear(GL_COLOR_BUFFER_BIT);
  [m_Context flushBuffer];

  [NSOpenGLContext clearCurrentContext];
  [m_Context clearDrawable];
  [m_BGContext clearDrawable];

  CGDisplayErr err = CGDisplaySwitchToMode(kCGDirectMainDisplay, m_CurrentDisplayMode);

  ASSERT(err == kCGErrorSuccess);
  CGDisplayShowCursor(kCGDirectMainDisplay);
  err = CGDisplayRelease(m_DisplayID);
  ASSERT(err == kCGErrorSuccess);
  SetActualParamsFromMode(m_CurrentDisplayMode);
  // We don't own this so we cannot release it.
  m_CurrentDisplayMode = nil;
  m_CurrentParams.windowed = true;
}

int LowLevelWindow_MacOSX::ChangeDisplayMode(const VideoModeParams& p) {
  CFDictionaryRef mode = nil;
  CFDictionaryRef newMode;
  CGDisplayErr err;

  if (!m_CurrentDisplayMode) {
    m_DisplayID = CGMainDisplayID();
    if ((err = CGDisplayCapture(m_DisplayID)) != kCGErrorSuccess) {
      return err;
    }
    // Only hide the first time we go to full screen.
    CGDisplayHideCursor(kCGDirectMainDisplay);
    mode = CGDisplayCurrentMode(kCGDirectMainDisplay);
  }

  if (p.rate == REFRESH_DEFAULT) {
    newMode = CGDisplayBestModeForParameters(kCGDirectMainDisplay, p.bpp, p.width, p.height, nil);
  } else {
    newMode = CGDisplayBestModeForParametersAndRefreshRate(
        kCGDirectMainDisplay, p.bpp, p.width, p.height, p.rate, nil);
  }

  err = CGDisplaySwitchToMode(kCGDirectMainDisplay, newMode);

  if (err != kCGErrorSuccess) {
    return err;  // We don't own mode, don't release it.
  }

  if (!m_CurrentDisplayMode) {
    m_CurrentDisplayMode = mode;
  }
  m_CurrentParams.windowed = false;
  SetActualParamsFromMode(newMode);

  return 0;
}

// http://lukassen.wordpress.com/2010/01/18/taming-snow-leopard-cgdisplaybitsperpixel-deprication/
static size_t GetDisplayBitsPerPixel(CGDirectDisplayID displayId) {
  CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayId);
  size_t depth = 0;

  CFStringRef pixEnc = CGDisplayModeCopyPixelEncoding(mode);
  if (CFStringCompare(pixEnc, CFSTR(IO32BitDirectPixels), kCFCompareCaseInsensitive) ==
      kCFCompareEqualTo) {
    depth = 32;
  } else if (
      CFStringCompare(pixEnc, CFSTR(IO16BitDirectPixels), kCFCompareCaseInsensitive) ==
      kCFCompareEqualTo) {
    depth = 16;
  } else if (
      CFStringCompare(pixEnc, CFSTR(IO8BitIndexedPixels), kCFCompareCaseInsensitive) ==
      kCFCompareEqualTo) {
    depth = 8;
  }

  CFRelease(pixEnc);
  CGDisplayModeRelease(mode);

  return depth;
}

void LowLevelWindow_MacOSX::SetActualParamsFromMode(CFDictionaryRef mode) {
  SInt32 rate;
  bool ret = CFNumberGetValue(
      (CFNumberRef)CFDictionaryGetValue(mode, CFSTR("RefreshRate")), kCFNumberSInt32Type, &rate);

  if (!ret || rate == 0) {
    rate = 60;
  }
  m_CurrentParams.rate = rate;

  if (!m_CurrentParams.windowed) {
    GLint swap;
    m_CurrentParams.width = CGDisplayPixelsWide(kCGDirectMainDisplay);
    m_CurrentParams.height = CGDisplayPixelsHigh(kCGDirectMainDisplay);
    CGLGetParameter(CGLGetCurrentContext(), kCGLCPSwapInterval, &swap);
    m_CurrentParams.vsync = swap != 0;
  } else {
    __block NSSize size;
    dispatch_sync(dispatch_get_main_queue(), ^{
      size = [[((SMWindowDelegate*)m_WindowDelegate)->m_Window contentView] frame].size;
    });

    m_CurrentParams.width = int(size.width);
    m_CurrentParams.height = int(size.height);
  }

  m_CurrentParams.bpp = GetDisplayBitsPerPixel(kCGDirectMainDisplay);
}

static int GetIntValue(CFTypeRef r) {
  int ret;

  if (!r || CFGetTypeID(r) != CFNumberGetTypeID() ||
      !CFNumberGetValue(CFNumberRef(r), kCFNumberIntType, &ret)) {
    return 0;
  }
  return ret;
}

static bool GetBoolValue(CFTypeRef r) {
  return r && CFGetTypeID(r) == CFBooleanGetTypeID() && CFBooleanGetValue(CFBooleanRef(r));
}

static double GetDoubleValue(CFTypeRef r) {
  double ret;

  if (!r || CFGetTypeID(r) != CFNumberGetTypeID() ||
      !CFNumberGetValue(CFNumberRef(r), kCFNumberDoubleType, &ret)) {
    return 0;
  }
  return ret;
}

static DisplayMode ConvertDisplayMode(CFDictionaryRef dict) {
  int width = GetIntValue(CFDictionaryGetValue(dict, kCGDisplayWidth));
  int height = GetIntValue(CFDictionaryGetValue(dict, kCGDisplayHeight));
  double rate = GetDoubleValue(CFDictionaryGetValue(dict, kCGDisplayRefreshRate));

  return {static_cast<unsigned int>(width), static_cast<unsigned int>(height), rate};
}

void LowLevelWindow_MacOSX::GetDisplaySpecs(DisplaySpecs& specs) const {
  CFArrayRef modes = CGDisplayAvailableModes(kCGDirectMainDisplay);
  ASSERT(modes);
  const CFIndex count = CFArrayGetCount(modes);

  std::set<DisplayMode> available;
  CFDictionaryRef currentModeDict = CGDisplayCurrentMode(kCGDirectMainDisplay);
  DisplayMode current = ConvertDisplayMode(currentModeDict);

  for (CFIndex i = 0; i < count; ++i) {
    CFDictionaryRef dict = (CFDictionaryRef)CFArrayGetValueAtIndex(modes, i);
    CFTypeRef safe = CFDictionaryGetValue(dict, kCGDisplayModeIsSafeForHardware);
    DisplayMode mode = ConvertDisplayMode(dict);

    if (!mode.width || !mode.height) {
      continue;
    }
    if (safe && !GetBoolValue(safe)) {
      continue;
    }
    available.insert(mode);
  }
  // Do not release modes! We don't own them here.
  RectI bounds(0, 0, current.width, current.height);
  DisplaySpec s("", "Fullscreen", available, current, bounds);
  specs.insert(s);
}

void LowLevelWindow_MacOSX::SwapBuffers() {
  RageTimer timer;
  CGLContextObj context = CGLGetCurrentContext();
  GLint swapInterval = -1;
  if (context != nullptr) {
    CGLGetParameter(context, kCGLCPSwapInterval, &swapInterval);
  }
  const CGLError error = CGLFlushDrawable(context);
  const float elapsedMs = timer.GetDeltaTime() * 1000.0f;

  if (elapsedMs >= g_fPerfTraceSlowMacSwapBuffersMs.Get() ||
      error != kCGLNoError) {
    const float expectedFrameMs = ExpectedFrameMsForRate(m_CurrentParams.rate);
    const int missedIntervals =
        MissedIntervalsForElapsedMs(elapsedMs, expectedFrameMs);
    LOG->Trace(
        "PERF_TRACE: macos_swap_buffers total_ms=%.3f error=%d vsync=%d "
        "swap_interval=%d frame_pacing_owns_swap=%d "
        "frame_pacing_target_hz=%.3f rate=%d windowed=%d "
        "expected_frame_ms=%.3f missed_intervals=%d requested_size=%dx%d",
        elapsedMs, static_cast<int>(error), m_CurrentParams.vsync ? 1 : 0,
        swapInterval, MacOSFramePacingOwnsSwapInterval() ? 1 : 0,
        g_fFramePacingTargetHz.Get(), m_CurrentParams.rate,
        m_CurrentParams.windowed ? 1 : 0, expectedFrameMs, missedIntervals,
        m_CurrentParams.width, m_CurrentParams.height);
  }
}

void LowLevelWindow_MacOSX::Update() {
  // Keep the system from sleeping or the screen saver from activating.
  UpdateSystemActivity(IdleActivity);

  LockMutex lock(g_ResizeLock);
  if (likely(!g_bResized)) {
    return;
  }
  g_bResized = false;
  if (m_CurrentParams.width == g_iWidth && m_CurrentParams.height == g_iHeight) {
    return;
  }
  m_CurrentParams.width = g_iWidth;
  m_CurrentParams.height = g_iHeight;
  lock.Unlock();  // Unlock before calling ResolutionChanged().
  dispatch_sync(dispatch_get_main_queue(), ^{
    [m_Context update];
  });

  DISPLAY->ResolutionChanged();
}

RenderTarget* LowLevelWindow_MacOSX::CreateRenderTarget() {
  return new RenderTarget_MacOSX(m_Context);
}

void LowLevelWindow_MacOSX::BeginConcurrentRendering() {
  if (m_CurrentParams.windowed) {
    [m_BGContext setView:[((SMWindowDelegate*)m_WindowDelegate)->m_Window contentView]];
  } else {
    [m_BGContext setFullScreen];
  }
  [m_BGContext makeCurrentContext];
}

/*
 * (c) 2005-2006, 2008 Steve Checkoway
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
