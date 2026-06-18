#include "RageDisplay.h"

#include <algorithm>
#include <climits>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "DisplaySpec.h"
#include "EnumHelper.h"
#include "LocalizedString.h"
#include "LuaManager.h"
#include "ModelTypes.h"
#include "PerfDiagnostics.h"
#include "Preference.h"
#include "RageFile.h"
#include "RageLog.h"
#include "RageMath.h"
#include "RageSurface.h"
#include "RageSurfaceUtils_Zoom.h"
#include "RageSurface_Save_BMP.h"
#include "RageSurface_Save_JPEG.h"
#include "RageSurface_Save_PNG.h"
#include "RageTimer.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "StdString.h"
#include "arch/ArchHooks/ArchHooks.h"
#include "config.hpp"
#include "global.h"

#ifdef HAVE_UNISTD_H
#include <unistd.h>
#endif

#ifdef __APPLE__
#include "arch/LowLevelWindow/MacOSFramePacing.h"

#include <mach/mach_time.h>
#endif

// Statistics stuff
RageTimer g_LastCheckTimer;
int g_iNumVerts;
int g_iFPS, g_iVPF, g_iCFPS;

int RageDisplay::GetFPS() const { return g_iFPS; }
int RageDisplay::GetVPF() const { return g_iVPF; }
int RageDisplay::GetCumFPS() const { return g_iCFPS; }

static int g_iFramesRenderedSinceLastCheck, g_iFramesRenderedSinceLastReset,
    g_iVertsRenderedSinceLastCheck, g_iNumChecksSinceLastReset;
static RageTimer g_LastFrameEndedAt(RageZeroTimer);

struct Centering {
  Centering(
      int iTranslateX = 0, int iTranslateY = 0, int iAddWidth = 0,
      int iAddHeight = 0)
      : m_iTranslateX(iTranslateX),
        m_iTranslateY(iTranslateY),
        m_iAddWidth(iAddWidth),
        m_iAddHeight(iAddHeight) {}

  int m_iTranslateX, m_iTranslateY, m_iAddWidth, m_iAddHeight;
};

static std::vector<Centering> g_CenteringStack(1, Centering(0, 0, 0, 0));

RageDisplay* DISPLAY =
    nullptr;  // global and accessible from anywhere in our program

Preference<bool> LOG_FPS("LogFPS", false);
Preference<float> g_fFrameLimitPercent("FrameLimitPercent", 0.0f);
Preference<float> g_fFramePacingTargetHz("FramePacingTargetHz", 0.0f);
static float g_fFramePacingRuntimeTargetHz = 0.0f;
Preference<float> g_fFramePacingSleepMarginMs(
    "FramePacingSleepMarginMs", 1.0f);
Preference<float> g_fFramePacingMaxSleepChunkMs(
    "FramePacingMaxSleepChunkMs", 1.0f);
Preference<float> g_fFramePacingFineWaitMs("FramePacingFineWaitMs", 0.5f);
Preference<float> g_fFramePacingWaitResyncMs(
    "FramePacingWaitResyncMs", 4.0f);
#ifdef __APPLE__
template<typename T>
struct FixedFramePacingValue {
  explicit constexpr FixedFramePacingValue(T value_) : value(value_) {}
  constexpr T Get() const { return value; }
  const T value;
};

Preference<float> g_fFramePacingMacMaxSpinMs(
    "FramePacingMacMaxSpinMs", 2.0f);
Preference<float> g_fFramePacingMacOSHighRefreshAdaptiveMaxMarginMs(
    "FramePacingMacOSHighRefreshAdaptiveMaxMarginMs", 2.5f);
static constexpr FixedFramePacingValue<float>
    g_fFramePacingMacOSAdaptiveLeadBaseMs(1.5f);
static constexpr FixedFramePacingValue<float>
    g_fFramePacingMacOSAdaptiveLeadMaxMs(2.5f);
static constexpr FixedFramePacingValue<float>
    g_fFramePacingMacOSHighRefreshSwapPressureLeadMaxMs(3.25f);
static constexpr FixedFramePacingValue<int>
    g_iFramePacingMacOSSwapPressureLeadMode(1);
static constexpr FixedFramePacingValue<int>
    g_iFramePacingMacOSSwapPressureTransientFrames(2);
static constexpr FixedFramePacingValue<float>
    g_fFramePacingMacOSAdaptiveLeadStepUpMs(0.25f);
static constexpr FixedFramePacingValue<float>
    g_fFramePacingMacOSAdaptiveLeadStepDownMs(0.25f);
static constexpr FixedFramePacingValue<float>
    g_fFramePacingMacOSAdaptiveLeadWaitCapMs(3.0f);
static constexpr FixedFramePacingValue<float>
    g_fFramePacingMacOSAdaptiveLeadWaitStepDownMs(0.50f);
static constexpr FixedFramePacingValue<int>
    g_iFramePacingMacOSAdaptiveLeadSwapBlockFrames(2);
static constexpr FixedFramePacingValue<int>
    g_iFramePacingMacOSAdaptiveLeadSafeFrames(6);
static constexpr FixedFramePacingValue<int>
    g_iFramePacingMacOSAdaptiveLeadStableFrames(240);
static constexpr FixedFramePacingValue<bool>
    g_bFramePacingMacOSAdaptiveLeadEarlyBackpressure(true);
Preference<float> g_fFramePacingMacOSPreSwapLoadThresholdMs(
    "FramePacingMacOSPreSwapLoadThresholdMs", 6.5f);
#endif
Preference<bool> g_bFramePacingAdaptiveMargin(
    "FramePacingAdaptiveMargin", true);
Preference<float> g_fFramePacingAdaptiveMaxMarginMs(
    "FramePacingAdaptiveMaxMarginMs", 8.0f);
Preference<float> g_fFramePacingAdaptiveStepUpMs(
    "FramePacingAdaptiveStepUpMs", 1.0f);
Preference<float> g_fFramePacingAdaptiveStepDownMs(
    "FramePacingAdaptiveStepDownMs", 0.25f);
Preference<float> g_fFramePacingAdaptiveLateMs(
    "FramePacingAdaptiveLateMs", 4.0f);
Preference<float> g_fFramePacingAdaptiveWakeLateMs(
    "FramePacingAdaptiveWakeLateMs", 4.0f);
Preference<float> g_fFramePacingAdaptiveWakeLateStepUpMs(
    "FramePacingAdaptiveWakeLateStepUpMs", 0.25f);
Preference<float> g_fFramePacingPhaseResyncMs(
    "FramePacingPhaseResyncMs", 8.0f);
Preference<int> g_iFramePacingAdaptiveWarmupFrames(
    "FramePacingAdaptiveWarmupFrames", 45);
Preference<int> g_iFramePacingAdaptiveLateFrames(
    "FramePacingAdaptiveLateFrames", 3);
Preference<int> g_iFramePacingAdaptiveWakeLateFrames(
    "FramePacingAdaptiveWakeLateFrames", 6);
Preference<int> g_iFramePacingAdaptiveStableFrames(
    "FramePacingAdaptiveStableFrames", 180);
Preference<float> g_fPerfTraceFramePacingLateMs(
    "PerfTraceFramePacingLateMs", 8.0f);

namespace {
constexpr float kFramePacingMinWakeLateMs = 4.0f;
#ifdef __APPLE__
constexpr float kFramePacingMacMinFineWaitMs = 4.0f;
#endif

static bool FramePacingSwapLikelyBlocked(
    uint64_t swapBuffersUsec, uint64_t intervalUsec);

static uint64_t g_iFramePacerNextPresentUsec = 0;
static uint64_t g_iFramePacerFrames = 0;
static uint64_t g_iFramePacerLastPresentTraceUsec = 0;
static uint64_t g_iFramePacerLastPlannedWaitUsec = 0;
static uint64_t g_iFramePacerLastSleepUsec = 0;
static uint64_t g_iFramePacerLastActualSleepUsec = 0;
static uint64_t g_iFramePacerLastSleepOvershootUsec = 0;
static uint64_t g_iFramePacerLastFineWaitUsec = 0;
static uint64_t g_iFramePacerLastSpinWaitUsec = 0;
static uint64_t g_iFramePacerLastSpinCapUsec = 0;
static uint64_t g_iFramePacerLastWaitResyncThresholdUsec = 0;
#ifdef __APPLE__
static uint64_t g_iFramePacerLastDisplayLinkPeriodUsec = 0;
static uint64_t g_iFramePacerLastDisplayLinkTickCount = 0;
static uint64_t g_iFramePacerLastDisplayLinkTicksDuringWait = 0;
static uint64_t g_iFramePacerLastDisplayLinkWaitActualUsec = 0;
static uint64_t g_iFramePacerLastDisplayLinkFinalWaitUsec = 0;
static uint64_t g_iFramePacerLastDisplayLinkFinalWaitSleepUsec = 0;
static uint64_t g_iFramePacerLastDisplayLinkFinalWaitYieldUsec = 0;
static uint64_t g_iFramePacerLastDisplayLinkFinalWaitSpinUsec = 0;
static uint64_t g_iFramePacerLastDisplayLinkFinalWaitOvershootUsec = 0;
static int g_iFramePacerLastDisplayLinkFinalWaitSleepChunks = 0;
static int g_iFramePacerLastDisplayLinkFinalWaitYields = 0;
static uint64_t g_iFramePacerLastDisplayLinkPresentLeadUsec = 0;
static uint64_t g_iFramePacerLastDisplayLinkLateToleranceUsec = 0;
static uint64_t g_iFramePacerLastDisplayLinkPhaseToleranceUsec = 0;
static uint64_t g_iFramePacerLastDisplayLinkTargetUsec = 0;
static uint64_t g_iFramePacerLastDisplayLinkDesiredUsec = 0;
static uint64_t g_iFramePacerLastDisplayLinkLatestUsec = 0;
static uint64_t g_iFramePacerLastDisplayLinkLastOutputUsec = 0;
static uint64_t g_iFramePacerLastDisplayLinkSelectedOutputUsec = 0;
static int64_t g_iFramePacerLastDisplayLinkOutputToTargetUsec = 0;
static int64_t g_iFramePacerLastDisplayLinkSelectedOutputToTargetUsec = 0;
static int64_t g_iFramePacerLastDisplayLinkOutputLateUsec = 0;
static bool g_bFramePacerLastDisplayLinkUsed = false;
static bool g_bFramePacerLastDisplayLinkTimedOut = false;
static bool g_bFramePacerLastDisplayLinkFinalWaitCapped = false;
static bool g_bFramePacerLastDisplayLinkOutputPhaseAccepted = false;
static bool g_bFramePacerLastDisplayLinkOutputAlignedPresentEnabled = false;
static bool g_bFramePacerLastDisplayLinkOutputAlignedPresent = false;
static bool g_bFramePacerLastDisplayLinkOutputCapRejected = false;
static int g_iFramePacerLastDisplayLinkOutputAlignedPresentMode = 1;
static bool g_bFramePacerLastDisplayLinkPhaseAligned = false;
static int64_t g_iFramePacerLastDisplayLinkPhaseAlignUsec = 0;
static const char* g_szFramePacerLastDisplayLinkSelectedOutputSource = "none";
static const char* g_szFramePacerLastDisplayLinkStatus = "unavailable";
static uint64_t g_iFramePacerMacOSAdaptiveLeadUsec = 0;
static uint64_t g_iFramePacerLastMacOSAdaptiveLeadBaseUsec = 0;
static uint64_t g_iFramePacerLastMacOSAdaptiveLeadMaxUsec = 0;
static int64_t g_iFramePacerLastMacOSAdaptiveLeadAdjustUsec = 0;
static int g_iFramePacerMacOSSwapBlockStreak = 0;
static int g_iFramePacerMacOSSevereSwapBlockStreak = 0;
static int g_iFramePacerMacOSSwapBlockPressure = 0;
static int g_iFramePacerMacOSWaitOvershootPressure = 0;
static int g_iFramePacerMacOSSwapPressureTransientFrames = 0;
static int g_iFramePacerMacOSLeadStableFrames = 0;
static bool g_bFramePacerMacOSSafeMode = false;
static bool g_bFramePacerLastMacOSEarlySwapBackpressure = false;
static bool g_bFramePacerLastMacOSWaitOvershootPressure = false;
static bool g_bFramePacerLastMacOSPreSwapLoadPressure = false;
static uint64_t g_iFramePacerLastMacOSPreSwapLoadUsec = 0;
static uint64_t g_iFramePacerLastMacOSPreSwapLoadThresholdUsec = 0;
static int g_iFramePacerMacOSPreSwapLoadPressureFrames = 0;
static uint64_t g_iFramePacerLastMacOSWaitCapUsec = 0;
static bool g_bFramePacerLastMacOSAdaptiveLeadChanged = false;
static const char* g_szFramePacerLastMacOSAdaptiveLeadReason = "init";
#endif
static uint64_t g_iFramePacerAdaptiveMarginUsec = 0;
static uint64_t g_iFramePacerLastBaseMarginUsec = 0;
static uint64_t g_iFramePacerLastEffectiveMarginUsec = 0;
static uint64_t g_iFramePacerLastNextMarginUsec = 0;
static uint64_t g_iFramePacerLastWaitMarginUsec = 0;
static uint64_t g_iFramePacerLastMaxMarginUsec = 0;
static uint64_t g_iFramePacerLastSwapBuffersUsec = 0;
static int64_t g_iFramePacerLastAdaptiveAdjustUsec = 0;
static int64_t g_iFramePacerLastLateBeforeUsec = 0;
static int64_t g_iFramePacerLastLateAfterWaitUsec = 0;
static int64_t g_iFramePacerLastWakeLateUsec = 0;
static int64_t g_iFramePacerLastBeforeSwapPhaseErrorUsec = 0;
static int g_iFramePacerLastSleepChunks = 0;
static int g_iFramePacerStableFrames = 0;
static int g_iFramePacerConsecutiveLateFrames = 0;
static int g_iFramePacerConsecutiveWakeLateFrames = 0;
static int g_iFramePacerWarmupFramesRemaining = 0;
static bool g_bFramePacerLoggedEnable = false;
static bool g_bFramePacerWasEnabled = false;
static bool g_bFramePacerLastAdaptiveChanged = false;
static const char* g_szFramePacerLastAdaptiveReason = "init";
static const char* g_szFramePacerLastClassification = "init";
static const char* g_szFramePacerLastBeforeSwapResyncReason = "none";
static const char* g_szFramePacerLastWaitAbortReason = "none";
static const char* g_szFramePacerLastAfterSwapResyncReason = "none";

static float ClampFramePacingHz(float targetHz) {
  if (!std::isfinite(targetHz) || targetHz <= 0.0f) {
    return 0.0f;
  }
  return std::clamp(targetHz, 10.0f, 1000.0f);
}

static float EffectiveFramePacingTargetHz(int fallbackHz) {
  const float runtimeHz = ClampFramePacingHz(g_fFramePacingRuntimeTargetHz);
  if (runtimeHz > 0.0f) {
    return runtimeHz;
  }
  const float configuredHz = ClampFramePacingHz(g_fFramePacingTargetHz.Get());
  if (configuredHz > 0.0f) {
    return configuredHz;
  }
#ifdef __APPLE__
  return fallbackHz > 0
             ? ClampFramePacingHz(static_cast<float>(fallbackHz))
             : 0.0f;
#else
  return 0.0f;
#endif
}

static uint64_t FramePacingIntervalUsec(float targetHz) {
  return static_cast<uint64_t>(
      std::llround(1000000.0 / static_cast<double>(targetHz)));
}

static uint64_t FramePacingMarginUsec(uint64_t intervalUsec) {
  const float marginMs =
      std::max(0.0f, g_fFramePacingSleepMarginMs.Get());
  const uint64_t requestedUsec =
      static_cast<uint64_t>(std::llround(marginMs * 1000.0f));
  return std::min(requestedUsec, intervalUsec / 2);
}

static uint64_t FramePacingAdaptiveMaxMarginUsec(
    uint64_t intervalUsec, uint64_t baseMarginUsec) {
  const float maxMs = g_fFramePacingAdaptiveMaxMarginMs.Get();
  const uint64_t fallbackUsec = 8000;
  uint64_t requestedUsec = fallbackUsec;
  if (std::isfinite(maxMs) && maxMs > 0.0f) {
    requestedUsec =
        static_cast<uint64_t>(std::llround(maxMs * 1000.0f));
  }

#ifdef __APPLE__
  uint64_t intervalCapUsec = (intervalUsec * 3) / 4;
  constexpr uint64_t kHighRefreshIntervalUsec = 11111;  // 90 Hz and above.
  const float highRefreshMaxMs =
      g_fFramePacingMacOSHighRefreshAdaptiveMaxMarginMs.Get();
  if (intervalUsec <= kHighRefreshIntervalUsec &&
      std::isfinite(highRefreshMaxMs) && highRefreshMaxMs > 0.0f) {
    const uint64_t highRefreshCapUsec =
        static_cast<uint64_t>(std::llround(highRefreshMaxMs * 1000.0f));
    intervalCapUsec = std::min(intervalCapUsec, highRefreshCapUsec);
  }
#else
  const uint64_t intervalCapUsec = intervalUsec / 2;
#endif
  const uint64_t maxUsec =
      std::min<uint64_t>(requestedUsec, intervalCapUsec);
  return std::max(baseMarginUsec, maxUsec);
}

static uint64_t FramePacingStepUsec(
    float requestedMs, uint64_t intervalUsec, uint64_t fallbackUsec) {
  if (!std::isfinite(requestedMs) || requestedMs <= 0.0f) {
    return fallbackUsec;
  }

  const uint64_t requestedUsec =
      static_cast<uint64_t>(std::llround(requestedMs * 1000.0f));
  return std::clamp<uint64_t>(requestedUsec, 100, intervalUsec / 4);
}

static uint64_t FramePacingThresholdUsec(
    float requestedMs, uint64_t intervalUsec, uint64_t fallbackUsec,
    uint64_t minimumUsec) {
  uint64_t requestedUsec = fallbackUsec;
  if (std::isfinite(requestedMs) && requestedMs > 0.0f) {
    requestedUsec =
        static_cast<uint64_t>(std::llround(requestedMs * 1000.0f));
  }

  const uint64_t maxUsec = std::max<uint64_t>(minimumUsec, intervalUsec);
  return std::clamp<uint64_t>(requestedUsec, minimumUsec, maxUsec);
}

#ifdef __APPLE__
static uint64_t FramePacingMacOSLeadPreferenceUsec(
    float requestedMs, uint64_t intervalUsec, uint64_t fallbackUsec,
    uint64_t minimumUsec, uint64_t maximumUsec) {
  uint64_t requestedUsec = fallbackUsec;
  if (std::isfinite(requestedMs) && requestedMs >= 0.0f) {
    requestedUsec =
        static_cast<uint64_t>(std::llround(requestedMs * 1000.0f));
  }
  return std::clamp<uint64_t>(
      requestedUsec, minimumUsec, std::max(minimumUsec, maximumUsec));
}

static uint64_t FramePacingMacOSAdaptiveLeadBaseUsec(
    uint64_t intervalUsec) {
  return FramePacingMacOSLeadPreferenceUsec(
      g_fFramePacingMacOSAdaptiveLeadBaseMs.Get(), intervalUsec, 2000, 0,
      std::max<uint64_t>(500, intervalUsec / 2));
}

static uint64_t FramePacingMacOSAdaptiveLeadMaxUsec(
    uint64_t intervalUsec, uint64_t baseLeadUsec) {
  uint64_t requestedMaxUsec =
      FramePacingMacOSLeadPreferenceUsec(
          g_fFramePacingMacOSAdaptiveLeadMaxMs.Get(), intervalUsec, 2500,
          baseLeadUsec, std::max<uint64_t>(baseLeadUsec, intervalUsec));

  constexpr uint64_t kHighRefreshIntervalUsec = 11111;  // 90 Hz and above.
  const float pressureMaxMs =
      g_fFramePacingMacOSHighRefreshSwapPressureLeadMaxMs.Get();
  if (intervalUsec <= kHighRefreshIntervalUsec &&
      std::isfinite(pressureMaxMs) && pressureMaxMs > 0.0f) {
    const uint64_t pressureMaxUsec =
        FramePacingMacOSLeadPreferenceUsec(
            pressureMaxMs, intervalUsec, 5500, baseLeadUsec,
            std::max<uint64_t>(baseLeadUsec, (intervalUsec * 3) / 4));
    requestedMaxUsec = std::max(requestedMaxUsec, pressureMaxUsec);
  }

  const uint64_t leadCapUsec =
      std::max<uint64_t>(baseLeadUsec, (intervalUsec * 3) / 4);
  requestedMaxUsec = std::min<uint64_t>(requestedMaxUsec, leadCapUsec);
  return std::clamp<uint64_t>(
      requestedMaxUsec, baseLeadUsec, leadCapUsec);
}

static uint64_t FramePacingMacOSAdaptiveLeadStepUpUsec(
    uint64_t intervalUsec) {
  return FramePacingMacOSLeadPreferenceUsec(
      g_fFramePacingMacOSAdaptiveLeadStepUpMs.Get(), intervalUsec, 250, 100,
      std::max<uint64_t>(100, intervalUsec / 4));
}

static uint64_t FramePacingMacOSAdaptiveLeadStepDownUsec(
    uint64_t intervalUsec) {
  return FramePacingMacOSLeadPreferenceUsec(
      g_fFramePacingMacOSAdaptiveLeadStepDownMs.Get(), intervalUsec, 250, 50,
      std::max<uint64_t>(50, intervalUsec / 8));
}

static int FramePacingMacOSSwapPressureLeadMode() {
  // Mode 2 was useful diagnostically, but it made compositor-bound stalls worse
  // on macOS/OpenGL by presenting too early into the compositor phase. Keep the
  // controller conservative on the known-good baseline.
  return std::clamp(g_iFramePacingMacOSSwapPressureLeadMode.Get(), 1, 1);
}

static bool FramePacingMacOSAdaptiveLeadEnabled() {
  // Local Preferences.ini can carry stale diagnostic values from previous
  // experiments. Use a fixed low lead on the known-good macOS/OpenGL baseline.
  return false;
}

static int FramePacingMacOSSwapPressureTransientFrames() {
  return std::clamp(
      g_iFramePacingMacOSSwapPressureTransientFrames.Get(), 1, 30);
}

static uint64_t FramePacingMacOSAdaptiveLeadWaitCapUsec(
    uint64_t intervalUsec, uint64_t baseLeadUsec, uint64_t maxLeadUsec) {
  return FramePacingMacOSLeadPreferenceUsec(
      g_fFramePacingMacOSAdaptiveLeadWaitCapMs.Get(), intervalUsec, 6000,
      baseLeadUsec, maxLeadUsec);
}

static uint64_t FramePacingMacOSAdaptiveLeadWaitStepDownUsec(
    uint64_t intervalUsec) {
  return FramePacingMacOSLeadPreferenceUsec(
      g_fFramePacingMacOSAdaptiveLeadWaitStepDownMs.Get(), intervalUsec, 500,
      100, std::max<uint64_t>(100, intervalUsec / 4));
}

static int FramePacingMacOSAdaptiveLeadSwapBlockFrames() {
  return std::clamp(
      g_iFramePacingMacOSAdaptiveLeadSwapBlockFrames.Get(), 1, 30);
}

static int FramePacingMacOSAdaptiveLeadSafeFrames() {
  return std::clamp(
      g_iFramePacingMacOSAdaptiveLeadSafeFrames.Get(), 2, 120);
}

static int FramePacingMacOSAdaptiveLeadStableFrames() {
  return std::clamp(
      g_iFramePacingMacOSAdaptiveLeadStableFrames.Get(), 30, 3600);
}

static uint64_t FramePacingMacOSPreSwapLoadThresholdUsec(
    uint64_t intervalUsec) {
  const float requestedMs = g_fFramePacingMacOSPreSwapLoadThresholdMs.Get();
  const uint64_t fallbackUsec =
      intervalUsec > 0 ? (intervalUsec * 78) / 100 : 6500;
  if (!std::isfinite(requestedMs) || requestedMs <= 0.0f) {
    return fallbackUsec;
  }

  const uint64_t requestedUsec =
      static_cast<uint64_t>(std::llround(requestedMs * 1000.0f));
  const uint64_t minUsec = std::max<uint64_t>(1000, intervalUsec / 2);
  return std::clamp<uint64_t>(requestedUsec, minUsec, intervalUsec);
}

static uint64_t FramePacingMacOSRiskySwapThresholdUsec(
    uint64_t intervalUsec) {
  if (intervalUsec == 0) {
    return 0;
  }

  return intervalUsec + std::max<uint64_t>(1000, intervalUsec / 5);
}

static uint64_t FramePacingMacOSSevereSwapThresholdUsec(
    uint64_t intervalUsec) {
  if (intervalUsec == 0) {
    return 0;
  }

  return intervalUsec + std::max<uint64_t>(1500, intervalUsec / 3);
}

static bool FramePacingMacOSRiskySwapBlocked(
    uint64_t swapBuffersUsec, uint64_t intervalUsec) {
  return intervalUsec > 0 && swapBuffersUsec >=
                                FramePacingMacOSRiskySwapThresholdUsec(
                                    intervalUsec);
}

static bool FramePacingMacOSSevereSwapBlocked(
    uint64_t swapBuffersUsec, uint64_t intervalUsec) {
  return intervalUsec > 0 && swapBuffersUsec >=
                                FramePacingMacOSSevereSwapThresholdUsec(
                                    intervalUsec);
}

static bool FramePacingMacOSEarlySwapBackpressure(
    uint64_t swapBuffersUsec, uint64_t intervalUsec) {
  return g_bFramePacingMacOSAdaptiveLeadEarlyBackpressure.Get() &&
         FramePacingSwapLikelyBlocked(swapBuffersUsec, intervalUsec) &&
         g_bFramePacerLastDisplayLinkUsed &&
         g_bFramePacerLastDisplayLinkOutputPhaseAccepted &&
         g_iFramePacerLastDisplayLinkOutputLateUsec <
             -static_cast<int64_t>(
                 std::max<uint64_t>(1000, intervalUsec / 4));
}

static uint64_t FramePacingMacOSAdaptiveLeadUsec(
    uint64_t intervalUsec) {
  const uint64_t baseLeadUsec =
      FramePacingMacOSAdaptiveLeadBaseUsec(intervalUsec);
  const uint64_t maxLeadUsec =
      FramePacingMacOSAdaptiveLeadMaxUsec(intervalUsec, baseLeadUsec);
  g_iFramePacerLastMacOSAdaptiveLeadBaseUsec = baseLeadUsec;
  g_iFramePacerLastMacOSAdaptiveLeadMaxUsec = maxLeadUsec;

  if (!FramePacingMacOSAdaptiveLeadEnabled()) {
    g_iFramePacerMacOSAdaptiveLeadUsec = baseLeadUsec;
    g_iFramePacerLastMacOSAdaptiveLeadAdjustUsec = 0;
    g_bFramePacerLastMacOSAdaptiveLeadChanged = false;
    g_szFramePacerLastMacOSAdaptiveLeadReason = "disabled";
    g_bFramePacerMacOSSafeMode = false;
    return baseLeadUsec;
  }

  if (g_iFramePacerMacOSAdaptiveLeadUsec == 0) {
    g_iFramePacerMacOSAdaptiveLeadUsec = baseLeadUsec;
  }
  g_iFramePacerMacOSAdaptiveLeadUsec = std::clamp<uint64_t>(
      g_iFramePacerMacOSAdaptiveLeadUsec, baseLeadUsec, maxLeadUsec);
  return g_iFramePacerMacOSAdaptiveLeadUsec;
}
#endif

static uint64_t FramePacingAdaptiveStepUpUsec(uint64_t intervalUsec) {
  return FramePacingStepUsec(
      g_fFramePacingAdaptiveStepUpMs.Get(), intervalUsec, 1000);
}

static uint64_t FramePacingAdaptiveStepDownUsec(uint64_t intervalUsec) {
  return FramePacingStepUsec(
      g_fFramePacingAdaptiveStepDownMs.Get(), intervalUsec, 250);
}

static uint64_t FramePacingAdaptiveWakeLateStepUpUsec(
    uint64_t intervalUsec) {
  return FramePacingStepUsec(
      g_fFramePacingAdaptiveWakeLateStepUpMs.Get(), intervalUsec, 250);
}

static uint64_t FramePacingAdaptiveLateThresholdUsec(
    uint64_t intervalUsec) {
  return FramePacingThresholdUsec(
      g_fFramePacingAdaptiveLateMs.Get(), intervalUsec, 4000, 1000);
}

static uint64_t FramePacingAdaptiveWakeLateThresholdUsec(
    uint64_t intervalUsec) {
  const float effectiveWakeLateMs =
      std::max(g_fFramePacingAdaptiveWakeLateMs.Get(),
               kFramePacingMinWakeLateMs);
  const uint64_t minimumUsec =
      static_cast<uint64_t>(
          std::llround(kFramePacingMinWakeLateMs * 1000.0f));
  return FramePacingThresholdUsec(
      effectiveWakeLateMs, intervalUsec, minimumUsec, minimumUsec);
}

static uint64_t FramePacingPhaseResyncThresholdUsec(uint64_t intervalUsec) {
  const float requestedMs = g_fFramePacingPhaseResyncMs.Get();
  const uint64_t fallbackUsec =
      std::max<uint64_t>(4000, (intervalUsec * 3) / 4);
  if (!std::isfinite(requestedMs) || requestedMs <= 0.0f) {
    return fallbackUsec;
  }

  const uint64_t requestedUsec =
      static_cast<uint64_t>(std::llround(requestedMs * 1000.0f));
  const uint64_t maxUsec = std::max(fallbackUsec, intervalUsec * 2);
  return std::clamp<uint64_t>(
      requestedUsec, fallbackUsec, maxUsec);
}

static int FramePacingAdaptiveWarmupFrames() {
  return std::clamp(g_iFramePacingAdaptiveWarmupFrames.Get(), 0, 600);
}

static int FramePacingAdaptiveLateFrames() {
  return std::clamp(g_iFramePacingAdaptiveLateFrames.Get(), 1, 30);
}

static int FramePacingAdaptiveWakeLateFrames() {
  return std::clamp(g_iFramePacingAdaptiveWakeLateFrames.Get(), 1, 60);
}

static int FramePacingAdaptiveStableFrames() {
  return std::clamp(g_iFramePacingAdaptiveStableFrames.Get(), 30, 1800);
}

static uint64_t FramePacingEffectiveMarginUsec(uint64_t intervalUsec) {
  const uint64_t baseMarginUsec = FramePacingMarginUsec(intervalUsec);
  const uint64_t maxMarginUsec =
      FramePacingAdaptiveMaxMarginUsec(intervalUsec, baseMarginUsec);
  g_iFramePacerLastBaseMarginUsec = baseMarginUsec;
  g_iFramePacerLastMaxMarginUsec = maxMarginUsec;

  if (!g_bFramePacingAdaptiveMargin.Get()) {
    g_iFramePacerAdaptiveMarginUsec = baseMarginUsec;
    uint64_t effectiveMarginUsec = baseMarginUsec;
#ifdef __APPLE__
    effectiveMarginUsec = std::max<uint64_t>(
        effectiveMarginUsec,
        FramePacingMacOSAdaptiveLeadUsec(intervalUsec));
    effectiveMarginUsec =
        std::min<uint64_t>(effectiveMarginUsec, maxMarginUsec);
#endif
    g_iFramePacerLastEffectiveMarginUsec = effectiveMarginUsec;
    g_iFramePacerLastNextMarginUsec = effectiveMarginUsec;
    return effectiveMarginUsec;
  }

  if (g_iFramePacerAdaptiveMarginUsec == 0) {
    g_iFramePacerAdaptiveMarginUsec = baseMarginUsec;
  }
  g_iFramePacerAdaptiveMarginUsec = std::clamp<uint64_t>(
      g_iFramePacerAdaptiveMarginUsec, baseMarginUsec, maxMarginUsec);
  uint64_t effectiveMarginUsec = g_iFramePacerAdaptiveMarginUsec;
#ifdef __APPLE__
  effectiveMarginUsec = std::max<uint64_t>(
      effectiveMarginUsec,
      FramePacingMacOSAdaptiveLeadUsec(intervalUsec));
  effectiveMarginUsec =
      std::min<uint64_t>(effectiveMarginUsec, maxMarginUsec);
#endif
  g_iFramePacerLastEffectiveMarginUsec = effectiveMarginUsec;
  g_iFramePacerLastNextMarginUsec = effectiveMarginUsec;
  return effectiveMarginUsec;
}

static uint64_t FramePacingMaxSleepChunkUsec(uint64_t intervalUsec) {
  const float chunkMs = g_fFramePacingMaxSleepChunkMs.Get();
  const uint64_t fallbackUsec = 1000;
  if (!std::isfinite(chunkMs) || chunkMs <= 0.0f) {
    return fallbackUsec;
  }

  const uint64_t requestedUsec =
      static_cast<uint64_t>(std::llround(chunkMs * 1000.0f));
  return std::clamp<uint64_t>(requestedUsec, 100, intervalUsec / 2);
}

static uint64_t FramePacingFineWaitUsec(uint64_t intervalUsec) {
  float fineMs = g_fFramePacingFineWaitMs.Get();
#ifdef __APPLE__
  fineMs = std::max(fineMs, kFramePacingMacMinFineWaitMs);
#endif
  const uint64_t fallbackUsec = 500;
  if (!std::isfinite(fineMs) || fineMs <= 0.0f) {
    return fallbackUsec;
  }

  const uint64_t requestedUsec =
      static_cast<uint64_t>(std::llround(fineMs * 1000.0f));
  return std::clamp<uint64_t>(requestedUsec, 100, intervalUsec / 4);
}

static uint64_t FramePacingWaitResyncThresholdUsec(uint64_t intervalUsec) {
  return FramePacingThresholdUsec(
      g_fFramePacingWaitResyncMs.Get(), intervalUsec, 4000, 1000);
}

static uint64_t FramePacingMaxSpinUsec(uint64_t fineWaitUsec) {
#ifdef __APPLE__
  const float spinMs = g_fFramePacingMacMaxSpinMs.Get();
  uint64_t requestedUsec = 2000;
  if (std::isfinite(spinMs) && spinMs > 0.0f) {
    requestedUsec =
        static_cast<uint64_t>(std::llround(spinMs * 1000.0f));
  }
  return std::clamp<uint64_t>(
      requestedUsec, 100, std::max<uint64_t>(100, fineWaitUsec));
#else
  (void)fineWaitUsec;
  return 200;
#endif
}

static uint64_t FramePacingResyncThresholdUsec(uint64_t intervalUsec) {
  return intervalUsec * 4;
}

static bool FramePacingSwapLikelyBlocked(
    uint64_t swapBuffersUsec, uint64_t intervalUsec) {
  if (swapBuffersUsec == 0 || intervalUsec == 0) {
    return false;
  }

  const uint64_t nearIntervalUsec =
      intervalUsec > 1000 ? intervalUsec - 1000 : intervalUsec;
  return swapBuffersUsec >= nearIntervalUsec;
}

static const char* ClassifyFramePacing(
    int64_t presentLateUsec, int64_t wakeLateUsec, uint64_t swapBuffersUsec,
    uint64_t sleepOvershootUsec, uint64_t intervalUsec, int skippedIntervals,
    bool hardResynced, bool phaseResynced) {
  if (FramePacingSwapLikelyBlocked(swapBuffersUsec, intervalUsec)) {
    return "swap_block";
  }
  if (hardResynced || skippedIntervals > 0) {
    return "phase_skip";
  }
  if (phaseResynced ||
      presentLateUsec >
          static_cast<int64_t>(FramePacingPhaseResyncThresholdUsec(
              intervalUsec))) {
    return "present_phase_late";
  }
  if (presentLateUsec >
      static_cast<int64_t>(FramePacingAdaptiveLateThresholdUsec(
          intervalUsec))) {
    return "present_late";
  }
  if (wakeLateUsec >
      static_cast<int64_t>(FramePacingAdaptiveWakeLateThresholdUsec(
          intervalUsec))) {
    return "pacing_wake_late";
  }
  if (sleepOvershootUsec >
      FramePacingAdaptiveWakeLateThresholdUsec(intervalUsec)) {
    return "sleep_overshoot";
  }
  return "stable";
}

static const char* FramePacingWaitStrategyName() {
#ifdef __APPLE__
  if (MacOSFramePacingDisplayLinkEnabled()) {
    return "macos_cvdisplaylink";
  }
  return "macos_chunked_absolute_bounded_spin";
#else
  return "chunked_sleep";
#endif
}

struct FramePacingWaitStats {
  uint64_t requested_sleep_usec = 0;
  uint64_t actual_sleep_usec = 0;
  uint64_t sleep_overshoot_usec = 0;
  uint64_t fine_wait_usec = 0;
  uint64_t spin_wait_usec = 0;
  uint64_t spin_cap_usec = 0;
  const char* abort_reason = "none";
  int sleep_chunks = 0;
#ifdef __APPLE__
  bool display_link_used = false;
  bool display_link_timed_out = false;
  uint64_t display_link_tick_count = 0;
  uint64_t display_link_ticks_during_wait = 0;
  uint64_t display_link_period_usec = 0;
  uint64_t display_link_wait_actual_usec = 0;
  uint64_t display_link_final_wait_usec = 0;
  uint64_t display_link_final_wait_sleep_usec = 0;
  uint64_t display_link_final_wait_yield_usec = 0;
  uint64_t display_link_final_wait_spin_usec = 0;
  uint64_t display_link_final_wait_overshoot_usec = 0;
  int display_link_final_wait_sleep_chunks = 0;
  int display_link_final_wait_yields = 0;
  uint64_t display_link_present_lead_usec = 0;
  uint64_t display_link_late_tolerance_usec = 0;
  uint64_t display_link_phase_tolerance_usec = 0;
  uint64_t display_link_target_usec = 0;
  uint64_t display_link_desired_usec = 0;
  uint64_t display_link_latest_usec = 0;
  uint64_t display_link_last_output_usec = 0;
  uint64_t display_link_selected_output_usec = 0;
  int64_t display_link_output_to_target_usec = 0;
  int64_t display_link_selected_output_to_target_usec = 0;
  int64_t display_link_output_late_usec = 0;
  bool display_link_final_wait_capped = false;
  bool display_link_output_phase_accepted = false;
  int display_link_output_aligned_present_mode = 1;
  bool display_link_output_aligned_present_enabled = false;
  bool display_link_output_aligned_present = false;
  bool display_link_output_cap_rejected = false;
  const char* display_link_selected_output_source = "none";
  const char* display_link_status = "unavailable";
#endif
};

static void FramePacingSleepUsec(uint64_t usec) {
  if (usec == 0) {
    return;
  }

  usleep(static_cast<unsigned int>(std::min<uint64_t>(usec, 1000000)));
}

static void FramePacingWaitUntilUsec(uint64_t targetUsec) {
  const uint64_t nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
  if (targetUsec <= nowUsec) {
    return;
  }

#ifdef __APPLE__
  static mach_timebase_info_data_t timebase = {0, 0};
  if (timebase.denom == 0) {
    mach_timebase_info(&timebase);
  }
  if (timebase.numer == 0 || timebase.denom == 0) {
    FramePacingSleepUsec(targetUsec - nowUsec);
    return;
  }

  const uint64_t remainingUsec = targetUsec - nowUsec;
  const double ticks =
      static_cast<double>(remainingUsec) * 1000.0 *
      static_cast<double>(timebase.denom) /
      static_cast<double>(timebase.numer);
  mach_wait_until(
      mach_absolute_time() +
      std::max<uint64_t>(1, static_cast<uint64_t>(std::llround(ticks))));
#else
  FramePacingSleepUsec(targetUsec - nowUsec);
#endif
}

static FramePacingWaitStats WaitUntilFramePacingWakeUsec(
    uint64_t wakeUsec, uint64_t targetPresentUsec, uint64_t intervalUsec,
    uint64_t fineWaitUsec, uint64_t maxSleepChunkUsec, bool appHasFocus,
    uint64_t macOSPresentLeadUsec) {
  FramePacingWaitStats stats;
  uint64_t nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
#ifndef __APPLE__
  (void)macOSPresentLeadUsec;
#endif

  if (!appHasFocus) {
    if (wakeUsec > nowUsec) {
      const uint64_t requestedUsec =
          std::max<uint64_t>(wakeUsec - nowUsec, 10000);
      const uint64_t sleepStartUsec = nowUsec;
      FramePacingWaitUntilUsec(nowUsec + requestedUsec);
      nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
      stats.requested_sleep_usec = requestedUsec;
      stats.actual_sleep_usec = nowUsec - sleepStartUsec;
      stats.sleep_chunks = 1;
    }
  } else {
#ifdef __APPLE__
    MacOSFramePacingDisplayLinkStats displayLinkStats;
    if (MacOSFramePacingWaitForDisplayLink(
            targetPresentUsec, intervalUsec, appHasFocus,
            macOSPresentLeadUsec,
            &displayLinkStats)) {
      stats.display_link_used = true;
      stats.display_link_timed_out = displayLinkStats.timed_out;
      stats.display_link_tick_count = displayLinkStats.tick_count;
      stats.display_link_ticks_during_wait =
          displayLinkStats.ticks_during_wait;
      stats.display_link_period_usec = displayLinkStats.period_usec;
      stats.display_link_wait_actual_usec =
          displayLinkStats.wait_actual_usec;
      stats.display_link_final_wait_usec =
          displayLinkStats.final_wait_usec;
      stats.display_link_final_wait_sleep_usec =
          displayLinkStats.final_wait_sleep_usec;
      stats.display_link_final_wait_yield_usec =
          displayLinkStats.final_wait_yield_usec;
      stats.display_link_final_wait_spin_usec =
          displayLinkStats.final_wait_spin_usec;
      stats.display_link_final_wait_overshoot_usec =
          displayLinkStats.final_wait_overshoot_usec;
      stats.display_link_final_wait_sleep_chunks =
          displayLinkStats.final_wait_sleep_chunks;
      stats.display_link_final_wait_yields =
          displayLinkStats.final_wait_yields;
      stats.display_link_present_lead_usec =
          displayLinkStats.present_lead_usec;
      stats.display_link_late_tolerance_usec =
          displayLinkStats.late_tolerance_usec;
      stats.display_link_phase_tolerance_usec =
          displayLinkStats.phase_tolerance_usec;
      stats.display_link_target_usec = displayLinkStats.target_present_usec;
      stats.display_link_desired_usec =
          displayLinkStats.desired_present_usec;
      stats.display_link_latest_usec =
          displayLinkStats.latest_present_usec;
      stats.display_link_last_output_usec =
          displayLinkStats.last_output_usec;
      stats.display_link_selected_output_usec =
          displayLinkStats.selected_output_usec;
      stats.display_link_output_to_target_usec =
          displayLinkStats.output_to_target_usec;
      stats.display_link_selected_output_to_target_usec =
          displayLinkStats.selected_output_to_target_usec;
      stats.display_link_output_late_usec =
          displayLinkStats.output_late_usec;
      stats.display_link_final_wait_capped =
          displayLinkStats.final_wait_capped;
      stats.display_link_output_phase_accepted =
          displayLinkStats.output_phase_accepted;
      stats.display_link_output_aligned_present_mode =
          displayLinkStats.output_aligned_present_mode;
      stats.display_link_output_aligned_present_enabled =
          displayLinkStats.output_aligned_present_enabled;
      stats.display_link_output_aligned_present =
          displayLinkStats.output_aligned_present;
      stats.display_link_output_cap_rejected =
          displayLinkStats.output_aligned_cap_rejected;
      stats.display_link_selected_output_source =
          displayLinkStats.selected_output_source;
      stats.display_link_status = displayLinkStats.status;
      stats.requested_sleep_usec = displayLinkStats.wait_requested_usec;
      stats.actual_sleep_usec = displayLinkStats.wait_actual_usec;
      stats.sleep_chunks = static_cast<int>(
          std::min<uint64_t>(displayLinkStats.ticks_during_wait,
                             static_cast<uint64_t>(INT_MAX)));
      stats.abort_reason =
          displayLinkStats.timed_out ? "display_link_timeout" : "none";
      if (stats.actual_sleep_usec > stats.requested_sleep_usec) {
        stats.sleep_overshoot_usec =
            stats.actual_sleep_usec - stats.requested_sleep_usec;
      }
      return stats;
    }
#endif
    const uint64_t maxSpinUsec = FramePacingMaxSpinUsec(fineWaitUsec);
    stats.spin_cap_usec = maxSpinUsec;

#ifdef __APPLE__
    while (nowUsec < wakeUsec) {
      const uint64_t remainingUsec = wakeUsec - nowUsec;
      const uint64_t yieldWindowUsec = std::min<uint64_t>(
          intervalUsec,
          std::max<uint64_t>(5000, fineWaitUsec + maxSpinUsec));
      const uint64_t sleepChunkUsec =
          std::min<uint64_t>(maxSleepChunkUsec, 500);

      if (remainingUsec > yieldWindowUsec) {
        const uint64_t requestedUsec =
            std::min(remainingUsec - yieldWindowUsec, sleepChunkUsec);
        const uint64_t sleepStartUsec = nowUsec;
        FramePacingWaitUntilUsec(sleepStartUsec + requestedUsec);
        nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
        stats.requested_sleep_usec += requestedUsec;
        stats.actual_sleep_usec += nowUsec - sleepStartUsec;
        ++stats.sleep_chunks;

        if (nowUsec >= wakeUsec) {
          stats.abort_reason = "sleep_overshoot";
          break;
        }
        continue;
      }

      if (remainingUsec > maxSpinUsec) {
        const uint64_t yieldStartUsec = nowUsec;
        std::this_thread::yield();
        nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
        stats.fine_wait_usec += nowUsec - yieldStartUsec;

        if (nowUsec >= wakeUsec) {
          stats.abort_reason = "yield_overshoot";
          break;
        }
        continue;
      }

      const uint64_t spinStartUsec = nowUsec;
      do {
        nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
      } while (
          nowUsec < wakeUsec &&
          nowUsec - spinStartUsec < maxSpinUsec);
      stats.spin_wait_usec += nowUsec - spinStartUsec;

      if (nowUsec < wakeUsec) {
        stats.abort_reason = "spin_cap";
      } else if (nowUsec - spinStartUsec > maxSpinUsec) {
        stats.abort_reason = "spin_preempted";
      }
      break;
    }
#else
    constexpr uint64_t kBusySpinWindowUsec = 200;
    while (nowUsec < wakeUsec) {
      const uint64_t remainingUsec = wakeUsec - nowUsec;

      if (remainingUsec > fineWaitUsec) {
        const uint64_t requestedUsec =
            std::min(remainingUsec - fineWaitUsec, maxSleepChunkUsec);
        const uint64_t sleepStartUsec = nowUsec;
        FramePacingWaitUntilUsec(nowUsec + requestedUsec);
        nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
        stats.requested_sleep_usec += requestedUsec;
        stats.actual_sleep_usec += nowUsec - sleepStartUsec;
        ++stats.sleep_chunks;
        continue;
      }

      if (remainingUsec > kBusySpinWindowUsec) {
        const uint64_t yieldStartUsec = nowUsec;
        std::this_thread::yield();
        nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
        stats.fine_wait_usec += nowUsec - yieldStartUsec;
        continue;
      }

      const uint64_t spinStartUsec = nowUsec;
      do {
        nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
      } while (nowUsec < wakeUsec);
      stats.spin_wait_usec += nowUsec - spinStartUsec;
      break;
    }
#endif
  }

  if (stats.actual_sleep_usec > stats.requested_sleep_usec) {
    stats.sleep_overshoot_usec =
        stats.actual_sleep_usec - stats.requested_sleep_usec;
  }

  return stats;
}

static uint64_t FramePacingSwapBuffersUsec(float swapBuffersMs) {
  if (!std::isfinite(swapBuffersMs) || swapBuffersMs < 0.0f) {
    return 0;
  }

  return static_cast<uint64_t>(std::llround(swapBuffersMs * 1000.0f));
}

static void UpdateFramePacingAdaptiveMargin(
    uint64_t intervalUsec, int64_t presentLateUsec, int skippedIntervals,
    bool hardResynced, bool phaseResynced, uint64_t swapBuffersUsec) {
  const uint64_t baseMarginUsec = FramePacingMarginUsec(intervalUsec);
  const uint64_t maxMarginUsec =
      FramePacingAdaptiveMaxMarginUsec(intervalUsec, baseMarginUsec);
  const uint64_t lateThresholdUsec =
      FramePacingAdaptiveLateThresholdUsec(intervalUsec);
  const uint64_t wakeLateThresholdUsec =
      FramePacingAdaptiveWakeLateThresholdUsec(intervalUsec);
  const uint64_t stepUpUsec =
      FramePacingAdaptiveStepUpUsec(intervalUsec);
  const uint64_t wakeLateStepUpUsec =
      FramePacingAdaptiveWakeLateStepUpUsec(intervalUsec);
  const uint64_t stepDownUsec =
      FramePacingAdaptiveStepDownUsec(intervalUsec);
  const int64_t positivePresentLateUsec =
      std::max<int64_t>(presentLateUsec, 0);
  const int64_t positiveWakeLateUsec =
      std::max<int64_t>(g_iFramePacerLastWakeLateUsec, 0);

  g_iFramePacerLastSwapBuffersUsec = swapBuffersUsec;
  g_iFramePacerLastBaseMarginUsec = baseMarginUsec;
  g_iFramePacerLastMaxMarginUsec = maxMarginUsec;
  g_iFramePacerLastAdaptiveAdjustUsec = 0;
  g_bFramePacerLastAdaptiveChanged = false;
  g_szFramePacerLastAdaptiveReason = "stable";
  g_szFramePacerLastClassification = ClassifyFramePacing(
      presentLateUsec, g_iFramePacerLastWakeLateUsec, swapBuffersUsec,
      g_iFramePacerLastSleepOvershootUsec, intervalUsec, skippedIntervals,
      hardResynced, phaseResynced);

  if (!g_bFramePacingAdaptiveMargin.Get()) {
    g_iFramePacerAdaptiveMarginUsec = baseMarginUsec;
    g_iFramePacerLastNextMarginUsec = baseMarginUsec;
    g_iFramePacerStableFrames = 0;
    g_iFramePacerConsecutiveLateFrames = 0;
    g_iFramePacerConsecutiveWakeLateFrames = 0;
    g_szFramePacerLastAdaptiveReason = "disabled";
    return;
  }

  if (g_iFramePacerAdaptiveMarginUsec == 0) {
    g_iFramePacerAdaptiveMarginUsec = baseMarginUsec;
  }
  g_iFramePacerAdaptiveMarginUsec = std::clamp<uint64_t>(
      g_iFramePacerAdaptiveMarginUsec, baseMarginUsec, maxMarginUsec);

  const uint64_t oldMarginUsec = g_iFramePacerAdaptiveMarginUsec;
  if (g_iFramePacerWarmupFramesRemaining > 0) {
    --g_iFramePacerWarmupFramesRemaining;
    g_iFramePacerStableFrames = 0;
    g_iFramePacerConsecutiveLateFrames = 0;
    g_iFramePacerConsecutiveWakeLateFrames = 0;
    g_iFramePacerLastNextMarginUsec = g_iFramePacerAdaptiveMarginUsec;
    g_szFramePacerLastAdaptiveReason = "warmup";
    return;
  }

  const bool missedPresent = skippedIntervals > 0 || hardResynced;
  const bool presentLate =
      positivePresentLateUsec > static_cast<int64_t>(lateThresholdUsec);
  const bool wakeLate =
      positiveWakeLateUsec > static_cast<int64_t>(wakeLateThresholdUsec);
  const bool phaseLate = phaseResynced;
  const bool swapLikelyBlocked =
      FramePacingSwapLikelyBlocked(swapBuffersUsec, intervalUsec);
  const bool severeLate =
      missedPresent ||
      positivePresentLateUsec > static_cast<int64_t>(intervalUsec) ||
      swapBuffersUsec > intervalUsec;
  const bool wakeLateStillPresentedOnTime =
      wakeLate && positivePresentLateUsec == 0;
  const bool wakeLateActionable =
      wakeLate && !wakeLateStillPresentedOnTime;
  const bool hardLateThisFrame =
      missedPresent || phaseLate || presentLate || swapLikelyBlocked;
  const bool lateThisFrame = hardLateThisFrame || wakeLateActionable;

  if (hardLateThisFrame) {
    ++g_iFramePacerConsecutiveLateFrames;
  } else {
    g_iFramePacerConsecutiveLateFrames = 0;
  }

  if (wakeLateActionable) {
    ++g_iFramePacerConsecutiveWakeLateFrames;
  } else {
    g_iFramePacerConsecutiveWakeLateFrames = 0;
  }

  const bool onlyWakeLateActionable =
      wakeLateActionable && !missedPresent && !phaseLate && !presentLate &&
      !swapLikelyBlocked;
  const bool wakeLateStreakReady =
      onlyWakeLateActionable &&
      g_iFramePacerConsecutiveWakeLateFrames >=
          FramePacingAdaptiveWakeLateFrames();
  const bool shouldIncrease =
      severeLate ||
      g_iFramePacerConsecutiveLateFrames >= FramePacingAdaptiveLateFrames() ||
      wakeLateStreakReady;

  if (shouldIncrease) {
    uint64_t targetMarginUsec =
        std::min(
            maxMarginUsec,
            oldMarginUsec +
                (onlyWakeLateActionable ? wakeLateStepUpUsec : stepUpUsec));

    if (missedPresent) {
      targetMarginUsec = std::min<uint64_t>(
          maxMarginUsec,
          targetMarginUsec +
              stepUpUsec * static_cast<uint64_t>(
                                std::clamp(skippedIntervals, 1, 3)));
    }
    if (phaseLate || presentLate) {
      targetMarginUsec =
          std::min<uint64_t>(maxMarginUsec, targetMarginUsec + stepUpUsec);
    }
    if (wakeLate && !onlyWakeLateActionable) {
      targetMarginUsec =
          std::min<uint64_t>(maxMarginUsec, targetMarginUsec + stepUpUsec);
    }
    if (swapLikelyBlocked) {
      targetMarginUsec =
          std::min<uint64_t>(maxMarginUsec, targetMarginUsec + stepUpUsec);
    }

    g_iFramePacerAdaptiveMarginUsec =
        std::clamp<uint64_t>(targetMarginUsec, baseMarginUsec, maxMarginUsec);
    g_iFramePacerStableFrames = 0;
    g_szFramePacerLastAdaptiveReason =
        missedPresent       ? "missed_present"
        : phaseLate         ? "phase_late"
        : swapLikelyBlocked ? "swap_block"
        : presentLate       ? "present_late"
        : wakeLateStreakReady ? "wake_late_guarded"
        : wakeLate          ? "wake_late"
                            : "late_streak";
  } else {
    if (lateThisFrame) {
      g_iFramePacerStableFrames = 0;
      g_szFramePacerLastAdaptiveReason =
          onlyWakeLateActionable ? "wake_late_observed" : "late_observed";
    } else {
      ++g_iFramePacerStableFrames;
      if (wakeLateStillPresentedOnTime) {
        g_szFramePacerLastAdaptiveReason = "wake_late_ignored";
      }
    }
    if (g_iFramePacerStableFrames >= FramePacingAdaptiveStableFrames() &&
        oldMarginUsec > baseMarginUsec) {
      g_iFramePacerAdaptiveMarginUsec =
          oldMarginUsec > baseMarginUsec + stepDownUsec
              ? oldMarginUsec - stepDownUsec
              : baseMarginUsec;
      g_iFramePacerStableFrames = 0;
      g_szFramePacerLastAdaptiveReason = "stable_decay";
    }
  }

  g_iFramePacerLastNextMarginUsec = g_iFramePacerAdaptiveMarginUsec;
  if (g_iFramePacerAdaptiveMarginUsec != oldMarginUsec) {
    g_iFramePacerLastAdaptiveAdjustUsec =
        static_cast<int64_t>(g_iFramePacerAdaptiveMarginUsec) -
        static_cast<int64_t>(oldMarginUsec);
    g_bFramePacerLastAdaptiveChanged = true;
  }
}

#ifdef __APPLE__
static void UpdateFramePacingMacOSAdaptiveLead(
    uint64_t intervalUsec, int64_t presentLateUsec, int skippedIntervals,
    bool hardResynced, bool phaseResynced, uint64_t swapBuffersUsec) {
  const uint64_t baseLeadUsec =
      FramePacingMacOSAdaptiveLeadBaseUsec(intervalUsec);
  const uint64_t maxLeadUsec =
      FramePacingMacOSAdaptiveLeadMaxUsec(intervalUsec, baseLeadUsec);
  g_iFramePacerLastMacOSAdaptiveLeadBaseUsec = baseLeadUsec;
  g_iFramePacerLastMacOSAdaptiveLeadMaxUsec = maxLeadUsec;
  g_iFramePacerLastMacOSAdaptiveLeadAdjustUsec = 0;
  g_bFramePacerLastMacOSAdaptiveLeadChanged = false;
  g_szFramePacerLastMacOSAdaptiveLeadReason = "stable";

  if (!FramePacingMacOSAdaptiveLeadEnabled()) {
    g_iFramePacerMacOSAdaptiveLeadUsec = baseLeadUsec;
    g_iFramePacerMacOSSwapBlockStreak = 0;
    g_iFramePacerMacOSSevereSwapBlockStreak = 0;
    g_iFramePacerMacOSSwapBlockPressure = 0;
    g_iFramePacerMacOSWaitOvershootPressure = 0;
    g_iFramePacerMacOSSwapPressureTransientFrames = 0;
    g_iFramePacerMacOSLeadStableFrames = 0;
    g_bFramePacerMacOSSafeMode = false;
	  g_bFramePacerLastMacOSEarlySwapBackpressure = false;
	  g_bFramePacerLastMacOSWaitOvershootPressure = false;
	  g_bFramePacerLastMacOSPreSwapLoadPressure = false;
	  g_iFramePacerLastMacOSPreSwapLoadUsec = 0;
	  g_iFramePacerLastMacOSPreSwapLoadThresholdUsec = 0;
	  g_iFramePacerMacOSPreSwapLoadPressureFrames = 0;
	  g_iFramePacerLastMacOSWaitCapUsec = 0;
	  g_szFramePacerLastMacOSAdaptiveLeadReason = "disabled";
	  return;
	}

  if (g_iFramePacerMacOSAdaptiveLeadUsec == 0) {
    g_iFramePacerMacOSAdaptiveLeadUsec = baseLeadUsec;
  }
  g_iFramePacerMacOSAdaptiveLeadUsec = std::clamp<uint64_t>(
      g_iFramePacerMacOSAdaptiveLeadUsec, baseLeadUsec, maxLeadUsec);
  const uint64_t oldLeadUsec = g_iFramePacerMacOSAdaptiveLeadUsec;
  const bool swapBlocked =
      FramePacingSwapLikelyBlocked(swapBuffersUsec, intervalUsec);
  const bool riskySwapBlocked =
      FramePacingMacOSRiskySwapBlocked(swapBuffersUsec, intervalUsec);
  const bool severeSwapBlocked =
      FramePacingMacOSSevereSwapBlocked(swapBuffersUsec, intervalUsec);
  const bool missedPresent = skippedIntervals > 0 || hardResynced;
  const bool phaseLate = phaseResynced;
  const bool presentLate =
      presentLateUsec > static_cast<int64_t>(intervalUsec / 2);
  const bool finalWaitOverslept =
      g_iFramePacerLastDisplayLinkFinalWaitOvershootUsec >
      std::max<uint64_t>(1000, intervalUsec / 4);
  const int64_t positiveWakeLateUsec =
      std::max<int64_t>(0, g_iFramePacerLastWakeLateUsec);
  const bool genericWaitOverslept =
      g_iFramePacerLastSleepOvershootUsec >
      std::max<uint64_t>(1000, intervalUsec / 4);
  const bool waitTimingSlipped =
      positiveWakeLateUsec > static_cast<int64_t>(
                                 std::max<uint64_t>(1000, intervalUsec / 4)) ||
      genericWaitOverslept || finalWaitOverslept;
  const bool waitOvershootPressure =
      waitTimingSlipped && !swapBlocked &&
      (presentLateUsec > 0 || phaseLate || missedPresent);
  // Pre-swap load is telemetry only. The sampled value includes the intentional
  // frame-pacing wait before CGLFlushDrawable, so it must not drive policy.
  const bool rawEarlySwapBackpressure =
      FramePacingMacOSEarlySwapBackpressure(swapBuffersUsec, intervalUsec);
  const bool earlySwapBackpressure =
      rawEarlySwapBackpressure && !missedPresent && !phaseLate &&
      !presentLate && !riskySwapBlocked && !severeSwapBlocked &&
      !waitOvershootPressure;
  const bool severeFrame =
      severeSwapBlocked || missedPresent || finalWaitOverslept;
  const bool riskyLeadPressure =
      riskySwapBlocked && !severeFrame && !earlySwapBackpressure &&
      !waitOvershootPressure;
  const bool stableFrame =
      !swapBlocked && !severeFrame && !phaseLate && !presentLate &&
      !waitOvershootPressure;
  const bool severeLeadPressure =
      severeFrame && !earlySwapBackpressure && !waitOvershootPressure;
  const int swapPressureLeadMode = FramePacingMacOSSwapPressureLeadMode();

  g_bFramePacerLastMacOSEarlySwapBackpressure = earlySwapBackpressure;
  g_bFramePacerLastMacOSWaitOvershootPressure = waitOvershootPressure;
  g_bFramePacerLastMacOSPreSwapLoadPressure = false;
  g_iFramePacerLastMacOSWaitCapUsec =
      FramePacingMacOSAdaptiveLeadWaitCapUsec(
          intervalUsec, baseLeadUsec, maxLeadUsec);

  if (swapBlocked) {
    ++g_iFramePacerMacOSSwapBlockStreak;
    const int pressureAdd = severeSwapBlocked ? 4 : riskySwapBlocked ? 3 : 2;
    g_iFramePacerMacOSSwapBlockPressure = std::min(
        FramePacingMacOSAdaptiveLeadSafeFrames() * 4,
        g_iFramePacerMacOSSwapBlockPressure + pressureAdd);
    if (swapPressureLeadMode == 2) {
      g_iFramePacerMacOSSwapPressureTransientFrames =
          FramePacingMacOSSwapPressureTransientFrames();
    }
  } else {
    if (g_iFramePacerMacOSSwapBlockStreak > 0) {
      --g_iFramePacerMacOSSwapBlockStreak;
    }

    const int pressureDecay =
        waitOvershootPressure ? 4 : stableFrame ? 2 : 1;
    g_iFramePacerMacOSSwapBlockPressure = std::max(
        0, g_iFramePacerMacOSSwapBlockPressure - pressureDecay);
  }

  if (severeLeadPressure) {
    g_iFramePacerMacOSSevereSwapBlockStreak = std::min(
        FramePacingMacOSAdaptiveLeadSafeFrames() * 2,
        g_iFramePacerMacOSSevereSwapBlockStreak + 2);
  } else if (earlySwapBackpressure &&
             g_iFramePacerMacOSSevereSwapBlockStreak > 0) {
    --g_iFramePacerMacOSSevereSwapBlockStreak;
  } else if (stableFrame &&
             g_iFramePacerMacOSSevereSwapBlockStreak > 0) {
    --g_iFramePacerMacOSSevereSwapBlockStreak;
  }

  if (stableFrame) {
    ++g_iFramePacerMacOSLeadStableFrames;
    if (g_iFramePacerMacOSLeadStableFrames %
            std::max(1, FramePacingMacOSAdaptiveLeadStableFrames() / 3) ==
        0) {
      g_iFramePacerMacOSSwapBlockPressure =
          std::max(0, g_iFramePacerMacOSSwapBlockPressure - 1);
      g_iFramePacerMacOSWaitOvershootPressure =
          std::max(0, g_iFramePacerMacOSWaitOvershootPressure - 1);
    }
  } else {
    g_iFramePacerMacOSLeadStableFrames = 0;
  }

  if (waitOvershootPressure) {
    g_iFramePacerMacOSWaitOvershootPressure = std::min(
        FramePacingMacOSAdaptiveLeadSafeFrames() * 4,
        g_iFramePacerMacOSWaitOvershootPressure + 3);
  } else if (g_iFramePacerMacOSWaitOvershootPressure > 0 &&
             !swapBlocked) {
    --g_iFramePacerMacOSWaitOvershootPressure;
  }

  const int swapBlockPressureThreshold =
      FramePacingMacOSAdaptiveLeadSwapBlockFrames() * 2;
  const bool swapPressureReady =
      g_iFramePacerMacOSSwapBlockPressure >= swapBlockPressureThreshold;
  const int waitOvershootPressureThreshold =
      std::max(1, FramePacingMacOSAdaptiveLeadSwapBlockFrames());
  const bool waitOvershootPressureReady =
      g_iFramePacerMacOSWaitOvershootPressure >=
      waitOvershootPressureThreshold;
  const bool swapPressureCanRaiseLead =
      swapPressureReady && !waitOvershootPressureReady;

  if (g_iFramePacerMacOSSevereSwapBlockStreak >=
      FramePacingMacOSAdaptiveLeadSafeFrames()) {
    g_bFramePacerMacOSSafeMode = true;
  } else if (
      g_bFramePacerMacOSSafeMode &&
      g_iFramePacerMacOSLeadStableFrames >=
          FramePacingMacOSAdaptiveLeadStableFrames() * 2 &&
      g_iFramePacerMacOSSevereSwapBlockStreak == 0) {
    g_bFramePacerMacOSSafeMode = false;
  }

  uint64_t targetLeadUsec = oldLeadUsec;
  if (swapPressureLeadMode == 0) {
    targetLeadUsec = baseLeadUsec;
    g_bFramePacerMacOSSafeMode = false;
    g_iFramePacerMacOSSwapPressureTransientFrames = 0;
    g_szFramePacerLastMacOSAdaptiveLeadReason = "swap_pressure_disabled";
  } else if (earlySwapBackpressure && oldLeadUsec > baseLeadUsec) {
    const uint64_t stepDownUsec =
        FramePacingMacOSAdaptiveLeadStepDownUsec(intervalUsec);
    const uint64_t earlyBackpressureStepUsec = std::max<uint64_t>(
        stepDownUsec, FramePacingMacOSAdaptiveLeadStepUpUsec(intervalUsec));
    targetLeadUsec =
        oldLeadUsec > baseLeadUsec + earlyBackpressureStepUsec
            ? oldLeadUsec - earlyBackpressureStepUsec
            : baseLeadUsec;
    g_bFramePacerMacOSSafeMode = false;
    g_iFramePacerMacOSLeadStableFrames = 0;
    g_szFramePacerLastMacOSAdaptiveLeadReason = "early_swap_backpressure";
  } else if (
      waitOvershootPressureReady &&
      oldLeadUsec > g_iFramePacerLastMacOSWaitCapUsec) {
    const uint64_t stepDownUsec = std::max<uint64_t>(
        FramePacingMacOSAdaptiveLeadStepDownUsec(intervalUsec),
        FramePacingMacOSAdaptiveLeadWaitStepDownUsec(intervalUsec));
    targetLeadUsec =
        oldLeadUsec > g_iFramePacerLastMacOSWaitCapUsec + stepDownUsec
            ? oldLeadUsec - stepDownUsec
            : g_iFramePacerLastMacOSWaitCapUsec;
    g_bFramePacerMacOSSafeMode = false;
    g_iFramePacerMacOSLeadStableFrames = 0;
    g_iFramePacerMacOSSevereSwapBlockStreak =
        std::max(0, g_iFramePacerMacOSSevereSwapBlockStreak - 1);
    g_szFramePacerLastMacOSAdaptiveLeadReason = "wait_overshoot_cap";
  } else if (g_bFramePacerMacOSSafeMode) {
    targetLeadUsec = maxLeadUsec;
    g_szFramePacerLastMacOSAdaptiveLeadReason = "safe_mode";
  } else if (
      swapPressureLeadMode == 2 &&
      g_iFramePacerMacOSSwapPressureTransientFrames > 0) {
    const uint64_t transientLeadUsec = std::min<uint64_t>(
        maxLeadUsec,
        std::max<uint64_t>(
            baseLeadUsec + FramePacingMacOSAdaptiveLeadStepUpUsec(intervalUsec),
            FramePacingMacOSAdaptiveLeadWaitCapUsec(
                intervalUsec, baseLeadUsec, maxLeadUsec)));
    targetLeadUsec = transientLeadUsec;
    --g_iFramePacerMacOSSwapPressureTransientFrames;
    g_szFramePacerLastMacOSAdaptiveLeadReason = "swap_pressure_transient";
  } else if (
      severeLeadPressure || riskyLeadPressure || swapPressureCanRaiseLead) {
    const uint64_t stepUsec =
        FramePacingMacOSAdaptiveLeadStepUpUsec(intervalUsec);
    const uint64_t multiplier =
        swapPressureLeadMode == 2
            ? 1
            : severeLeadPressure
                ? 2
                : riskyLeadPressure
                    ? 1
            : std::clamp(
                  g_iFramePacerMacOSSwapBlockPressure /
                      std::max(1, swapBlockPressureThreshold),
                  1, 3);
    targetLeadUsec = std::min<uint64_t>(
        maxLeadUsec, oldLeadUsec + stepUsec * multiplier);
    g_szFramePacerLastMacOSAdaptiveLeadReason =
        severeLeadPressure
            ? "severe_swap"
            : riskyLeadPressure ? "risky_swap" : "swap_pressure";
  } else if (
      stableFrame &&
      g_iFramePacerMacOSLeadStableFrames >=
          FramePacingMacOSAdaptiveLeadStableFrames() &&
      g_iFramePacerMacOSSwapBlockPressure == 0 &&
      oldLeadUsec > baseLeadUsec) {
    const uint64_t stepDownUsec =
        FramePacingMacOSAdaptiveLeadStepDownUsec(intervalUsec);
    targetLeadUsec =
        oldLeadUsec > baseLeadUsec + stepDownUsec
            ? oldLeadUsec - stepDownUsec
            : baseLeadUsec;
    g_iFramePacerMacOSLeadStableFrames = 0;
    g_szFramePacerLastMacOSAdaptiveLeadReason = "stable_decay";
  }

  g_iFramePacerMacOSAdaptiveLeadUsec = std::clamp<uint64_t>(
      targetLeadUsec, baseLeadUsec, maxLeadUsec);
  if (g_iFramePacerMacOSAdaptiveLeadUsec != oldLeadUsec) {
    g_iFramePacerLastMacOSAdaptiveLeadAdjustUsec =
        static_cast<int64_t>(g_iFramePacerMacOSAdaptiveLeadUsec) -
        static_cast<int64_t>(oldLeadUsec);
    g_bFramePacerLastMacOSAdaptiveLeadChanged = true;
  }

  const uint64_t baseMarginUsec = FramePacingMarginUsec(intervalUsec);
  const uint64_t maxMarginUsec =
      FramePacingAdaptiveMaxMarginUsec(intervalUsec, baseMarginUsec);
  g_iFramePacerLastNextMarginUsec = std::min<uint64_t>(
      maxMarginUsec,
      std::max<uint64_t>(g_iFramePacerAdaptiveMarginUsec,
                         g_iFramePacerMacOSAdaptiveLeadUsec));
}
#endif

static void ResetFramePacer() {
  g_iFramePacerNextPresentUsec = 0;
  g_iFramePacerFrames = 0;
  g_iFramePacerLastPlannedWaitUsec = 0;
  g_iFramePacerLastSleepUsec = 0;
  g_iFramePacerLastActualSleepUsec = 0;
  g_iFramePacerLastSleepOvershootUsec = 0;
  g_iFramePacerLastFineWaitUsec = 0;
  g_iFramePacerLastSpinWaitUsec = 0;
  g_iFramePacerLastSpinCapUsec = 0;
  g_iFramePacerLastWaitResyncThresholdUsec = 0;
#ifdef __APPLE__
  g_iFramePacerLastDisplayLinkPeriodUsec = 0;
  g_iFramePacerLastDisplayLinkTickCount = 0;
  g_iFramePacerLastDisplayLinkTicksDuringWait = 0;
  g_iFramePacerLastDisplayLinkWaitActualUsec = 0;
  g_iFramePacerLastDisplayLinkFinalWaitUsec = 0;
  g_iFramePacerLastDisplayLinkFinalWaitSleepUsec = 0;
  g_iFramePacerLastDisplayLinkFinalWaitYieldUsec = 0;
  g_iFramePacerLastDisplayLinkFinalWaitSpinUsec = 0;
  g_iFramePacerLastDisplayLinkFinalWaitOvershootUsec = 0;
  g_iFramePacerLastDisplayLinkFinalWaitSleepChunks = 0;
  g_iFramePacerLastDisplayLinkFinalWaitYields = 0;
  g_iFramePacerLastDisplayLinkPresentLeadUsec = 0;
  g_iFramePacerLastDisplayLinkLateToleranceUsec = 0;
  g_iFramePacerLastDisplayLinkPhaseToleranceUsec = 0;
  g_iFramePacerLastDisplayLinkTargetUsec = 0;
  g_iFramePacerLastDisplayLinkDesiredUsec = 0;
  g_iFramePacerLastDisplayLinkLatestUsec = 0;
  g_iFramePacerLastDisplayLinkLastOutputUsec = 0;
  g_iFramePacerLastDisplayLinkSelectedOutputUsec = 0;
  g_iFramePacerLastDisplayLinkOutputToTargetUsec = 0;
  g_iFramePacerLastDisplayLinkSelectedOutputToTargetUsec = 0;
  g_iFramePacerLastDisplayLinkOutputLateUsec = 0;
  g_bFramePacerLastDisplayLinkUsed = false;
  g_bFramePacerLastDisplayLinkTimedOut = false;
  g_bFramePacerLastDisplayLinkFinalWaitCapped = false;
  g_bFramePacerLastDisplayLinkOutputPhaseAccepted = false;
  g_bFramePacerLastDisplayLinkOutputAlignedPresentEnabled = false;
  g_bFramePacerLastDisplayLinkOutputAlignedPresent = false;
  g_bFramePacerLastDisplayLinkOutputCapRejected = false;
  g_iFramePacerLastDisplayLinkOutputAlignedPresentMode = 1;
  g_bFramePacerLastDisplayLinkPhaseAligned = false;
  g_iFramePacerLastDisplayLinkPhaseAlignUsec = 0;
  g_szFramePacerLastDisplayLinkSelectedOutputSource = "none";
  g_szFramePacerLastDisplayLinkStatus = "reset";
  g_iFramePacerLastMacOSAdaptiveLeadBaseUsec = 0;
  g_iFramePacerLastMacOSAdaptiveLeadMaxUsec = 0;
  g_iFramePacerLastMacOSAdaptiveLeadAdjustUsec = 0;
  g_iFramePacerMacOSSwapBlockStreak = 0;
  g_iFramePacerMacOSSevereSwapBlockStreak = 0;
  g_iFramePacerMacOSSwapBlockPressure = 0;
  g_iFramePacerMacOSWaitOvershootPressure = 0;
  g_iFramePacerMacOSSwapPressureTransientFrames = 0;
  g_iFramePacerMacOSLeadStableFrames = 0;
  g_bFramePacerMacOSSafeMode = false;
	  g_bFramePacerLastMacOSEarlySwapBackpressure = false;
	  g_bFramePacerLastMacOSWaitOvershootPressure = false;
	  g_bFramePacerLastMacOSPreSwapLoadPressure = false;
	  g_iFramePacerLastMacOSPreSwapLoadUsec = 0;
	  g_iFramePacerLastMacOSPreSwapLoadThresholdUsec = 0;
	  g_iFramePacerMacOSPreSwapLoadPressureFrames = 0;
  g_iFramePacerLastMacOSWaitCapUsec = 0;
	  g_bFramePacerLastMacOSAdaptiveLeadChanged = false;
	  g_szFramePacerLastMacOSAdaptiveLeadReason = "reset";
#endif
  g_iFramePacerAdaptiveMarginUsec = 0;
  g_iFramePacerLastBaseMarginUsec = 0;
  g_iFramePacerLastEffectiveMarginUsec = 0;
  g_iFramePacerLastNextMarginUsec = 0;
  g_iFramePacerLastWaitMarginUsec = 0;
  g_iFramePacerLastMaxMarginUsec = 0;
  g_iFramePacerLastSwapBuffersUsec = 0;
  g_iFramePacerLastAdaptiveAdjustUsec = 0;
  g_iFramePacerLastLateBeforeUsec = 0;
  g_iFramePacerLastLateAfterWaitUsec = 0;
  g_iFramePacerLastWakeLateUsec = 0;
  g_iFramePacerLastBeforeSwapPhaseErrorUsec = 0;
  g_iFramePacerLastSleepChunks = 0;
  g_iFramePacerStableFrames = 0;
  g_iFramePacerConsecutiveLateFrames = 0;
  g_iFramePacerConsecutiveWakeLateFrames = 0;
  g_iFramePacerWarmupFramesRemaining = 0;
  g_bFramePacerLoggedEnable = false;
  g_bFramePacerWasEnabled = false;
  g_bFramePacerLastAdaptiveChanged = false;
  g_szFramePacerLastAdaptiveReason = "reset";
  g_szFramePacerLastClassification = "reset";
  g_szFramePacerLastBeforeSwapResyncReason = "none";
  g_szFramePacerLastWaitAbortReason = "none";
  g_szFramePacerLastAfterSwapResyncReason = "none";
}

}  // namespace

void RageDisplay::ReportFramePacingPreSwapLoad(float renderBeforeSwapMs) {
#ifdef __APPLE__
  g_iFramePacerMacOSPreSwapLoadPressureFrames = 0;
  g_bFramePacerLastMacOSPreSwapLoadPressure = false;

  if (!std::isfinite(renderBeforeSwapMs) || renderBeforeSwapMs <= 0.0f) {
    g_iFramePacerLastMacOSPreSwapLoadUsec = 0;
    g_iFramePacerLastMacOSPreSwapLoadThresholdUsec = 0;
    return;
  }

  const float targetHz =
      EffectiveFramePacingTargetHz(GetActualVideoModeParams().rate);
  if (targetHz < 90.0f) {
    g_iFramePacerLastMacOSPreSwapLoadUsec = 0;
    g_iFramePacerLastMacOSPreSwapLoadThresholdUsec = 0;
    return;
  }

  const uint64_t intervalUsec = FramePacingIntervalUsec(targetHz);
  const uint64_t loadUsec =
      static_cast<uint64_t>(std::llround(renderBeforeSwapMs * 1000.0f));
  const uint64_t thresholdUsec =
      FramePacingMacOSPreSwapLoadThresholdUsec(intervalUsec);
  g_iFramePacerLastMacOSPreSwapLoadUsec = loadUsec;
  g_iFramePacerLastMacOSPreSwapLoadThresholdUsec = thresholdUsec;
#else
  (void)renderBeforeSwapMs;
#endif
}

static const char* RagePixelFormatNames[] = {
    "RGBA8", "BGRA8", "RGBA4", "RGB5A1", "RGB5",
    "RGB8",  "PAL",   "BGR8",  "A1BGR5", "X1RGB5",
};
XToString(RagePixelFormat);

/* bNeedReloadTextures is set to true if the device was re-created and we need
 * to reload textures.  On failure, an error message is returned.
 * XXX: the renderer itself should probably be the one to try fallback modes */
static LocalizedString SETVIDEOMODE_FAILED(
    "RageDisplay", "SetVideoMode failed:");
std::string RageDisplay::SetVideoMode(
    VideoModeParams p, bool& bNeedReloadTextures) {
  std::string err;
  std::vector<std::string> vs;

  if ((err = this->TryVideoMode(p, bNeedReloadTextures)) == "") {
    return std::string();
  }
  LOG->Trace("TryVideoMode failed: %s", err.c_str());
  vs.push_back(err);

  // fall back to settings that will most likely work
  p.bpp = 16;
  if ((err = this->TryVideoMode(p, bNeedReloadTextures)) == "") {
    return std::string();
  }
  vs.push_back(err);

  // "Intel(R) 82810E Graphics Controller" won't accept a 16 bpp surface if
  // the desktop is 32 bpp, so try 32 bpp as well.
  p.bpp = 32;
  if ((err = this->TryVideoMode(p, bNeedReloadTextures)) == "") {
    return std::string();
  }
  vs.push_back(err);

  // Fall back on a known resolution good rather than 640 x 480.
  DisplaySpecs dr;
  this->GetDisplaySpecs(dr);
  if (dr.empty()) {
    vs.push_back("No display resolutions");
    return SETVIDEOMODE_FAILED.GetValue() + " " + join(";", vs);
  }

  DisplaySpec d = *dr.begin();
  // Try to find DisplaySpec corresponding to requested display
  for (const auto& candidate : dr) {
    if (candidate.currentMode() != nullptr) {
      d = candidate;
      if (candidate.id() == p.sDisplayId) {
        break;
      }
    }
  }

  p.sDisplayId = d.id();
  const DisplayMode supported = d.currentMode() != nullptr
                                    ? *d.currentMode()
                                    : *d.supportedModes().begin();
  p.width = supported.width;
  p.height = supported.height;
  p.rate = std::round(supported.refreshRate);
  if ((err = this->TryVideoMode(p, bNeedReloadTextures)) == "") {
    return std::string();
  }
  vs.push_back(err);

  return SETVIDEOMODE_FAILED.GetValue() + " " + join(";", vs);
}

void RageDisplay::ProcessStatsOnFlip() {
  g_iFramesRenderedSinceLastCheck++;
  g_iFramesRenderedSinceLastReset++;

  if (g_LastCheckTimer.Ago() >= 1.0f)  // update stats every 1 sec.
  {
    float fActualTime = g_LastCheckTimer.GetDeltaTime();
    g_iNumChecksSinceLastReset++;
    g_iFPS = std::lrint(g_iFramesRenderedSinceLastCheck / fActualTime);
    g_iCFPS = g_iFramesRenderedSinceLastReset / g_iNumChecksSinceLastReset;
    g_iCFPS = std::lrint(g_iCFPS / fActualTime);
    g_iVPF = g_iVertsRenderedSinceLastCheck / g_iFramesRenderedSinceLastCheck;
    g_iFramesRenderedSinceLastCheck = g_iVertsRenderedSinceLastCheck = 0;
    if (LOG_FPS) {
      std::string sStats = GetStats();
      Replace(sStats, "\n", ", ");
      LOG->Trace("%s", sStats.c_str());
    }
  }
}

void RageDisplay::ResetStats() {
  g_iFPS = g_iVPF = 0;
  g_iFramesRenderedSinceLastCheck = g_iFramesRenderedSinceLastReset = 0;
  g_iNumChecksSinceLastReset = 0;
  g_iVertsRenderedSinceLastCheck = 0;
  g_LastCheckTimer.GetDeltaTime();
}

std::string RageDisplay::GetStats() const {
  std::string s;
  // If FPS == 0, we don't have stats yet.
  if (!GetFPS()) {
    s = "-- FPS\n-- av FPS\n-- VPF";
  }

  s = ssprintf("%i FPS\n%i av FPS\n%i VPF", GetFPS(), GetCumFPS(), GetVPF());

  //	#if defined(_WIN32)
  s += "\n" + this->GetApiDescription();
  //	#endif

  return s;
}

bool RageDisplay::BeginFrame() {
  this->SetDefaultRenderStates();

  return true;
}

void RageDisplay::EndFrame() { ProcessStatsOnFlip(); }

void RageDisplay::BeginConcurrentRendering() { this->SetDefaultRenderStates(); }

void RageDisplay::StatsAddVerts(int iNumVertsRendered) {
  g_iVertsRenderedSinceLastCheck += iNumVertsRendered;
}

/* Draw a line as a quad.  GL_LINES with SmoothLines off can draw line
 * ends at odd angles--they're forced to axis-alignment regardless of the
 * angle of the line. */
void RageDisplay::DrawPolyLine(
    const RageSpriteVertex& p1, const RageSpriteVertex& p2, float LineWidth) {
  // soh cah toa strikes strikes again!
  float opp = p2.p.x - p1.p.x;
  float adj = p2.p.y - p1.p.y;
  float hyp = std::pow(opp * opp + adj * adj, 0.5f);

  float lsin = opp / hyp;
  float lcos = adj / hyp;

  RageSpriteVertex v[4];

  v[0] = v[1] = p1;
  v[2] = v[3] = p2;

  float ydist = lsin * LineWidth / 2;
  float xdist = lcos * LineWidth / 2;

  v[0].p.x += xdist;
  v[0].p.y -= ydist;
  v[1].p.x -= xdist;
  v[1].p.y += ydist;
  v[2].p.x -= xdist;
  v[2].p.y += ydist;
  v[3].p.x += xdist;
  v[3].p.y -= ydist;

  this->DrawQuad(v);
}

void RageDisplay::DrawLineStripInternal(
    const RageSpriteVertex v[], int iNumVerts, float LineWidth) {
  ASSERT(iNumVerts >= 2);

  /* Draw a line strip with rounded corners using polys. This is used on
   * cards that have strange allergic reactions to antialiased points and
   * lines. */
  for (int i = 0; i < iNumVerts - 1; ++i) {
    DrawPolyLine(v[i], v[i + 1], LineWidth);
  }

  // Join the lines with circles so we get rounded corners.
  for (int i = 0; i < iNumVerts; ++i) {
    DrawCircle(v[i], LineWidth / 2);
  }
}

void RageDisplay::DrawCircleInternal(const RageSpriteVertex& p, float radius) {
  const int subdivisions = 32;
  RageSpriteVertex v[subdivisions + 2];
  v[0] = p;

  for (int i = 0; i < subdivisions + 1; ++i) {
    const float fRotation = float(i) / subdivisions * 2 * PI;
    const float fX = std::cos(fRotation) * radius;
    const float fY = -std::sin(fRotation) * radius;
    v[1 + i] = v[0];
    v[1 + i].p.x += fX;
    v[1 + i].p.y += fY;
  }

  this->DrawFan(v, subdivisions + 2);
}

void RageDisplay::SetDefaultRenderStates() {
  SetLighting(false);
  SetCullMode(CULL_NONE);
  SetZWrite(false);
  SetZTestMode(ZTEST_OFF);
  SetAlphaTest(true);
  SetBlendMode(BLEND_NORMAL);
  SetTextureFiltering(TextureUnit_1, true);
  SetZBias(0);
  LoadMenuPerspective(0, 640, 480, 320, 240);  // 0 FOV = ortho
}

// Matrix stuff
class MatrixStack {
  std::vector<RageMatrix> stack;

 public:
  MatrixStack() : stack() {
    stack.resize(1);
    LoadIdentity();
  }

  // Pops the top of the stack.
  void Pop() {
    stack.pop_back();
    ASSERT(stack.size() > 0);  // underflow
  }

  // Pushes the stack by one, duplicating the current matrix.
  void Push() {
    stack.push_back(stack.back());
    ASSERT(stack.size() < 100);  // overflow
  }

  // Loads identity in the current matrix.
  void LoadIdentity() { RageMatrixIdentity(&stack.back()); }

  // Loads the given matrix into the current matrix
  void LoadMatrix(const RageMatrix& m) { stack.back() = m; }

  // Right-Multiplies the given matrix to the current matrix.
  // (transformation is about the current world origin)
  void MultMatrix(const RageMatrix& m) {
    RageMatrixMultiply(&stack.back(), &m, &stack.back());
  }

  // Left-Multiplies the given matrix to the current matrix
  // (transformation is about the local origin of the object)
  void MultMatrixLocal(const RageMatrix& m) {
    RageMatrixMultiply(&stack.back(), &stack.back(), &m);
  }

  // Right multiply the current matrix with the computed rotation
  // matrix, counterclockwise about the given axis with the given angle.
  // (rotation is about the current world origin)
  void RotateX(float degrees) {
    RageMatrix m;
    RageMatrixRotationX(&m, degrees);
    MultMatrix(m);
  }
  void RotateY(float degrees) {
    RageMatrix m;
    RageMatrixRotationY(&m, degrees);
    MultMatrix(m);
  }
  void RotateZ(float degrees) {
    RageMatrix m;
    RageMatrixRotationZ(&m, degrees);
    MultMatrix(m);
  }

  // Left multiply the current matrix with the computed rotation
  // matrix. All angles are counterclockwise. (rotation is about the
  // local origin of the object)
  void RotateXLocal(float degrees) {
    RageMatrix m;
    RageMatrixRotationX(&m, degrees);
    MultMatrixLocal(m);
  }
  void RotateYLocal(float degrees) {
    RageMatrix m;
    RageMatrixRotationY(&m, degrees);
    MultMatrixLocal(m);
  }
  void RotateZLocal(float degrees) {
    RageMatrix m;
    RageMatrixRotationZ(&m, degrees);
    MultMatrixLocal(m);
  }

  // Right multiply the current matrix with the computed scale
  // matrix. (transformation is about the current world origin)
  void Scale(float x, float y, float z) {
    RageMatrix m;
    RageMatrixScaling(&m, x, y, z);
    MultMatrix(m);
  }

  // Left multiply the current matrix with the computed scale
  // matrix. (transformation is about the local origin of the object)
  void ScaleLocal(float x, float y, float z) {
    RageMatrix m;
    RageMatrixScaling(&m, x, y, z);
    MultMatrixLocal(m);
  }

  // Right multiply the current matrix with the computed translation
  // matrix. (transformation is about the current world origin)
  void Translate(float x, float y, float z) {
    RageMatrix m;
    RageMatrixTranslation(&m, x, y, z);
    MultMatrix(m);
  }

  // Left multiply the current matrix with the computed translation
  // matrix. (transformation is about the local origin of the object)
  void TranslateLocal(float x, float y, float z) {
    RageMatrix m;
    RageMatrixTranslation(&m, x, y, z);
    MultMatrixLocal(m);
  }

  void SkewX(float fAmount) {
    RageMatrix m;
    RageMatrixSkewX(&m, fAmount);
    MultMatrixLocal(m);
  }

  void SkewY(float fAmount) {
    RageMatrix m;
    RageMatrixSkewY(&m, fAmount);
    MultMatrixLocal(m);
  }

  // Obtain the current matrix at the top of the stack
  const RageMatrix* GetTop() const { return &stack.back(); }
  void SetTop(const RageMatrix& m) { stack.back() = m; }
};

static RageMatrix g_CenteringMatrix;
static MatrixStack g_ProjectionStack;
static MatrixStack g_ViewStack;
static MatrixStack g_WorldStack;
static MatrixStack g_TextureStack;

RageDisplay::RageDisplay() {
  RageMatrixIdentity(&g_CenteringMatrix);
  g_ProjectionStack = MatrixStack();
  g_ViewStack = MatrixStack();
  g_WorldStack = MatrixStack();
  g_TextureStack = MatrixStack();

  // Register with Lua.
  {
    Lua* L = LUA->Get();
    lua_pushstring(L, "DISPLAY");
    this->PushSelf(L);
    lua_settable(L, LUA_GLOBALSINDEX);
    LUA->Release(L);
  }
}

RageDisplay::~RageDisplay() {
  // Unregister with Lua.
  LUA->UnsetGlobal("DISPLAY");
}

const RageMatrix* RageDisplay::GetCentering() const {
  return &g_CenteringMatrix;
}

const RageMatrix* RageDisplay::GetProjectionTop() const {
  return g_ProjectionStack.GetTop();
}

const RageMatrix* RageDisplay::GetViewTop() const {
  return g_ViewStack.GetTop();
}

const RageMatrix* RageDisplay::GetWorldTop() const {
  return g_WorldStack.GetTop();
}

const RageMatrix* RageDisplay::GetTextureTop() const {
  return g_TextureStack.GetTop();
}

void RageDisplay::PushMatrix() { g_WorldStack.Push(); }

void RageDisplay::PopMatrix() { g_WorldStack.Pop(); }

void RageDisplay::Translate(float x, float y, float z) {
  g_WorldStack.TranslateLocal(x, y, z);
}

void RageDisplay::TranslateWorld(float x, float y, float z) {
  g_WorldStack.Translate(x, y, z);
}

void RageDisplay::Scale(float x, float y, float z) {
  g_WorldStack.ScaleLocal(x, y, z);
}

void RageDisplay::RotateX(float deg) { g_WorldStack.RotateXLocal(deg); }

void RageDisplay::RotateY(float deg) { g_WorldStack.RotateYLocal(deg); }

void RageDisplay::RotateZ(float deg) { g_WorldStack.RotateZLocal(deg); }

void RageDisplay::SkewX(float fAmount) { g_WorldStack.SkewX(fAmount); }

void RageDisplay::SkewY(float fAmount) { g_WorldStack.SkewY(fAmount); }

void RageDisplay::PostMultMatrix(const RageMatrix& m) {
  g_WorldStack.MultMatrix(m);
}

void RageDisplay::PreMultMatrix(const RageMatrix& m) {
  g_WorldStack.MultMatrixLocal(m);
}

void RageDisplay::LoadIdentity() { g_WorldStack.LoadIdentity(); }

void RageDisplay::TexturePushMatrix() { g_TextureStack.Push(); }

void RageDisplay::TexturePopMatrix() { g_TextureStack.Pop(); }

void RageDisplay::TextureTranslate(float x, float y) {
  g_TextureStack.TranslateLocal(x, y, 0);
}

void RageDisplay::LoadMenuPerspective(
    float fovDegrees, float fWidth, float fHeight, float fVanishPointX,
    float fVanishPointY) {
  // fovDegrees == 0 gives ortho projection.
  if (fovDegrees == 0) {
    float left = 0, right = fWidth, bottom = fHeight, top = 0;
    g_ProjectionStack.LoadMatrix(
        GetOrthoMatrix(left, right, bottom, top, -1000, +1000));
    g_ViewStack.LoadIdentity();
  } else {
    rage_clamp(fovDegrees, 0.1f, 179.9f);
    float fovRadians = fovDegrees / 180.f * PI;
    float theta = fovRadians / 2;
    float fDistCameraFromImage = fWidth / 2 / std::tan(theta);

    fVanishPointX = SCALE(fVanishPointX, 0, fWidth, fWidth, 0);
    fVanishPointY = SCALE(fVanishPointY, 0, fHeight, fHeight, 0);

    fVanishPointX -= fWidth / 2;
    fVanishPointY -= fHeight / 2;

    // It's the caller's responsibility to push first.
    g_ProjectionStack.LoadMatrix(GetFrustumMatrix(
        (fVanishPointX - fWidth / 2) / fDistCameraFromImage,
        (fVanishPointX + fWidth / 2) / fDistCameraFromImage,
        (fVanishPointY + fHeight / 2) / fDistCameraFromImage,
        (fVanishPointY - fHeight / 2) / fDistCameraFromImage, 1,
        fDistCameraFromImage + 1000));

    g_ViewStack.LoadMatrix(RageLookAt(
        -fVanishPointX + fWidth / 2, -fVanishPointY + fHeight / 2,
        fDistCameraFromImage, -fVanishPointX + fWidth / 2,
        -fVanishPointY + fHeight / 2, 0, 0.0f, 1.0f, 0.0f));
  }
}

void RageDisplay::CameraPushMatrix() {
  g_ProjectionStack.Push();
  g_ViewStack.Push();
}

void RageDisplay::CameraPopMatrix() {
  g_ProjectionStack.Pop();
  g_ViewStack.Pop();
}

/* gluLookAt. The result is pre-multiplied to the matrix (M = L * M) instead of
 * post-multiplied. */
void RageDisplay::LoadLookAt(
    float fFOV, const RageVector3& Eye, const RageVector3& At,
    const RageVector3& Up) {
  float fAspect = GetActualVideoModeParams().fDisplayAspectRatio;
  g_ProjectionStack.LoadMatrix(GetPerspectiveMatrix(fFOV, fAspect, 1, 1000));

  // Flip the Y coordinate, so positive numbers go down.
  g_ProjectionStack.Scale(1, -1, 1);

  g_ViewStack.LoadMatrix(
      RageLookAt(Eye.x, Eye.y, Eye.z, At.x, At.y, At.z, Up.x, Up.y, Up.z));
}

RageMatrix RageDisplay::GetPerspectiveMatrix(
    float fovy, float aspect, float zNear, float zFar) {
  float ymax = zNear * std::tan(fovy * PI / 360.0f);
  float ymin = -ymax;
  float xmin = ymin * aspect;
  float xmax = ymax * aspect;

  return GetFrustumMatrix(xmin, xmax, ymin, ymax, zNear, zFar);
}

RageSurface* RageDisplay::CreateSurfaceFromPixfmt(
    RagePixelFormat pixfmt, void* pixels, int width, int height, int pitch) {
  const RagePixelFormatDesc* tpf = GetPixelFormatDesc(pixfmt);

  RageSurface* surf = CreateSurfaceFrom(
      width, height, tpf->bpp, tpf->masks[0], tpf->masks[1], tpf->masks[2],
      tpf->masks[3], (uint8_t*)pixels, pitch);

  return surf;
}

RagePixelFormat RageDisplay::FindPixelFormat(
    int iBPP, unsigned iRmask, unsigned iGmask, unsigned iBmask,
    unsigned iAmask, bool bRealtime) {
  RagePixelFormatDesc tmp = {iBPP, {iRmask, iGmask, iBmask, iAmask}};

  FOREACH_ENUM(RagePixelFormat, iPixFmt) {
    const RagePixelFormatDesc* pf =
        GetPixelFormatDesc(RagePixelFormat(iPixFmt));
    if (!SupportsTextureFormat(RagePixelFormat(iPixFmt), bRealtime)) {
      continue;
    }

    if (memcmp(pf, &tmp, sizeof(tmp))) {
      continue;
    }
    return iPixFmt;
  }

  return RagePixelFormat_Invalid;
}

/* These convert to OpenGL's coordinate system: -1,-1 is the bottom-left,
 * +1,+1 is the top-right, and Z goes from -1 (viewer) to +1 (distance).
 * It's a little odd, but very well-defined. */
RageMatrix RageDisplay::GetOrthoMatrix(
    float l, float r, float b, float t, float zn, float zf) {
  RageMatrix m(
      2 / (r - l), 0, 0, 0, 0, 2 / (t - b), 0, 0, 0, 0, -2 / (zf - zn), 0,
      -(r + l) / (r - l), -(t + b) / (t - b), -(zf + zn) / (zf - zn), 1);
  return m;
}

RageMatrix RageDisplay::GetFrustumMatrix(
    float l, float r, float b, float t, float zn, float zf) {
  // glFrustum
  float A = (r + l) / (r - l);
  float B = (t + b) / (t - b);
  float C = -1 * (zf + zn) / (zf - zn);
  float D = -1 * (2 * zf * zn) / (zf - zn);
  RageMatrix m(
      2 * zn / (r - l), 0, 0, 0, 0, 2 * zn / (t - b), 0, 0, A, B, C, -1, 0, 0,
      D, 0);
  return m;
}

void RageDisplay::ResolutionChanged() {
  // The centering matrix depends on the resolution.
  UpdateCentering();
}

void RageDisplay::PrepareForTextureManagerShutdown() {}

void RageDisplay::ResetFramePresentationTelemetry() {}

void RageDisplay::CenteringPushMatrix() {
  g_CenteringStack.push_back(g_CenteringStack.back());
  ASSERT(g_CenteringStack.size() < 100);  // overflow
}

void RageDisplay::CenteringPopMatrix() {
  g_CenteringStack.pop_back();
  ASSERT(g_CenteringStack.size() > 0);  // underflow
  UpdateCentering();
}

void RageDisplay::ChangeCentering(
    int iTranslateX, int iTranslateY, int iAddWidth, int iAddHeight) {
  g_CenteringStack.back() =
      Centering(iTranslateX, iTranslateY, iAddWidth, iAddHeight);

  UpdateCentering();
}

RageMatrix RageDisplay::GetCenteringMatrix(
    float fTranslateX, float fTranslateY, float fAddWidth,
    float fAddHeight) const {
  // in screen space, left edge = -1, right edge = 1, bottom edge = -1. top edge
  // = 1
  float fWidth = (float)GetActualVideoModeParams().windowWidth;
  float fHeight = (float)GetActualVideoModeParams().windowHeight;
  float fPercentShiftX = SCALE(fTranslateX, 0, fWidth, 0, +2.0f);
  float fPercentShiftY = SCALE(fTranslateY, 0, fHeight, 0, -2.0f);
  float fPercentScaleX = SCALE(fAddWidth, 0, fWidth, 1.0f, 2.0f);
  float fPercentScaleY = SCALE(fAddHeight, 0, fHeight, 1.0f, 2.0f);

  RageMatrix m1;
  RageMatrix m2;
  RageMatrixTranslation(&m1, fPercentShiftX, fPercentShiftY, 0);
  RageMatrixScaling(&m2, fPercentScaleX, fPercentScaleY, 1);
  RageMatrix mOut;
  RageMatrixMultiply(&mOut, &m1, &m2);
  return mOut;
}

void RageDisplay::UpdateCentering() {
  const Centering& p = g_CenteringStack.back();
  g_CenteringMatrix = GetCenteringMatrix(
      (float)p.m_iTranslateX, (float)p.m_iTranslateY, (float)p.m_iAddWidth,
      (float)p.m_iAddHeight);
}

bool RageDisplay::SaveScreenshot(
    const std::string& sPath, GraphicsFileFormat format) {
  RageSurface* surface = this->CreateScreenshot();

  if (nullptr == surface) {
    LOG->Warn("SaveScreenshot: failed to create a screenshot surface");
    return false;
  }

  /* Unless we're in lossless, resize the image to 640x480.  If we're saving
   * lossy, there's no sense in saving 1280x960 screenshots, and we don't want
   * to output screenshots in a strange (non-1) sample aspect ratio. */
  if (format != SAVE_LOSSLESS && format != SAVE_LOSSLESS_SENSIBLE) {
    // Maintain the DAR.
    ASSERT(GetActualVideoModeParams().fDisplayAspectRatio > 0);
    int iHeight = 480;
    // This used to be lrint. However, lrint causes odd resolutions like
    // 639x480 (4:3) and 853x480 (16:9). ceil gives correct values. -aj
    int iWidth =
        std::ceil(iHeight * GetActualVideoModeParams().fDisplayAspectRatio);
    RageSurfaceUtils::Zoom(surface, iWidth, iHeight);
  }

  RageFile out;
  if (!out.Open(sPath, RageFile::WRITE)) {
    LOG->Warn(
        "SaveScreenshot: Failed to open %s for writing: %s", sPath.c_str(),
        out.GetError().c_str());
    RageUtil::SafeDelete(surface);
    return false;
  }

  bool bSuccess = false;
  std::string strError = "";
  switch (format) {
    case SAVE_LOSSLESS:
      bSuccess = RageSurfaceUtils::SaveBMP(surface, out);
      break;
    case SAVE_LOSSLESS_SENSIBLE:
      bSuccess = RageSurfaceUtils::SavePNG(surface, out, strError);
      break;
    case SAVE_LOSSY_LOW_QUAL:
      bSuccess = RageSurfaceUtils::SaveJPEG(surface, out, false);
      break;
    case SAVE_LOSSY_HIGH_QUAL:
      bSuccess = RageSurfaceUtils::SaveJPEG(surface, out, true);
      break;
    default:
      LOG->Warn(
          "SaveScreenshot: Invalid graphics file format requested %d", format);
      bSuccess = false;
      break;
  }

  RageUtil::SafeDelete(surface);

  if (!bSuccess) {
    LOG->Warn(
        "SaveScreenshot: Failed to save screenshot to %s: %s", sPath.c_str(),
        out.GetError().c_str());
  }

  return bSuccess;
}

void RageDisplay::DrawQuads(const RageSpriteVertex v[], int iNumVerts) {
  ASSERT((iNumVerts % 4) == 0);

  if (!iNumVerts) {
    return;
  }

  this->DrawQuadsInternal(v, iNumVerts);

  StatsAddVerts(iNumVerts);
}

void RageDisplay::DrawQuadStrip(const RageSpriteVertex v[], int iNumVerts) {
  ASSERT((iNumVerts % 2) == 0);

  if (iNumVerts < 4) {
    return;
  }

  this->DrawQuadStripInternal(v, iNumVerts);

  StatsAddVerts(iNumVerts);
}

void RageDisplay::DrawFan(const RageSpriteVertex v[], int iNumVerts) {
  ASSERT(iNumVerts >= 3);

  this->DrawFanInternal(v, iNumVerts);

  StatsAddVerts(iNumVerts);
}

void RageDisplay::DrawStrip(const RageSpriteVertex v[], int iNumVerts) {
  ASSERT(iNumVerts >= 3);

  this->DrawStripInternal(v, iNumVerts);

  StatsAddVerts(iNumVerts);
}

void RageDisplay::DrawTriangles(const RageSpriteVertex v[], int iNumVerts) {
  if (iNumVerts == 0) {
    return;
  }

  ASSERT(iNumVerts >= 3);

  this->DrawTrianglesInternal(v, iNumVerts);

  StatsAddVerts(iNumVerts);
}

void RageDisplay::DrawCompiledGeometry(
    const RageCompiledGeometry* p, int iMeshIndex,
    const std::vector<msMesh>& vMeshes) {
  this->DrawCompiledGeometryInternal(p, iMeshIndex);

  StatsAddVerts(vMeshes[iMeshIndex].Triangles.size());
}

void RageDisplay::DrawLineStrip(
    const RageSpriteVertex v[], int iNumVerts, float LineWidth) {
  ASSERT(iNumVerts >= 2);

  this->DrawLineStripInternal(v, iNumVerts, LineWidth);
}

/*
 * Draw a strip of:
 *
 * 0..1..2
 * . /.\ .
 * ./ . \.
 * 3..4..5
 * . /.\ .
 * ./ . \.
 * 6..7..8
 */

void RageDisplay::DrawSymmetricQuadStrip(
    const RageSpriteVertex v[], int iNumVerts) {
  ASSERT(iNumVerts >= 3);

  if (iNumVerts < 6) {
    return;
  }

  this->DrawSymmetricQuadStripInternal(v, iNumVerts);

  StatsAddVerts(iNumVerts);
}

void RageDisplay::DrawCircle(const RageSpriteVertex& v, float radius) {
  this->DrawCircleInternal(v, radius);
}

void RageDisplay::SetRuntimeFramePacingTargetHz(float targetHz) {
  g_fFramePacingRuntimeTargetHz = ClampFramePacingHz(targetHz);
}

void RageDisplay::FrameLimitBeforeVsync(int iFPS) {
  ASSERT(iFPS != 0);

  const float targetHz = EffectiveFramePacingTargetHz(iFPS);
  if (targetHz > 0.0f) {
    const uint64_t intervalUsec = FramePacingIntervalUsec(targetHz);
    const uint64_t marginUsec = FramePacingEffectiveMarginUsec(intervalUsec);
    uint64_t waitMarginUsec = marginUsec;
	    const uint64_t maxSleepChunkUsec =
	        FramePacingMaxSleepChunkUsec(intervalUsec);
	    const uint64_t fineWaitUsec = FramePacingFineWaitUsec(intervalUsec);
	#ifdef __APPLE__
	    uint64_t macOSPresentLeadUsec =
	        FramePacingMacOSAdaptiveLeadUsec(intervalUsec);
	#else
	    const uint64_t macOSPresentLeadUsec = 0;
	#endif
    g_iFramePacerLastWaitMarginUsec = waitMarginUsec;
    const uint64_t nowUsec = RageTimer::GetTimeSinceStartMicroseconds();

    if (!g_bFramePacerWasEnabled || g_iFramePacerNextPresentUsec == 0) {
      g_iFramePacerNextPresentUsec = nowUsec + intervalUsec;
      g_bFramePacerWasEnabled = true;
      g_bFramePacerLoggedEnable = false;
      if (g_iFramePacerWarmupFramesRemaining == 0) {
        g_iFramePacerWarmupFramesRemaining =
            FramePacingAdaptiveWarmupFrames();
      }
    }

    if (!g_bFramePacerLoggedEnable && PerfDiagnosticsEnabled()) {
      LOG->Trace(
          "FRAME_PACING: enabled target_hz=%.3f interval_us=%llu "
          "sleep_margin_us=%llu effective_margin_us=%llu "
          "adaptive_margin=%d adaptive_max_margin_us=%llu "
          "adaptive_warmup_frames=%d adaptive_late_frames=%d "
          "adaptive_wake_late_us=%llu adaptive_wake_late_frames=%d "
          "adaptive_wake_late_step_us=%llu phase_resync_us=%llu "
          "wait_resync_us=%llu max_sleep_chunk_us=%llu "
          "fine_wait_us=%llu spin_cap_us=%llu wait_strategy=%s "
          "configured_target_hz=%.3f legacy_frame_limit_percent=%.3f "
          "mode_rate=%d"
#ifdef __APPLE__
          " macos_display_link_enabled=%d "
          "macos_adaptive_lead=%d macos_lead_us=%llu "
	          "macos_lead_base_us=%llu macos_lead_max_us=%llu "
	          "macos_wait_cap_us=%llu macos_wait_step_down_us=%llu "
	          "macos_lead_safe=%d"
	#endif
          ,
          targetHz, static_cast<unsigned long long>(intervalUsec),
          static_cast<unsigned long long>(g_iFramePacerLastBaseMarginUsec),
          static_cast<unsigned long long>(marginUsec),
          g_bFramePacingAdaptiveMargin.Get() ? 1 : 0,
          static_cast<unsigned long long>(g_iFramePacerLastMaxMarginUsec),
          FramePacingAdaptiveWarmupFrames(),
          FramePacingAdaptiveLateFrames(),
          static_cast<unsigned long long>(
              FramePacingAdaptiveWakeLateThresholdUsec(intervalUsec)),
          FramePacingAdaptiveWakeLateFrames(),
          static_cast<unsigned long long>(
              FramePacingAdaptiveWakeLateStepUpUsec(intervalUsec)),
          static_cast<unsigned long long>(
              FramePacingPhaseResyncThresholdUsec(intervalUsec)),
          static_cast<unsigned long long>(
              FramePacingWaitResyncThresholdUsec(intervalUsec)),
          static_cast<unsigned long long>(maxSleepChunkUsec),
          static_cast<unsigned long long>(fineWaitUsec),
          static_cast<unsigned long long>(
              FramePacingMaxSpinUsec(fineWaitUsec)),
          FramePacingWaitStrategyName(),
          ClampFramePacingHz(g_fFramePacingTargetHz.Get()),
          g_fFrameLimitPercent.Get(), iFPS
#ifdef __APPLE__
          ,
          MacOSFramePacingDisplayLinkEnabled() ? 1 : 0,
          FramePacingMacOSAdaptiveLeadEnabled() ? 1 : 0,
          static_cast<unsigned long long>(macOSPresentLeadUsec),
          static_cast<unsigned long long>(
              g_iFramePacerLastMacOSAdaptiveLeadBaseUsec),
          static_cast<unsigned long long>(
              g_iFramePacerLastMacOSAdaptiveLeadMaxUsec),
          static_cast<unsigned long long>(
              FramePacingMacOSAdaptiveLeadWaitCapUsec(
                  intervalUsec, g_iFramePacerLastMacOSAdaptiveLeadBaseUsec,
                  g_iFramePacerLastMacOSAdaptiveLeadMaxUsec)),
	          static_cast<unsigned long long>(
	              FramePacingMacOSAdaptiveLeadWaitStepDownUsec(intervalUsec)),
	          g_bFramePacerMacOSSafeMode ? 1 : 0
	#endif
	          );
    }
    g_bFramePacerLoggedEnable = true;

    int64_t lateUsec =
        static_cast<int64_t>(nowUsec) -
        static_cast<int64_t>(g_iFramePacerNextPresentUsec);
    g_szFramePacerLastBeforeSwapResyncReason = "none";
    g_iFramePacerLastBeforeSwapPhaseErrorUsec = lateUsec;
    if (lateUsec >
        static_cast<int64_t>(FramePacingResyncThresholdUsec(intervalUsec))) {
      if (PerfDiagnosticsEnabled()) {
        LOG->Trace(
            "FRAME_PACING: resync phase=before_swap reason=very_late_no_wait "
            "late_us=%lld target_hz=%.3f interval_us=%llu",
            static_cast<long long>(lateUsec), targetHz,
            static_cast<unsigned long long>(intervalUsec));
      }
      g_szFramePacerLastBeforeSwapResyncReason = "very_late_no_wait";
    } else if (
        lateUsec >
        static_cast<int64_t>(FramePacingPhaseResyncThresholdUsec(
            intervalUsec))) {
      if (PerfDiagnosticsEnabled()) {
        LOG->Trace(
            "FRAME_PACING: resync phase=before_swap reason=phase_late_no_wait "
            "late_us=%lld target_hz=%.3f interval_us=%llu threshold_us=%llu",
            static_cast<long long>(lateUsec), targetHz,
            static_cast<unsigned long long>(intervalUsec),
            static_cast<unsigned long long>(
                FramePacingPhaseResyncThresholdUsec(intervalUsec)));
      }
      g_szFramePacerLastBeforeSwapResyncReason = "phase_late_no_wait";
    } else {
      const int64_t leadUsec =
          static_cast<int64_t>(g_iFramePacerNextPresentUsec) -
          static_cast<int64_t>(nowUsec);
      const uint64_t maxLeadUsec = intervalUsec + waitMarginUsec;
      if (leadUsec > static_cast<int64_t>(maxLeadUsec)) {
        if (PerfDiagnosticsEnabled()) {
          LOG->Trace(
              "FRAME_PACING: resync phase=before_swap reason=phase_ahead "
              "lead_us=%lld target_hz=%.3f interval_us=%llu max_lead_us=%llu",
              static_cast<long long>(leadUsec), targetHz,
              static_cast<unsigned long long>(intervalUsec),
              static_cast<unsigned long long>(maxLeadUsec));
        }
        g_iFramePacerNextPresentUsec = nowUsec + intervalUsec;
        lateUsec = -static_cast<int64_t>(intervalUsec);
        g_iFramePacerLastBeforeSwapPhaseErrorUsec = -leadUsec;
        g_szFramePacerLastBeforeSwapResyncReason = "phase_ahead";
      }
    }

    uint64_t wakeUsec =
        g_iFramePacerNextPresentUsec > waitMarginUsec
            ? g_iFramePacerNextPresentUsec - waitMarginUsec
            : g_iFramePacerNextPresentUsec;
    int64_t plannedWaitUsec =
        static_cast<int64_t>(wakeUsec) - static_cast<int64_t>(nowUsec);
    const uint64_t maxPlannedWaitUsec =
        intervalUsec + std::max<uint64_t>(500, intervalUsec / 8);
	    if (plannedWaitUsec >
	        static_cast<int64_t>(maxPlannedWaitUsec)) {
      if (PerfDiagnosticsEnabled()) {
        LOG->Trace(
            "FRAME_PACING: resync phase=before_swap "
            "reason=planned_wait_over_budget planned_wait_us=%lld "
            "target_hz=%.3f interval_us=%llu margin_us=%llu "
            "wait_margin_us=%llu "
            "max_planned_wait_us=%llu",
            static_cast<long long>(plannedWaitUsec), targetHz,
            static_cast<unsigned long long>(intervalUsec),
          static_cast<unsigned long long>(marginUsec),
          static_cast<unsigned long long>(waitMarginUsec),
          static_cast<unsigned long long>(maxPlannedWaitUsec));
      }
      g_iFramePacerNextPresentUsec = nowUsec + intervalUsec;
      wakeUsec = g_iFramePacerNextPresentUsec > waitMarginUsec
                     ? g_iFramePacerNextPresentUsec - waitMarginUsec
                     : g_iFramePacerNextPresentUsec;
      plannedWaitUsec =
          static_cast<int64_t>(wakeUsec) - static_cast<int64_t>(nowUsec);
      g_iFramePacerLastBeforeSwapPhaseErrorUsec =
          -static_cast<int64_t>(intervalUsec);
	      g_szFramePacerLastBeforeSwapResyncReason =
	          "planned_wait_over_budget";
	    }

	    FramePacingWaitStats waitStats;
    if (plannedWaitUsec > 0) {
      waitStats = WaitUntilFramePacingWakeUsec(
          wakeUsec, g_iFramePacerNextPresentUsec, intervalUsec, fineWaitUsec,
          maxSleepChunkUsec, HOOKS->AppHasFocus(), macOSPresentLeadUsec);
    }

    const uint64_t afterWaitUsec =
        RageTimer::GetTimeSinceStartMicroseconds();
    g_iFramePacerLastPlannedWaitUsec =
        plannedWaitUsec > 0 ? static_cast<uint64_t>(plannedWaitUsec) : 0;
    g_iFramePacerLastSleepUsec = waitStats.requested_sleep_usec;
    g_iFramePacerLastActualSleepUsec = waitStats.actual_sleep_usec;
    g_iFramePacerLastSleepOvershootUsec = waitStats.sleep_overshoot_usec;
    g_iFramePacerLastFineWaitUsec = waitStats.fine_wait_usec;
    g_iFramePacerLastSpinWaitUsec = waitStats.spin_wait_usec;
    g_iFramePacerLastSpinCapUsec = waitStats.spin_cap_usec;
    g_iFramePacerLastWaitResyncThresholdUsec =
        FramePacingWaitResyncThresholdUsec(intervalUsec);
    g_szFramePacerLastWaitAbortReason = waitStats.abort_reason;
#ifdef __APPLE__
    g_iFramePacerLastDisplayLinkPeriodUsec =
        waitStats.display_link_period_usec;
    g_iFramePacerLastDisplayLinkTickCount =
        waitStats.display_link_tick_count;
    g_iFramePacerLastDisplayLinkTicksDuringWait =
        waitStats.display_link_ticks_during_wait;
    g_iFramePacerLastDisplayLinkWaitActualUsec =
        waitStats.display_link_wait_actual_usec;
    g_iFramePacerLastDisplayLinkFinalWaitUsec =
        waitStats.display_link_final_wait_usec;
    g_iFramePacerLastDisplayLinkFinalWaitSleepUsec =
        waitStats.display_link_final_wait_sleep_usec;
    g_iFramePacerLastDisplayLinkFinalWaitYieldUsec =
        waitStats.display_link_final_wait_yield_usec;
    g_iFramePacerLastDisplayLinkFinalWaitSpinUsec =
        waitStats.display_link_final_wait_spin_usec;
    g_iFramePacerLastDisplayLinkFinalWaitOvershootUsec =
        waitStats.display_link_final_wait_overshoot_usec;
    g_iFramePacerLastDisplayLinkFinalWaitSleepChunks =
        waitStats.display_link_final_wait_sleep_chunks;
    g_iFramePacerLastDisplayLinkFinalWaitYields =
        waitStats.display_link_final_wait_yields;
    g_iFramePacerLastDisplayLinkPresentLeadUsec =
        waitStats.display_link_present_lead_usec;
    g_iFramePacerLastDisplayLinkLateToleranceUsec =
        waitStats.display_link_late_tolerance_usec;
    g_iFramePacerLastDisplayLinkPhaseToleranceUsec =
        waitStats.display_link_phase_tolerance_usec;
    g_iFramePacerLastDisplayLinkTargetUsec =
        waitStats.display_link_target_usec;
    g_iFramePacerLastDisplayLinkDesiredUsec =
        waitStats.display_link_desired_usec;
    g_iFramePacerLastDisplayLinkLatestUsec =
        waitStats.display_link_latest_usec;
    g_iFramePacerLastDisplayLinkLastOutputUsec =
        waitStats.display_link_last_output_usec;
    g_iFramePacerLastDisplayLinkSelectedOutputUsec =
        waitStats.display_link_selected_output_usec;
    g_iFramePacerLastDisplayLinkOutputToTargetUsec =
        waitStats.display_link_output_to_target_usec;
    g_iFramePacerLastDisplayLinkSelectedOutputToTargetUsec =
        waitStats.display_link_selected_output_to_target_usec;
    g_iFramePacerLastDisplayLinkOutputLateUsec =
        waitStats.display_link_output_late_usec;
    g_bFramePacerLastDisplayLinkUsed = waitStats.display_link_used;
    g_bFramePacerLastDisplayLinkTimedOut =
        waitStats.display_link_timed_out;
    g_bFramePacerLastDisplayLinkFinalWaitCapped =
        waitStats.display_link_final_wait_capped;
    g_bFramePacerLastDisplayLinkOutputPhaseAccepted =
        waitStats.display_link_output_phase_accepted;
    g_iFramePacerLastDisplayLinkOutputAlignedPresentMode =
        waitStats.display_link_output_aligned_present_mode;
    g_bFramePacerLastDisplayLinkOutputAlignedPresentEnabled =
        waitStats.display_link_output_aligned_present_enabled;
    g_bFramePacerLastDisplayLinkOutputAlignedPresent =
        waitStats.display_link_output_aligned_present;
    g_bFramePacerLastDisplayLinkOutputCapRejected =
        waitStats.display_link_output_cap_rejected;
    g_szFramePacerLastDisplayLinkSelectedOutputSource =
        waitStats.display_link_selected_output_source != nullptr
            ? waitStats.display_link_selected_output_source
            : "unknown";
    g_szFramePacerLastDisplayLinkStatus =
        waitStats.display_link_status != nullptr
            ? waitStats.display_link_status
            : "unknown";
#endif
    g_iFramePacerLastLateBeforeUsec = lateUsec;
    g_iFramePacerLastLateAfterWaitUsec =
        static_cast<int64_t>(afterWaitUsec) -
        static_cast<int64_t>(g_iFramePacerNextPresentUsec);
    g_iFramePacerLastWakeLateUsec =
        static_cast<int64_t>(afterWaitUsec) - static_cast<int64_t>(wakeUsec);
    g_iFramePacerLastSleepChunks = waitStats.sleep_chunks;
    return;
  }

  if (g_bFramePacerWasEnabled) {
    if (PerfDiagnosticsEnabled()) {
      LOG->Trace("FRAME_PACING: disabled");
    }
    ResetFramePacer();
  }

  int iDelayMicroseconds = 0;
  if (g_fFrameLimitPercent.Get() > 0.0f && !g_LastFrameEndedAt.IsZero()) {
    float fFrameTime = g_LastFrameEndedAt.GetDeltaTime();
    float fExpectedTime = 1.0f / iFPS;

    /* This is typically used to turn some of the delay that would normally
     * be waiting for vsync and turn it into a usleep, to make sure we give
     * up the CPU.  If we overshoot the sleep, then we'll miss the vsync,
     * so allow tweaking the amount of time we expect a frame to take.
     * Frame limiting is disabled by setting this to 0. */
    fExpectedTime *= g_fFrameLimitPercent.Get();
    float fExtraTime = fExpectedTime - fFrameTime;

    iDelayMicroseconds = int(fExtraTime * 1000000);
  }

  if (!HOOKS->AppHasFocus()) {
    iDelayMicroseconds = std::max(
        iDelayMicroseconds,
        10000);  // give some time to other processes and threads
  }

  if (iDelayMicroseconds > 0) {
    usleep(iDelayMicroseconds);
  }
}

void RageDisplay::FrameLimitAfterVsync(float swapBuffersMs) {
  const float targetHz =
      EffectiveFramePacingTargetHz(GetActualVideoModeParams().rate);
  if (targetHz > 0.0f) {
    const uint64_t intervalUsec = FramePacingIntervalUsec(targetHz);
    const uint64_t nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
    const uint64_t swapBuffersUsec =
        FramePacingSwapBuffersUsec(swapBuffersMs);
    const int64_t presentLateUsec =
        g_iFramePacerNextPresentUsec == 0
            ? 0
            : static_cast<int64_t>(nowUsec) -
                  static_cast<int64_t>(g_iFramePacerNextPresentUsec);
    const uint64_t waitResyncThresholdUsec =
        FramePacingWaitResyncThresholdUsec(intervalUsec);
    const int64_t positiveWakeLateUsec =
        std::max<int64_t>(0, g_iFramePacerLastWakeLateUsec);
    const bool waitAbort =
        std::strcmp(g_szFramePacerLastWaitAbortReason, "none") != 0;
    const bool waitLateAfterWait =
        g_iFramePacerLastLateAfterWaitUsec > 0 || presentLateUsec > 0;
    const bool waitWakeLate =
        positiveWakeLateUsec > static_cast<int64_t>(waitResyncThresholdUsec) &&
        waitLateAfterWait;
    const bool waitOverslept =
        g_iFramePacerLastSleepOvershootUsec > waitResyncThresholdUsec &&
        waitLateAfterWait;
    const bool spinPreempted =
        std::strcmp(g_szFramePacerLastWaitAbortReason, "spin_preempted") == 0;
    const bool spinPreemptedLate = spinPreempted && waitLateAfterWait;
    const float traceLateMs =
        std::max(0.0f, g_fPerfTraceFramePacingLateMs.Get());
    const int64_t traceLateUsec =
        static_cast<int64_t>(std::llround(traceLateMs * 1000.0f));
    const bool swapLikelyBlocked =
        FramePacingSwapLikelyBlocked(swapBuffersUsec, intervalUsec);

    ++g_iFramePacerFrames;
    uint64_t nextPresentUsec = g_iFramePacerNextPresentUsec + intervalUsec;
    int skippedIntervals = 0;
    while (nextPresentUsec <= nowUsec && skippedIntervals < 4) {
      nextPresentUsec += intervalUsec;
      ++skippedIntervals;
    }

    bool hardResynced = false;
    bool phaseResynced = false;
    bool waitResynced = false;
    g_szFramePacerLastAfterSwapResyncReason = "none";
#ifdef __APPLE__
    g_bFramePacerLastDisplayLinkPhaseAligned = false;
    g_iFramePacerLastDisplayLinkPhaseAlignUsec = 0;
#endif
    if (presentLateUsec >
            static_cast<int64_t>(FramePacingResyncThresholdUsec(intervalUsec)) ||
        nextPresentUsec <= nowUsec) {
      nextPresentUsec = nowUsec + intervalUsec;
      hardResynced = true;
      g_szFramePacerLastAfterSwapResyncReason = "hard_present_late";
    } else if (
        presentLateUsec >
        static_cast<int64_t>(FramePacingPhaseResyncThresholdUsec(
            intervalUsec))) {
      nextPresentUsec = nowUsec + intervalUsec;
      phaseResynced = true;
      g_szFramePacerLastAfterSwapResyncReason = "phase_present_late";
    } else if (
        waitWakeLate || waitOverslept || spinPreemptedLate ||
        (waitAbort && waitLateAfterWait)) {
      nextPresentUsec = nowUsec + intervalUsec;
      phaseResynced = true;
      waitResynced = true;
      g_szFramePacerLastAfterSwapResyncReason =
          spinPreemptedLate ? "spin_preempted"
          : waitWakeLate ? "wake_late"
          : waitOverslept ? "sleep_overshoot"
                          : g_szFramePacerLastWaitAbortReason;
    }

    UpdateFramePacingAdaptiveMargin(
        intervalUsec, presentLateUsec, skippedIntervals, hardResynced,
        phaseResynced, swapBuffersUsec);
#ifdef __APPLE__
    UpdateFramePacingMacOSAdaptiveLead(
        intervalUsec, presentLateUsec, skippedIntervals, hardResynced,
        phaseResynced, swapBuffersUsec);
#endif

    const int64_t absPresentLateUsec =
        presentLateUsec < 0 ? -presentLateUsec : presentLateUsec;
    const int64_t absWakeLateUsec =
        g_iFramePacerLastWakeLateUsec < 0
            ? -g_iFramePacerLastWakeLateUsec
            : g_iFramePacerLastWakeLateUsec;
    const bool shouldTraceFramePacing =
        absPresentLateUsec >= traceLateUsec ||
        absWakeLateUsec >= traceLateUsec ||
        g_iFramePacerLastSleepOvershootUsec >=
            static_cast<uint64_t>(traceLateUsec) ||
        skippedIntervals > 0 || hardResynced || phaseResynced ||
        waitResynced ||
        g_bFramePacerLastAdaptiveChanged ||
#ifdef __APPLE__
        g_bFramePacerLastMacOSAdaptiveLeadChanged ||
#endif
        g_iFramePacerFrames <= 5 ||
        g_iFramePacerFrames % 240 == 0;
    const bool framePacingTraceRateLimited =
        g_iFramePacerFrames > 5 && g_iFramePacerFrames % 240 != 0 &&
        g_iFramePacerLastPresentTraceUsec != 0 &&
        nowUsec - g_iFramePacerLastPresentTraceUsec < 250000;
    if (PerfDiagnosticsEnabled() && shouldTraceFramePacing &&
        !framePacingTraceRateLimited) {
      g_iFramePacerLastPresentTraceUsec = nowUsec;
      LOG->Trace(
          "FRAME_PACING: present frame=%llu target_hz=%.3f "
          "base_margin_us=%llu effective_margin_us=%llu next_margin_us=%llu "
          "wait_margin_us=%llu max_margin_us=%llu adaptive_adjust_us=%lld "
          "adaptive_reason=%s stable_frames=%d swap_buffers_us=%llu "
          "late_streak=%d wake_late_streak=%d warmup_remaining=%d "
          "classification=%s "
          "planned_wait_us=%llu sleep_us=%llu actual_sleep_us=%llu "
          "sleep_overshoot_us=%llu sleep_chunks=%d fine_wait_us=%llu "
          "spin_wait_us=%llu wake_late_us=%lld late_before_us=%lld "
          "late_after_wait_us=%lld present_late_us=%lld "
          "next_interval_us=%llu skipped_intervals=%d resynced=%d "
          "hard_resynced=%d phase_resynced=%d "
          "wait_resynced=%d wait_abort=%s wait_resync=%s "
          "wait_resync_us=%llu spin_cap_us=%llu "
          "before_swap_resync=%s before_swap_phase_error_us=%lld"
#ifdef __APPLE__
          " macos_adaptive_lead_us=%llu "
          "macos_adaptive_lead_base_us=%llu "
          "macos_adaptive_lead_max_us=%llu "
          "macos_adaptive_lead_adjust_us=%lld "
          "macos_adaptive_lead_reason=%s "
          "macos_swap_block_streak=%d "
          "macos_severe_swap_streak=%d "
          "macos_swap_block_pressure=%d "
          "macos_swap_pressure_lead_mode=%d "
          "macos_swap_pressure_transient_frames=%d "
          "macos_risky_swap=%d "
          "macos_severe_swap=%d "
          "macos_risky_swap_threshold_us=%llu "
          "macos_severe_swap_threshold_us=%llu "
	          "macos_wait_overshoot_pressure=%d "
	          "macos_wait_overshoot_active=%d "
	          "macos_wait_cap_us=%llu "
		          "macos_lead_stable_frames=%d "
		          "macos_safe_mode=%d "
	          "macos_early_swap_backpressure=%d "
	          "macos_pre_swap_load_pressure=%d "
	          "macos_pre_swap_load_frames=%d "
	          "macos_pre_swap_load_us=%llu "
	          "macos_pre_swap_load_threshold_us=%llu"
	          " display_link_used=%d display_link_status=%s "
          "display_link_timed_out=%d display_link_period_us=%llu "
          "display_link_ticks=%llu display_link_ticks_wait=%llu "
          "display_link_wait_us=%llu display_link_final_wait_us=%llu "
          "display_link_final_sleep_us=%llu "
          "display_link_final_yield_us=%llu "
          "display_link_final_spin_us=%llu "
          "display_link_final_overshoot_us=%llu "
          "display_link_final_sleep_chunks=%d "
          "display_link_final_yields=%d "
          "display_link_present_lead_us=%llu "
          "display_link_late_tolerance_us=%llu "
          "display_link_phase_tolerance_us=%llu "
          "display_link_target_us=%llu display_link_desired_us=%llu "
          "display_link_latest_us=%llu display_link_last_output_us=%llu "
          "display_link_selected_output_us=%llu "
          "display_link_selected_output_source=%s "
          "display_link_final_wait_capped=%d "
          "display_link_output_phase_accepted=%d "
          "display_link_output_aligned_present_mode=%d "
          "display_link_output_aligned_present_enabled=%d "
          "display_link_output_aligned_present=%d "
          "display_link_output_cap_rejected=%d "
          "display_link_phase_aligned=%d "
          "display_link_phase_align_us=%lld "
          "display_link_output_to_target_us=%lld "
          "display_link_selected_output_to_target_us=%lld "
          "display_link_output_late_us=%lld"
#endif
          ,
          static_cast<unsigned long long>(g_iFramePacerFrames), targetHz,
          static_cast<unsigned long long>(g_iFramePacerLastBaseMarginUsec),
          static_cast<unsigned long long>(
              g_iFramePacerLastEffectiveMarginUsec),
          static_cast<unsigned long long>(g_iFramePacerLastNextMarginUsec),
          static_cast<unsigned long long>(g_iFramePacerLastWaitMarginUsec),
          static_cast<unsigned long long>(g_iFramePacerLastMaxMarginUsec),
          static_cast<long long>(g_iFramePacerLastAdaptiveAdjustUsec),
          g_szFramePacerLastAdaptiveReason, g_iFramePacerStableFrames,
          static_cast<unsigned long long>(g_iFramePacerLastSwapBuffersUsec),
          g_iFramePacerConsecutiveLateFrames,
          g_iFramePacerConsecutiveWakeLateFrames,
          g_iFramePacerWarmupFramesRemaining,
          g_szFramePacerLastClassification,
          static_cast<unsigned long long>(g_iFramePacerLastPlannedWaitUsec),
          static_cast<unsigned long long>(g_iFramePacerLastSleepUsec),
          static_cast<unsigned long long>(g_iFramePacerLastActualSleepUsec),
          static_cast<unsigned long long>(
              g_iFramePacerLastSleepOvershootUsec),
          g_iFramePacerLastSleepChunks,
          static_cast<unsigned long long>(g_iFramePacerLastFineWaitUsec),
          static_cast<unsigned long long>(g_iFramePacerLastSpinWaitUsec),
          static_cast<long long>(g_iFramePacerLastWakeLateUsec),
          static_cast<long long>(g_iFramePacerLastLateBeforeUsec),
          static_cast<long long>(g_iFramePacerLastLateAfterWaitUsec),
          static_cast<long long>(presentLateUsec),
          static_cast<unsigned long long>(intervalUsec), skippedIntervals,
          (hardResynced || phaseResynced) ? 1 : 0,
          hardResynced ? 1 : 0, phaseResynced ? 1 : 0,
          waitResynced ? 1 : 0,
          g_szFramePacerLastWaitAbortReason,
          g_szFramePacerLastAfterSwapResyncReason,
          static_cast<unsigned long long>(
              g_iFramePacerLastWaitResyncThresholdUsec),
          static_cast<unsigned long long>(g_iFramePacerLastSpinCapUsec),
          g_szFramePacerLastBeforeSwapResyncReason,
          static_cast<long long>(
              g_iFramePacerLastBeforeSwapPhaseErrorUsec)
#ifdef __APPLE__
              ,
          static_cast<unsigned long long>(
              g_iFramePacerMacOSAdaptiveLeadUsec),
          static_cast<unsigned long long>(
              g_iFramePacerLastMacOSAdaptiveLeadBaseUsec),
          static_cast<unsigned long long>(
              g_iFramePacerLastMacOSAdaptiveLeadMaxUsec),
          static_cast<long long>(
              g_iFramePacerLastMacOSAdaptiveLeadAdjustUsec),
          g_szFramePacerLastMacOSAdaptiveLeadReason,
          g_iFramePacerMacOSSwapBlockStreak,
          g_iFramePacerMacOSSevereSwapBlockStreak,
          g_iFramePacerMacOSSwapBlockPressure,
          FramePacingMacOSSwapPressureLeadMode(),
          g_iFramePacerMacOSSwapPressureTransientFrames,
          FramePacingMacOSRiskySwapBlocked(
              g_iFramePacerLastSwapBuffersUsec, intervalUsec)
              ? 1
              : 0,
          FramePacingMacOSSevereSwapBlocked(
              g_iFramePacerLastSwapBuffersUsec, intervalUsec)
              ? 1
              : 0,
          static_cast<unsigned long long>(
              FramePacingMacOSRiskySwapThresholdUsec(intervalUsec)),
          static_cast<unsigned long long>(
              FramePacingMacOSSevereSwapThresholdUsec(intervalUsec)),
          g_iFramePacerMacOSWaitOvershootPressure,
	          g_bFramePacerLastMacOSWaitOvershootPressure ? 1 : 0,
	          static_cast<unsigned long long>(
	              g_iFramePacerLastMacOSWaitCapUsec),
	          g_iFramePacerMacOSLeadStableFrames,
	          g_bFramePacerMacOSSafeMode ? 1 : 0,
	          g_bFramePacerLastMacOSEarlySwapBackpressure ? 1 : 0,
	          g_bFramePacerLastMacOSPreSwapLoadPressure ? 1 : 0,
	          g_iFramePacerMacOSPreSwapLoadPressureFrames,
	          static_cast<unsigned long long>(
	              g_iFramePacerLastMacOSPreSwapLoadUsec),
	          static_cast<unsigned long long>(
	              g_iFramePacerLastMacOSPreSwapLoadThresholdUsec),
	          g_bFramePacerLastDisplayLinkUsed ? 1 : 0,
          g_szFramePacerLastDisplayLinkStatus,
          g_bFramePacerLastDisplayLinkTimedOut ? 1 : 0,
          static_cast<unsigned long long>(
              g_iFramePacerLastDisplayLinkPeriodUsec),
          static_cast<unsigned long long>(
              g_iFramePacerLastDisplayLinkTickCount),
          static_cast<unsigned long long>(
              g_iFramePacerLastDisplayLinkTicksDuringWait),
          static_cast<unsigned long long>(
              g_iFramePacerLastDisplayLinkWaitActualUsec),
          static_cast<unsigned long long>(
              g_iFramePacerLastDisplayLinkFinalWaitUsec),
          static_cast<unsigned long long>(
              g_iFramePacerLastDisplayLinkFinalWaitSleepUsec),
          static_cast<unsigned long long>(
              g_iFramePacerLastDisplayLinkFinalWaitYieldUsec),
          static_cast<unsigned long long>(
              g_iFramePacerLastDisplayLinkFinalWaitSpinUsec),
          static_cast<unsigned long long>(
              g_iFramePacerLastDisplayLinkFinalWaitOvershootUsec),
          g_iFramePacerLastDisplayLinkFinalWaitSleepChunks,
          g_iFramePacerLastDisplayLinkFinalWaitYields,
          static_cast<unsigned long long>(
              g_iFramePacerLastDisplayLinkPresentLeadUsec),
          static_cast<unsigned long long>(
              g_iFramePacerLastDisplayLinkLateToleranceUsec),
          static_cast<unsigned long long>(
              g_iFramePacerLastDisplayLinkPhaseToleranceUsec),
          static_cast<unsigned long long>(
              g_iFramePacerLastDisplayLinkTargetUsec),
          static_cast<unsigned long long>(
              g_iFramePacerLastDisplayLinkDesiredUsec),
          static_cast<unsigned long long>(
              g_iFramePacerLastDisplayLinkLatestUsec),
          static_cast<unsigned long long>(
              g_iFramePacerLastDisplayLinkLastOutputUsec),
          static_cast<unsigned long long>(
              g_iFramePacerLastDisplayLinkSelectedOutputUsec),
          g_szFramePacerLastDisplayLinkSelectedOutputSource,
          g_bFramePacerLastDisplayLinkFinalWaitCapped ? 1 : 0,
          g_bFramePacerLastDisplayLinkOutputPhaseAccepted ? 1 : 0,
          g_iFramePacerLastDisplayLinkOutputAlignedPresentMode,
          g_bFramePacerLastDisplayLinkOutputAlignedPresentEnabled ? 1 : 0,
          g_bFramePacerLastDisplayLinkOutputAlignedPresent ? 1 : 0,
          g_bFramePacerLastDisplayLinkOutputCapRejected ? 1 : 0,
          g_bFramePacerLastDisplayLinkPhaseAligned ? 1 : 0,
          static_cast<long long>(
              g_iFramePacerLastDisplayLinkPhaseAlignUsec),
          static_cast<long long>(
              g_iFramePacerLastDisplayLinkOutputToTargetUsec),
          static_cast<long long>(
              g_iFramePacerLastDisplayLinkSelectedOutputToTargetUsec),
          static_cast<long long>(
              g_iFramePacerLastDisplayLinkOutputLateUsec)
#endif
          );
    }

    g_iFramePacerNextPresentUsec = nextPresentUsec;
    return;
  }

  if (g_fFrameLimitPercent.Get() == 0.0f) {
    return;
  }

  g_LastFrameEndedAt.Touch();
}

void RageDisplay::ResetFramePacing(const char* reason) {
  const float targetHz =
      EffectiveFramePacingTargetHz(GetActualVideoModeParams().rate);
  const bool wasEnabled =
      g_bFramePacerWasEnabled || g_iFramePacerNextPresentUsec != 0;
  ResetFramePacer();
  ResetFramePresentationTelemetry();
#ifdef __APPLE__
  MacOSFramePacingResetDisplayLink(reason != nullptr ? reason : "manual");
#endif

  if (targetHz <= 0.0f) {
    return;
  }

  g_iFramePacerWarmupFramesRemaining = FramePacingAdaptiveWarmupFrames();
  if (PerfDiagnosticsEnabled()) {
    LOG->Trace(
        "FRAME_PACING: reset reason=%s target_hz=%.3f warmup_frames=%d "
        "was_enabled=%d",
        reason != nullptr ? reason : "manual", targetHz,
        g_iFramePacerWarmupFramesRemaining, wasEnabled ? 1 : 0);
  }
}

RageCompiledGeometry::~RageCompiledGeometry() { m_bNeedsNormals = false; }

void RageCompiledGeometry::Set(
    const std::vector<msMesh>& vMeshes, bool bNeedsNormals) {
  m_bNeedsNormals = bNeedsNormals;

  size_t totalVerts = 0;
  size_t totalTriangles = 0;

  m_bAnyNeedsTextureMatrixScale = false;

  m_vMeshInfo.resize(vMeshes.size());
  for (unsigned i = 0; i < vMeshes.size(); i++) {
    const msMesh& mesh = vMeshes[i];
    const std::vector<RageModelVertex>& Vertices = mesh.Vertices;
    const std::vector<msTriangle>& Triangles = mesh.Triangles;

    MeshInfo& meshInfo = m_vMeshInfo[i];
    meshInfo.m_bNeedsTextureMatrixScale = false;

    meshInfo.iVertexStart = totalVerts;
    meshInfo.iVertexCount = Vertices.size();
    meshInfo.iTriangleStart = totalTriangles;
    meshInfo.iTriangleCount = Triangles.size();

    totalVerts += Vertices.size();
    totalTriangles += Triangles.size();

    for (unsigned j = 0; j < Vertices.size(); ++j) {
      if (Vertices[j].TextureMatrixScale.x != 1.0f ||
          Vertices[j].TextureMatrixScale.y != 1.0f) {
        meshInfo.m_bNeedsTextureMatrixScale = true;
        m_bAnyNeedsTextureMatrixScale = true;
      }
    }
  }

  this->Allocate(vMeshes);

  Change(vMeshes);
}

// lua start
#include "LuaBinding.h"

// Register with Lua.
static void register_REFRESH_DEFAULT(lua_State* L) {
  lua_pushstring(L, "REFRESH_DEFAULT");
  lua_pushinteger(L, REFRESH_DEFAULT);
  lua_settable(L, LUA_GLOBALSINDEX);
}
REGISTER_WITH_LUA_FUNCTION(register_REFRESH_DEFAULT);

/** @brief Allow Lua to have access to the RageDisplay. */
class LunaRageDisplay : public Luna<RageDisplay> {
 public:
  static int GetDisplayWidth(T* p, lua_State* L) {
    VideoModeParams params = p->GetActualVideoModeParams();
    LuaHelpers::Push(L, params.width);
    return 1;
  }

  static int GetDisplayHeight(T* p, lua_State* L) {
    VideoModeParams params = p->GetActualVideoModeParams();
    LuaHelpers::Push(L, params.height);
    return 1;
  }

  static int GetFPS(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetFPS());
    return 1;
  }

  static int GetVPF(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetVPF());
    return 1;
  }

  static int GetCumFPS(T* p, lua_State* L) {
    lua_pushnumber(L, p->GetCumFPS());
    return 1;
  }

  static int GetDisplaySpecs(T* p, lua_State* L) {
    DisplaySpecs s;
    p->GetDisplaySpecs(s);
    pushDisplaySpecs(L, s);
    return 1;
  }

  static int SupportsRenderToTexture(T* p, lua_State* L) {
    lua_pushboolean(L, p->SupportsRenderToTexture());
    return 1;
  }

  static int SupportsFullscreenBorderlessWindow(T* p, lua_State* L) {
    lua_pushboolean(L, p->SupportsFullscreenBorderlessWindow());
    return 1;
  }

  LunaRageDisplay() {
    ADD_METHOD(GetDisplayWidth);
    ADD_METHOD(GetDisplayHeight);
    ADD_METHOD(GetFPS);
    ADD_METHOD(GetVPF);
    ADD_METHOD(GetCumFPS);
    ADD_METHOD(GetDisplaySpecs);
    ADD_METHOD(SupportsRenderToTexture);
    ADD_METHOD(SupportsFullscreenBorderlessWindow);
  }
};

LUA_REGISTER_CLASS(RageDisplay)
// lua end

/*
 * Copyright (c) 2001-2004 Chris Danford, Glenn Maynard
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
