#import "LowLevelWindow_MacOSX.h"
#import "DisplaySpec.h"
#import "MacOSMetalPresenter.h"
#import "MacOSFramePacing.h"
#import "PerfDiagnostics.h"
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
#include <vector>

#import <Cocoa/Cocoa.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <OpenGL/CGLIOSurface.h>
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
constexpr float kMacOSFramePacingDisplayLinkFinalSleepChunkMs = 0.5f;
constexpr float kMacOSFramePacingDisplayLinkFinalYieldMs = 5.0f;
constexpr float kMacOSFramePacingDisplayLinkFinalSpinMs = 1.5f;
constexpr float kMacOSOpenGLFenceAutoWaitHighRefreshMs = 1.5f;
constexpr float kMacOSOpenGLFenceAutoMinRefreshHz = 90.0f;
constexpr float kMacOSOpenGLFenceTraceMinMs = 12.0f;
static Preference<float> g_fPerfTraceSlowMacSwapBuffersMs(
    "PerfTraceSlowMacSwapBuffersMs", 20.0f);
// -1 means "auto": on high-refresh macOS/OpenGL, wait on the GPU fence until it
// signals, but only up to a small budget.  This is not a blind sleep; it returns
// as soon as GPU work is complete, and prevents CGLFlushDrawable from becoming
// the first place that discovers unfinished GPU work.
static Preference<float> g_fMacOSOpenGLFencePacingWaitMs(
    "MacOSOpenGLFencePacingWaitMs", -1.0f);
static Preference<std::string> g_sMacOSPresentBackend(
    "MacOSPresentBackend", "opengl");
extern Preference<float> g_fFramePacingTargetHz;

static MacOSOpenGLFenceWaitStats g_LastOpenGLFenceWaitStats;

#ifndef GL_READ_FRAMEBUFFER_EXT
#define GL_READ_FRAMEBUFFER_EXT 0x8CA8
#endif
#ifndef GL_DRAW_FRAMEBUFFER_EXT
#define GL_DRAW_FRAMEBUFFER_EXT 0x8CA9
#endif

struct MacOSMetalOpenGLBridgeSurface {
  GLuint texture = 0;
  GLuint framebuffer = 0;
  GLuint depth = 0;
};

struct MacOSMetalOpenGLBridge {
  std::vector<MacOSMetalOpenGLBridgeSurface> surfaces;
  GLenum textureTarget = GL_TEXTURE_RECTANGLE_ARB;
  GLenum internalFormat = GL_RGBA;
  GLenum format = GL_BGRA;
  GLenum type = GL_UNSIGNED_INT_8_8_8_8_REV;
  int width = 0;
  int height = 0;
};

namespace {
bool MacOSFramePacingUseDisplayLinkEnabled() {
  return true;
}

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

int MacOSFramePacingOutputAlignedPresentMode() {
  return 1;
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
  const uint64_t maxSleepUsec =
      std::max<uint64_t>(100, std::min<uint64_t>(500, intervalUsec / 8));
  return ClampedDisplayLinkUsecPreference(
      MacOSFramePacingDisplayLinkFinalSleepChunkMs(), 500, 100,
      maxSleepUsec);
}

uint64_t DisplayLinkFinalYieldWindowUsec(
    uint64_t periodUsec, uint64_t intervalUsec) {
  const uint64_t effectivePeriodUsec =
      periodUsec != 0 ? periodUsec : intervalUsec;
  const uint64_t maxYieldUsec = std::max<uint64_t>(
      5000, std::min<uint64_t>(7000, (effectivePeriodUsec * 3) / 4));
  const uint64_t requestedYieldUsec =
      ClampedDisplayLinkUsecPreference(
          MacOSFramePacingDisplayLinkFinalYieldMs(), 5000, 1000,
          maxYieldUsec);
  return std::max<uint64_t>(5000, requestedYieldUsec);
}

uint64_t DisplayLinkFinalSpinWindowUsec(
    uint64_t periodUsec, uint64_t intervalUsec,
    uint64_t yieldWindowUsec) {
  const uint64_t effectivePeriodUsec =
      periodUsec != 0 ? periodUsec : intervalUsec;
  const uint64_t maxSpinUsec = std::min<uint64_t>(
      std::max<uint64_t>(100, yieldWindowUsec),
      std::max<uint64_t>(1500, std::min<uint64_t>(2500,
                                                  effectivePeriodUsec / 4)));
  const uint64_t requestedSpinUsec =
      ClampedDisplayLinkUsecPreference(
          MacOSFramePacingDisplayLinkFinalSpinMs(), 1500, 0,
          maxSpinUsec);
  return std::max<uint64_t>(1500, requestedSpinUsec);
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
  if (MacOSFramePacingOutputAlignedPresentMode() == 0) {
    return false;
  }
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

bool DisplayLinkOutputAlignedPresentWouldCap(
    const DisplayLinkOutputPhase& outputPhase, uint64_t presentLeadUsec,
    uint64_t latestPresentUsec, uint64_t phaseToleranceUsec,
    uint64_t displayLinkTickCount, int outputAlignedPresentMode) {
  if (!outputPhase.valid || !outputPhase.phase_accepted ||
      outputPhase.output_usec <= presentLeadUsec) {
    return false;
  }

  const uint64_t desiredPresentUsec =
      outputPhase.output_usec - presentLeadUsec;
  if (desiredPresentUsec <= latestPresentUsec) {
    return false;
  }

  if (outputAlignedPresentMode != 3) {
    return false;
  }

  constexpr uint64_t kWarmupDisplayLinkTicks = 45;
  if (displayLinkTickCount <= kWarmupDisplayLinkTicks) {
    return false;
  }

  const uint64_t aheadUsec =
      outputPhase.output_to_target_usec > 0
          ? static_cast<uint64_t>(outputPhase.output_to_target_usec)
          : 0;
  const uint64_t strictAheadThresholdUsec =
      std::max<uint64_t>(1500, (phaseToleranceUsec * 3) / 4);
  return aheadUsec >= strictAheadThresholdUsec;
}

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
    uint64_t periodUsec, uint64_t phaseToleranceUsec,
    bool allowNextOutput) {
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
  if (allowNextOutput && periodUsec != 0 &&
      lastOutputUsec <= UINT64_MAX - periodUsec) {
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
    if (!MacOSFramePacingUseDisplayLinkEnabled()) {
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
    const int outputAlignedPresentMode =
        MacOSFramePacingOutputAlignedPresentMode();
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
      const uint64_t currentPresentLeadUsec =
          DisplayLinkPresentLeadUsec(
              currentPeriodUsec, intervalUsec, presentLeadOverrideUsec);
      const uint64_t currentLateToleranceUsec =
          DisplayLinkLateToleranceUsec(currentPeriodUsec, intervalUsec);
      const uint64_t currentLatestPresentUsec =
          (targetPresentUsec > currentPresentLeadUsec
               ? targetPresentUsec - currentPresentLeadUsec
               : targetPresentUsec) +
          currentLateToleranceUsec;
      const bool outputAlignedPresent =
          DisplayLinkUseOutputAlignedPresent(currentPeriodUsec, intervalUsec);
      const DisplayLinkOutputPhase outputPhase =
          SelectDisplayLinkOutputForTarget(
              m_LastOutputRageUsec, targetPresentUsec,
              currentPeriodUsec, phaseToleranceUsec,
              outputAlignedPresentMode < 2);
      const bool outputAlignedCapRejected =
          outputAlignedPresentMode == 3 &&
          DisplayLinkOutputAlignedPresentWouldCap(
              outputPhase, currentPresentLeadUsec,
              currentLatestPresentUsec, phaseToleranceUsec,
              m_TickCount, outputAlignedPresentMode);

      if (outputAlignedPresent && outputPhase.phase_accepted &&
          !outputAlignedCapRejected) {
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
            phaseToleranceUsec, outputAlignedPresentMode < 2);
    const bool outputAlignedPresent =
        DisplayLinkUseOutputAlignedPresent(periodUsec, intervalUsec) &&
        outputPhase.phase_accepted &&
        !(outputAlignedPresentMode == 3 &&
          DisplayLinkOutputAlignedPresentWouldCap(
              outputPhase, presentLeadUsec, latestPresentUsec,
              phaseToleranceUsec, tickCount, outputAlignedPresentMode));
    const bool outputAlignedCapRejected =
        DisplayLinkUseOutputAlignedPresent(periodUsec, intervalUsec) &&
        outputPhase.phase_accepted && !outputAlignedPresent &&
        outputAlignedPresentMode == 3;
    const bool selectedOutputPhaseAccepted =
        outputPhase.phase_accepted;
    uint64_t desiredPresentUsec =
        outputAlignedPresent && selectedOutputPhaseAccepted &&
                outputPhase.output_usec > presentLeadUsec
            ? outputPhase.output_usec - presentLeadUsec
            : targetPresentUsec > presentLeadUsec
                  ? targetPresentUsec - presentLeadUsec
                  : targetPresentUsec;
    bool finalWaitCapped = false;
    desiredPresentUsec = CappedDisplayLinkDesiredPresentUsec(
        desiredPresentUsec, latestPresentUsec, &finalWaitCapped);
    if (!timedOut && outputAlignedPresent) {
      status = "output_aligned";
    } else if (!timedOut && outputAlignedCapRejected) {
      status = "output_cap_rejected";
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
      stats->output_aligned_present_mode = outputAlignedPresentMode;
      stats->output_aligned_present = outputAlignedPresent;
      stats->output_aligned_cap_rejected = outputAlignedCapRejected;
      stats->output_aligned_present_enabled =
          outputAlignedPresentMode != 0;
      stats->selected_output_source = outputPhase.source;
      stats->status = status;
    }
    return true;
  }

  void Reset(const char* reason) {
    std::lock_guard<std::mutex> lock(m_Mutex);
    m_TickCount = 0;
    m_LastOutputRageUsec = 0;
    if (PerfDiagnosticsEnabled()) {
      LOG->Trace(
          "MACOS_DISPLAY_LINK: reset reason=%s started=%d failed=%d",
          reason != nullptr ? reason : "manual", m_Started ? 1 : 0,
          m_Failed ? 1 : 0);
    }
  }

  bool Enabled() const { return MacOSFramePacingUseDisplayLinkEnabled(); }

  bool GetLastOutputSnapshot(
      uint64_t* lastOutputUsec, uint64_t* periodUsec) {
    std::lock_guard<std::mutex> lock(m_Mutex);
    if (m_LastOutputRageUsec == 0) {
      return false;
    }
    if (lastOutputUsec != nullptr) {
      *lastOutputUsec = m_LastOutputRageUsec;
    }
    if (periodUsec != nullptr) {
      *periodUsec = m_LastPeriodUsec;
    }
    return true;
  }

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
    if (PerfDiagnosticsEnabled()) {
      LOG->Trace(
          "MACOS_DISPLAY_LINK: started actual_period_us=%llu "
          "current_context=%p bind_result=%d",
          static_cast<unsigned long long>(actualPeriodUsec),
          m_BoundContext, static_cast<int>(m_LastBindResult));
    }
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
    if (PerfDiagnosticsEnabled()) {
      LOG->Trace(
          "MACOS_DISPLAY_LINK: bound_context context=%p result=%d",
          currentContext, static_cast<int>(m_LastBindResult));
    }
  }

  void FillBaseStats(MacOSFramePacingDisplayLinkStats* stats) const {
    if (stats == nullptr) {
      return;
    }
    stats->available = true;
    stats->enabled = MacOSFramePacingUseDisplayLinkEnabled();
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

static bool MacOSFramePacingGetLastDisplayLinkOutput(
    uint64_t* lastOutputUsec, uint64_t* periodUsec) {
  return DisplayLinkPacer().GetLastOutputSnapshot(
      lastOutputUsec, periodUsec);
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

bool MacOSOpenGLGetLastFenceWaitStats(MacOSOpenGLFenceWaitStats* stats) {
  if (stats == nullptr) {
    return false;
  }
  *stats = g_LastOpenGLFenceWaitStats;
  return stats->available;
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

static float ClampMacOSFramePacingHz(float targetHz) {
  if (!std::isfinite(targetHz) || targetHz <= 0.0f) {
    return 0.0f;
  }
  return std::clamp(targetHz, 10.0f, 1000.0f);
}

static float EffectiveMacOSFramePacingTargetHz(const VideoModeParams& params) {
  const float configuredHz =
      ClampMacOSFramePacingHz(g_fFramePacingTargetHz.Get());
  if (configuredHz > 0.0f) {
    return configuredHz;
  }
  return params.rate > 0
             ? ClampMacOSFramePacingHz(static_cast<float>(params.rate))
             : 0.0f;
}

static bool MacOSMetalPresentRequested() {
  return CompareNoCase(g_sMacOSPresentBackend.Get(), "metal") == 0;
}

static bool MacOSMetalBridgeEnabled() {
  return MacOSMetalPresentRequested();
}

static bool MacOSMetalDirectPresentEnabled() {
  return MacOSMetalPresentRequested();
}

static int MacOSOpenGLOffscreenPresentMode() {
  return 1;
}

static const char* MacOSOpenGLOffscreenPresentModeName(int mode) {
  switch (mode) {
    case 0:
      return "off";
    case 1:
      return "auto";
    case 2:
      return "always";
    default:
      return "unknown";
  }
}

static int MacOSOpenGLOffscreenPresentMinRate() {
  return 90;
}

static GLint DesiredMacOSSwapInterval(const VideoModeParams& params) {
  if (!params.vsync) {
    return 0;
  }
  return EffectiveMacOSFramePacingTargetHz(params) > 0.0f ? 0 : 1;
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

static GLint DesiredMacOSMPSwapsInFlight() {
  return 1;
}

static bool MacOSOpenGLHardwareVsyncForcedEnabled() {
  return false;
}

static uint64_t MacOSOpenGLFencePacingWaitUsec(
    const VideoModeParams& params) {
  const float requestedMs = g_fMacOSOpenGLFencePacingWaitMs.Get();
  if (!std::isfinite(requestedMs)) {
    return 0;
  }

  float effectiveMs = requestedMs;
  if (requestedMs < 0.0f) {
    const float targetHz = EffectiveMacOSFramePacingTargetHz(params);
    const bool highRefresh =
        (targetHz >= kMacOSOpenGLFenceAutoMinRefreshHz) ||
        (params.rate >= static_cast<int>(kMacOSOpenGLFenceAutoMinRefreshHz));
    effectiveMs = highRefresh ? kMacOSOpenGLFenceAutoWaitHighRefreshMs : 0.0f;
  }
  if (effectiveMs <= 0.0f) {
    return 0;
  }
  return std::min<uint64_t>(
      5000,
      static_cast<uint64_t>(std::llround(effectiveMs * 1000.0f)));
}

static const char* MacOSOpenGLFenceWaitStatusName(GLenum status) {
  switch (status) {
    case GL_ALREADY_SIGNALED:
      return "already_signaled";
    case GL_CONDITION_SATISFIED:
      return "condition_satisfied";
    case GL_TIMEOUT_EXPIRED:
      return "timeout";
    case GL_WAIT_FAILED:
      return "wait_failed";
    default:
      return "unknown";
  }
}

static GLint CurrentMacOSMPSwapsInFlight(NSOpenGLContext* context) {
  if (context == nil) {
    return -1;
  }

  GLint swapsInFlight = -1;
  if (CGLGetParameter(
          [context CGLContextObj], kCGLCPMPSwapsInFlight,
          &swapsInFlight) != kCGLNoError) {
    return -1;
  }
  return swapsInFlight;
}

static GLint ApplyMacOSMPSwapsInFlight(NSOpenGLContext* context) {
  const GLint requestedSwapsInFlight = DesiredMacOSMPSwapsInFlight();
  const GLint previousSwapsInFlight = CurrentMacOSMPSwapsInFlight(context);
  if (context == nil || requestedSwapsInFlight <= 0) {
    LOG->Trace(
        "MacOS OpenGL MP swaps in flight configured: requested=%d actual=%d "
        "previous=%d enabled=%d error=%d",
        requestedSwapsInFlight, previousSwapsInFlight, previousSwapsInFlight,
        0, 0);
    return previousSwapsInFlight;
  }

  GLint appliedSwapsInFlight = requestedSwapsInFlight;
  const CGLError error = CGLSetParameter(
      [context CGLContextObj], kCGLCPMPSwapsInFlight, &appliedSwapsInFlight);
  const GLint actualSwapsInFlight = CurrentMacOSMPSwapsInFlight(context);
  LOG->Trace(
      "MacOS OpenGL MP swaps in flight configured: requested=%d actual=%d "
      "previous=%d enabled=%d error=%d",
      requestedSwapsInFlight, actualSwapsInFlight, previousSwapsInFlight, 1,
      static_cast<int>(error));
  return actualSwapsInFlight;
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
      "hardware_vsync_forced=%d "
      "frame_pacing_target_hz=%.3f configured_frame_pacing_target_hz=%.3f "
      "windowed=%d error=%d",
      params.vsync ? 1 : 0, desiredSwap, actualSwap, previousSwap,
      actualSwap == 0 &&
              EffectiveMacOSFramePacingTargetHz(params) > 0.0f
          ? 1
          : 0,
      MacOSOpenGLHardwareVsyncForcedEnabled() ? 1 : 0,
      EffectiveMacOSFramePacingTargetHz(params), g_fFramePacingTargetHz.Get(),
      windowed ? 1 : 0,
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
    : m_Context(nil),
      m_BGContext(nil),
      m_CurrentDisplayMode(nil),
      m_DisplayID(0),
      m_MetalPresenter(new MacOSMetalPresenter()),
      m_iMetalBridgeRenderSurfaceIndex(-1),
      m_bMetalBridgeFrameActive(false),
      m_bLoggedMetalBridgeFirstFrame(false),
      m_bLoggedMetalBridgeFirstBlit(false),
      m_bMetalDirectPresentSubmittedThisFrame(false),
      m_bMetalBridgeForceOpenGLFallbackThisFrame(false),
      m_bMetalBridgeBuildPending(false),
      m_iMetalBridgeBuildFrameCountdown(0) {
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
  ReleaseMetalOpenGLBridge();
  if (m_MetalPresenter) {
    m_MetalPresenter->Shutdown();
  }
  m_bMetalBridgeBuildPending = false;
  m_iMetalBridgeBuildFrameCountdown = 0;
  [m_Context release];
  [m_BGContext clearDrawable];
  [m_BGContext release];
  [m_WindowDelegate performSelectorOnMainThread:@selector(closeWindow)
                                     withObject:nil
                                  waitUntilDone:YES];
  [m_WindowDelegate release];
}

bool LowLevelWindow_MacOSX::ShouldRenderOffscreen() const {
  const int mode = MacOSOpenGLOffscreenPresentMode();
  if (mode == 0) {
    return false;
  }

  const float targetHz = EffectiveMacOSFramePacingTargetHz(m_CurrentParams);
  if (mode == 2) {
    return true;
  }

  return targetHz >= static_cast<float>(MacOSOpenGLOffscreenPresentMinRate());
}

const ActualVideoModeParams LowLevelWindow_MacOSX::GetActualVideoModeParams()
    const {
  return ActualVideoModeParams(
      m_CurrentParams, m_CurrentParams.width, m_CurrentParams.height,
      ShouldRenderOffscreen());
}

static void ReleaseMetalOpenGLBridgeResources(
    MacOSMetalOpenGLBridge* bridge) {
  if (bridge == nullptr) {
    return;
  }

  for (MacOSMetalOpenGLBridgeSurface& surface : bridge->surfaces) {
    if (surface.depth != 0) {
      glDeleteRenderbuffersEXT(1, &surface.depth);
      surface.depth = 0;
    }
    if (surface.framebuffer != 0) {
      glDeleteFramebuffersEXT(1, &surface.framebuffer);
      surface.framebuffer = 0;
    }
    if (surface.texture != 0) {
      glDeleteTextures(1, &surface.texture);
      surface.texture = 0;
    }
  }
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

void LowLevelWindow_MacOSX::ReleaseMetalOpenGLBridge() {
  if (!m_MetalOpenGLBridge) {
    return;
  }

  if (m_bMetalBridgeFrameActive) {
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
    m_bMetalBridgeFrameActive = false;
  }
  m_iMetalBridgeRenderSurfaceIndex = -1;
  m_bLoggedMetalBridgeFirstFrame = false;
  m_bLoggedMetalBridgeFirstBlit = false;
  m_bMetalDirectPresentSubmittedThisFrame = false;
  m_bMetalBridgeForceOpenGLFallbackThisFrame = false;
  ReleaseMetalOpenGLBridgeResources(m_MetalOpenGLBridge.get());
  m_MetalOpenGLBridge.reset();
  while (glGetError() != GL_NO_ERROR);
}

bool LowLevelWindow_MacOSX::BuildMetalOpenGLBridge() {
  if (!m_MetalPresenter || !m_MetalPresenter->IsInteropReady()) {
    ReleaseMetalOpenGLBridge();
    return false;
  }

  CGLContextObj context = CGLGetCurrentContext();
  IOSurfaceRef ioSurface = static_cast<IOSurfaceRef>(
      m_MetalPresenter->InteropIOSurfaceAt(0));
  const int width = m_MetalPresenter->InteropSurfaceWidth();
  const int height = m_MetalPresenter->InteropSurfaceHeight();
  if (context == nullptr || ioSurface == nullptr || width <= 0 || height <= 0) {
    LOG->Warn(
        "MacOS Metal presenter OpenGL bridge unavailable: invalid context or "
        "IOSurface dimensions context=%p surface=%p size=%dx%d.",
        context, ioSurface, width, height);
    return false;
  }

  if (m_MetalOpenGLBridge &&
      m_MetalOpenGLBridge->width == width &&
      m_MetalOpenGLBridge->height == height &&
      static_cast<int>(m_MetalOpenGLBridge->surfaces.size()) ==
          m_MetalPresenter->InteropSurfaceCount()) {
    return true;
  }

  ReleaseMetalOpenGLBridge();

  struct BridgeAttempt {
    GLenum textureTarget;
    GLenum internalFormat;
    GLenum format;
    GLenum type;
    const char* name;
  };

  // Apple's CGLIOSurface header documents GL_TEXTURE_RECTANGLE_ARB as the
  // supported target for CGLTexImageIOSurface2D.  The standalone interop POC
  // confirmed that rectangle textures work on Apple Silicon while GL_TEXTURE_2D
  // returns kCGLBadValue (10008), so the engine only probes the safe rectangle
  // path.
  const BridgeAttempt attempts[] = {
      {GL_TEXTURE_RECTANGLE_ARB, GL_RGBA, GL_BGRA,
       GL_UNSIGNED_INT_8_8_8_8_REV, "rect_rgba_bgra8888rev"},
      {GL_TEXTURE_RECTANGLE_ARB, GL_RGBA8, GL_BGRA,
       GL_UNSIGNED_INT_8_8_8_8_REV, "rect_rgba8_bgra8888rev"},
  };

  while (glGetError() != GL_NO_ERROR);

  for (const BridgeAttempt& attempt : attempts) {
    std::unique_ptr<MacOSMetalOpenGLBridge> bridge(
        new MacOSMetalOpenGLBridge());
    bridge->textureTarget = attempt.textureTarget;
    bridge->internalFormat = attempt.internalFormat;
    bridge->format = attempt.format;
    bridge->type = attempt.type;
    bridge->width = width;
    bridge->height = height;
    bridge->surfaces.resize(m_MetalPresenter->InteropSurfaceCount());

    bool attemptOk = true;
    for (int i = 0; i < m_MetalPresenter->InteropSurfaceCount(); ++i) {
      IOSurfaceRef attemptSurface = static_cast<IOSurfaceRef>(
          m_MetalPresenter->InteropIOSurfaceAt(i));
      MacOSMetalOpenGLBridgeSurface& bridgeSurface = bridge->surfaces[i];
      CGLError imageError = kCGLNoError;
      GLenum glErrorAfterImage = GL_NO_ERROR;
      GLenum fboStatus = GL_FRAMEBUFFER_COMPLETE_EXT;

      glGenTextures(1, &bridgeSurface.texture);
      glBindTexture(attempt.textureTarget, bridgeSurface.texture);
      glTexParameteri(
          attempt.textureTarget, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri(
          attempt.textureTarget, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
      glTexParameteri(
          attempt.textureTarget, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
      glTexParameteri(
          attempt.textureTarget, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

      LOG->Trace(
          "MacOS Metal presenter OpenGL bridge attempt starting: attempt=%s "
          "surface_index=%d size=%dx%d target=0x%x internal=0x%x "
          "format=0x%x type=0x%x surface=%p texture=%u",
          attempt.name, i, width, height,
          static_cast<unsigned int>(attempt.textureTarget),
          static_cast<unsigned int>(attempt.internalFormat),
          static_cast<unsigned int>(attempt.format),
          static_cast<unsigned int>(attempt.type), attemptSurface,
          bridgeSurface.texture);

      imageError = CGLTexImageIOSurface2D(
          context, attempt.textureTarget, attempt.internalFormat, width, height,
          attempt.format, attempt.type, attemptSurface, 0);
      glErrorAfterImage = glGetError();

      if (imageError == kCGLNoError && glErrorAfterImage == GL_NO_ERROR) {
        glGenFramebuffersEXT(1, &bridgeSurface.framebuffer);
        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, bridgeSurface.framebuffer);
        glFramebufferTexture2DEXT(
            GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT,
            attempt.textureTarget, bridgeSurface.texture, 0);

        glGenRenderbuffersEXT(1, &bridgeSurface.depth);
        glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, bridgeSurface.depth);
        glRenderbufferStorageEXT(
            GL_RENDERBUFFER_EXT, GL_DEPTH_COMPONENT16, width, height);
        glFramebufferRenderbufferEXT(
            GL_FRAMEBUFFER_EXT, GL_DEPTH_ATTACHMENT_EXT, GL_RENDERBUFFER_EXT,
            bridgeSurface.depth);

        fboStatus = glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT);
      }

      if (imageError != kCGLNoError || glErrorAfterImage != GL_NO_ERROR ||
          fboStatus != GL_FRAMEBUFFER_COMPLETE_EXT) {
        attemptOk = false;
        LOG->Trace(
            "MacOS Metal presenter OpenGL bridge attempt failed: attempt=%s "
            "surface_index=%d cgl_error=%d gl_error_after_image=0x%x "
            "fbo_status=0x%x size=%dx%d target=0x%x internal=0x%x "
            "format=0x%x type=0x%x",
            attempt.name, i, static_cast<int>(imageError),
            static_cast<unsigned int>(glErrorAfterImage),
            static_cast<unsigned int>(fboStatus), width, height,
            static_cast<unsigned int>(attempt.textureTarget),
            static_cast<unsigned int>(attempt.internalFormat),
            static_cast<unsigned int>(attempt.format),
            static_cast<unsigned int>(attempt.type));
        break;
      }
    }

    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
    glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, 0);
    glBindTexture(attempt.textureTarget, 0);
    while (glGetError() != GL_NO_ERROR);

    if (attemptOk) {
      LOG->Trace(
          "MacOS Metal presenter OpenGL bridge ready: attempt=%s "
          "surface_count=%d size=%dx%d target=0x%x internal=0x%x "
          "format=0x%x type=0x%x",
          attempt.name, static_cast<int>(bridge->surfaces.size()), width,
          height, static_cast<unsigned int>(attempt.textureTarget),
          static_cast<unsigned int>(attempt.internalFormat),
          static_cast<unsigned int>(attempt.format),
          static_cast<unsigned int>(attempt.type));
      m_MetalOpenGLBridge = std::move(bridge);
      return true;
    }

    ReleaseMetalOpenGLBridgeResources(bridge.get());
  }

  LOG->Warn(
      "MacOS Metal presenter OpenGL bridge unavailable: "
      "CGLTexImageIOSurface2D/FBO validation failed for all attempts "
      "size=%dx%d surface_count=%d.",
      width, height, m_MetalPresenter->InteropSurfaceCount());
  return false;
}

bool LowLevelWindow_MacOSX::BeginMetalPresentBridgeFrame() {
  if (!m_MetalOpenGLBridge || m_MetalOpenGLBridge->surfaces.empty() ||
      m_bMetalBridgeFrameActive) {
    return false;
  }

  const int surfaceCount =
      static_cast<int>(m_MetalOpenGLBridge->surfaces.size());
  int nextSurfaceIndex = -1;
  constexpr int kSurfaceWaitAttempts = 80;
  constexpr int kSurfaceWaitAttemptUsec = 100;
  for (int waitAttempt = 0;
       waitAttempt < kSurfaceWaitAttempts && nextSurfaceIndex < 0;
       ++waitAttempt) {
    for (int offset = 1; offset <= surfaceCount; ++offset) {
      const int candidate =
          (m_iMetalBridgeRenderSurfaceIndex + offset) % surfaceCount;
      if (!m_MetalPresenter ||
          !m_MetalPresenter->IsInteropSurfaceBusy(candidate)) {
        nextSurfaceIndex = candidate;
        break;
      }
    }
    if (nextSurfaceIndex < 0) {
      std::this_thread::sleep_for(
          std::chrono::microseconds(kSurfaceWaitAttemptUsec));
    }
  }

  if (nextSurfaceIndex < 0) {
    if (PerfDiagnosticsEnabled()) {
      static uint64_t s_iMetalBridgeBusySurfaceFrames = 0;
      ++s_iMetalBridgeBusySurfaceFrames;
      if (s_iMetalBridgeBusySurfaceFrames <= 3 ||
          s_iMetalBridgeBusySurfaceFrames % 5000 == 0) {
        LOG->Trace(
            "PERF_TRACE: macos_metal_bridge_surface_unavailable "
            "surface_count=%d wait_budget_us=%d frames=%llu",
            surfaceCount,
            kSurfaceWaitAttempts * kSurfaceWaitAttemptUsec,
            static_cast<unsigned long long>(s_iMetalBridgeBusySurfaceFrames));
      }
    }
    return false;
  }

  m_iMetalBridgeRenderSurfaceIndex = nextSurfaceIndex;
  const MacOSMetalOpenGLBridgeSurface& surface =
      m_MetalOpenGLBridge->surfaces[m_iMetalBridgeRenderSurfaceIndex];
  if (surface.framebuffer == 0) {
    return false;
  }

  glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, surface.framebuffer);
  glViewport(0, 0, m_MetalOpenGLBridge->width, m_MetalOpenGLBridge->height);
  glClearColor(0, 0, 0, 0);
  glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
  m_bMetalBridgeFrameActive = true;
  m_bMetalBridgeForceOpenGLFallbackThisFrame = false;
  if (!m_bLoggedMetalBridgeFirstFrame) {
    LOG->Trace(
        "MacOS Metal bridge rendering frame into IOSurface FBO: "
        "surface_index=%d framebuffer=%u texture=%u size=%dx%d",
        m_iMetalBridgeRenderSurfaceIndex, surface.framebuffer,
        surface.texture, m_MetalOpenGLBridge->width,
        m_MetalOpenGLBridge->height);
    m_bLoggedMetalBridgeFirstFrame = true;
  }
  return true;
}

bool LowLevelWindow_MacOSX::ResumeMetalPresentBridgeFrame() {
  if (!m_bMetalBridgeFrameActive || !m_MetalOpenGLBridge ||
      m_iMetalBridgeRenderSurfaceIndex < 0 ||
      m_iMetalBridgeRenderSurfaceIndex >=
          static_cast<int>(m_MetalOpenGLBridge->surfaces.size())) {
    return false;
  }

  const MacOSMetalOpenGLBridgeSurface& surface =
      m_MetalOpenGLBridge->surfaces[m_iMetalBridgeRenderSurfaceIndex];
  if (surface.framebuffer == 0) {
    return false;
  }

  glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, surface.framebuffer);
  glViewport(0, 0, m_MetalOpenGLBridge->width, m_MetalOpenGLBridge->height);
  return true;
}

void LowLevelWindow_MacOSX::MarkMetalPresentBridgeFallbackFrame() {
  if (m_bMetalBridgeFrameActive) {
    m_bMetalBridgeForceOpenGLFallbackThisFrame = true;
  }
}

void LowLevelWindow_MacOSX::EndMetalPresentBridgeFrame() {
  if (!m_bMetalBridgeFrameActive || !m_MetalOpenGLBridge ||
      m_iMetalBridgeRenderSurfaceIndex < 0 ||
      m_iMetalBridgeRenderSurfaceIndex >=
          static_cast<int>(m_MetalOpenGLBridge->surfaces.size())) {
    return;
  }

  const MacOSMetalOpenGLBridgeSurface& surface =
      m_MetalOpenGLBridge->surfaces[m_iMetalBridgeRenderSurfaceIndex];
  m_bMetalDirectPresentSubmittedThisFrame = false;
  if (m_bMetalBridgeForceOpenGLFallbackThisFrame &&
      PerfDiagnosticsEnabled()) {
    static uint64_t s_iMetalNestedRenderTargetFallbackFrames = 0;
    ++s_iMetalNestedRenderTargetFallbackFrames;
    if (s_iMetalNestedRenderTargetFallbackFrames <= 3 ||
        s_iMetalNestedRenderTargetFallbackFrames % 5000 == 0) {
      LOG->Trace(
          "PERF_TRACE: macos_metal_direct_present_fallback "
          "reason=nested_render_target fallback_frames=%llu",
          static_cast<unsigned long long>(
              s_iMetalNestedRenderTargetFallbackFrames));
    }
  }
  if (!m_bMetalBridgeForceOpenGLFallbackThisFrame &&
      MacOSMetalDirectPresentEnabled() && m_MetalPresenter) {
    GLsync metalReadFence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    GLenum metalReadFenceStatus = GL_WAIT_FAILED;
    if (metalReadFence != nullptr) {
      metalReadFenceStatus =
          glClientWaitSync(metalReadFence, GL_SYNC_FLUSH_COMMANDS_BIT, 0);
      if (metalReadFenceStatus == GL_TIMEOUT_EXPIRED) {
        metalReadFenceStatus =
            glClientWaitSync(metalReadFence, 0, 1500 * 1000);
      }
      glDeleteSync(metalReadFence);
    }
    const bool metalReadFenceReady =
        metalReadFenceStatus == GL_ALREADY_SIGNALED ||
        metalReadFenceStatus == GL_CONDITION_SATISFIED;
    if (metalReadFenceReady) {
      m_bMetalDirectPresentSubmittedThisFrame =
          m_MetalPresenter->PresentInteropSurfaceAt(
              m_iMetalBridgeRenderSurfaceIndex,
              EffectiveMacOSFramePacingTargetHz(m_CurrentParams));
    } else if (PerfDiagnosticsEnabled()) {
      static uint64_t s_iMetalFenceFallbackFrames = 0;
      ++s_iMetalFenceFallbackFrames;
      if (s_iMetalFenceFallbackFrames <= 3 ||
          s_iMetalFenceFallbackFrames % 5000 == 0) {
        LOG->Trace(
            "PERF_TRACE: macos_metal_direct_present_fallback "
            "reason=gl_fence_not_ready status=0x%x wait_budget_us=1500 "
            "fallback_frames=%llu",
            metalReadFenceStatus,
            static_cast<unsigned long long>(s_iMetalFenceFallbackFrames));
      }
    }
    static bool s_bLoggedDirectPresentFence = false;
    if (!s_bLoggedDirectPresentFence) {
      LOG->Trace(
          "MacOS Metal direct-present GL fence completed: "
          "status=0x%x wait_budget_us=1500",
          metalReadFenceStatus);
      s_bLoggedDirectPresentFence = true;
    }
    if (m_bMetalDirectPresentSubmittedThisFrame) {
      glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
      glViewport(0, 0, m_CurrentParams.width, m_CurrentParams.height);
      m_bMetalBridgeFrameActive = false;
      return;
    }
  }

  using GLBlitFramebufferEXTProc = void (*)(
      GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLbitfield,
      GLenum);
  auto* blitFramebuffer =
      reinterpret_cast<GLBlitFramebufferEXTProc>(
          GetProcAddress("glBlitFramebufferEXT"));
  if (blitFramebuffer == nullptr) {
    static bool s_bWarnedMissingBlit = false;
    if (!s_bWarnedMissingBlit) {
      LOG->Warn(
          "MacOS Metal bridge frame could not be copied to the OpenGL "
          "backbuffer: glBlitFramebufferEXT is unavailable.");
      s_bWarnedMissingBlit = true;
    }
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
    m_bMetalBridgeFrameActive = false;
    return;
  }

  glBindFramebufferEXT(GL_READ_FRAMEBUFFER_EXT, surface.framebuffer);
  glBindFramebufferEXT(GL_DRAW_FRAMEBUFFER_EXT, 0);
  blitFramebuffer(
      0, 0, m_MetalOpenGLBridge->width, m_MetalOpenGLBridge->height,
      0, 0, m_CurrentParams.width, m_CurrentParams.height,
      GL_COLOR_BUFFER_BIT, GL_NEAREST);
  if (!m_bLoggedMetalBridgeFirstBlit) {
    LOG->Trace(
        "MacOS Metal bridge copied IOSurface FBO to OpenGL backbuffer: "
        "surface_index=%d framebuffer=%u size=%dx%d dst_size=%dx%d",
        m_iMetalBridgeRenderSurfaceIndex, surface.framebuffer,
        m_MetalOpenGLBridge->width, m_MetalOpenGLBridge->height,
        m_CurrentParams.width, m_CurrentParams.height);
    m_bLoggedMetalBridgeFirstBlit = true;
  }
  glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
  glViewport(0, 0, m_CurrentParams.width, m_CurrentParams.height);
  m_bMetalBridgeFrameActive = false;
}

bool LowLevelWindow_MacOSX::PresentOpenGLBackbufferViaMetal() {
  if (!MacOSMetalDirectPresentEnabled() || !m_MetalPresenter ||
      !m_MetalOpenGLBridge || m_MetalOpenGLBridge->surfaces.empty() ||
      m_bMetalBridgeFrameActive) {
    return false;
  }

  using GLBlitFramebufferEXTProc = void (*)(
      GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLbitfield,
      GLenum);
  auto* blitFramebuffer =
      reinterpret_cast<GLBlitFramebufferEXTProc>(
          GetProcAddress("glBlitFramebufferEXT"));
  if (blitFramebuffer == nullptr) {
    return false;
  }

  const int surfaceCount =
      static_cast<int>(m_MetalOpenGLBridge->surfaces.size());
  int nextSurfaceIndex = -1;
  constexpr int kSurfaceWaitAttempts = 80;
  constexpr int kSurfaceWaitAttemptUsec = 100;
  for (int waitAttempt = 0;
       waitAttempt < kSurfaceWaitAttempts && nextSurfaceIndex < 0;
       ++waitAttempt) {
    for (int offset = 1; offset <= surfaceCount; ++offset) {
      const int candidate =
          (m_iMetalBridgeRenderSurfaceIndex + offset) % surfaceCount;
      if (!m_MetalPresenter->IsInteropSurfaceBusy(candidate)) {
        nextSurfaceIndex = candidate;
        break;
      }
    }
    if (nextSurfaceIndex < 0) {
      std::this_thread::sleep_for(
          std::chrono::microseconds(kSurfaceWaitAttemptUsec));
    }
  }

  if (nextSurfaceIndex < 0) {
    if (PerfDiagnosticsEnabled()) {
      static uint64_t s_iMetalBackbufferBusySurfaceFrames = 0;
      ++s_iMetalBackbufferBusySurfaceFrames;
      if (s_iMetalBackbufferBusySurfaceFrames <= 3 ||
          s_iMetalBackbufferBusySurfaceFrames % 5000 == 0) {
        LOG->Trace(
            "PERF_TRACE: macos_metal_backbuffer_present_unavailable "
            "reason=busy_iosurfaces surface_count=%d wait_budget_us=%d "
            "frames=%llu",
            surfaceCount,
            kSurfaceWaitAttempts * kSurfaceWaitAttemptUsec,
            static_cast<unsigned long long>(
                s_iMetalBackbufferBusySurfaceFrames));
      }
    }
    return false;
  }

  m_iMetalBridgeRenderSurfaceIndex = nextSurfaceIndex;
  const MacOSMetalOpenGLBridgeSurface& surface =
      m_MetalOpenGLBridge->surfaces[m_iMetalBridgeRenderSurfaceIndex];
  if (surface.framebuffer == 0) {
    return false;
  }

  glBindFramebufferEXT(GL_READ_FRAMEBUFFER_EXT, 0);
  glReadBuffer(GL_BACK);
  glBindFramebufferEXT(GL_DRAW_FRAMEBUFFER_EXT, surface.framebuffer);
  glDrawBuffer(GL_COLOR_ATTACHMENT0_EXT);
  blitFramebuffer(
      0, 0, m_CurrentParams.width, m_CurrentParams.height,
      0, 0, m_MetalOpenGLBridge->width, m_MetalOpenGLBridge->height,
      GL_COLOR_BUFFER_BIT, GL_NEAREST);
  glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
  glReadBuffer(GL_BACK);
  glDrawBuffer(GL_BACK);
  glViewport(0, 0, m_CurrentParams.width, m_CurrentParams.height);

  GLsync metalReadFence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
  GLenum metalReadFenceStatus = GL_WAIT_FAILED;
  if (metalReadFence != nullptr) {
    metalReadFenceStatus =
        glClientWaitSync(metalReadFence, GL_SYNC_FLUSH_COMMANDS_BIT, 0);
    if (metalReadFenceStatus == GL_TIMEOUT_EXPIRED) {
      metalReadFenceStatus = glClientWaitSync(metalReadFence, 0, 1500 * 1000);
    }
    glDeleteSync(metalReadFence);
  }

  const bool metalReadFenceReady =
      metalReadFenceStatus == GL_ALREADY_SIGNALED ||
      metalReadFenceStatus == GL_CONDITION_SATISFIED;
  if (!metalReadFenceReady) {
    if (PerfDiagnosticsEnabled()) {
      static uint64_t s_iMetalBackbufferFenceFallbackFrames = 0;
      ++s_iMetalBackbufferFenceFallbackFrames;
      if (s_iMetalBackbufferFenceFallbackFrames <= 3 ||
          s_iMetalBackbufferFenceFallbackFrames % 5000 == 0) {
        LOG->Trace(
            "PERF_TRACE: macos_metal_backbuffer_present_unavailable "
            "reason=gl_fence_not_ready status=0x%x wait_budget_us=1500 "
            "frames=%llu",
            metalReadFenceStatus,
            static_cast<unsigned long long>(
                s_iMetalBackbufferFenceFallbackFrames));
      }
    }
    return false;
  }

  m_bMetalDirectPresentSubmittedThisFrame =
      m_MetalPresenter->PresentInteropSurfaceAt(
          m_iMetalBridgeRenderSurfaceIndex,
          EffectiveMacOSFramePacingTargetHz(m_CurrentParams));
  if (m_bMetalDirectPresentSubmittedThisFrame &&
      PerfDiagnosticsEnabled()) {
    static bool s_bLoggedBackbufferPresent = false;
    if (!s_bLoggedBackbufferPresent) {
      LOG->Trace(
          "MacOS Metal backbuffer present active: surface_count=%d "
          "size=%dx%d source_size=%dx%d",
          surfaceCount, m_MetalOpenGLBridge->width,
          m_MetalOpenGLBridge->height, m_CurrentParams.width,
          m_CurrentParams.height);
      s_bLoggedBackbufferPresent = true;
    }
  }
  return m_bMetalDirectPresentSubmittedThisFrame;
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
  const GLint desiredMPSwapsInFlight = DesiredMacOSMPSwapsInFlight();
  const GLint currentMPSwapsInFlight = CurrentMacOSMPSwapsInFlight(m_Context);
  const bool bChangeVsync =
      bRebuildContext || currentSwapInterval != desiredSwapInterval;
  const bool bChangeMPSwapsInFlight =
      bRebuildContext ||
      (desiredMPSwapsInFlight > 0 &&
       currentMPSwapsInFlight != desiredMPSwapsInFlight);
  const bool bMetalBridgeRequested = MacOSMetalBridgeEnabled();
  const bool bChangePresentBackend =
      bMetalBridgeRequested
          ? (m_MetalPresenter && !m_MetalPresenter->IsAvailable())
          : (m_MetalPresenter && m_MetalPresenter->IsAvailable());

  auto configurePresentBackend = [&](bool windowed) {
    if (bMetalBridgeRequested && m_MetalPresenter && windowed) {
      SMWindowDelegate* delegate = (SMWindowDelegate*)m_WindowDelegate;
      ReleaseMetalOpenGLBridge();
      if ([NSThread isMainThread]) {
        m_MetalPresenter->Initialize(
            (void*)delegate->m_Window, m_CurrentParams.width,
            m_CurrentParams.height,
            EffectiveMacOSFramePacingTargetHz(m_CurrentParams));
      } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
          m_MetalPresenter->Initialize(
              (void*)delegate->m_Window, m_CurrentParams.width,
              m_CurrentParams.height,
              EffectiveMacOSFramePacingTargetHz(m_CurrentParams));
        });
      }
      if (m_MetalPresenter->IsInteropReady()) {
        if (MacOSMetalDirectPresentEnabled()) {
          m_MetalPresenter->AttachLayerToWindow((void*)delegate->m_Window);
        } else {
          m_MetalPresenter->DetachLayer();
        }
        m_bMetalBridgeBuildPending = true;
        m_iMetalBridgeBuildFrameCountdown = 5;
        LOG->Trace(
            "MacOS Metal bridge build queued: frames_until_build=%d",
            m_iMetalBridgeBuildFrameCountdown);
      }
    } else {
      if (MacOSMetalPresentRequested() && !windowed) {
        LOG->Warn(
            "MacOSPresentBackend=metal is currently available only for the "
            "windowed Metal-presenter bootstrap. Full-screen exclusive mode "
            "keeps the OpenGL presentation path until the IOSurface bridge is "
            "implemented.");
      }
      ReleaseMetalOpenGLBridge();
      if (m_MetalPresenter) {
        m_MetalPresenter->Shutdown();
      }
      m_bMetalBridgeBuildPending = false;
      m_iMetalBridgeBuildFrameCountdown = 0;
    }

    const bool effectiveMetal =
        m_MetalPresenter && m_MetalPresenter->IsAvailable() &&
        m_MetalPresenter->IsInteropReady() &&
        m_MetalPresenter->IsLayerAttached() && windowed;
    LOG->Trace(
        "MacOS present backend: requested=%s effective=%s. "
        "OpenGL offscreen present policy: mode=%s mode_value=%d "
        "enabled=%d target_hz=%.3f min_rate=%d windowed=%d size=%dx%d "
        "metal_bridge_requested=%d metal_direct_present_enabled=%d "
        "metal_layer_attached=%d",
        g_sMacOSPresentBackend.Get().c_str(),
        effectiveMetal ? "metal" : "opengl",
        MacOSOpenGLOffscreenPresentModeName(
            MacOSOpenGLOffscreenPresentMode()),
        MacOSOpenGLOffscreenPresentMode(), ShouldRenderOffscreen() ? 1 : 0,
        EffectiveMacOSFramePacingTargetHz(m_CurrentParams),
        MacOSOpenGLOffscreenPresentMinRate(), windowed ? 1 : 0,
        m_CurrentParams.width, m_CurrentParams.height,
        bMetalBridgeRequested ? 1 : 0,
        MacOSMetalDirectPresentEnabled() ? 1 : 0,
        effectiveMetal ? 1 : 0);
  };

  if (!bChangeMode && !bChangeVsync && !bChangeMPSwapsInFlight) {
    if (bChangePresentBackend) {
      configurePresentBackend(m_CurrentParams.windowed);
    }
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
    if (bChangeMPSwapsInFlight) {
      ApplyMacOSMPSwapsInFlight(m_Context);
    }

    configurePresentBackend(true);

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
  if (bChangeMPSwapsInFlight) {
    ApplyMacOSMPSwapsInFlight(m_Context);
  }

  configurePresentBackend(false);

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
  g_LastOpenGLFenceWaitStats = MacOSOpenGLFenceWaitStats();
  CGLContextObj context = CGLGetCurrentContext();
  if (m_bMetalBridgeBuildPending && context != nullptr) {
    --m_iMetalBridgeBuildFrameCountdown;
    if (m_iMetalBridgeBuildFrameCountdown <= 0) {
      m_bMetalBridgeBuildPending = false;
      LOG->Trace(
          "MacOS Metal bridge build running after deferred frames.");
      BuildMetalOpenGLBridge();
    }
  }
  GLint swapInterval = -1;
  GLint swapsInFlight = -1;
  if (context != nullptr) {
    CGLGetParameter(context, kCGLCPSwapInterval, &swapInterval);
    CGLGetParameter(context, kCGLCPMPSwapsInFlight, &swapsInFlight);
  }
  if (m_bMetalDirectPresentSubmittedThisFrame &&
      MacOSMetalDirectPresentEnabled()) {
    const uint64_t flushReturnUsec =
        RageTimer::GetTimeSinceStartMicroseconds();
    const float elapsedMs = timer.GetDeltaTime() * 1000.0f;
    g_LastOpenGLFenceWaitStats.available = true;
    g_LastOpenGLFenceWaitStats.pacing_wait_enabled = false;
    g_LastOpenGLFenceWaitStats.trace_enabled = PerfDiagnosticsEnabled();
    g_LastOpenGLFenceWaitStats.fence_created = false;
    g_LastOpenGLFenceWaitStats.gpu_busy = false;
    g_LastOpenGLFenceWaitStats.wait_saturated = false;
    g_LastOpenGLFenceWaitStats.wait_actual_usec = 0;
    g_LastOpenGLFenceWaitStats.wait_budget_usec = 0;
    static uint64_t s_iMetalDirectPresentSkipFrames = 0;
    ++s_iMetalDirectPresentSkipFrames;
    const bool traceSkipFrame =
        PerfDiagnosticsEnabled() &&
        (s_iMetalDirectPresentSkipFrames <= 5 ||
         s_iMetalDirectPresentSkipFrames % 600 == 0);
    if (traceSkipFrame) {
      LOG->Trace(
          "PERF_TRACE: macos_swap_buffers skipped_for_metal_direct_present=1 "
          "total_ms=%.3f error=0 vsync=%d swap_interval=%d "
          "mps_swaps_in_flight=%d frame_pacing_target_hz=%.3f rate=%d "
          "windowed=%d flush_return_us=%llu skipped_frames=%llu "
          "requested_size=%dx%d",
          elapsedMs, m_CurrentParams.vsync ? 1 : 0, swapInterval,
          swapsInFlight, EffectiveMacOSFramePacingTargetHz(m_CurrentParams),
          m_CurrentParams.rate, m_CurrentParams.windowed ? 1 : 0,
          static_cast<unsigned long long>(flushReturnUsec),
          static_cast<unsigned long long>(s_iMetalDirectPresentSkipFrames),
          m_CurrentParams.width, m_CurrentParams.height);
    }
    m_bMetalDirectPresentSubmittedThisFrame = false;
    return;
  }
  m_bMetalDirectPresentSubmittedThisFrame = false;
  const uint64_t fenceWaitUsec =
      context != nullptr ? MacOSOpenGLFencePacingWaitUsec(m_CurrentParams) : 0;
  const bool fencePacingWait = context != nullptr && fenceWaitUsec > 0;
  const bool fenceTraceEnabled = context != nullptr && PerfDiagnosticsEnabled();
  const bool fenceEnabled = fencePacingWait || fenceTraceEnabled;
  bool fenceCreated = false;
  GLenum fenceImmediateStatus = GL_WAIT_FAILED;
  GLenum fenceWaitStatus = GL_WAIT_FAILED;
  float fenceImmediateMs = 0.0f;
  float fenceWaitMs = 0.0f;
  GLsync fence = nullptr;
  uint64_t displayLinkOutputUsec = 0;
  uint64_t displayLinkPeriodUsec = 0;
  const bool displayLinkSnapshot =
      MacOSFramePacingGetLastDisplayLinkOutput(
          &displayLinkOutputUsec, &displayLinkPeriodUsec);
  if (fenceEnabled) {
    fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    fenceCreated = fence != nullptr;
    if (fenceCreated) {
      RageTimer fenceImmediateTimer;
      fenceImmediateStatus =
          glClientWaitSync(fence, GL_SYNC_FLUSH_COMMANDS_BIT, 0);
      fenceImmediateMs = fenceImmediateTimer.GetDeltaTime() * 1000.0f;
      fenceWaitStatus = fenceImmediateStatus;
      if (fenceImmediateStatus == GL_TIMEOUT_EXPIRED && fencePacingWait) {
        RageTimer fenceWaitTimer;
        fenceWaitStatus =
            glClientWaitSync(fence, 0, fenceWaitUsec * 1000);
        fenceWaitMs = fenceWaitTimer.GetDeltaTime() * 1000.0f;
      }
    }
  }
  const CGLError error = CGLFlushDrawable(context);
  const uint64_t flushReturnUsec =
      RageTimer::GetTimeSinceStartMicroseconds();
  const float elapsedMs = timer.GetDeltaTime() * 1000.0f;
  if (fenceCreated) {
    glDeleteSync(fence);
  }
  const float expectedFrameMs = ExpectedFrameMsForRate(m_CurrentParams.rate);
  const float configuredTraceMs =
      std::max(0.0f, g_fPerfTraceSlowMacSwapBuffersMs.Get());
  const float frameBudgetTraceMs =
      expectedFrameMs > 0.0f ? expectedFrameMs : 8.0f;
  const float effectiveTraceMs =
      configuredTraceMs > 0.0f ? configuredTraceMs : frameBudgetTraceMs;
  const float fenceTraceMs =
      std::max(kMacOSOpenGLFenceTraceMinMs, frameBudgetTraceMs * 1.5f);
  const bool fenceIndicatesGpuBusy =
      fenceCreated && fenceImmediateStatus == GL_TIMEOUT_EXPIRED;
  const uint64_t fenceWaitActualUsec =
      static_cast<uint64_t>(std::llround(std::max(0.0f, fenceWaitMs) * 1000.0f));
  const bool fenceWaitSaturated =
      fenceWaitUsec > 0 && fenceWaitActualUsec + 50 >= fenceWaitUsec &&
      fenceWaitStatus == GL_TIMEOUT_EXPIRED;
  const bool fenceSlowTrace =
      fenceTraceEnabled && elapsedMs >= fenceTraceMs;
  int64_t flushReturnToOutputUsec = 0;
  int64_t flushReturnPhaseUsec = 0;
  if (displayLinkSnapshot) {
    flushReturnToOutputUsec =
        static_cast<int64_t>(flushReturnUsec) -
        static_cast<int64_t>(displayLinkOutputUsec);
    if (displayLinkPeriodUsec != 0) {
      const int64_t period =
          static_cast<int64_t>(displayLinkPeriodUsec);
      flushReturnPhaseUsec = flushReturnToOutputUsec % period;
      if (flushReturnPhaseUsec < 0) {
        flushReturnPhaseUsec += period;
      }
    }
  }
  g_LastOpenGLFenceWaitStats.available = true;
  g_LastOpenGLFenceWaitStats.pacing_wait_enabled = fencePacingWait;
  g_LastOpenGLFenceWaitStats.trace_enabled = fenceTraceEnabled;
  g_LastOpenGLFenceWaitStats.fence_created = fenceCreated;
  g_LastOpenGLFenceWaitStats.gpu_busy = fenceIndicatesGpuBusy;
  g_LastOpenGLFenceWaitStats.wait_saturated = fenceWaitSaturated;
  g_LastOpenGLFenceWaitStats.wait_actual_usec = fenceWaitActualUsec;
  g_LastOpenGLFenceWaitStats.wait_budget_usec = fenceWaitUsec;

  if (!PerfDiagnosticsEnabled() && error != kCGLNoError) {
    LOG->Warn(
        "CGLFlushDrawable failed: error=%d vsync=%d swap_interval=%d "
        "mps_swaps_in_flight=%d requested_size=%dx%d",
        static_cast<int>(error), m_CurrentParams.vsync ? 1 : 0,
        swapInterval, swapsInFlight, g_iWidth, g_iHeight);
  }

  if (PerfDiagnosticsEnabled() &&
      (elapsedMs >= effectiveTraceMs || error != kCGLNoError ||
       fenceSlowTrace)) {
    const int missedIntervals =
        MissedIntervalsForElapsedMs(elapsedMs, expectedFrameMs);
    LOG->Trace(
        "PERF_TRACE: macos_swap_buffers total_ms=%.3f error=%d vsync=%d "
        "swap_interval=%d mps_swaps_in_flight=%d "
        "fence_pacing_wait=%d fence_trace=%d fence_created=%d "
        "fence_immediate_status=%s "
        "fence_immediate_ms=%.3f fence_wait_status=%s fence_wait_ms=%.3f "
        "fence_wait_actual_us=%llu fence_wait_budget_us=%llu "
        "fence_wait_saturated=%d fence_gpu_busy=%d "
        "frame_pacing_owns_swap=%d "
        "hardware_vsync_forced=%d "
        "display_link_snapshot=%d display_link_output_us=%llu "
        "display_link_period_us=%llu flush_return_us=%llu "
        "flush_return_to_output_us=%lld flush_return_phase_us=%lld "
        "frame_pacing_target_hz=%.3f rate=%d windowed=%d "
        "expected_frame_ms=%.3f trace_threshold_ms=%.3f "
        "configured_trace_threshold_ms=%.3f missed_intervals=%d "
        "requested_size=%dx%d",
        elapsedMs, static_cast<int>(error), m_CurrentParams.vsync ? 1 : 0,
        swapInterval, swapsInFlight, fencePacingWait ? 1 : 0,
        fenceTraceEnabled ? 1 : 0,
        fenceCreated ? 1 : 0,
        MacOSOpenGLFenceWaitStatusName(fenceImmediateStatus),
        fenceImmediateMs,
        MacOSOpenGLFenceWaitStatusName(fenceWaitStatus),
        fenceWaitMs,
        static_cast<unsigned long long>(fenceWaitActualUsec),
        static_cast<unsigned long long>(fenceWaitUsec),
        fenceWaitSaturated ? 1 : 0,
        fenceIndicatesGpuBusy ? 1 : 0,
        swapInterval == 0 &&
                EffectiveMacOSFramePacingTargetHz(m_CurrentParams) > 0.0f
            ? 1
            : 0,
        MacOSOpenGLHardwareVsyncForcedEnabled() ? 1 : 0,
        displayLinkSnapshot ? 1 : 0,
        static_cast<unsigned long long>(displayLinkOutputUsec),
        static_cast<unsigned long long>(displayLinkPeriodUsec),
        static_cast<unsigned long long>(flushReturnUsec),
        static_cast<long long>(flushReturnToOutputUsec),
        static_cast<long long>(flushReturnPhaseUsec),
        EffectiveMacOSFramePacingTargetHz(m_CurrentParams),
        m_CurrentParams.rate,
        m_CurrentParams.windowed ? 1 : 0, expectedFrameMs, effectiveTraceMs,
        configuredTraceMs, missedIntervals, m_CurrentParams.width,
        m_CurrentParams.height);
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
