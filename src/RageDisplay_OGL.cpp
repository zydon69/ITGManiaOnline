#include "RageDisplay_OGL.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "Actor.h"
#include "DisplaySpec.h"
#include "EnumHelper.h"
#include "LocalizedString.h"
#include "ModelTypes.h"
#include "Preference.h"
#include "RageDisplay.h"
#include "RageDisplay_OGL_Helpers.h"
#include "RageException.h"
#include "RageFile.h"
#include "RageLog.h"
#include "RageMath.h"
#include "RageSurface.h"
#include "RageSurfaceUtils.h"
#include "RageTextureID.h"
#include "RageTextureManager.h"
#include "RageTextureRenderTarget.h"
#include "RageTimer.h"
#include "RageTypes.h"
#include "RageUtil.h"
#include "RageUtil/Endian.h"
#include "PerfDiagnostics.h"
#include "Screen.h"
#include "ScreenManager.h"
#include "Sprite.h"
#include "arch/LowLevelWindow/LowLevelWindow.h"
#include "global.h"

#ifdef __APPLE__
#include "arch/LowLevelWindow/MacOSFramePacing.h"
#include "arch/LowLevelWindow/MacOSMetalPresenter.h"
#endif

using namespace RageDisplay_Legacy_Helpers;

#if defined(WINDOWS)
#include <GL/wglew.h>
#endif

#if defined(_MSC_VER)
#pragma comment(lib, "opengl32.lib")
#pragma comment(lib, "glu32.lib")
#endif

#ifdef NO_GL_FLUSH
#define glFlush()
#endif

//
// Globals
//

static bool g_bReversePackedPixelsWorks = true;
static bool g_bColorIndexTableWorks = true;

/* OpenGL system information that generally doesn't change at runtime. */

/* Range and granularity of points and lines: */
static float g_line_range[2];
static float g_point_range[2];

/* OpenGL version * 10: */
static int g_glVersion;

/* GLU version * 10: */
static int g_gluVersion;

static int g_iMaxTextureUnits = 0;
static Preference<float> g_fPerfTraceSlowDisplayEndFrameMs(
    "PerfTraceSlowDisplayEndFrameMs", 20.0f);
static Preference<float> g_fPerfTraceDisplayEndFrameBudgetMultiplier(
    "PerfTraceDisplayEndFrameBudgetMultiplier", 2.0f);
#ifdef __APPLE__
static Preference<bool> g_bOpenGLFinishAfterSwap(
    "OpenGLFinishAfterSwap", false);
#else
static Preference<bool> g_bOpenGLFinishAfterSwap(
    "OpenGLFinishAfterSwap", true);
#endif
static Preference<int> g_iOpenGLFinishEveryNFrames(
    "OpenGLFinishEveryNFrames", 0);
static uint64_t g_iOpenGLFramesSinceFinish = 0;
#ifdef __APPLE__
template<typename T>
struct FixedOpenGLPacingValue {
  explicit constexpr FixedOpenGLPacingValue(T value_) : value(value_) {}
  constexpr T Get() const { return value; }
  const T value;
};

static constexpr FixedOpenGLPacingValue<bool> g_bOpenGLPreFramePacingSync(true);
static constexpr FixedOpenGLPacingValue<bool>
    g_bOpenGLPreFramePacingFinishOnBackpressure(true);
static constexpr FixedOpenGLPacingValue<int> g_iOpenGLPreFramePacingFinishFrames(
    2);
static constexpr FixedOpenGLPacingValue<int>
    g_iOpenGLPreFramePacingMaxReactiveFinishFrames(2);
static constexpr FixedOpenGLPacingValue<int>
    g_iOpenGLPreFramePacingHighRefreshMaxReactiveFinishFrames(1);
static constexpr FixedOpenGLPacingValue<int>
    g_iOpenGLPreFramePacingHighRefreshMinRate(90);
static constexpr FixedOpenGLPacingValue<bool>
    g_bOpenGLPreFramePacingProactiveFinish(true);
static constexpr FixedOpenGLPacingValue<int>
    g_iOpenGLPreFramePacingProactiveFinishEveryNFrames(240);
static constexpr FixedOpenGLPacingValue<int>
    g_iOpenGLPreFramePacingHighRefreshMaxProactiveFinishEveryNFrames(15);
static constexpr FixedOpenGLPacingValue<int>
    g_iOpenGLPreFramePacingProactiveFinishFrames(1);
static constexpr FixedOpenGLPacingValue<int>
    g_iOpenGLPreFramePacingProactiveFinishMinRate(90);
static constexpr FixedOpenGLPacingValue<bool>
    g_bOpenGLPreFramePacingContinuousFinish(false);
static constexpr FixedOpenGLPacingValue<int>
    g_iOpenGLPreFramePacingContinuousFinishMinRate(90);
static constexpr FixedOpenGLPacingValue<int>
    g_iOpenGLPreFramePacingContinuousFinishLogEveryNFrames(240);
static Preference<float> g_fPerfTraceSlowOpenGLPreFramePacingSyncMs(
    "PerfTraceSlowOpenGLPreFramePacingSyncMs", 2.0f);
static Preference<bool> g_bPerfTraceOpenGLPreFramePacingProactiveDetails(
    "PerfTraceOpenGLPreFramePacingProactiveDetails", false);
static Preference<int> g_iPerfTraceOpenGLPreFramePacingSummaryEveryN(
    "PerfTraceOpenGLPreFramePacingSummaryEveryN", 0);
static Preference<float> g_fPerfTraceOpenGLPreFramePacingSummaryEveryMs(
    "PerfTraceOpenGLPreFramePacingSummaryEveryMs", 0.0f);
static constexpr int kOpenGLPreFramePacingHighRefreshProactiveMaxEveryNFrames =
    15;
static int g_iOpenGLPreFramePacingFinishFramesRemaining = 0;
static uint64_t g_iOpenGLPreFramePacingFrames = 0;
static uint64_t g_iOpenGLPreFramePacingProactiveFinishes = 0;
static uint64_t g_iOpenGLPreFramePacingContinuousFinishes = 0;
static uint64_t g_iOpenGLPreFramePacingLastSummaryUsec = 0;

struct OpenGLPreFramePacingTraceStats {
  uint64_t samples = 0;
  uint64_t flushes = 0;
  uint64_t proactiveFinishes = 0;
  uint64_t backpressureFinishes = 0;
  uint64_t continuousFinishes = 0;
  float totalMs = 0.0f;
  float maxMs = 0.0f;
  const char* maxMode = "none";
};

static OpenGLPreFramePacingTraceStats g_OpenGLPreFramePacingTraceStats;

static void RecordOpenGLPreFramePacingTrace(
    const char* mode, float elapsedMs) {
  ++g_OpenGLPreFramePacingTraceStats.samples;
  g_OpenGLPreFramePacingTraceStats.totalMs += elapsedMs;
  if (elapsedMs > g_OpenGLPreFramePacingTraceStats.maxMs) {
    g_OpenGLPreFramePacingTraceStats.maxMs = elapsedMs;
    g_OpenGLPreFramePacingTraceStats.maxMode = mode;
  }

  if (strcmp(mode, "finish_proactive") == 0) {
    ++g_OpenGLPreFramePacingTraceStats.proactiveFinishes;
  } else if (strcmp(mode, "finish_backpressure") == 0) {
    ++g_OpenGLPreFramePacingTraceStats.backpressureFinishes;
  } else if (strcmp(mode, "finish_continuous") == 0) {
    ++g_OpenGLPreFramePacingTraceStats.continuousFinishes;
  } else if (strcmp(mode, "flush") == 0) {
    ++g_OpenGLPreFramePacingTraceStats.flushes;
  }
}

static bool ShouldLogOpenGLPreFramePacingSummary() {
  if (!PerfDiagnosticsEnabled()) {
    return false;
  }

  const float everyMs = g_fPerfTraceOpenGLPreFramePacingSummaryEveryMs.Get();
  if (std::isfinite(everyMs) && everyMs > 0.0f) {
    const uint64_t nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
    if (g_iOpenGLPreFramePacingLastSummaryUsec == 0) {
      g_iOpenGLPreFramePacingLastSummaryUsec = nowUsec;
      return false;
    }
    const uint64_t everyUsec =
        static_cast<uint64_t>(std::llround(everyMs * 1000.0f));
    if (everyUsec > 0 &&
        nowUsec - g_iOpenGLPreFramePacingLastSummaryUsec >= everyUsec) {
      g_iOpenGLPreFramePacingLastSummaryUsec = nowUsec;
      return g_OpenGLPreFramePacingTraceStats.samples > 0;
    }
    return false;
  }

  const int everyN =
      std::clamp(g_iPerfTraceOpenGLPreFramePacingSummaryEveryN.Get(), 0, 36000);
  return everyN > 0 && g_OpenGLPreFramePacingTraceStats.samples > 0 &&
         (g_iOpenGLPreFramePacingFrames % static_cast<uint64_t>(everyN)) == 0;
}

static void LogAndResetOpenGLPreFramePacingSummary(
    int rate, int proactiveEveryNFramesConfigured,
    int proactiveEveryNFramesEffective, int highRefreshProactiveMaxEveryNFrames,
    bool highRefreshProactiveCapActive) {
  const OpenGLPreFramePacingTraceStats& stats =
      g_OpenGLPreFramePacingTraceStats;
  const float avgMs =
      stats.samples > 0 ? stats.totalMs / static_cast<float>(stats.samples)
                        : 0.0f;
  LOG->Trace(
      "PERF_TRACE: opengl_pre_frame_pacing_summary samples=%llu "
      "avg_ms=%.3f max_ms=%.3f max_mode=%s flushes=%llu "
      "proactive_finishes=%llu backpressure_finishes=%llu "
      "continuous_finishes=%llu rate=%d "
      "proactive_every_n_configured=%d proactive_every_n_effective=%d "
      "proactive_high_refresh_max_every_n=%d "
      "proactive_high_refresh_cap_active=%d frame=%llu",
      static_cast<unsigned long long>(stats.samples), avgMs, stats.maxMs,
      stats.maxMode, static_cast<unsigned long long>(stats.flushes),
      static_cast<unsigned long long>(stats.proactiveFinishes),
      static_cast<unsigned long long>(stats.backpressureFinishes),
      static_cast<unsigned long long>(stats.continuousFinishes),
      rate,
      proactiveEveryNFramesConfigured, proactiveEveryNFramesEffective,
      highRefreshProactiveMaxEveryNFrames,
      highRefreshProactiveCapActive ? 1 : 0,
      static_cast<unsigned long long>(g_iOpenGLPreFramePacingFrames));
  g_OpenGLPreFramePacingTraceStats = OpenGLPreFramePacingTraceStats();
}
#endif

struct DisplayEndFramePerfBucket {
  uint64_t frames = 0;
  uint64_t over12ms = 0;
  uint64_t over16ms = 0;
  uint64_t over20ms = 0;
  uint64_t swapBlockFrames = 0;
  uint64_t pacingWaitFrames = 0;
  uint64_t hardwareVsyncWaitFrames = 0;
  uint64_t mixedPresentFrames = 0;
  uint64_t unknownFrames = 0;
  uint64_t swapOverBudgetFrames = 0;
  uint64_t swapOver12ms = 0;
  uint64_t swapOver16ms = 0;
  uint64_t swapOver20ms = 0;
  uint64_t presentIntervalFrames = 0;
  uint64_t presentIntervalOverBudgetFrames = 0;
  uint64_t presentIntervalOverDoubleBudgetFrames = 0;
  float presentIntervalMsSum = 0.0f;
  float maxPresentIntervalMs = 0.0f;
  uint64_t fenceWaitFrames = 0;
  uint64_t fenceWaitSaturatedFrames = 0;
  uint64_t fenceWaitActualUsecSum = 0;
  uint64_t fenceWaitActualUsecMax = 0;
  uint64_t fenceWaitBudgetUsecMax = 0;
  float maxTotalMs = 0.0f;
  float maxSwapMs = 0.0f;
  float maxFrameLimitBeforeMs = 0.0f;
  int maxMissedSwapIntervals = 0;
  int maxMissedTotalIntervals = 0;
  std::string worstScreen = "none";
  std::string worstClassification = "none";
};

struct DisplayEndFramePerfSummary {
  DisplayEndFramePerfBucket all;
  DisplayEndFramePerfBucket gameplay;
  DisplayEndFramePerfBucket evaluationStage;
  DisplayEndFramePerfBucket selectMusic;
  DisplayEndFramePerfBucket selectStyle;
  DisplayEndFramePerfBucket other;
  uint64_t firstSampleUsec = 0;
  uint64_t lastSampleUsec = 0;
};

static DisplayEndFramePerfSummary g_DisplayEndFramePerfSummary;
static uint64_t g_iLastPresentReturnUsec = 0;

static const char* CurrentTopScreenName() {
  if (SCREENMAN == nullptr || SCREENMAN->GetTopScreen() == nullptr) {
    return "NoScreen";
  }
  return SCREENMAN->GetTopScreen()->GetName().c_str();
}

static bool IsGameplayScreenName(const char* screenName) {
  return screenName != nullptr && strcmp(screenName, "ScreenGameplay") == 0;
}

static bool IsEvaluationStageScreenName(const char* screenName) {
  return screenName != nullptr &&
         strcmp(screenName, "ScreenEvaluationStage") == 0;
}

static bool IsSelectMusicScreenName(const char* screenName) {
  return screenName != nullptr && strcmp(screenName, "ScreenSelectMusic") == 0;
}

static bool IsSelectStyleScreenName(const char* screenName) {
  return screenName != nullptr && strcmp(screenName, "ScreenSelectStyle") == 0;
}

static void RecordDisplayEndFramePerfBucket(
    DisplayEndFramePerfBucket& bucket, float totalMs, float swapBuffersMs,
    float frameLimitBeforeMs, float presentReturnIntervalMs,
    float expectedFrameMs,
    int missedSwapIntervals, int missedTotalIntervals,
    const char* classification, const char* screenName
#ifdef __APPLE__
    ,
    const MacOSOpenGLFenceWaitStats* fenceStats
#endif
    ) {
  ++bucket.frames;
  bucket.over12ms += totalMs >= 12.0f ? 1 : 0;
  bucket.over16ms += totalMs >= 16.0f ? 1 : 0;
  bucket.over20ms += totalMs >= 20.0f ? 1 : 0;
  bucket.swapOverBudgetFrames +=
      expectedFrameMs > 0.0f && swapBuffersMs >= expectedFrameMs ? 1 : 0;
  bucket.swapOver12ms += swapBuffersMs >= 12.0f ? 1 : 0;
  bucket.swapOver16ms += swapBuffersMs >= 16.0f ? 1 : 0;
  bucket.swapOver20ms += swapBuffersMs >= 20.0f ? 1 : 0;
  if (presentReturnIntervalMs > 0.0f) {
    ++bucket.presentIntervalFrames;
    bucket.presentIntervalMsSum += presentReturnIntervalMs;
    bucket.maxPresentIntervalMs =
        std::max(bucket.maxPresentIntervalMs, presentReturnIntervalMs);
    bucket.presentIntervalOverBudgetFrames +=
        expectedFrameMs > 0.0f && presentReturnIntervalMs >= expectedFrameMs * 1.5f
            ? 1
            : 0;
    bucket.presentIntervalOverDoubleBudgetFrames +=
        expectedFrameMs > 0.0f && presentReturnIntervalMs >= expectedFrameMs * 2.0f
            ? 1
            : 0;
  }
#ifdef __APPLE__
  if (fenceStats != nullptr && fenceStats->available &&
      fenceStats->pacing_wait_enabled && fenceStats->fence_created &&
      fenceStats->wait_budget_usec > 0) {
    ++bucket.fenceWaitFrames;
    bucket.fenceWaitSaturatedFrames += fenceStats->wait_saturated ? 1 : 0;
    bucket.fenceWaitActualUsecSum += fenceStats->wait_actual_usec;
    bucket.fenceWaitActualUsecMax =
        std::max(bucket.fenceWaitActualUsecMax, fenceStats->wait_actual_usec);
    bucket.fenceWaitBudgetUsecMax =
        std::max(bucket.fenceWaitBudgetUsecMax, fenceStats->wait_budget_usec);
  }
#endif
  bucket.maxSwapMs = std::max(bucket.maxSwapMs, swapBuffersMs);
  bucket.maxFrameLimitBeforeMs =
      std::max(bucket.maxFrameLimitBeforeMs, frameLimitBeforeMs);
  bucket.maxMissedSwapIntervals =
      std::max(bucket.maxMissedSwapIntervals, missedSwapIntervals);
  bucket.maxMissedTotalIntervals =
      std::max(bucket.maxMissedTotalIntervals, missedTotalIntervals);

  if (classification == nullptr) {
    classification = "unknown";
  }
  if (strcmp(classification, "swap_block") == 0) {
    ++bucket.swapBlockFrames;
  } else if (strcmp(classification, "pacing_wait") == 0) {
    ++bucket.pacingWaitFrames;
  } else if (strcmp(classification, "hardware_vsync_wait") == 0) {
    ++bucket.hardwareVsyncWaitFrames;
  } else if (strcmp(classification, "mixed_present") == 0) {
    ++bucket.mixedPresentFrames;
  } else {
    ++bucket.unknownFrames;
  }

  if (totalMs > bucket.maxTotalMs) {
    bucket.maxTotalMs = totalMs;
    bucket.worstScreen = screenName != nullptr ? screenName : "unknown";
    bucket.worstClassification = classification;
  }
}

static void RecordDisplayEndFramePerf(
    float totalMs, float swapBuffersMs, float frameLimitBeforeMs,
    float presentReturnIntervalMs, float expectedFrameMs,
    int missedSwapIntervals, int missedTotalIntervals,
    const char* classification, const char* screenName) {
  const uint64_t nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
  if (g_DisplayEndFramePerfSummary.firstSampleUsec == 0) {
    g_DisplayEndFramePerfSummary.firstSampleUsec = nowUsec;
  }
  g_DisplayEndFramePerfSummary.lastSampleUsec = nowUsec;

#ifdef __APPLE__
  MacOSOpenGLFenceWaitStats fenceStats;
  MacOSOpenGLGetLastFenceWaitStats(&fenceStats);
#endif

  RecordDisplayEndFramePerfBucket(
      g_DisplayEndFramePerfSummary.all, totalMs, swapBuffersMs,
      frameLimitBeforeMs, presentReturnIntervalMs, expectedFrameMs,
      missedSwapIntervals, missedTotalIntervals, classification, screenName
#ifdef __APPLE__
      ,
      &fenceStats
#endif
      );
  if (IsGameplayScreenName(screenName)) {
    RecordDisplayEndFramePerfBucket(
        g_DisplayEndFramePerfSummary.gameplay, totalMs, swapBuffersMs,
        frameLimitBeforeMs, presentReturnIntervalMs, expectedFrameMs,
        missedSwapIntervals, missedTotalIntervals, classification, screenName
#ifdef __APPLE__
        ,
        &fenceStats
#endif
        );
  } else if (IsEvaluationStageScreenName(screenName)) {
    RecordDisplayEndFramePerfBucket(
        g_DisplayEndFramePerfSummary.evaluationStage, totalMs, swapBuffersMs,
        frameLimitBeforeMs, presentReturnIntervalMs, expectedFrameMs,
        missedSwapIntervals, missedTotalIntervals, classification, screenName
#ifdef __APPLE__
        ,
        &fenceStats
#endif
        );
  } else if (IsSelectMusicScreenName(screenName)) {
    RecordDisplayEndFramePerfBucket(
        g_DisplayEndFramePerfSummary.selectMusic, totalMs, swapBuffersMs,
        frameLimitBeforeMs, presentReturnIntervalMs, expectedFrameMs,
        missedSwapIntervals, missedTotalIntervals, classification, screenName
#ifdef __APPLE__
        ,
        &fenceStats
#endif
        );
  } else if (IsSelectStyleScreenName(screenName)) {
    RecordDisplayEndFramePerfBucket(
        g_DisplayEndFramePerfSummary.selectStyle, totalMs, swapBuffersMs,
        frameLimitBeforeMs, presentReturnIntervalMs, expectedFrameMs,
        missedSwapIntervals, missedTotalIntervals, classification, screenName
#ifdef __APPLE__
        ,
        &fenceStats
#endif
        );
  } else {
    RecordDisplayEndFramePerfBucket(
        g_DisplayEndFramePerfSummary.other, totalMs, swapBuffersMs,
        frameLimitBeforeMs, presentReturnIntervalMs, expectedFrameMs,
        missedSwapIntervals, missedTotalIntervals, classification, screenName
#ifdef __APPLE__
        ,
        &fenceStats
#endif
        );
  }
}

static void LogDisplayEndFramePerfBucket(
    const char* label, const DisplayEndFramePerfBucket& bucket) {
  const double fenceSaturatedPct =
      bucket.fenceWaitFrames > 0
          ? (100.0 * static_cast<double>(bucket.fenceWaitSaturatedFrames) /
             static_cast<double>(bucket.fenceWaitFrames))
          : 0.0;
  const double fenceWaitActualAvgUsec =
      bucket.fenceWaitFrames > 0
          ? (static_cast<double>(bucket.fenceWaitActualUsecSum) /
             static_cast<double>(bucket.fenceWaitFrames))
          : 0.0;
  const double presentIntervalAvgMs =
      bucket.presentIntervalFrames > 0
          ? (static_cast<double>(bucket.presentIntervalMsSum) /
             static_cast<double>(bucket.presentIntervalFrames))
          : 0.0;
  LOG->Trace(
      "PERF_SUMMARY: display_end_frame scope=%s frames=%llu over12ms=%llu "
      "over16ms=%llu over20ms=%llu swap_block_frames=%llu "
      "pacing_wait_frames=%llu hardware_vsync_wait_frames=%llu "
      "mixed_present_frames=%llu "
      "unknown_frames=%llu swap_over_budget_frames=%llu "
      "swap_over12ms=%llu swap_over16ms=%llu swap_over20ms=%llu "
      "fence_wait_frames=%llu fence_saturated_frames=%llu "
      "fence_saturated_pct=%.3f fence_wait_actual_avg_us=%.1f "
      "fence_wait_actual_max_us=%llu fence_wait_budget_max_us=%llu "
      "present_interval_frames=%llu present_interval_over_budget_frames=%llu "
      "present_interval_over_double_budget_frames=%llu "
      "present_interval_avg_ms=%.3f max_present_interval_ms=%.3f "
      "max_total_ms=%.3f max_swap_ms=%.3f "
      "max_frame_limit_before_ms=%.3f max_missed_swap_intervals=%d "
      "max_missed_total_intervals=%d worst_screen=%s "
      "worst_classification=%s",
      label != nullptr ? label : "unknown",
      static_cast<unsigned long long>(bucket.frames),
      static_cast<unsigned long long>(bucket.over12ms),
      static_cast<unsigned long long>(bucket.over16ms),
      static_cast<unsigned long long>(bucket.over20ms),
      static_cast<unsigned long long>(bucket.swapBlockFrames),
      static_cast<unsigned long long>(bucket.pacingWaitFrames),
      static_cast<unsigned long long>(bucket.hardwareVsyncWaitFrames),
      static_cast<unsigned long long>(bucket.mixedPresentFrames),
      static_cast<unsigned long long>(bucket.unknownFrames),
      static_cast<unsigned long long>(bucket.swapOverBudgetFrames),
      static_cast<unsigned long long>(bucket.swapOver12ms),
      static_cast<unsigned long long>(bucket.swapOver16ms),
      static_cast<unsigned long long>(bucket.swapOver20ms),
      static_cast<unsigned long long>(bucket.fenceWaitFrames),
      static_cast<unsigned long long>(bucket.fenceWaitSaturatedFrames),
      fenceSaturatedPct, fenceWaitActualAvgUsec,
      static_cast<unsigned long long>(bucket.fenceWaitActualUsecMax),
      static_cast<unsigned long long>(bucket.fenceWaitBudgetUsecMax),
      static_cast<unsigned long long>(bucket.presentIntervalFrames),
      static_cast<unsigned long long>(bucket.presentIntervalOverBudgetFrames),
      static_cast<unsigned long long>(
          bucket.presentIntervalOverDoubleBudgetFrames),
      presentIntervalAvgMs, bucket.maxPresentIntervalMs,
      bucket.maxTotalMs, bucket.maxSwapMs, bucket.maxFrameLimitBeforeMs,
      bucket.maxMissedSwapIntervals, bucket.maxMissedTotalIntervals,
      bucket.worstScreen.c_str(), bucket.worstClassification.c_str());
}

static void LogDisplayEndFramePerfSummary() {
  if (!PerfDiagnosticsEnabled()) {
    return;
  }

  if (g_DisplayEndFramePerfSummary.all.frames == 0) {
    return;
  }

  const uint64_t durationUsec =
      g_DisplayEndFramePerfSummary.lastSampleUsec >
              g_DisplayEndFramePerfSummary.firstSampleUsec
          ? g_DisplayEndFramePerfSummary.lastSampleUsec -
                g_DisplayEndFramePerfSummary.firstSampleUsec
          : 0;
  LOG->Trace(
      "PERF_SUMMARY: display_session duration_ms=%.3f all_frames=%llu "
      "gameplay_frames=%llu",
      static_cast<double>(durationUsec) / 1000.0,
      static_cast<unsigned long long>(
          g_DisplayEndFramePerfSummary.all.frames),
      static_cast<unsigned long long>(
          g_DisplayEndFramePerfSummary.gameplay.frames));
  LogDisplayEndFramePerfBucket("all", g_DisplayEndFramePerfSummary.all);
  LogDisplayEndFramePerfBucket(
      "gameplay", g_DisplayEndFramePerfSummary.gameplay);
  LogDisplayEndFramePerfBucket(
      "evaluation_stage", g_DisplayEndFramePerfSummary.evaluationStage);
  LogDisplayEndFramePerfBucket(
      "select_music", g_DisplayEndFramePerfSummary.selectMusic);
  LogDisplayEndFramePerfBucket(
      "select_style", g_DisplayEndFramePerfSummary.selectStyle);
  LogDisplayEndFramePerfBucket("other", g_DisplayEndFramePerfSummary.other);
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

#ifdef __APPLE__
static int OpenGLPreFramePacingReactiveFinishFrames(int rate) {
  const int requestedFrames =
      std::clamp(g_iOpenGLPreFramePacingFinishFrames.Get(), 0, 120);
  int maxFrames =
      std::clamp(g_iOpenGLPreFramePacingMaxReactiveFinishFrames.Get(), 0, 30);
  const int highRefreshMinRate =
      std::clamp(g_iOpenGLPreFramePacingHighRefreshMinRate.Get(), 1, 1000);
  if (rate >= highRefreshMinRate) {
    maxFrames = std::min(
        maxFrames,
        std::clamp(
            g_iOpenGLPreFramePacingHighRefreshMaxReactiveFinishFrames.Get(),
            0, 30));
  }
  return std::min(requestedFrames, maxFrames);
}

static int OpenGLPreFramePacingProactiveFinishEveryNFrames(int rate) {
  const int requestedEveryNFrames = std::clamp(
      g_iOpenGLPreFramePacingProactiveFinishEveryNFrames.Get(), 1, 36000);
  const int proactiveFinishMinRate = std::clamp(
      g_iOpenGLPreFramePacingProactiveFinishMinRate.Get(), 1, 1000);
  if (rate < proactiveFinishMinRate) {
    return requestedEveryNFrames;
  }

  const int highRefreshMaxEveryNFrames = std::clamp(
      g_iOpenGLPreFramePacingHighRefreshMaxProactiveFinishEveryNFrames.Get(),
      1, kOpenGLPreFramePacingHighRefreshProactiveMaxEveryNFrames);
  return std::min(requestedEveryNFrames, highRefreshMaxEveryNFrames);
}
#endif

static const char* ClassifyDisplayEndFrame(
    float totalMs, float offscreenMs, float preFramePacingSyncMs,
    float frameLimitBeforeMs, float swapBuffersMs, float frameLimitAfterMs,
    float glFinishMs, float glFlushMs, float windowUpdateMs, float statsMs,
    float expectedFrameMs) {
  const float effectiveExpectedMs =
      expectedFrameMs > 0.0f ? expectedFrameMs : 16.667f;
  if (swapBuffersMs >= effectiveExpectedMs * 0.9f) {
    return "swap_block";
  }
  if (preFramePacingSyncMs >= 4.0f) {
    return "pre_frame_pacing_sync";
  }
  if (frameLimitBeforeMs >= effectiveExpectedMs * 0.9f &&
      swapBuffersMs < effectiveExpectedMs * 0.5f) {
    return "pacing_wait";
  }
  if (glFinishMs >= 4.0f) {
    return "gl_finish";
  }
  if (glFlushMs >= 4.0f) {
    return "gl_flush";
  }
  if (windowUpdateMs >= 4.0f) {
    return "window_update";
  }
  if (offscreenMs >= 4.0f) {
    return "offscreen";
  }
  if (frameLimitAfterMs >= 4.0f) {
    return "pacing_after";
  }
  if (statsMs >= 4.0f) {
    return "stats";
  }
  if (totalMs >= effectiveExpectedMs * 1.4f) {
    return "mixed_present";
  }
  return "unknown";
}

/* We don't actually use normals (we don't turn on lighting), there's just
 * no GL_T2F_C4F_V3F. */
static const GLenum RageSpriteVertexFormat = GL_T2F_C4F_N3F_V3F;

/* If we support texture matrix scaling, a handle to the vertex program: */
static GLhandleARB g_bTextureMatrixShader = 0;

static std::map<uintptr_t, RenderTarget*> g_mapRenderTargets;
static RenderTarget* g_pCurrentRenderTarget = nullptr;

static LowLevelWindow* g_pWind;

static bool g_bInvertY = false;

static bool ShouldTraceGlTextureUploads() {
  return LogTextureUploadDiagnosticsEnabled();
}

static void InvalidateObjects();

static RageDisplay::RagePixelFormatDesc PIXEL_FORMAT_DESC[NUM_RagePixelFormat] =
    {{/* R8G8B8A8 */
      32,
      {0xFF000000, 0x00FF0000, 0x0000FF00, 0x000000FF}},
     {/* B8G8R8A8 */
      32,
      {0x0000FF00, 0x00FF0000, 0xFF000000, 0x000000FF}},
     {
         /* R4G4B4A4 */
         16,
         {0xF000, 0x0F00, 0x00F0, 0x000F},
     },
     {
         /* R5G5B5A1 */
         16,
         {0xF800, 0x07C0, 0x003E, 0x0001},
     },
     {
         /* R5G5B5X1 */
         16,
         {0xF800, 0x07C0, 0x003E, 0x0000},
     },
     {/* R8G8B8 */
      24,
      {0xFF0000, 0x00FF00, 0x0000FF, 0x000000}},
     {
         /* Paletted */
         8,
         {0, 0, 0, 0} /* N/A */
     },
     {/* B8G8R8 */
      24,
      {0x0000FF, 0x00FF00, 0xFF0000, 0x000000}},
     {
         /* A1R5G5B5 */
         16,
         {0x7C00, 0x03E0, 0x001F, 0x8000},
     },
     {
         /* X1R5G5B5 */
         16,
         {0x7C00, 0x03E0, 0x001F, 0x0000},
     }};

/* g_GLPixFmtInfo is used for both texture formats and surface formats.  For
 * example, it's fine to ask for a RagePixelFormat_RGB5 texture, but to supply a
 * surface matching RagePixelFormat_RGB8.  OpenGL will simply discard the extra
 * bits.
 *
 * It's possible for a format to be supported as a texture format but not as a
 * surface format.  For example, if packed pixels aren't supported, we can still
 * use GL_RGB5_A1, but we'll have to convert to a supported surface pixel format
 * first.  It's not ideal, since we'll convert to RGBA8 and OGL will convert
 * back, but it works fine.
 */
struct GLPixFmtInfo_t {
  GLenum internalfmt; /* target format */
  GLenum format;      /* target format */
  GLenum type;        /* data format */
} const g_GLPixFmtInfo[NUM_RagePixelFormat] = {
    {
        /* R8G8B8A8 */
        GL_RGBA8,
        GL_RGBA,
        GL_UNSIGNED_BYTE,
    },
    {
        /* R8G8B8A8 */
        GL_RGBA8,
        GL_BGRA,
        GL_UNSIGNED_BYTE,
    },
    {
        /* B4G4R4A4 */
        GL_RGBA4,
        GL_RGBA,
        GL_UNSIGNED_SHORT_4_4_4_4,
    },
    {
        /* B5G5R5A1 */
        GL_RGB5_A1,
        GL_RGBA,
        GL_UNSIGNED_SHORT_5_5_5_1,
    },
    {
        /* B5G5R5 */
        GL_RGB5,
        GL_RGBA,
        GL_UNSIGNED_SHORT_5_5_5_1,
    },
    {
        /* B8G8R8 */
        GL_RGB8,
        GL_RGB,
        GL_UNSIGNED_BYTE,
    },
    {
        /* Paletted */
        GL_COLOR_INDEX8_EXT,
        GL_COLOR_INDEX,
        GL_UNSIGNED_BYTE,
    },
    {
        /* B8G8R8 */
        GL_RGB8,
        GL_BGR,
        GL_UNSIGNED_BYTE,
    },
    {
        /* A1R5G5B5 (matches D3DFMT_A1R5G5B5) */
        GL_RGB5_A1,
        GL_BGRA,
        GL_UNSIGNED_SHORT_1_5_5_5_REV,
    },
    {
        /* X1R5G5B5 */
        GL_RGB5,
        GL_BGRA,
        GL_UNSIGNED_SHORT_1_5_5_5_REV,
    }};

static void FixLittleEndian() {
  if constexpr (!Endian::little) {
    return;
  }

  static bool bInitialized = false;
  if (bInitialized) {
    return;
  }
  bInitialized = true;

  for (int i = 0; i < NUM_RagePixelFormat; ++i) {
    RageDisplay::RagePixelFormatDesc& pf = PIXEL_FORMAT_DESC[i];

    /* OpenGL and RageSurface handle byte formats differently; we need
     * to flip non-paletted masks to make them line up. */
    if (g_GLPixFmtInfo[i].type != GL_UNSIGNED_BYTE || pf.bpp == 8) {
      continue;
    }

    for (int mask = 0; mask < 4; ++mask) {
      int m = pf.masks[mask];
      switch (pf.bpp) {
        case 24:
          m = Swap24(m);
          break;
        case 32:
          m = Swap32(m);
          break;
        default:
          FAIL_M(ssprintf("Unsupported BPP value: %i", pf.bpp));
      }
      pf.masks[mask] = m;
    }
  }
}

static void TurnOffHardwareVBO() {
  if (GLEW_ARB_vertex_buffer_object) {
    glBindBufferARB(GL_ARRAY_BUFFER_ARB, 0);
    glBindBufferARB(GL_ELEMENT_ARRAY_BUFFER_ARB, 0);
  }
}

RageDisplay_Legacy::RageDisplay_Legacy() {
  LOG->Trace("RageDisplay_Legacy::RageDisplay_Legacy()");
  LOG->MapLog("renderer", "Current renderer: OpenGL");

  FixLittleEndian();
  RageDisplay_Legacy_Helpers::Init();

	g_pWind = nullptr;
	g_bTextureMatrixShader = 0;
	offscreenRenderTarget = nullptr;
}

std::string GetInfoLog(GLhandleARB h) {
  GLint iLength;
  glGetObjectParameterivARB(h, GL_OBJECT_INFO_LOG_LENGTH_ARB, &iLength);
  if (!iLength) {
    return std::string();
  }

  GLcharARB* pInfoLog = new GLcharARB[iLength];
  glGetInfoLogARB(h, iLength, &iLength, pInfoLog);
  std::string sRet = pInfoLog;
  delete[] pInfoLog;
  TrimRight(sRet);
  return sRet;
}

GLhandleARB CompileShader(
    GLenum ShaderType, std::string sFile, std::vector<std::string> asDefines) {
  /* XXX: This would not be necessary if it wasn't for the special case for Cel.
   */
  if (ShaderType == GL_FRAGMENT_SHADER_ARB &&
      !glewIsSupported("GL_VERSION_2_0")) {
    LOG->Warn(
        "Fragment shaders not supported by driver. Some effects will not be "
        "available.");
    return 0;
  }

  std::string sBuffer;
  {
    RageFile file;
    if (!file.Open(sFile)) {
      LOG->Warn(
          "Error compiling shader %s: %s", sFile.c_str(),
          file.GetError().c_str());
      return 0;
    }

    if (file.Read(sBuffer, file.GetFileSize()) == -1) {
      LOG->Warn(
          "Error compiling shader %s: %s", sFile.c_str(),
          file.GetError().c_str());
      return 0;
    }
  }

  LOG->Trace("Compiling shader %s", sFile.c_str());
  GLhandleARB hShader = glCreateShaderObjectARB(ShaderType);
  std::vector<const GLcharARB*> apData;
  std::vector<GLint> aiLength;
  for (std::string& s : asDefines) {
    s = ssprintf("#define %s\n", s.c_str());
    apData.push_back(s.data());
    aiLength.push_back(s.size());
  }
  apData.push_back("#line 1\n");
  aiLength.push_back(8);

  apData.push_back(sBuffer.data());
  aiLength.push_back(sBuffer.size());
  glShaderSourceARB(hShader, apData.size(), &apData[0], &aiLength[0]);

  glCompileShaderARB(hShader);

  std::string sInfo = GetInfoLog(hShader);

  GLint bCompileStatus = GL_FALSE;
  glGetObjectParameterivARB(
      hShader, GL_OBJECT_COMPILE_STATUS_ARB, &bCompileStatus);
  if (!bCompileStatus) {
    LOG->Warn("Error compiling shader %s:\n%s", sFile.c_str(), sInfo.c_str());
    glDeleteObjectARB(hShader);
    return 0;
  }

  if (!sInfo.empty()) {
    LOG->Trace(
        "Messages compiling shader %s:\n%s", sFile.c_str(), sInfo.c_str());
  }

  return hShader;
}

GLhandleARB LoadShader(
    GLenum ShaderType, std::string sFile, std::vector<std::string> asDefines) {
  /* Vertex shaders are supported by more hardware than fragment shaders.
   * If this causes any trouble I will have to up the requirement for both
   * of them to at least GL 2.0. Regardless we need basic GLSL support.
   * -Colby */
  if (!glewIsSupported("GL_ARB_shading_language_100 GL_ARB_shader_objects") ||
      (ShaderType == GL_FRAGMENT_SHADER_ARB &&
       !glewIsSupported("GL_VERSION_2_0")) ||
      (ShaderType == GL_VERTEX_SHADER_ARB &&
       !glewIsSupported("GL_ARB_vertex_shader"))) {
    LOG->Warn(
        "%s shaders not supported by driver. Some effects will not be "
        "available.",
        (ShaderType == GL_FRAGMENT_SHADER_ARB) ? "Fragment" : "Vertex");
    return 0;
  }

  // XXX: dumb, but I don't feel like refactoring ragedisplay for this. -Colby
  GLhandleARB secondaryShader = 0;
  if (sFile == "Data/Shaders/GLSL/Cel.vert") {
    secondaryShader = CompileShader(
        GL_FRAGMENT_SHADER_ARB, "Data/Shaders/GLSL/Cel.frag", asDefines);
  } else if (sFile == "Data/Shaders/GLSL/Shell.vert") {
    secondaryShader = CompileShader(
        GL_FRAGMENT_SHADER_ARB, "Data/Shaders/GLSL/Shell.frag", asDefines);
  } else if (sFile == "Data/Shaders/GLSL/Distance field.vert") {
    secondaryShader = CompileShader(
        GL_FRAGMENT_SHADER_ARB, "Data/Shaders/GLSL/Distance field.frag",
        asDefines);
  }

  GLhandleARB hShader = CompileShader(ShaderType, sFile, asDefines);
  if (hShader == 0) {
    return 0;
  }

  GLhandleARB hProgram = glCreateProgramObjectARB();
  glAttachObjectARB(hProgram, hShader);

  if (secondaryShader) {
    glAttachObjectARB(hProgram, secondaryShader);
    glDeleteObjectARB(secondaryShader);
  }
  glDeleteObjectARB(hShader);

  // Link the program.
  glLinkProgramARB(hProgram);
  GLint bLinkStatus = false;
  glGetObjectParameterivARB(hProgram, GL_OBJECT_LINK_STATUS_ARB, &bLinkStatus);

  if (!bLinkStatus) {
    LOG->Warn(
        "Error linking shader %s: %s", sFile.c_str(),
        GetInfoLog(hProgram).c_str());
    glDeleteObjectARB(hProgram);
    return 0;
  }
  return hProgram;
}

static int g_iAttribTextureMatrixScale;

static GLhandleARB g_bUnpremultiplyShader = 0;
static GLhandleARB g_bColorBurnShader = 0;
static GLhandleARB g_bColorDodgeShader = 0;
static GLhandleARB g_bVividLightShader = 0;
static GLhandleARB g_hHardMixShader = 0;
static GLhandleARB g_hOverlayShader = 0;
static GLhandleARB g_hScreenShader = 0;
static GLhandleARB g_hYUYV422Shader = 0;
static GLhandleARB g_gShellShader = 0;
static GLhandleARB g_gCelShader = 0;
static GLhandleARB g_gDistanceFieldShader = 0;

void InitShaders() {
  // xxx: replace this with a ShaderManager or something that reads in
  // the shaders and determines shader type by file extension. -aj
  // argh shaders in stepmania are painful -colby
  std::vector<std::string> asDefines;

  // used for scrolling textures (I think)
  g_bTextureMatrixShader = LoadShader(
      GL_VERTEX_SHADER_ARB, "Data/Shaders/GLSL/Texture matrix scaling.vert",
      asDefines);

  // these two are for dancing characters and are both actually shader pairs
  g_gShellShader = LoadShader(
      GL_VERTEX_SHADER_ARB, "Data/Shaders/GLSL/Shell.vert", asDefines);
  g_gCelShader =
      LoadShader(GL_VERTEX_SHADER_ARB, "Data/Shaders/GLSL/Cel.vert", asDefines);
  g_gDistanceFieldShader = LoadShader(
      GL_VERTEX_SHADER_ARB, "Data/Shaders/GLSL/Distance field.vert", asDefines);

  // effects
  g_bUnpremultiplyShader = LoadShader(
      GL_FRAGMENT_SHADER_ARB, "Data/Shaders/GLSL/Unpremultiply.frag",
      asDefines);
  g_bColorBurnShader = LoadShader(
      GL_FRAGMENT_SHADER_ARB, "Data/Shaders/GLSL/Color burn.frag", asDefines);
  g_bColorDodgeShader = LoadShader(
      GL_FRAGMENT_SHADER_ARB, "Data/Shaders/GLSL/Color dodge.frag", asDefines);
  g_bVividLightShader = LoadShader(
      GL_FRAGMENT_SHADER_ARB, "Data/Shaders/GLSL/Vivid light.frag", asDefines);
  g_hHardMixShader = LoadShader(
      GL_FRAGMENT_SHADER_ARB, "Data/Shaders/GLSL/Hard mix.frag", asDefines);
  g_hOverlayShader = LoadShader(
      GL_FRAGMENT_SHADER_ARB, "Data/Shaders/GLSL/Overlay.frag", asDefines);
  g_hScreenShader = LoadShader(
      GL_FRAGMENT_SHADER_ARB, "Data/Shaders/GLSL/Screen.frag", asDefines);
  g_hYUYV422Shader = LoadShader(
      GL_FRAGMENT_SHADER_ARB, "Data/Shaders/GLSL/YUYV422.frag", asDefines);

#if defined(MACOSX)
  if (g_bTextureMatrixShader) {
    LOG->Trace(
        "Scaling shader disabled on macOS OpenGL: vertex attribute binding is "
        "unstable on this context.");
    glDeleteObjectARB(g_bTextureMatrixShader);
    g_bTextureMatrixShader = 0;
  }
#endif

  // Bind attributes.
  if (g_bTextureMatrixShader) {
    if (glGetAttribLocationARB == nullptr || glVertexAttrib2fARB == nullptr) {
      LOG->Warn(
          "Scaling shader disabled: required vertex attribute functions are "
          "not available in this OpenGL context.");
      glDeleteObjectARB(g_bTextureMatrixShader);
      g_bTextureMatrixShader = 0;
      return;
    }

    FlushGLErrors();
    g_iAttribTextureMatrixScale =
        glGetAttribLocationARB(g_bTextureMatrixShader, "TextureMatrixScale");
    if (g_iAttribTextureMatrixScale == -1) {
      LOG->Trace(
          "Scaling shader link failed: couldn't bind attribute "
          "\"TextureMatrixScale\"");
      glDeleteObjectARB(g_bTextureMatrixShader);
      g_bTextureMatrixShader = 0;
    } else {
      AssertNoGLError();

      /* Older Catalyst drivers seem to throw GL_INVALID_OPERATION here. */
      glVertexAttrib2fARB(g_iAttribTextureMatrixScale, 1, 1);
      GLenum iError = glGetError();
      if (iError == GL_INVALID_OPERATION) {
        LOG->Trace(
            "Scaling shader failed: glVertexAttrib2fARB returned "
            "GL_INVALID_OPERATION");
        glDeleteObjectARB(g_bTextureMatrixShader);
        g_bTextureMatrixShader = 0;
      } else {
        ASSERT_M(iError == GL_NO_ERROR, GLToString(iError));
      }
    }
  }
}

static LocalizedString OBTAIN_AN_UPDATED_VIDEO_DRIVER(
    "RageDisplay_Legacy",
    "Obtain an updated driver from your video card manufacturer.");
static LocalizedString GLDIRECT_IS_NOT_COMPATIBLE(
    "RageDisplay_Legacy",
    "GLDirect was detected.  GLDirect is not compatible with this game and "
    "should be disabled.");
std::string RageDisplay_Legacy::Init(
    const VideoModeParams& p, bool bAllowUnacceleratedRenderer) {
  g_pWind = LowLevelWindow::Create();

  bool bIgnore = false;
  std::string sError = SetVideoMode(p, bIgnore);
  if (sError != "") {
    return sError;
  }

  // Log driver details
  g_pWind->LogDebugInformation();
  LOG->Info(
      "OGL Vendor: %s", reinterpret_cast<const char*>(glGetString(GL_VENDOR)));
  LOG->Info(
      "OGL Renderer: %s",
      reinterpret_cast<const char*>(glGetString(GL_RENDERER)));
  LOG->Info(
      "OGL Version: %s",
      reinterpret_cast<const char*>(glGetString(GL_VERSION)));
  LOG->Info("OGL Max texture size: %i", GetMaxTextureSize());
  LOG->Info("OGL Texture units: %i", g_iMaxTextureUnits);

  /* Pretty-print the extension string: */
  LOG->Info("OGL Extensions:");
  {
    const char* szExtensionString = (const char*)glGetString(GL_EXTENSIONS);
    std::vector<std::string> asExtensions;
    split(szExtensionString, " ", asExtensions);
    sort(asExtensions.begin(), asExtensions.end());
    size_t iNextToPrint = 0;
    while (iNextToPrint < asExtensions.size()) {
      size_t iLastToPrint = iNextToPrint;
      std::string sType;
      for (size_t i = iNextToPrint; i < asExtensions.size(); ++i) {
        std::vector<std::string> asBits;
        split(asExtensions[i], "_", asBits);
        std::string sThisType;
        if (asBits.size() > 2) {
          sThisType = join("_", asBits.begin(), asBits.begin() + 2);
        }
        if (i > iNextToPrint && sThisType != sType) {
          break;
        }
        sType = sThisType;
        iLastToPrint = i;
      }

      if (iNextToPrint == iLastToPrint) {
        LOG->Info("  %s", asExtensions[iNextToPrint].c_str());
        ++iNextToPrint;
        continue;
      }

      std::string sList = ssprintf("  %s: ", sType.c_str());
      while (iNextToPrint <= iLastToPrint) {
        std::vector<std::string> asBits;
        split(asExtensions[iNextToPrint], "_", asBits);
        std::string sShortExt = join("_", asBits.begin() + 2, asBits.end());
        sList += sShortExt;
        if (iNextToPrint < iLastToPrint) {
          sList += ", ";
        }
        if (iNextToPrint == iLastToPrint ||
            sList.size() + asExtensions[iNextToPrint + 1].size() > 120) {
          LOG->Info("%s", sList.c_str());
          sList = "    ";
        }
        ++iNextToPrint;
      }
    }
  }

  if (g_pWind->IsSoftwareRenderer(sError)) {
    if (!bAllowUnacceleratedRenderer) {
      return sError + "  " + OBTAIN_AN_UPDATED_VIDEO_DRIVER.GetValue() + "\n\n";
    }
    LOG->Warn("Low-performance OpenGL renderer: %s", sError.c_str());
  }

#if defined(_WIN32)
  /* GLDirect is a Direct3D wrapper for OpenGL.  It's rather buggy; and if in
   * any case GLDirect can successfully render us, we should be able to do so
   * too using Direct3D directly.  (If we can't, it's a bug that we can work
   * around--if GLDirect can do it, so can we!) */
  if (!strncmp((const char*)glGetString(GL_RENDERER), "GLDirect", 8)) {
    return GLDIRECT_IS_NOT_COMPATIBLE.GetValue() + "\n";
  }
#endif

  /* Log this, so if people complain that the radar looks bad on their
   * system we can compare them: */
  glGetFloatv(GL_LINE_WIDTH_RANGE, g_line_range);
  glGetFloatv(GL_POINT_SIZE_RANGE, g_point_range);

  return std::string();
}

RageDisplay_Legacy::~RageDisplay_Legacy() {
  ReleaseOffscreenRenderTarget();
  LogDisplayEndFramePerfSummary();
  delete g_pWind;
}

std::string RageDisplay_Legacy::GetApiDescription() const {
  return "OpenGL";
}

std::string RageDisplay_Legacy::GetPresentationStats() const {
#ifdef __APPLE__
  return MacOSMetalPresenterGetRuntimeStatsLine();
#else
  return std::string();
#endif
}

void RageDisplay_Legacy::GetDisplaySpecs(DisplaySpecs& out) const {
  out.clear();
  g_pWind->GetDisplaySpecs(out);
}

static void CheckPalettedTextures() {
  std::string sError;
  do {
    if (!GLEW_EXT_paletted_texture) {
      sError = "GL_EXT_paletted_texture missing";
      break;
    }

    /* Check to see if paletted textures really work. */
    GLenum glTexFormat = g_GLPixFmtInfo[RagePixelFormat_PAL].internalfmt;
    GLenum glImageFormat = g_GLPixFmtInfo[RagePixelFormat_PAL].format;
    GLenum glImageType = g_GLPixFmtInfo[RagePixelFormat_PAL].type;

    int iBits = 8;

    FlushGLErrors();
#define GL_CHECK_ERROR(f)                                               \
  {                                                                     \
    GLenum glError = glGetError();                                      \
    if (glError != GL_NO_ERROR) {                                       \
      sError = ssprintf(f " failed (%s)", GLToString(glError).c_str()); \
      break;                                                            \
    }                                                                   \
  }

    glTexImage2D(
        GL_PROXY_TEXTURE_2D, 0, glTexFormat, 16, 16, 0, glImageFormat,
        glImageType, nullptr);
    GL_CHECK_ERROR("glTexImage2D");

    GLuint iFormat = 0;
    glGetTexLevelParameteriv(
        GL_PROXY_TEXTURE_2D, 0, GLenum(GL_TEXTURE_INTERNAL_FORMAT),
        (GLint*)&iFormat);
    GL_CHECK_ERROR("glGetTexLevelParameteriv(GL_TEXTURE_INTERNAL_FORMAT)");
    if (iFormat != glTexFormat) {
      sError = ssprintf(
          "Expected format %s, got %s instead", GLToString(glTexFormat).c_str(),
          GLToString(iFormat).c_str());
      break;
    }

    GLubyte palette[256 * 4];
    memset(palette, 0, sizeof(palette));
    glColorTableEXT(
        GL_PROXY_TEXTURE_2D, GL_RGBA8, 256, GL_RGBA, GL_UNSIGNED_BYTE, palette);
    GL_CHECK_ERROR("glColorTableEXT");

    GLint iSize = 0;
    glGetTexLevelParameteriv(
        GL_PROXY_TEXTURE_2D, 0, GLenum(GL_TEXTURE_INDEX_SIZE_EXT), &iSize);
    GL_CHECK_ERROR("glGetTexLevelParameteriv(GL_TEXTURE_INDEX_SIZE_EXT)");
    if (iBits > iSize || iSize > 8) {
      sError = ssprintf(
          "Expected %i-bit palette, got a %i-bit one instead", iBits,
          int(iSize));
      break;
    }

    GLint iRealWidth = 0;
    glGetColorTableParameterivEXT(
        GL_PROXY_TEXTURE_2D, GL_COLOR_TABLE_WIDTH, &iRealWidth);
    GL_CHECK_ERROR("glGetColorTableParameterivEXT(GL_COLOR_TABLE_WIDTH)");
    if (iRealWidth != 1 << iBits) {
      sError = ssprintf(
          "GL_COLOR_TABLE_WIDTH returned %i instead of %i", int(iRealWidth),
          1 << iBits);
      break;
    }

    GLint iRealFormat = 0;
    glGetColorTableParameterivEXT(
        GL_PROXY_TEXTURE_2D, GL_COLOR_TABLE_FORMAT, &iRealFormat);
    GL_CHECK_ERROR("glGetColorTableParameterivEXT(GL_COLOR_TABLE_FORMAT)");
    if (iRealFormat != GL_RGBA8) {
      sError = ssprintf(
          "GL_COLOR_TABLE_FORMAT returned %s instead of GL_RGBA8",
          GLToString(iRealFormat).c_str());
      break;
    }
  } while (0);
#undef GL_CHECK_ERROR

  if (sError == "") {
    return;
  }

  /* If 8-bit palettes don't work, disable them entirely--don't trust 4-bit
   * palettes if it can't even get 8-bit ones right. */
  glColorTableEXT = nullptr;
  glGetColorTableParameterivEXT = nullptr;
  LOG->Info("Paletted textures disabled: %s.", sError.c_str());
}

static void CheckReversePackedPixels() {
  /* Try to create a texture. */
  FlushGLErrors();
  glTexImage2D(
      GL_PROXY_TEXTURE_2D, 0, GL_RGBA, 16, 16, 0, GL_BGRA,
      GL_UNSIGNED_SHORT_1_5_5_5_REV, nullptr);

  const GLenum glError = glGetError();
  if (glError == GL_NO_ERROR) {
    g_bReversePackedPixelsWorks = true;
  } else {
    g_bReversePackedPixelsWorks = false;
    LOG->Info(
        "GL_UNSIGNED_SHORT_1_5_5_5_REV failed (%s), disabled",
        GLToString(glError).c_str());
  }
}

void SetupExtensions() {
  const float fGLVersion = StringToFloat((const char*)glGetString(GL_VERSION));
  g_glVersion = std::lrint(fGLVersion * 10);

  const float fGLUVersion =
      StringToFloat((const char*)gluGetString(GLU_VERSION));
  g_gluVersion = std::lrint(fGLUVersion * 10);

#ifndef HAVE_X11  // LLW_X11 needs to init GLEW early for GLX exts
  glewInit();
#endif

  g_iMaxTextureUnits = 1;
  if (GLEW_ARB_multitexture) {
    glGetIntegerv(GL_MAX_TEXTURE_UNITS_ARB, (GLint*)&g_iMaxTextureUnits);
  }

  CheckPalettedTextures();
  CheckReversePackedPixels();

  {
    GLint iMaxTableSize = 0;
    glGetIntegerv(GL_MAX_PIXEL_MAP_TABLE, &iMaxTableSize);
    if (iMaxTableSize < 256) {
      /* The minimum GL_MAX_PIXEL_MAP_TABLE is 32; if it's not at least 256,
       * we can't fit a palette in it, so we can't send paletted data as input
       * for a non-paletted texture. */
      LOG->Info("GL_MAX_PIXEL_MAP_TABLE is only %d", int(iMaxTableSize));
      g_bColorIndexTableWorks = false;
    } else {
      g_bColorIndexTableWorks = true;
    }
  }
}

bool RageDisplay_Legacy::UseOffscreenRenderTarget() {
  if (!GetActualVideoModeParams().renderOffscreen || !TEXTUREMAN) {
    return false;
  }

  if (!SupportsRenderToTexture()) {
    static bool s_bWarnedUnsupportedOffscreenPresent = false;
    if (!s_bWarnedUnsupportedOffscreenPresent) {
      LOG->Warn(
          "OpenGL offscreen present requested but render-to-texture is not "
          "supported; falling back to direct backbuffer rendering.");
      s_bWarnedUnsupportedOffscreenPresent = true;
    }
    return false;
  }

	if (!offscreenRenderTarget) {
		RenderTargetParam param;
		param.bWithDepthBuffer = true;
		param.bWithAlpha = true;
		param.bFloat = false;
		param.iWidth = GetActualVideoModeParams().width;
		param.iHeight = GetActualVideoModeParams().height;
		RageTextureID id(
				ssprintf("FullscreenTexture%dx%d", param.iWidth, param.iHeight));
		// See if we have this texture loaded already (not GC'd yet). If it exists
		// and we try to recreate it, we'll get an error.
		if (TEXTUREMAN->IsTextureRegistered(id)) {
			offscreenRenderTarget =
					static_cast<RageTextureRenderTarget*>(TEXTUREMAN->LoadTexture(id));
		} else {
			offscreenRenderTarget = new RageTextureRenderTarget(id, param);
			TEXTUREMAN->RegisterTexture(id, offscreenRenderTarget);
		}
		LOG->Trace(
				"OpenGL offscreen present target ready: mode=single_buffer "
				"size=%dx%d texture_size=%dx%d fbo=%d platform_rtt=%d",
				param.iWidth, param.iHeight, offscreenRenderTarget->GetTextureWidth(),
				offscreenRenderTarget->GetTextureHeight(),
				GLEW_EXT_framebuffer_object ? 1 : 0,
				g_pWind->SupportsRenderToTexture() ? 1 : 0);
	}
	return true;
}

void RageDisplay_Legacy::ReleaseOffscreenRenderTarget() {
	if (offscreenRenderTarget && TEXTUREMAN) {
		TEXTUREMAN->UnloadTexture(offscreenRenderTarget);
		offscreenRenderTarget = nullptr;
	}
}

void RageDisplay_Legacy::PrepareForTextureManagerShutdown() {
	ReleaseOffscreenRenderTarget();
}

void RageDisplay_Legacy::ResetFramePresentationTelemetry() {
  g_iLastPresentReturnUsec = 0;
}

void RageDisplay_Legacy::ResolutionChanged() {
  // LOG->Warn( "RageDisplay_Legacy::ResolutionChanged" );
  ResetFramePresentationTelemetry();

  /*
   * Clear any junk that's in the framebuffer without going through EndFrame().
   * The full presentation path can depend on runtime pacing state that is not
   * fully established during the initial video-mode transition.
   */
  const ActualVideoModeParams mode = g_pWind->GetActualVideoModeParams();
  glViewport(0, 0, mode.windowWidth, mode.windowHeight);
  glClearColor(0, 0, 0, 0);
  glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
  glFlush();

  RageDisplay::ResolutionChanged();

	ReleaseOffscreenRenderTarget();
}

// Return true if mode change was successful.
// bNewDeviceOut is set true if a new device was created and textures
// need to be reloaded.
std::string RageDisplay_Legacy::TryVideoMode(
    const VideoModeParams& p, bool& bNewDeviceOut) {
  // LOG->Warn( "RageDisplay_Legacy::TryVideoMode( %d, %d, %d, %d, %d, %d )",
  // p.windowed, p.width, p.height, p.bpp, p.rate, p.vsync );

  std::string err;
  err = g_pWind->TryVideoMode(p, bNewDeviceOut);
  if (err != "") {
    return err;  // failed to set video mode
  }

  /* Now that we've initialized, we can search for extensions.  Do this before
   * InvalidateObjects, since AllocateBuffers needs it. */
  SetupExtensions();

  if (bNewDeviceOut) {
    /* We have a new OpenGL context, so we have to tell our textures that
     * their OpenGL texture number is invalid. */
    if (TEXTUREMAN) {
      TEXTUREMAN->InvalidateTextures();
    }

    /* Delete all render targets.  They may have associated resources other than
     * the texture itself. */
    for (std::pair<const uintptr_t, RenderTarget*>& rt : g_mapRenderTargets) {
      delete rt.second;
    }
    g_mapRenderTargets.clear();

    /* Recreate all vertex buffers. */
    InvalidateObjects();

    InitShaders();
  }

// I'm not sure this is correct -Colby
#if defined(WINDOWS)
  /* Set vsync the Windows way, if we can.  (What other extensions are there
   * to do this, for other archs?) */
  if (wglewIsSupported("WGL_EXT_swap_control")) {
    wglSwapIntervalEXT(p.vsync);
  } else {
    return std::string(
        "The WGL_EXT_swap_control extension is not supported on your "
        "computer.");
  }
#endif

  ResolutionChanged();

  return std::string();  // successfully set mode
}

// https://stackoverflow.com/q/6594214
// Since glGetIntegerv won't initialize the variable if it fails, account for
// failure. We initialize it to -1, so we know if it failed. Failure here is
// extremely uncommon, but was first reported on a setup using an AMD RX 6600
// series GPU & late 2024 driver.
int RageDisplay_Legacy::GetMaxTextureSize() const {
  GLint size = -1;
  glGetIntegerv(GL_MAX_TEXTURE_SIZE, &size);

  if (size <= 0) {
    LOG->Warn(
        "RageDisplay_Legacy::GetMaxTextureSize: glGetIntegerv %s %d",
        (size == -1) ? "failed" : "returned invalid value", size);
    return 2048;
  }

  return size;
}

bool RageDisplay_Legacy::BeginFrame() {
  /* We do this in here, rather than ResolutionChanged, or we won't update the
   * viewport for the concurrent rendering context. */
  int fWidth = g_pWind->GetActualVideoModeParams().windowWidth;
  int fHeight = g_pWind->GetActualVideoModeParams().windowHeight;

  glViewport(0, 0, fWidth, fHeight);

  glClearColor(0, 0, 0, 0);
  SetZWrite(true);
  glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

	bool beginFrame = RageDisplay::BeginFrame();
	if (beginFrame && UseOffscreenRenderTarget()) {
		offscreenRenderTarget->BeginRenderingTo(false);
	}

  return beginFrame;
}

void RageDisplay_Legacy::EndFrame() {
  RageTimer totalTimer;
  RageTimer phaseTimer;
  float offscreenMs = 0.0f;
  float preFramePacingSyncMs = 0.0f;
  float frameLimitBeforeMs = 0.0f;
  float swapBuffersMs = 0.0f;
  float frameLimitAfterMs = 0.0f;
  float glFinishMs = 0.0f;
  float glFlushMs = 0.0f;
  float windowUpdateMs = 0.0f;
  float statsMs = 0.0f;
  const char* preFramePacingSyncMode = "none";
  const char* glSyncMode = "flush";
  const ActualVideoModeParams mode = g_pWind->GetActualVideoModeParams();
  const float expectedFrameMs = ExpectedFrameMsForRate(mode.rate);
#ifdef __APPLE__
  bool preFramePacingProactiveArmed = false;
  bool preFramePacingContinuousFinish = false;
  const int reactiveFinishFrames =
      OpenGLPreFramePacingReactiveFinishFrames(mode.rate);
  const int highRefreshReactiveCap =
      std::clamp(
          g_iOpenGLPreFramePacingHighRefreshMaxReactiveFinishFrames.Get(), 0,
          30);
  const int highRefreshMinRate =
      std::clamp(g_iOpenGLPreFramePacingHighRefreshMinRate.Get(), 1, 1000);
  const bool highRefreshReactiveCapActive =
      mode.rate >= highRefreshMinRate &&
      reactiveFinishFrames <= highRefreshReactiveCap;
  g_iOpenGLPreFramePacingFinishFramesRemaining = std::min(
      g_iOpenGLPreFramePacingFinishFramesRemaining, reactiveFinishFrames);
  int preFramePacingFinishRemainingBefore =
      g_iOpenGLPreFramePacingFinishFramesRemaining;
  const int proactiveFinishMinRate = std::clamp(
      g_iOpenGLPreFramePacingProactiveFinishMinRate.Get(), 1, 1000);
  const int proactiveFinishEveryNFramesConfigured = std::clamp(
      g_iOpenGLPreFramePacingProactiveFinishEveryNFrames.Get(), 1, 36000);
  const int proactiveFinishEveryNFrames =
      OpenGLPreFramePacingProactiveFinishEveryNFrames(mode.rate);
  const int proactiveFinishEveryNFramesEffective =
      proactiveFinishEveryNFrames;
  const int highRefreshProactiveMaxEveryNFrames = std::clamp(
      g_iOpenGLPreFramePacingHighRefreshMaxProactiveFinishEveryNFrames.Get(),
      1, kOpenGLPreFramePacingHighRefreshProactiveMaxEveryNFrames);
  const bool highRefreshProactiveCapActive =
      mode.rate >= proactiveFinishMinRate &&
      proactiveFinishEveryNFrames < proactiveFinishEveryNFramesConfigured;
  const int proactiveFinishFrames = std::clamp(
      g_iOpenGLPreFramePacingProactiveFinishFrames.Get(), 0, 30);
  const int continuousFinishMinRate = std::clamp(
      g_iOpenGLPreFramePacingContinuousFinishMinRate.Get(), 1, 1000);
  const int continuousFinishLogEveryNFrames = std::clamp(
      g_iOpenGLPreFramePacingContinuousFinishLogEveryNFrames.Get(), 1, 36000);
  const MacOSMetalPresenterRuntimeStats metalPresenterRuntimeStats =
      MacOSMetalPresenterGetRuntimeStats();
  const bool metalDirectPresentRuntimeActive =
      metalPresenterRuntimeStats.submittedFrames > 0;
  const bool proactiveFinishAllowed =
      !metalDirectPresentRuntimeActive;
#endif

	if (UseOffscreenRenderTarget()) {
		offscreenRenderTarget->FinishRenderingTo();
		Sprite fullscreenSprite;
		fullscreenSprite.SetTexture(TEXTUREMAN->CopyTexture(offscreenRenderTarget));
		fullscreenSprite.SetHorizAlign(align_left);
		fullscreenSprite.SetVertAlign(align_top);
		CameraPushMatrix();
    LoadMenuPerspective(
        0, GetActualVideoModeParams().width, GetActualVideoModeParams().height,
        static_cast<float>(GetActualVideoModeParams().width) / 2.f,
        static_cast<float>(GetActualVideoModeParams().height) / 2.f);
		fullscreenSprite.Draw();
		CameraPopMatrix();
	}
  offscreenMs = phaseTimer.GetDeltaTime() * 1000.0f;

#ifdef __APPLE__
  if (g_bOpenGLPreFramePacingSync.Get()) {
    ++g_iOpenGLPreFramePacingFrames;
    if (proactiveFinishAllowed &&
        g_bOpenGLPreFramePacingProactiveFinish.Get() &&
        proactiveFinishFrames > 0 && mode.rate >= proactiveFinishMinRate &&
        (g_iOpenGLPreFramePacingFrames %
         static_cast<uint64_t>(proactiveFinishEveryNFramesEffective)) == 0) {
      g_iOpenGLPreFramePacingFinishFramesRemaining = std::max(
          g_iOpenGLPreFramePacingFinishFramesRemaining,
          proactiveFinishFrames);
      preFramePacingProactiveArmed = true;
      ++g_iOpenGLPreFramePacingProactiveFinishes;
    }
    RageTimer syncTimer;
    preFramePacingContinuousFinish =
        g_bOpenGLPreFramePacingContinuousFinish.Get() &&
        mode.rate >= continuousFinishMinRate;
    if (preFramePacingContinuousFinish) {
      glFinish();
      preFramePacingSyncMode = "finish_continuous";
      ++g_iOpenGLPreFramePacingContinuousFinishes;
      if (g_iOpenGLPreFramePacingFinishFramesRemaining > 0) {
        --g_iOpenGLPreFramePacingFinishFramesRemaining;
      }
    } else if (g_bOpenGLPreFramePacingFinishOnBackpressure.Get() &&
        g_iOpenGLPreFramePacingFinishFramesRemaining > 0) {
      glFinish();
      preFramePacingSyncMode =
          preFramePacingProactiveArmed ? "finish_proactive"
                                       : "finish_backpressure";
      --g_iOpenGLPreFramePacingFinishFramesRemaining;
    } else {
      glFlush();
      preFramePacingSyncMode = "flush";
    }
    preFramePacingSyncMs = syncTimer.GetDeltaTime() * 1000.0f;
    RecordOpenGLPreFramePacingTrace(
        preFramePacingSyncMode, preFramePacingSyncMs);
    const bool shouldLogContinuousFinish =
        preFramePacingContinuousFinish &&
        (g_iOpenGLPreFramePacingFrames %
         static_cast<uint64_t>(continuousFinishLogEveryNFrames)) == 0;
    const bool isBackpressureFinish =
        strcmp(preFramePacingSyncMode, "finish_backpressure") == 0;
    const bool shouldLogProactiveFinish =
        preFramePacingProactiveArmed &&
        g_bPerfTraceOpenGLPreFramePacingProactiveDetails.Get();
    if (PerfDiagnosticsEnabled() &&
        (preFramePacingSyncMs >=
             g_fPerfTraceSlowOpenGLPreFramePacingSyncMs.Get() ||
         shouldLogContinuousFinish || shouldLogProactiveFinish ||
         isBackpressureFinish)) {
      LOG->Trace(
          "PERF_TRACE: opengl_pre_frame_pacing_sync total_ms=%.3f mode=%s "
          "finish_remaining_before=%d finish_remaining_after=%d rate=%d "
          "expected_frame_ms=%.3f proactive_armed=%d "
          "reactive_requested_frames=%d reactive_effective_frames=%d "
          "reactive_high_refresh_cap_frames=%d "
          "reactive_high_refresh_min_rate=%d "
          "reactive_high_refresh_cap_active=%d "
          "proactive_every_n_configured=%d "
          "proactive_every_n_effective=%d "
          "proactive_high_refresh_max_every_n=%d "
          "proactive_high_refresh_cap_active=%d "
          "proactive_frames=%d "
          "proactive_min_rate=%d proactive_count=%llu "
          "metal_direct_present_active=%d proactive_allowed=%d "
          "continuous_finish=%d continuous_min_rate=%d "
          "continuous_log_every_n=%d continuous_count=%llu frame=%llu",
          preFramePacingSyncMs, preFramePacingSyncMode,
          preFramePacingFinishRemainingBefore,
          g_iOpenGLPreFramePacingFinishFramesRemaining, mode.rate,
          expectedFrameMs, preFramePacingProactiveArmed ? 1 : 0,
          std::clamp(g_iOpenGLPreFramePacingFinishFrames.Get(), 0, 120),
          reactiveFinishFrames,
          highRefreshReactiveCap,
          highRefreshMinRate,
          highRefreshReactiveCapActive ? 1 : 0,
          proactiveFinishEveryNFramesConfigured,
          proactiveFinishEveryNFramesEffective,
          highRefreshProactiveMaxEveryNFrames,
          highRefreshProactiveCapActive ? 1 : 0,
          proactiveFinishFrames,
          proactiveFinishMinRate,
          static_cast<unsigned long long>(
              g_iOpenGLPreFramePacingProactiveFinishes),
          metalDirectPresentRuntimeActive ? 1 : 0,
          proactiveFinishAllowed ? 1 : 0,
          preFramePacingContinuousFinish ? 1 : 0,
          continuousFinishMinRate, continuousFinishLogEveryNFrames,
          static_cast<unsigned long long>(
              g_iOpenGLPreFramePacingContinuousFinishes),
          static_cast<unsigned long long>(g_iOpenGLPreFramePacingFrames));
    }
    if (ShouldLogOpenGLPreFramePacingSummary()) {
      LogAndResetOpenGLPreFramePacingSummary(
          mode.rate, proactiveFinishEveryNFramesConfigured,
          proactiveFinishEveryNFramesEffective,
          highRefreshProactiveMaxEveryNFrames,
          highRefreshProactiveCapActive);
    }
  }
#endif

#ifdef __APPLE__
  const bool hardwareVsyncOwnsPacing = mode.vsync;
#else
  const bool hardwareVsyncOwnsPacing = false;
#endif
  if (!hardwareVsyncOwnsPacing) {
    FrameLimitBeforeVsync(mode.rate);
  }
  frameLimitBeforeMs = phaseTimer.GetDeltaTime() * 1000.0f;
#ifdef __APPLE__
  ReportFramePacingPreSwapLoad(
      offscreenMs + preFramePacingSyncMs + frameLimitBeforeMs);
#endif
  const bool metalBackbufferPresented =
      g_pWind->PresentOpenGLBackbufferViaMetal();
  if (metalBackbufferPresented) {
    glSyncMode = "metal_backbuffer";
  }
  g_pWind->SwapBuffers();
  const uint64_t presentReturnUsec = RageTimer::GetTimeSinceStartMicroseconds();
  const float presentReturnIntervalMs =
      g_iLastPresentReturnUsec != 0 && presentReturnUsec > g_iLastPresentReturnUsec
          ? static_cast<float>(presentReturnUsec - g_iLastPresentReturnUsec) /
                1000.0f
          : 0.0f;
  g_iLastPresentReturnUsec = presentReturnUsec;
  swapBuffersMs = phaseTimer.GetDeltaTime() * 1000.0f;

#ifdef __APPLE__
  const bool swapBackpressure =
      expectedFrameMs > 0.0f && swapBuffersMs >= expectedFrameMs * 0.9f;
  if (swapBackpressure &&
      g_bOpenGLPreFramePacingFinishOnBackpressure.Get()) {
    g_iOpenGLPreFramePacingFinishFramesRemaining = reactiveFinishFrames;
  }
#endif

  FrameLimitAfterVsync(swapBuffersMs);
  frameLimitAfterMs = phaseTimer.GetDeltaTime() * 1000.0f;

  const int finishEveryNFrames =
      std::max(0, g_iOpenGLFinishEveryNFrames.Get());
  const bool periodicFinish =
      finishEveryNFrames > 0 &&
      (++g_iOpenGLFramesSinceFinish %
       static_cast<uint64_t>(finishEveryNFrames)) == 0;
  if (g_bOpenGLFinishAfterSwap.Get() || periodicFinish) {
    glFinish();
    glFinishMs = phaseTimer.GetDeltaTime() * 1000.0f;
    glSyncMode = periodicFinish && !g_bOpenGLFinishAfterSwap.Get()
                     ? "periodic_finish"
                     : "finish";
  } else {
    glFlush();
    glFlushMs = phaseTimer.GetDeltaTime() * 1000.0f;
  }

  g_pWind->Update();
  windowUpdateMs = phaseTimer.GetDeltaTime() * 1000.0f;

  RageDisplay::EndFrame();
  statsMs = phaseTimer.GetDeltaTime() * 1000.0f;

  const float totalMs = totalTimer.GetDeltaTime() * 1000.0f;
  const float budgetMultiplier =
      std::max(0.0f, g_fPerfTraceDisplayEndFrameBudgetMultiplier.Get());
  const float budgetTraceMs =
      expectedFrameMs > 0.0f && budgetMultiplier > 0.0f
          ? expectedFrameMs * budgetMultiplier
          : 0.0f;
  const float configuredTraceMs =
      std::max(0.0f, g_fPerfTraceSlowDisplayEndFrameMs.Get());
  const float effectiveTraceMs =
      budgetTraceMs > 0.0f && configuredTraceMs > 0.0f
          ? std::min(budgetTraceMs, configuredTraceMs)
          : std::max(budgetTraceMs, configuredTraceMs);
  const int missedSwapIntervals =
      MissedIntervalsForElapsedMs(swapBuffersMs, expectedFrameMs);
  const int missedTotalIntervals =
      MissedIntervalsForElapsedMs(totalMs, expectedFrameMs);
  const char* currentScreenName = CurrentTopScreenName();
  const char* frameClassification = ClassifyDisplayEndFrame(
      totalMs, offscreenMs, preFramePacingSyncMs, frameLimitBeforeMs,
      swapBuffersMs, frameLimitAfterMs, glFinishMs, glFlushMs,
      windowUpdateMs, statsMs, expectedFrameMs);
#ifdef __APPLE__
  if (hardwareVsyncOwnsPacing && swapBuffersMs >= expectedFrameMs * 0.5f &&
      presentReturnIntervalMs > 0.0f &&
      presentReturnIntervalMs < expectedFrameMs * 1.5f) {
    frameClassification = "hardware_vsync_wait";
  }
#endif
  RecordDisplayEndFramePerf(
      totalMs, swapBuffersMs, frameLimitBeforeMs, presentReturnIntervalMs,
      expectedFrameMs, missedSwapIntervals, missedTotalIntervals,
      frameClassification, currentScreenName);
  if (PerfDiagnosticsEnabled() && effectiveTraceMs > 0.0f &&
      totalMs >= effectiveTraceMs) {
    const float renderBeforeSwapMs =
        offscreenMs + preFramePacingSyncMs + frameLimitBeforeMs;
    const float presentAndSyncMs =
        swapBuffersMs + frameLimitAfterMs + glFinishMs + glFlushMs;
    LOG->Trace(
      "PERF_TRACE: display_end_frame total_ms=%.3f offscreen_ms=%.3f "
        "render_before_swap_ms=%.3f present_and_sync_ms=%.3f "
        "pre_frame_pacing_sync_ms=%.3f pre_frame_pacing_sync_mode=%s "
        "frame_limit_before_ms=%.3f swap_buffers_ms=%.3f "
        "frame_limit_after_ms=%.3f gl_finish_ms=%.3f gl_flush_ms=%.3f "
        "gl_sync_mode=%s window_update_ms=%.3f "
        "stats_ms=%.3f classification=%s rate=%d vsync=%d windowed=%d "
        "render_offscreen=%d "
        "hardware_vsync_owns_pacing=%d present_return_interval_ms=%.3f "
#ifdef __APPLE__
        "pre_frame_finish_remaining_before=%d "
        "pre_frame_finish_remaining_after=%d "
        "pre_frame_finish_proactive_armed=%d "
        "pre_frame_finish_proactive_count=%llu "
        "pre_frame_finish_proactive_every_n_configured=%d "
        "pre_frame_finish_proactive_every_n_effective=%d "
        "pre_frame_finish_proactive_high_refresh_max_every_n=%d "
        "pre_frame_finish_proactive_high_refresh_cap_active=%d "
        "pre_frame_pacing_frame=%llu "
        "pre_frame_reactive_requested_frames=%d "
        "pre_frame_reactive_effective_frames=%d "
        "pre_frame_reactive_high_refresh_cap_frames=%d "
        "pre_frame_reactive_high_refresh_min_rate=%d "
        "pre_frame_reactive_high_refresh_cap_active=%d "
        "pre_frame_continuous_finish=%d "
        "pre_frame_continuous_count=%llu "
#endif
        "expected_frame_ms=%.3f missed_swap_intervals=%d "
        "missed_total_intervals=%d trace_threshold_ms=%.3f "
        "budget_multiplier=%.3f render_size=%dx%d window_size=%dx%d",
        totalMs, offscreenMs, renderBeforeSwapMs, presentAndSyncMs,
        preFramePacingSyncMs, preFramePacingSyncMode,
        frameLimitBeforeMs, swapBuffersMs, frameLimitAfterMs, glFinishMs,
        glFlushMs, glSyncMode, windowUpdateMs,
        statsMs,
        frameClassification,
        mode.rate,
        mode.vsync ? 1 : 0, mode.windowed ? 1 : 0,
        mode.renderOffscreen ? 1 : 0,
        hardwareVsyncOwnsPacing ? 1 : 0,
        presentReturnIntervalMs,
#ifdef __APPLE__
        preFramePacingFinishRemainingBefore,
        g_iOpenGLPreFramePacingFinishFramesRemaining,
        preFramePacingProactiveArmed ? 1 : 0,
        static_cast<unsigned long long>(
            g_iOpenGLPreFramePacingProactiveFinishes),
        proactiveFinishEveryNFramesConfigured,
        proactiveFinishEveryNFramesEffective,
        highRefreshProactiveMaxEveryNFrames,
        highRefreshProactiveCapActive ? 1 : 0,
        static_cast<unsigned long long>(g_iOpenGLPreFramePacingFrames),
        std::clamp(g_iOpenGLPreFramePacingFinishFrames.Get(), 0, 120),
        reactiveFinishFrames,
        highRefreshReactiveCap,
        highRefreshMinRate,
        highRefreshReactiveCapActive ? 1 : 0,
        preFramePacingContinuousFinish ? 1 : 0,
        static_cast<unsigned long long>(
            g_iOpenGLPreFramePacingContinuousFinishes),
#endif
        expectedFrameMs, missedSwapIntervals,
        missedTotalIntervals, effectiveTraceMs, budgetMultiplier, mode.width,
        mode.height, mode.windowWidth, mode.windowHeight);
  }
}

RageSurface* RageDisplay_Legacy::CreateScreenshot() {
  int width = g_pWind->GetActualVideoModeParams().width;
  int height = g_pWind->GetActualVideoModeParams().height;

  RageSurface* image = nullptr;
	if (offscreenRenderTarget) {
		RageSurface* raw = GetTexture(offscreenRenderTarget->GetTexHandle());
		image = CreateSurface(
				offscreenRenderTarget->GetImageWidth(),
				offscreenRenderTarget->GetImageHeight(), raw->fmt.BitsPerPixel,
				raw->fmt.Rmask, raw->fmt.Gmask, raw->fmt.Bmask, raw->fmt.Amask);
    RageSurfaceUtils::Blit(raw, image);
    delete raw;
  } else {
    const RagePixelFormatDesc& desc = PIXEL_FORMAT_DESC[RagePixelFormat_RGBA8];
    image = CreateSurface(
        width, height, desc.bpp, desc.masks[0], desc.masks[1], desc.masks[2],
        0);

    DebugFlushGLErrors();

    // TODO: revisit for MacOS, where backbuffer size can be less than window
    // size
    glReadBuffer(GL_FRONT);
    DebugAssertNoGLError();

    glReadPixels(
        0, 0, g_pWind->GetActualVideoModeParams().width,
        g_pWind->GetActualVideoModeParams().height, GL_RGBA, GL_UNSIGNED_BYTE,
        image->pixels);
    DebugAssertNoGLError();

    RageSurfaceUtils::FlipVertically(image);
  }

  return image;
}

RageSurface* RageDisplay_Legacy::GetTexture(uintptr_t iTexture) {
  if (iTexture == 0) {
    return nullptr;  // XXX
  }

  FlushGLErrors();

  glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(iTexture));
  GLint iHeight, iWidth, iAlphaBits;
  glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_HEIGHT, &iHeight);
  glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, &iWidth);
  glGetTexLevelParameteriv(
      GL_TEXTURE_2D, 0, GL_TEXTURE_ALPHA_SIZE, &iAlphaBits);
  int iFormat = iAlphaBits ? RagePixelFormat_RGBA8 : RagePixelFormat_RGB8;

  const RagePixelFormatDesc& desc = PIXEL_FORMAT_DESC[iFormat];
  RageSurface* pImage = CreateSurface(
      iWidth, iHeight, desc.bpp, desc.masks[0], desc.masks[1], desc.masks[2],
      desc.masks[3]);

  glGetTexImage(
      GL_TEXTURE_2D, 0, g_GLPixFmtInfo[iFormat].format, GL_UNSIGNED_BYTE,
      pImage->pixels);
  AssertNoGLError();

  return pImage;
}

ActualVideoModeParams RageDisplay_Legacy::GetActualVideoModeParams() const {
  return g_pWind->GetActualVideoModeParams();
}

static void SetupVertices(const RageSpriteVertex v[], int iNumVerts) {
  static const bool bInterleaveColor =
      !!GLEW_ARB_vertex_array_bgra || !!GLEW_EXT_vertex_array_bgra;
  if (bInterleaveColor) {
    const GLsizei stride = sizeof(RageSpriteVertex);

    glEnableClientState(GL_VERTEX_ARRAY);
    glVertexPointer(3, GL_FLOAT, stride, &v[0].p);

    glEnableClientState(GL_COLOR_ARRAY);
    glColorPointer(GL_BGRA, GL_UNSIGNED_BYTE, stride, &v[0].c);

    glEnableClientState(GL_TEXTURE_COORD_ARRAY);
    glTexCoordPointer(2, GL_FLOAT, stride, &v[0].t);

    if (GLEW_ARB_multitexture) {
      glClientActiveTextureARB(GL_TEXTURE1_ARB);
      glEnableClientState(GL_TEXTURE_COORD_ARRAY);
      glTexCoordPointer(2, GL_FLOAT, stride, &v[0].t);
      glClientActiveTextureARB(GL_TEXTURE0_ARB);
    }

    glEnableClientState(GL_NORMAL_ARRAY);
    glNormalPointer(GL_FLOAT, stride, &v[0].n);
    return;
  }

  // Convert from BGRA -> RGBA for drivers without GL_BGRA vertex arrays.
  static float *Vertex, *Texture, *Normal;
  static GLubyte* Color;
  static int Size = 0;
  if (iNumVerts > Size) {
    Size = iNumVerts;
    delete[] Vertex;
    delete[] Color;
    delete[] Texture;
    delete[] Normal;
    Vertex = new float[Size * 3];
    Color = new GLubyte[Size * 4];
    Texture = new float[Size * 2];
    Normal = new float[Size * 3];
  }

  for (unsigned i = 0; i < unsigned(iNumVerts); ++i) {
    Vertex[i * 3 + 0] = v[i].p[0];
    Vertex[i * 3 + 1] = v[i].p[1];
    Vertex[i * 3 + 2] = v[i].p[2];
    Color[i * 4 + 0] = v[i].c.r;
    Color[i * 4 + 1] = v[i].c.g;
    Color[i * 4 + 2] = v[i].c.b;
    Color[i * 4 + 3] = v[i].c.a;
    Texture[i * 2 + 0] = v[i].t[0];
    Texture[i * 2 + 1] = v[i].t[1];
    Normal[i * 3 + 0] = v[i].n[0];
    Normal[i * 3 + 1] = v[i].n[1];
    Normal[i * 3 + 2] = v[i].n[2];
  }
  glEnableClientState(GL_VERTEX_ARRAY);
  glVertexPointer(3, GL_FLOAT, 0, Vertex);

  glEnableClientState(GL_COLOR_ARRAY);
  glColorPointer(4, GL_UNSIGNED_BYTE, 0, Color);

  glEnableClientState(GL_TEXTURE_COORD_ARRAY);
  glTexCoordPointer(2, GL_FLOAT, 0, Texture);

  if (GLEW_ARB_multitexture) {
    glClientActiveTextureARB(GL_TEXTURE1_ARB);
    glEnableClientState(GL_TEXTURE_COORD_ARRAY);
    glTexCoordPointer(2, GL_FLOAT, 0, Texture);
    glClientActiveTextureARB(GL_TEXTURE0_ARB);
  }

  glEnableClientState(GL_NORMAL_ARRAY);
  glNormalPointer(GL_FLOAT, 0, Normal);
}

void RageDisplay_Legacy::SendCurrentMatrices() {
  RageMatrix projection;
  RageMatrixMultiply(&projection, GetCentering(), GetProjectionTop());

  if (g_bInvertY) {
    RageMatrix flip;
    RageMatrixScale(&flip, +1, -1, +1);
    RageMatrixMultiply(&projection, &flip, &projection);
  }
  glMatrixMode(GL_PROJECTION);
  glLoadMatrixf((const float*)&projection);

  // OpenGL has just "modelView", whereas D3D has "world" and "view"
  RageMatrix modelView;
  RageMatrixMultiply(&modelView, GetViewTop(), GetWorldTop());
  glMatrixMode(GL_MODELVIEW);
  glLoadMatrixf((const float*)&modelView);

  glMatrixMode(GL_TEXTURE);
  glLoadMatrixf((const float*)GetTextureTop());
}

class RageCompiledGeometrySWOGL : public RageCompiledGeometry {
 public:
  void Allocate(const std::vector<msMesh>& vMeshes) {
    /* Always allocate at least 1 entry, so &x[0] is valid. */
    const unsigned int verticesCount =
        std::max<unsigned int>(1u, GetTotalVertices());
    const unsigned int trianglesCount =
        std::max<unsigned int>(1u, GetTotalTriangles());

    m_vPosition.resize(verticesCount);
    m_vTexture.resize(verticesCount);
    m_vNormal.resize(verticesCount);
    m_vTexMatrixScale.resize(verticesCount);
    m_vTriangles.resize(trianglesCount);
  }
  void Change(const std::vector<msMesh>& vMeshes) {
    for (unsigned i = 0; i < vMeshes.size(); i++) {
      const MeshInfo& meshInfo = m_vMeshInfo[i];
      const msMesh& mesh = vMeshes[i];
      const std::vector<RageModelVertex>& Vertices = mesh.Vertices;
      const std::vector<msTriangle>& Triangles = mesh.Triangles;

      for (unsigned j = 0; j < Vertices.size(); j++) {
        m_vPosition[meshInfo.iVertexStart + j] = Vertices[j].p;
        m_vTexture[meshInfo.iVertexStart + j] = Vertices[j].t;
        m_vNormal[meshInfo.iVertexStart + j] = Vertices[j].n;
        m_vTexMatrixScale[meshInfo.iVertexStart + j] =
            Vertices[j].TextureMatrixScale;
      }

      for (unsigned j = 0; j < Triangles.size(); j++) {
        for (unsigned k = 0; k < 3; k++) {
          int iVertexIndexInVBO =
              meshInfo.iVertexStart + Triangles[j].nVertexIndices[k];
          m_vTriangles[meshInfo.iTriangleStart + j].nVertexIndices[k] =
              (uint16_t)iVertexIndexInVBO;
        }
      }
    }
  }
  void Draw(int iMeshIndex) const {
    TurnOffHardwareVBO();

    const MeshInfo& meshInfo = m_vMeshInfo[iMeshIndex];

    glEnableClientState(GL_VERTEX_ARRAY);
    glVertexPointer(3, GL_FLOAT, 0, &m_vPosition[0]);

    glDisableClientState(GL_COLOR_ARRAY);

    glEnableClientState(GL_TEXTURE_COORD_ARRAY);
    glTexCoordPointer(2, GL_FLOAT, 0, &m_vTexture[0]);

    glEnableClientState(GL_NORMAL_ARRAY);
    glNormalPointer(GL_FLOAT, 0, &m_vNormal[0]);

    if (meshInfo.m_bNeedsTextureMatrixScale) {
      // Kill the texture translation.
      // XXX: Change me to scale the translation by the TextureTranslationScale
      // of the first vertex.
      RageMatrix mat;
      glGetFloatv(GL_TEXTURE_MATRIX, (float*)mat);

      /*
      for( int i=0; i<4; i++ )
      {
              std::string s;
              for( int j=0; j<4; j++ )
                      s += ssprintf( "%f ", mat.m[i][j] );
              LOG->Trace( s );
      }
      */

      mat.m[3][0] = 0;
      mat.m[3][1] = 0;
      mat.m[3][2] = 0;

      glMatrixMode(GL_TEXTURE);
      glLoadMatrixf((const float*)mat);
    }

    glDrawElements(
        GL_TRIANGLES, meshInfo.iTriangleCount * 3, GL_UNSIGNED_SHORT,
        &m_vTriangles[0] + meshInfo.iTriangleStart);
  }

 protected:
  std::vector<RageVector3> m_vPosition;
  std::vector<RageVector2> m_vTexture;
  std::vector<RageVector3> m_vNormal;
  std::vector<msTriangle> m_vTriangles;
  std::vector<RageVector2> m_vTexMatrixScale;
};

class InvalidateObject;
static std::set<InvalidateObject*> g_InvalidateList;
class InvalidateObject {
 public:
  InvalidateObject() { g_InvalidateList.insert(this); }
  virtual ~InvalidateObject() { g_InvalidateList.erase(this); }
  virtual void Invalidate() = 0;
};

static void InvalidateObjects() {
  for (InvalidateObject* it : g_InvalidateList) {
    it->Invalidate();
  }
}

class RageCompiledGeometryHWOGL : public RageCompiledGeometrySWOGL,
                                  public InvalidateObject {
 protected:
  // vertex buffer object names
  GLuint m_nPositions;
  GLuint m_nTextureCoords;
  GLuint m_nNormals;
  GLuint m_nTriangles;
  GLuint m_nTextureMatrixScale;

  void AllocateBuffers();
  void UploadData();

 public:
  RageCompiledGeometryHWOGL();
  ~RageCompiledGeometryHWOGL();

  /* This is called when our OpenGL context is invalidated. */
  void Invalidate();

  void Allocate(const std::vector<msMesh>& vMeshes);
  void Change(const std::vector<msMesh>& vMeshes);
  void Draw(int iMeshIndex) const;
};

RageCompiledGeometryHWOGL::RageCompiledGeometryHWOGL() {
  m_nPositions = 0;
  m_nTextureCoords = 0;
  m_nNormals = 0;
  m_nTriangles = 0;
  m_nTextureMatrixScale = 0;

  AllocateBuffers();
}

RageCompiledGeometryHWOGL::~RageCompiledGeometryHWOGL() {
  DebugFlushGLErrors();

  glDeleteBuffersARB(1, &m_nPositions);
  DebugAssertNoGLError();
  glDeleteBuffersARB(1, &m_nTextureCoords);
  DebugAssertNoGLError();
  glDeleteBuffersARB(1, &m_nNormals);
  DebugAssertNoGLError();
  glDeleteBuffersARB(1, &m_nTriangles);
  DebugAssertNoGLError();
  glDeleteBuffersARB(1, &m_nTextureMatrixScale);
  DebugAssertNoGLError();
}

void RageCompiledGeometryHWOGL::AllocateBuffers() {
  DebugFlushGLErrors();

  if (!m_nPositions) {
    glGenBuffersARB(1, &m_nPositions);
    DebugAssertNoGLError();
  }

  if (!m_nTextureCoords) {
    glGenBuffersARB(1, &m_nTextureCoords);
    DebugAssertNoGLError();
  }

  if (!m_nNormals) {
    glGenBuffersARB(1, &m_nNormals);
    DebugAssertNoGLError();
  }

  if (!m_nTriangles) {
    glGenBuffersARB(1, &m_nTriangles);
    DebugAssertNoGLError();
  }

  if (!m_nTextureMatrixScale) {
    glGenBuffersARB(1, &m_nTextureMatrixScale);
    DebugAssertNoGLError();
  }
}

void RageCompiledGeometryHWOGL::UploadData() {
  DebugFlushGLErrors();

  glBindBufferARB(GL_ARRAY_BUFFER_ARB, m_nPositions);
  DebugAssertNoGLError();
  glBufferDataARB(
      GL_ARRAY_BUFFER_ARB, GetTotalVertices() * sizeof(RageVector3),
      &m_vPosition[0], GL_STATIC_DRAW_ARB);
  DebugAssertNoGLError();

  glBindBufferARB(GL_ARRAY_BUFFER_ARB, m_nTextureCoords);
  DebugAssertNoGLError();
  glBufferDataARB(
      GL_ARRAY_BUFFER_ARB, GetTotalVertices() * sizeof(RageVector2),
      &m_vTexture[0], GL_STATIC_DRAW_ARB);
  DebugAssertNoGLError();

  glBindBufferARB(GL_ARRAY_BUFFER_ARB, m_nNormals);
  DebugAssertNoGLError();
  glBufferDataARB(
      GL_ARRAY_BUFFER_ARB, GetTotalVertices() * sizeof(RageVector3),
      &m_vNormal[0], GL_STATIC_DRAW_ARB);
  DebugAssertNoGLError();

  glBindBufferARB(GL_ELEMENT_ARRAY_BUFFER_ARB, m_nTriangles);
  DebugAssertNoGLError();
  glBufferDataARB(
      GL_ELEMENT_ARRAY_BUFFER_ARB, GetTotalTriangles() * sizeof(msTriangle),
      &m_vTriangles[0], GL_STATIC_DRAW_ARB);
  DebugAssertNoGLError();

  if (m_bAnyNeedsTextureMatrixScale) {
    glBindBufferARB(GL_ARRAY_BUFFER_ARB, m_nTextureMatrixScale);
    DebugAssertNoGLError();
    glBufferDataARB(
        GL_ARRAY_BUFFER_ARB, GetTotalVertices() * sizeof(RageVector2),
        &m_vTexMatrixScale[0], GL_STATIC_DRAW_ARB);
    DebugAssertNoGLError();
  }
}

void RageCompiledGeometryHWOGL::Invalidate() {
  /* Our vertex buffers no longer exist.  Reallocate and reupload. */
  m_nPositions = 0;
  m_nTextureCoords = 0;
  m_nNormals = 0;
  m_nTriangles = 0;
  m_nTextureMatrixScale = 0;
  AllocateBuffers();
  UploadData();
}

void RageCompiledGeometryHWOGL::Allocate(const std::vector<msMesh>& vMeshes) {
  DebugFlushGLErrors();

  RageCompiledGeometrySWOGL::Allocate(vMeshes);
  glBindBufferARB(GL_ARRAY_BUFFER_ARB, m_nPositions);
  DebugAssertNoGLError();
  glBufferDataARB(
      GL_ARRAY_BUFFER_ARB, GetTotalVertices() * sizeof(RageVector3), nullptr,
      GL_STATIC_DRAW_ARB);
  DebugAssertNoGLError();

  glBindBufferARB(GL_ARRAY_BUFFER_ARB, m_nTextureCoords);
  DebugAssertNoGLError();
  glBufferDataARB(
      GL_ARRAY_BUFFER_ARB, GetTotalVertices() * sizeof(RageVector2), nullptr,
      GL_STATIC_DRAW_ARB);
  DebugAssertNoGLError();

  glBindBufferARB(GL_ARRAY_BUFFER_ARB, m_nNormals);
  DebugAssertNoGLError();
  glBufferDataARB(
      GL_ARRAY_BUFFER_ARB, GetTotalVertices() * sizeof(RageVector3), nullptr,
      GL_STATIC_DRAW_ARB);
  DebugAssertNoGLError();

  glBindBufferARB(GL_ELEMENT_ARRAY_BUFFER_ARB, m_nTriangles);
  DebugAssertNoGLError();
  glBufferDataARB(
      GL_ELEMENT_ARRAY_BUFFER_ARB, GetTotalTriangles() * sizeof(msTriangle),
      nullptr, GL_STATIC_DRAW_ARB);
  DebugAssertNoGLError();

  glBindBufferARB(GL_ARRAY_BUFFER_ARB, m_nTextureMatrixScale);
  DebugAssertNoGLError();
  glBufferDataARB(
      GL_ARRAY_BUFFER_ARB, GetTotalVertices() * sizeof(RageVector2), nullptr,
      GL_STATIC_DRAW_ARB);
}

void RageCompiledGeometryHWOGL::Change(const std::vector<msMesh>& vMeshes) {
  RageCompiledGeometrySWOGL::Change(vMeshes);

  UploadData();
}

void RageCompiledGeometryHWOGL::Draw(int iMeshIndex) const {
  DebugFlushGLErrors();

  const MeshInfo& meshInfo = m_vMeshInfo[iMeshIndex];
  if (!meshInfo.iVertexCount || !meshInfo.iTriangleCount) {
    return;
  }

  glEnableClientState(GL_VERTEX_ARRAY);
  DebugAssertNoGLError();
  glBindBufferARB(GL_ARRAY_BUFFER_ARB, m_nPositions);
  DebugAssertNoGLError();
  glVertexPointer(3, GL_FLOAT, 0, nullptr);
  DebugAssertNoGLError();

  glDisableClientState(GL_COLOR_ARRAY);
  DebugAssertNoGLError();

  glEnableClientState(GL_TEXTURE_COORD_ARRAY);
  DebugAssertNoGLError();
  glBindBufferARB(GL_ARRAY_BUFFER_ARB, m_nTextureCoords);
  DebugAssertNoGLError();
  glTexCoordPointer(2, GL_FLOAT, 0, nullptr);
  DebugAssertNoGLError();

  // TRICKY:  Don't bind and send normals if lighting is disabled.  This
  // will save some effort transforming these values.
  // XXX: We should keep track of these ourself and avoid glGet*()
  GLboolean bLighting;
  glGetBooleanv(GL_LIGHTING, &bLighting);
  GLboolean bTextureGenS;
  glGetBooleanv(GL_TEXTURE_GEN_S, &bTextureGenS);
  GLboolean bTextureGenT;
  glGetBooleanv(GL_TEXTURE_GEN_T, &bTextureGenT);

  if (bLighting || bTextureGenS || bTextureGenT) {
    glEnableClientState(GL_NORMAL_ARRAY);
    DebugAssertNoGLError();
    glBindBufferARB(GL_ARRAY_BUFFER_ARB, m_nNormals);
    DebugAssertNoGLError();
    glNormalPointer(GL_FLOAT, 0, nullptr);
    DebugAssertNoGLError();
  } else {
    glDisableClientState(GL_NORMAL_ARRAY);
    DebugAssertNoGLError();
  }

  if (meshInfo.m_bNeedsTextureMatrixScale) {
    if (g_bTextureMatrixShader != 0) {
      /* If we're using texture matrix scales, set up that buffer, too, and
       * enable the vertex shader.  This shader doesn't support all OpenGL
       * state, so only enable it if we're using it. */
      glEnableVertexAttribArrayARB(g_iAttribTextureMatrixScale);
      DebugAssertNoGLError();
      glBindBufferARB(GL_ARRAY_BUFFER_ARB, m_nTextureMatrixScale);
      DebugAssertNoGLError();
      glVertexAttribPointerARB(
          g_iAttribTextureMatrixScale, 2, GL_FLOAT, false, 0, nullptr);
      DebugAssertNoGLError();

      glUseProgramObjectARB(g_bTextureMatrixShader);
      DebugAssertNoGLError();
    } else {
      // Kill the texture translation.
      // XXX: Change me to scale the translation by the TextureTranslationScale
      // of the first vertex.
      RageMatrix mat;
      glGetFloatv(GL_TEXTURE_MATRIX, (float*)mat);

      /*
      for( int i=0; i<4; i++ )
      {
              std::string s;
              for( int j=0; j<4; j++ )
                      s += ssprintf( "%f ", mat.m[i][j] );
              LOG->Trace( s );
      }
      */

      mat.m[3][0] = 0;
      mat.m[3][1] = 0;
      mat.m[3][2] = 0;

      glMatrixMode(GL_TEXTURE);
      glLoadMatrixf((const float*)mat);
      DebugAssertNoGLError();
    }
  }

  glBindBufferARB(GL_ELEMENT_ARRAY_BUFFER_ARB, m_nTriangles);
  DebugAssertNoGLError();

#define BUFFER_OFFSET(o) ((char*)(o))

  ASSERT(glDrawRangeElements != nullptr);
  glDrawRangeElements(
      GL_TRIANGLES,
      meshInfo.iVertexStart,  // minimum array index contained in indices
      meshInfo.iVertexStart + meshInfo.iVertexCount - 1,
      // maximum array index contained in indices
      meshInfo.iTriangleCount * 3,  // number of elements to be rendered
      GL_UNSIGNED_SHORT,
      BUFFER_OFFSET(meshInfo.iTriangleStart * sizeof(msTriangle)));
  DebugAssertNoGLError();

  if (meshInfo.m_bNeedsTextureMatrixScale && g_bTextureMatrixShader != 0) {
    glDisableVertexAttribArrayARB(g_iAttribTextureMatrixScale);
    glUseProgramObjectARB(0);
  }
}

RageCompiledGeometry* RageDisplay_Legacy::CreateCompiledGeometry() {
  if (GLEW_ARB_vertex_buffer_object) {
    return new RageCompiledGeometryHWOGL;
  } else {
    return new RageCompiledGeometrySWOGL;
  }
}

void RageDisplay_Legacy::DeleteCompiledGeometry(RageCompiledGeometry* p) {
  delete p;
}

void RageDisplay_Legacy::DrawQuadsInternal(
    const RageSpriteVertex v[], int iNumVerts) {
  TurnOffHardwareVBO();
  SendCurrentMatrices();

  SetupVertices(v, iNumVerts);
  glDrawArrays(GL_QUADS, 0, iNumVerts);
}

void RageDisplay_Legacy::DrawQuadStripInternal(
    const RageSpriteVertex v[], int iNumVerts) {
  TurnOffHardwareVBO();
  SendCurrentMatrices();

  SetupVertices(v, iNumVerts);
  glDrawArrays(GL_QUAD_STRIP, 0, iNumVerts);
}

void RageDisplay_Legacy::DrawSymmetricQuadStripInternal(
    const RageSpriteVertex v[], int iNumVerts) {
  int iNumPieces = (iNumVerts - 3) / 3;
  int iNumTriangles = iNumPieces * 4;
  int iNumIndices = iNumTriangles * 3;

  // make a temporary index buffer
  static std::vector<uint16_t> vIndices;
  unsigned uOldSize = vIndices.size();
  unsigned uNewSize = std::max(uOldSize, (unsigned)iNumIndices);
  vIndices.resize(uNewSize);
  for (uint16_t i = (uint16_t)uOldSize / 12; i < (uint16_t)iNumPieces; i++) {
    // { 1, 3, 0 } { 1, 4, 3 } { 1, 5, 4 } { 1, 2, 5 }
    vIndices[i * 12 + 0] = i * 3 + 1;
    vIndices[i * 12 + 1] = i * 3 + 3;
    vIndices[i * 12 + 2] = i * 3 + 0;
    vIndices[i * 12 + 3] = i * 3 + 1;
    vIndices[i * 12 + 4] = i * 3 + 4;
    vIndices[i * 12 + 5] = i * 3 + 3;
    vIndices[i * 12 + 6] = i * 3 + 1;
    vIndices[i * 12 + 7] = i * 3 + 5;
    vIndices[i * 12 + 8] = i * 3 + 4;
    vIndices[i * 12 + 9] = i * 3 + 1;
    vIndices[i * 12 + 10] = i * 3 + 2;
    vIndices[i * 12 + 11] = i * 3 + 5;
  }

  TurnOffHardwareVBO();
  SendCurrentMatrices();

  SetupVertices(v, iNumVerts);
  glDrawElements(GL_TRIANGLES, iNumIndices, GL_UNSIGNED_SHORT, &vIndices[0]);
}

void RageDisplay_Legacy::DrawFanInternal(
    const RageSpriteVertex v[], int iNumVerts) {
  TurnOffHardwareVBO();
  SendCurrentMatrices();

  SetupVertices(v, iNumVerts);
  glDrawArrays(GL_TRIANGLE_FAN, 0, iNumVerts);
}

void RageDisplay_Legacy::DrawStripInternal(
    const RageSpriteVertex v[], int iNumVerts) {
  TurnOffHardwareVBO();
  SendCurrentMatrices();

  SetupVertices(v, iNumVerts);
  glDrawArrays(GL_TRIANGLE_STRIP, 0, iNumVerts);
}

void RageDisplay_Legacy::DrawTrianglesInternal(
    const RageSpriteVertex v[], int iNumVerts) {
  TurnOffHardwareVBO();
  SendCurrentMatrices();

  SetupVertices(v, iNumVerts);
  glDrawArrays(GL_TRIANGLES, 0, iNumVerts);
}

void RageDisplay_Legacy::DrawCompiledGeometryInternal(
    const RageCompiledGeometry* p, int iMeshIndex) {
  TurnOffHardwareVBO();
  SendCurrentMatrices();

  p->Draw(iMeshIndex);
}

void RageDisplay_Legacy::DrawLineStripInternal(
    const RageSpriteVertex v[], int iNumVerts, float fLineWidth) {
  TurnOffHardwareVBO();

  if (!GetActualVideoModeParams().bSmoothLines) {
    /* Fall back on the generic polygon-based line strip. */
    RageDisplay::DrawLineStripInternal(v, iNumVerts, fLineWidth);
    return;
  }

  SendCurrentMatrices();

  /* Draw a nice AA'd line loop.  One problem with this is that point and line
   * sizes don't always precisely match, which doesn't look quite right.
   * It's worth it for the AA, though. */
  glEnable(GL_LINE_SMOOTH);

  /* fLineWidth is in units relative to object space, but OpenGL line and point
   * sizes are in raster units (actual pixels).  Scale the line width by the
   * average ratio; if object space is 640x480, and we have a 1280x960 window,
   * we'll double the width. */
  {
    const RageMatrix* pMat = GetProjectionTop();
    float fW = 2 / pMat->m[0][0];
    float fH = -2 / pMat->m[1][1];
    float fWidthVal = float(g_pWind->GetActualVideoModeParams().width) / fW;
    float fHeightVal = float(g_pWind->GetActualVideoModeParams().height) / fH;
    fLineWidth *= (fWidthVal + fHeightVal) / 2;
  }

  /* Clamp the width to the hardware max for both lines and points (whichever
   * is more restrictive). */
  fLineWidth = std::clamp(fLineWidth, g_line_range[0], g_line_range[1]);
  fLineWidth = std::clamp(fLineWidth, g_point_range[0], g_point_range[1]);

  /* Hmm.  The granularity of lines and points might be different; for example,
   * if lines are .5 and points are .25, we might want to snap the width to the
   * nearest .5, so the hardware doesn't snap them to different sizes.  Does it
   * matter? */
  glLineWidth(fLineWidth);

  /* Draw the line loop: */
  SetupVertices(v, iNumVerts);
  glDrawArrays(GL_LINE_STRIP, 0, iNumVerts);
  StatsAddVerts(iNumVerts);

  glDisable(GL_LINE_SMOOTH);

  /* Round off the corners.  This isn't perfect; the point is sometimes a little
   * larger than the line, causing a small bump on the edge.  Not sure how to
   * fix that. */
  glPointSize(fLineWidth);

  /* Hack: if the points will all be the same, we don't want to draw
   * any points at all, since there's nothing to connect.  That'll happen
   * if both scale factors in the matrix are ~0.  (Actually, I think
   * it's true if two of the three scale factors are ~0, but we don't
   * use this for anything 3d at the moment anyway ...)  This is needed
   * because points aren't scaled like regular polys--a zero-size point
   * will still be drawn. */
  RageMatrix mat;
  glGetFloatv(GL_MODELVIEW_MATRIX, (float*)mat);

  if (mat.m[0][0] < 1e-5 && mat.m[1][1] < 1e-5) {
    return;
  }

  glEnable(GL_POINT_SMOOTH);

  SetupVertices(v, iNumVerts);
  glDrawArrays(GL_POINTS, 0, iNumVerts);
  StatsAddVerts(iNumVerts);

  glDisable(GL_POINT_SMOOTH);
}

static bool SetTextureUnit(TextureUnit tu) {
  // If multitexture isn't supported, ignore all textures except for 0.
  if (!GLEW_ARB_multitexture && tu != TextureUnit_1) {
    return false;
  }

  if ((int)tu > g_iMaxTextureUnits) {
    return false;
  }
  glActiveTextureARB(enum_add2(GL_TEXTURE0_ARB, tu));
  return true;
}

void RageDisplay_Legacy::ClearAllTextures() {
  FOREACH_ENUM(TextureUnit, i)
  SetTexture(i, 0);

  // HACK:  Reset the active texture to 0.
  // TODO:  Change all texture functions to take a stage number.
  if (GLEW_ARB_multitexture) {
    glActiveTextureARB(GL_TEXTURE0_ARB);
  }
}

int RageDisplay_Legacy::GetNumTextureUnits() {
  if (GLEW_ARB_multitexture) {
    return 1;
  } else {
    return g_iMaxTextureUnits;
  }
}

void RageDisplay_Legacy::SetTexture(TextureUnit tu, uintptr_t iTexture) {
  if (!SetTextureUnit(tu)) {
    return;
  }

  if (iTexture) {
    glEnable(GL_TEXTURE_2D);
    glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(iTexture));
  } else {
    glDisable(GL_TEXTURE_2D);
  }
}

void RageDisplay_Legacy::SetTextureMode(TextureUnit tu, TextureMode tm) {
  if (!SetTextureUnit(tu)) {
    return;
  }

  switch (tm) {
    case TextureMode_Modulate:
      glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
      break;
    case TextureMode_Add:
      glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_ADD);
      break;
    case TextureMode_Glow:
      // the below function is glowmode,brighten:
      if (!GLEW_ARB_texture_env_combine && !GLEW_EXT_texture_env_combine) {
        /* This is changing blend state, instead of texture state, which
         * isn't great, but it's better than doing nothing. */
        glBlendFunc(GL_SRC_ALPHA, GL_ONE);
        return;
      }

      // and this is glowmode,whiten:
      // Source color is the diffuse color only:
      glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_COMBINE_EXT);
      glTexEnvi(GL_TEXTURE_ENV, GLenum(GL_COMBINE_RGB_EXT), GL_REPLACE);
      glTexEnvi(
          GL_TEXTURE_ENV, GLenum(GL_SOURCE0_RGB_EXT), GL_PRIMARY_COLOR_EXT);

      // Source alpha is texture alpha * diffuse alpha:
      glTexEnvi(GL_TEXTURE_ENV, GLenum(GL_COMBINE_ALPHA_EXT), GL_MODULATE);
      glTexEnvi(GL_TEXTURE_ENV, GLenum(GL_OPERAND0_ALPHA_EXT), GL_SRC_ALPHA);
      glTexEnvi(
          GL_TEXTURE_ENV, GLenum(GL_SOURCE0_ALPHA_EXT), GL_PRIMARY_COLOR_EXT);
      glTexEnvi(GL_TEXTURE_ENV, GLenum(GL_OPERAND1_ALPHA_EXT), GL_SRC_ALPHA);
      glTexEnvi(GL_TEXTURE_ENV, GLenum(GL_SOURCE1_ALPHA_EXT), GL_TEXTURE);
      break;
    default:
      break;
  }
}

void RageDisplay_Legacy::SetTextureFiltering(TextureUnit tu, bool b) {
  glTexParameteri(
      GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, b ? GL_LINEAR : GL_NEAREST);

  GLint iMinFilter;
  if (b) {
    GLint iWidth1 = -1;
    GLint iWidth2 = -1;
    glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, &iWidth1);
    glGetTexLevelParameteriv(GL_TEXTURE_2D, 1, GL_TEXTURE_WIDTH, &iWidth2);
    if (iWidth1 > 1 && iWidth2 != 0) {
      /* Mipmaps are enabled. */
      if (g_pWind->GetActualVideoModeParams().bTrilinearFiltering) {
        iMinFilter = GL_LINEAR_MIPMAP_LINEAR;
      } else {
        iMinFilter = GL_LINEAR_MIPMAP_NEAREST;
      }
    } else {
      iMinFilter = GL_LINEAR;
    }
  } else {
    iMinFilter = GL_NEAREST;
  }

  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, iMinFilter);
}

void RageDisplay_Legacy::SetEffectMode(EffectMode effect) {
  if (!GLEW_ARB_fragment_program || !GLEW_ARB_shading_language_100 ||
      !GLEW_ARB_shader_objects) {
    return;
  }

  GLhandleARB hShader = 0;
  switch (effect) {
    case EffectMode_Normal:
      hShader = 0;
      break;
    case EffectMode_Unpremultiply:
      hShader = g_bUnpremultiplyShader;
      break;
    case EffectMode_ColorBurn:
      hShader = g_bColorBurnShader;
      break;
    case EffectMode_ColorDodge:
      hShader = g_bColorDodgeShader;
      break;
    case EffectMode_VividLight:
      hShader = g_bVividLightShader;
      break;
    case EffectMode_HardMix:
      hShader = g_hHardMixShader;
      break;
    case EffectMode_Overlay:
      hShader = g_hOverlayShader;
      break;
    case EffectMode_Screen:
      hShader = g_hScreenShader;
      break;
    case EffectMode_YUYV422:
      hShader = g_hYUYV422Shader;
      break;
    case EffectMode_DistanceField:
      hShader = g_gDistanceFieldShader;
    default:
      break;
  }

  DebugFlushGLErrors();
  glUseProgramObjectARB(hShader);
  if (hShader == 0) {
    return;
  }
  GLint iTexture1 = glGetUniformLocationARB(hShader, "Texture1");
  GLint iTexture2 = glGetUniformLocationARB(hShader, "Texture2");
  glUniform1iARB(iTexture1, 0);
  glUniform1iARB(iTexture2, 1);

  if (effect == EffectMode_YUYV422) {
    GLint iTextureWidthUniform =
        glGetUniformLocationARB(hShader, "TextureWidth");
    GLint iWidth;
    glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, &iWidth);
    glUniform1iARB(iTextureWidthUniform, iWidth);
  }

  DebugAssertNoGLError();
}

bool RageDisplay_Legacy::IsEffectModeSupported(EffectMode effect) {
  switch (effect) {
    case EffectMode_Normal:
      return true;
    case EffectMode_Unpremultiply:
      return g_bUnpremultiplyShader != 0;
    case EffectMode_ColorBurn:
      return g_bColorBurnShader != 0;
    case EffectMode_ColorDodge:
      return g_bColorDodgeShader != 0;
    case EffectMode_VividLight:
      return g_bVividLightShader != 0;
    case EffectMode_HardMix:
      return g_hHardMixShader != 0;
    case EffectMode_Overlay:
      return g_hOverlayShader != 0;
    case EffectMode_Screen:
      return g_hScreenShader != 0;
    case EffectMode_YUYV422:
      return g_hYUYV422Shader != 0;
    case EffectMode_DistanceField:
      return g_gDistanceFieldShader != 0;
    default:
      return false;
  }
}

void RageDisplay_Legacy::SetBlendMode(BlendMode mode) {
  glEnable(GL_BLEND);

  if (glBlendEquation != nullptr) {
    if (mode == BLEND_INVERT_DEST) {
      glBlendEquation(GL_FUNC_SUBTRACT);
    } else if (mode == BLEND_SUBTRACT) {
      glBlendEquation(GL_FUNC_REVERSE_SUBTRACT);
    } else {
      glBlendEquation(GL_FUNC_ADD);
    }
  }

  int iSourceRGB, iDestRGB;
  int iSourceAlpha = GL_ONE, iDestAlpha = GL_ONE_MINUS_SRC_ALPHA;
  switch (mode) {
    case BLEND_NORMAL:
      iSourceRGB = GL_SRC_ALPHA;
      iDestRGB = GL_ONE_MINUS_SRC_ALPHA;
      break;
    case BLEND_ADD:
      iSourceRGB = GL_SRC_ALPHA;
      iDestRGB = GL_ONE;
      break;
    case BLEND_SUBTRACT:
      iSourceRGB = GL_SRC_ALPHA;
      iDestRGB = GL_ONE_MINUS_SRC_ALPHA;
      break;
    case BLEND_MODULATE:
      iSourceRGB = GL_ZERO;
      iDestRGB = GL_SRC_COLOR;
      break;
    case BLEND_COPY_SRC:
      iSourceRGB = GL_ONE;
      iDestRGB = GL_ZERO;
      iSourceAlpha = GL_ONE;
      iDestAlpha = GL_ZERO;
      break;
    case BLEND_ALPHA_MASK:
      iSourceRGB = GL_ZERO;
      iDestRGB = GL_ONE;
      iSourceAlpha = GL_ZERO;
      iDestAlpha = GL_SRC_ALPHA;
      break;
    case BLEND_ALPHA_KNOCK_OUT:
      iSourceRGB = GL_ZERO;
      iDestRGB = GL_ONE;
      iSourceAlpha = GL_ZERO;
      iDestAlpha = GL_ONE_MINUS_SRC_ALPHA;
      break;
    case BLEND_ALPHA_MULTIPLY:
      iSourceRGB = GL_SRC_ALPHA;
      iDestRGB = GL_ZERO;
      break;
    case BLEND_WEIGHTED_MULTIPLY:
      /* output = 2*(dst*src).  0.5,0.5,0.5 is identity; darker colors darken
       * the image, and brighter colors lighten the image. */
      iSourceRGB = GL_DST_COLOR;
      iDestRGB = GL_SRC_COLOR;
      break;
    case BLEND_INVERT_DEST:
      /* out = src - dst.  The source color should almost always be #FFFFFF, to
       * make it "1 - dst". */
      iSourceRGB = GL_ONE;
      iDestRGB = GL_ONE;
      break;
    case BLEND_NO_EFFECT:
      iSourceRGB = GL_ZERO;
      iDestRGB = GL_ONE;
      iSourceAlpha = GL_ZERO;
      iDestAlpha = GL_ONE;
      break;
      DEFAULT_FAIL(mode);
  }

  if (GLEW_EXT_blend_equation_separate) {
    glBlendFuncSeparateEXT(iSourceRGB, iDestRGB, iSourceAlpha, iDestAlpha);
  } else {
    glBlendFunc(iSourceRGB, iDestRGB);
  }
}

bool RageDisplay_Legacy::IsZWriteEnabled() const {
  bool a;
  glGetBooleanv(GL_DEPTH_WRITEMASK, (unsigned char*)&a);
  return a;
}

bool RageDisplay_Legacy::IsZTestEnabled() const {
  GLenum a;
  glGetIntegerv(GL_DEPTH_FUNC, (GLint*)&a);
  return a != GL_ALWAYS;
}

void RageDisplay_Legacy::ClearZBuffer() {
  bool write = IsZWriteEnabled();
  SetZWrite(true);
  glClear(GL_DEPTH_BUFFER_BIT);
  SetZWrite(write);
}

void RageDisplay_Legacy::SetZWrite(bool b) { glDepthMask(b); }

void RageDisplay_Legacy::SetZBias(float f) {
  float fNear = SCALE(f, 0.0f, 1.0f, 0.05f, 0.0f);
  float fFar = SCALE(f, 0.0f, 1.0f, 1.0f, 0.95f);

  glDepthRange(fNear, fFar);
}

void RageDisplay_Legacy::SetZTestMode(ZTestMode mode) {
  glEnable(GL_DEPTH_TEST);
  switch (mode) {
    case ZTEST_OFF:
      glDepthFunc(GL_ALWAYS);
      break;
    case ZTEST_WRITE_ON_PASS:
      glDepthFunc(GL_LEQUAL);
      break;
    case ZTEST_WRITE_ON_FAIL:
      glDepthFunc(GL_GREATER);
      break;
    default:
      FAIL_M(ssprintf("Invalid ZTestMode: %i", mode));
  }
}

void RageDisplay_Legacy::SetTextureWrapping(TextureUnit tu, bool b) {
  /* This should be per-texture-unit state, but it's per-texture state in
   * OpenGl, so we'll behave incorrectly if the same texture is used in more
   * than one texture unit simultaneously with different wrapping. */
  SetTextureUnit(tu);

  GLenum mode = b ? GL_REPEAT : GL_CLAMP_TO_EDGE;
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, mode);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, mode);
}

void RageDisplay_Legacy::SetMaterial(
    const RageColor& emissive, const RageColor& ambient,
    const RageColor& diffuse, const RageColor& specular, float shininess) {
  // TRICKY:  If lighting is off, then setting the material
  // will have no effect.  Even if lighting is off, we still
  // want Models to have basic color and transparency.
  // We can do this fake lighting by setting the vertex color.
  // XXX: unintended: SetLighting must be called before SetMaterial
  GLboolean bLighting;
  glGetBooleanv(GL_LIGHTING, &bLighting);

  if (bLighting) {
    glMaterialfv(GL_FRONT, GL_EMISSION, emissive);
    glMaterialfv(GL_FRONT, GL_AMBIENT, ambient);
    glMaterialfv(GL_FRONT, GL_DIFFUSE, diffuse);
    glMaterialfv(GL_FRONT, GL_SPECULAR, specular);
    glMaterialf(GL_FRONT, GL_SHININESS, shininess);
  } else {
    RageColor c = diffuse;
    c.r += emissive.r + ambient.r;
    c.g += emissive.g + ambient.g;
    c.b += emissive.b + ambient.b;
    glColor4fv(c);
  }
}

void RageDisplay_Legacy::SetLighting(bool b) {
  if (b) {
    glEnable(GL_LIGHTING);
  } else {
    glDisable(GL_LIGHTING);
  }
}

void RageDisplay_Legacy::SetLightOff(int index) {
  glDisable(GL_LIGHT0 + index);
}

void RageDisplay_Legacy::SetLightDirectional(
    int index, const RageColor& ambient, const RageColor& diffuse,
    const RageColor& specular, const RageVector3& dir) {
  // Light coordinates are transformed by the modelview matrix, but
  // we are being passed in world-space coords.
  glPushMatrix();
  glLoadIdentity();

  glEnable(GL_LIGHT0 + index);
  glLightfv(GL_LIGHT0 + index, GL_AMBIENT, ambient);
  glLightfv(GL_LIGHT0 + index, GL_DIFFUSE, diffuse);
  glLightfv(GL_LIGHT0 + index, GL_SPECULAR, specular);
  float position[4] = {dir.x, dir.y, dir.z, 0};
  glLightfv(GL_LIGHT0 + index, GL_POSITION, position);

  glPopMatrix();
}

void RageDisplay_Legacy::SetCullMode(CullMode mode) {
  if (mode != CULL_NONE) {
    glEnable(GL_CULL_FACE);
  }
  switch (mode) {
    case CULL_BACK:
      glCullFace(GL_BACK);
      break;
    case CULL_FRONT:
      glCullFace(GL_FRONT);
      break;
    case CULL_NONE:
      glDisable(GL_CULL_FACE);
      break;
    default:
      FAIL_M(ssprintf("Invalid CullMode: %i", mode));
  }
}

const RageDisplay::RagePixelFormatDesc* RageDisplay_Legacy::GetPixelFormatDesc(
    RagePixelFormat pf) const {
  ASSERT(pf < NUM_RagePixelFormat);
  return &PIXEL_FORMAT_DESC[pf];
}

bool RageDisplay_Legacy::SupportsThreadedRendering() {
  return g_pWind->SupportsThreadedRendering();
}

void RageDisplay_Legacy::BeginConcurrentRenderingMainThread() {
  g_pWind->BeginConcurrentRenderingMainThread();
}

void RageDisplay_Legacy::EndConcurrentRenderingMainThread() {
  g_pWind->EndConcurrentRenderingMainThread();
}

void RageDisplay_Legacy::BeginConcurrentRendering() {
  g_pWind->BeginConcurrentRendering();
  RageDisplay::BeginConcurrentRendering();
}

void RageDisplay_Legacy::EndConcurrentRendering() {
  g_pWind->EndConcurrentRendering();
}

void RageDisplay_Legacy::DeleteTexture(uintptr_t iTexture) {
  if (iTexture == 0) {
    return;
  }

  if (g_mapRenderTargets.find(iTexture) != g_mapRenderTargets.end()) {
    delete g_mapRenderTargets[iTexture];
    g_mapRenderTargets.erase(iTexture);
    return;
  }

  DebugFlushGLErrors();
  glDeleteTextures(1, reinterpret_cast<GLuint*>(&iTexture));
  DebugAssertNoGLError();
}

RagePixelFormat RageDisplay_Legacy::GetImgPixelFormat(
    RageSurface*& img, bool& bFreeImg, int width, int height,
    bool bPalettedTexture) {
  RagePixelFormat pixfmt = FindPixelFormat(
      img->format->BitsPerPixel, img->format->Rmask, img->format->Gmask,
      img->format->Bmask, img->format->Amask);

  /* If img is paletted, we're setting up a non-paletted texture, and color
   * indexes are too small, depalettize. */
  bool bSupported = true;
  if (!bPalettedTexture && img->fmt.BytesPerPixel == 1 &&
      !g_bColorIndexTableWorks) {
    bSupported = false;
  }

  if (pixfmt == RagePixelFormat_Invalid || !SupportsSurfaceFormat(pixfmt)) {
    bSupported = false;
  }

  if (!bSupported) {
    /* The source isn't in a supported, known pixel format.  We need to convert
     * it ourself.  Just convert it to RGBA8, and let OpenGL convert it back
     * down to whatever the actual pixel format is.  This is a very slow code
     * path, which should almost never be used. */
    pixfmt = RagePixelFormat_RGBA8;
    ASSERT(SupportsSurfaceFormat(pixfmt));

    const RagePixelFormatDesc* pfd = DISPLAY->GetPixelFormatDesc(pixfmt);

    RageSurface* imgconv = CreateSurface(
        img->w, img->h, pfd->bpp, pfd->masks[0], pfd->masks[1], pfd->masks[2],
        pfd->masks[3]);
    RageSurfaceUtils::Blit(img, imgconv, width, height);
    img = imgconv;
    bFreeImg = true;
  } else {
    bFreeImg = false;
  }

  return pixfmt;
}

/* If we're sending a paletted surface to a non-paletted texture, set the
 * palette. */
void SetPixelMapForSurface(
    int glImageFormat, int glTexFormat, const RageSurfacePalette* palette) {
  if (glImageFormat != GL_COLOR_INDEX || glTexFormat == GL_COLOR_INDEX8_EXT) {
    glPixelTransferi(GL_MAP_COLOR, false);
    return;
  }

  GLushort buf[4][256];
  memset(buf, 0, sizeof(buf));

  for (int i = 0; i < palette->ncolors; ++i) {
    buf[0][i] = SCALE(palette->colors[i].r, 0, 255, 0, 65535);
    buf[1][i] = SCALE(palette->colors[i].g, 0, 255, 0, 65535);
    buf[2][i] = SCALE(palette->colors[i].b, 0, 255, 0, 65535);
    buf[3][i] = SCALE(palette->colors[i].a, 0, 255, 0, 65535);
  }

  DebugFlushGLErrors();
  glPixelMapusv(GL_PIXEL_MAP_I_TO_R, 256, buf[0]);
  glPixelMapusv(GL_PIXEL_MAP_I_TO_G, 256, buf[1]);
  glPixelMapusv(GL_PIXEL_MAP_I_TO_B, 256, buf[2]);
  glPixelMapusv(GL_PIXEL_MAP_I_TO_A, 256, buf[3]);
  glPixelTransferi(GL_MAP_COLOR, true);
  DebugAssertNoGLError();
}

uintptr_t RageDisplay_Legacy::CreateTexture(
    RagePixelFormat pixfmt, RageSurface* pImg, bool bGenerateMipMaps) {
  ASSERT(pixfmt < NUM_RagePixelFormat);

  /* Find the pixel format of the surface we've been given. */
  bool bFreeImg;
  RagePixelFormat SurfacePixFmt = GetImgPixelFormat(
      pImg, bFreeImg, pImg->w, pImg->h, pixfmt == RagePixelFormat_PAL);
  ASSERT(SurfacePixFmt != RagePixelFormat_Invalid);

  GLenum glTexFormat = g_GLPixFmtInfo[pixfmt].internalfmt;
  GLenum glImageFormat = g_GLPixFmtInfo[SurfacePixFmt].format;
  GLenum glImageType = g_GLPixFmtInfo[SurfacePixFmt].type;

  /* If the image is paletted, but we're not sending it to a paletted image,
   * set up glPixelMap. */
  SetPixelMapForSurface(
      glImageFormat, glTexFormat, pImg->format->palette.get());

  // HACK:  OpenGL 1.2 types aren't available in GLU 1.3.  Don't call GLU for
  // mip mapping if we're using an OGL 1.2 type and don't have >= GLU 1.3.
  // http://pyopengl.sourceforge.net/documentation/manual/gluBuild2DMipmaps.3G.html
  if (bGenerateMipMaps && g_gluVersion < 13) {
    switch (pixfmt) {
      // OpenGL 1.1 types
      case RagePixelFormat_RGBA8:
      case RagePixelFormat_RGB8:
      case RagePixelFormat_PAL:
      case RagePixelFormat_BGR8:
        break;
      // OpenGL 1.2 types
      default:
        LOG->Trace(
            "Can't generate mipmaps for type %s because GLU version %.1f is "
            "too old.",
            GLToString(glImageType).c_str(), g_gluVersion / 10.f);
        bGenerateMipMaps = false;
        break;
    }
  }

  SetTextureUnit(TextureUnit_1);

  // allocate OpenGL texture resource
  uintptr_t iTexHandle;
  glGenTextures(1, reinterpret_cast<GLuint*>(&iTexHandle));
  ASSERT(iTexHandle != 0);

  glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(iTexHandle));

  if (g_pWind->GetActualVideoModeParams().bAnisotropicFiltering &&
      GLEW_EXT_texture_filter_anisotropic) {
    GLfloat fLargestSupportedAnisotropy;
    glGetFloatv(
        GL_MAX_TEXTURE_MAX_ANISOTROPY_EXT, &fLargestSupportedAnisotropy);
    glTexParameterf(
        GL_TEXTURE_2D, GL_TEXTURE_MAX_ANISOTROPY_EXT,
        fLargestSupportedAnisotropy);
  }

  SetTextureFiltering(TextureUnit_1, true);
  SetTextureWrapping(TextureUnit_1, false);

  glPixelStorei(
      GL_UNPACK_ROW_LENGTH, pImg->pitch / pImg->format->BytesPerPixel);

  if (pixfmt == RagePixelFormat_PAL) {
    /* The texture is paletted; set the texture palette. */
    GLubyte palette[256 * 4];
    memset(palette, 0, sizeof(palette));
    int p = 0;
    /* Copy the palette to the format OpenGL expects. */
    for (int i = 0; i < pImg->format->palette->ncolors; ++i) {
      palette[p++] = pImg->format->palette->colors[i].r;
      palette[p++] = pImg->format->palette->colors[i].g;
      palette[p++] = pImg->format->palette->colors[i].b;
      palette[p++] = pImg->format->palette->colors[i].a;
    }

    /* Set the palette. */
    glColorTableEXT(
        GL_TEXTURE_2D, GL_RGBA8, 256, GL_RGBA, GL_UNSIGNED_BYTE, palette);

    GLint iRealFormat = 0;
    glGetColorTableParameterivEXT(
        GL_TEXTURE_2D, GL_COLOR_TABLE_FORMAT, &iRealFormat);
    ASSERT(iRealFormat == GL_RGBA8);
  }

  if (ShouldTraceGlTextureUploads()) {
    LOG->Trace(
        "%s (format %s, %ix%i, format %s, type %s, pixfmt %i, imgpixfmt %i)",
        "glTexImage2D", GLToString(glTexFormat).c_str(), pImg->w, pImg->h,
        GLToString(glImageFormat).c_str(), GLToString(glImageType).c_str(),
        pixfmt, SurfacePixFmt);
  }

  DebugFlushGLErrors();

  glTexImage2D(
      GL_TEXTURE_2D, 0, glTexFormat, power_of_two(pImg->w),
      power_of_two(pImg->h), 0, glImageFormat, glImageType, nullptr);
  if (pImg->pixels) {
    glTexSubImage2D(
        GL_TEXTURE_2D, 0, 0, 0, pImg->w, pImg->h, glImageFormat, glImageType,
        pImg->pixels);
  }

  if (bGenerateMipMaps) {
    glGenerateMipmap(GL_TEXTURE_2D);
  }

  DebugAssertNoGLError();

  /* Sanity check: */
  if (pixfmt == RagePixelFormat_PAL) {
    GLint iSize = 0;
    glGetTexLevelParameteriv(
        GL_TEXTURE_2D, 0, GLenum(GL_TEXTURE_INDEX_SIZE_EXT), &iSize);
    if (iSize != 8) {
      RageException::Throw("Thought paletted textures worked, but they don't.");
    }
  }

  glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
  glFlush();

  if (bFreeImg) {
    delete pImg;
  }
  return iTexHandle;
}

struct RageTextureLock_OGL : public RageTextureLock, public InvalidateObject {
 public:
  RageTextureLock_OGL() {
    m_iTexHandle = 0;
    m_iBuffer = 0;

    CreateObject();
  }

  ~RageTextureLock_OGL() {
    ASSERT(m_iTexHandle == 0);  // locked!
    glDeleteBuffersARB(1, &m_iBuffer);
  }

  /* This is called when our OpenGL context is invalidated. */
  void Invalidate() { m_iTexHandle = 0; }

  bool Lock(uintptr_t iTexHandle, RageSurface* pSurface) {
    ASSERT(m_iTexHandle == 0);
    ASSERT(pSurface->pixels == nullptr);

    CreateObject();

    m_iTexHandle = iTexHandle;
    glBindBufferARB(GL_PIXEL_UNPACK_BUFFER_ARB, m_iBuffer);

    int iSize = pSurface->h * pSurface->pitch;
    glBufferDataARB(GL_PIXEL_UNPACK_BUFFER_ARB, iSize, nullptr, GL_STREAM_DRAW);

    void* pSurfaceMemory =
        glMapBufferARB(GL_PIXEL_UNPACK_BUFFER_ARB, GL_WRITE_ONLY);
    if (pSurfaceMemory == nullptr) {
      m_iTexHandle = 0;
      glBindBufferARB(GL_PIXEL_UNPACK_BUFFER_ARB, 0);
      return false;
    }
    pSurface->pixels = (uint8_t*)pSurfaceMemory;
    pSurface->pixels_owned = false;
    return true;
  }

  void Unlock(RageSurface* pSurface, bool bChanged) {
    glUnmapBufferARB(GL_PIXEL_UNPACK_BUFFER_ARB);

    pSurface->pixels = (uint8_t*)BUFFER_OFFSET(0);

    if (bChanged) {
      DISPLAY->UpdateTexture(
          m_iTexHandle, pSurface, 0, 0, pSurface->w, pSurface->h);
    }

    pSurface->pixels = nullptr;

    m_iTexHandle = 0;
    glBindBufferARB(GL_PIXEL_UNPACK_BUFFER_ARB, 0);
  }

 private:
  void CreateObject() {
    if (m_iBuffer != 0) {
      return;
    }

    DebugFlushGLErrors();
    glGenBuffersARB(1, &m_iBuffer);
    DebugAssertNoGLError();
  }

  GLuint m_iBuffer;

  uintptr_t m_iTexHandle;
};

RageTextureLock* RageDisplay_Legacy::CreateTextureLock() {
  if (!GLEW_ARB_pixel_buffer_object) {
    return nullptr;
  }

  return new RageTextureLock_OGL;
}

void RageDisplay_Legacy::UpdateTexture(
    uintptr_t iTexHandle, RageSurface* pImg, int iXOffset, int iYOffset,
    int iWidth, int iHeight) {
  glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(iTexHandle));

  bool bFreeImg;
  RagePixelFormat SurfacePixFmt =
      GetImgPixelFormat(pImg, bFreeImg, iWidth, iHeight, false);

  glPixelStorei(
      GL_UNPACK_ROW_LENGTH, pImg->pitch / pImg->format->BytesPerPixel);

  GLenum glImageFormat = g_GLPixFmtInfo[SurfacePixFmt].format;
  GLenum glImageType = g_GLPixFmtInfo[SurfacePixFmt].type;

  /* If the image is paletted, but we're not sending it to a paletted image,
   * set up glPixelMap. */
  if (pImg->format->palette) {
    GLenum glTexFormat = 0;
    glGetTexLevelParameteriv(
        GL_PROXY_TEXTURE_2D, 0, GLenum(GL_TEXTURE_INTERNAL_FORMAT),
        (GLint*)&glTexFormat);
    SetPixelMapForSurface(
        glImageFormat, glTexFormat, pImg->format->palette.get());
  }

  glTexSubImage2D(
      GL_TEXTURE_2D, 0, iXOffset, iYOffset, iWidth, iHeight, glImageFormat,
      glImageType, pImg->pixels);

  /* Must unset PixelStore when we're done! */
  glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
  glFlush();

  if (bFreeImg) {
    delete pImg;
  }
}

class RenderTarget_FramebufferObject : public RenderTarget {
 public:
  RenderTarget_FramebufferObject();
  ~RenderTarget_FramebufferObject();
  void Create(
      const RenderTargetParam& param, int& iTextureWidthOut,
      int& iTextureHeightOut);
  uintptr_t GetTexture() const { return m_iTexHandle; }
  void StartRenderingTo();
  void FinishRenderingTo();

  virtual bool InvertY() const { return true; }

 private:
  uintptr_t m_iFrameBufferHandle;
  uintptr_t m_iTexHandle;
  uintptr_t m_iDepthBufferHandle;
};

RenderTarget_FramebufferObject::RenderTarget_FramebufferObject() {
  m_iFrameBufferHandle = 0;
  m_iTexHandle = 0;
  m_iDepthBufferHandle = 0;
}

RenderTarget_FramebufferObject::~RenderTarget_FramebufferObject() {
  if (m_iDepthBufferHandle) {
    glDeleteRenderbuffersEXT(
        1, reinterpret_cast<GLuint*>(&m_iDepthBufferHandle));
  }
  if (m_iFrameBufferHandle) {
    glDeleteFramebuffersEXT(
        1, reinterpret_cast<GLuint*>(&m_iFrameBufferHandle));
  }
  if (m_iTexHandle) {
    glDeleteTextures(1, reinterpret_cast<GLuint*>(&m_iTexHandle));
  }
}

void RenderTarget_FramebufferObject::Create(
    const RenderTargetParam& param, int& iTextureWidthOut,
    int& iTextureHeightOut) {
  m_Param = param;

  DebugFlushGLErrors();

  // Allocate OpenGL texture resource
  glGenTextures(1, reinterpret_cast<GLuint*>(&m_iTexHandle));
  ASSERT(m_iTexHandle != 0);

  int iTextureWidth = power_of_two(param.iWidth);
  int iTextureHeight = power_of_two(param.iHeight);

  iTextureWidthOut = iTextureWidth;
  iTextureHeightOut = iTextureHeight;

  glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(m_iTexHandle));
  GLenum internalformat;
  GLenum type = param.bWithAlpha ? GL_RGBA : GL_RGB;
  if (param.bFloat && GLEW_ARB_texture_float) {
    internalformat = param.bWithAlpha ? GL_RGBA16F_ARB : GL_RGB16F_ARB;
  } else {
    internalformat = param.bWithAlpha ? GL_RGBA8 : GL_RGB8;
  }

  glTexImage2D(
      GL_TEXTURE_2D, 0, internalformat, iTextureWidth, iTextureHeight, 0, type,
      GL_UNSIGNED_BYTE, nullptr);
  DebugAssertNoGLError();

  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

  /* Create the framebuffer object. */
  glGenFramebuffersEXT(1, reinterpret_cast<GLuint*>(&m_iFrameBufferHandle));
  ASSERT(m_iFrameBufferHandle != 0);

  /* Attach the texture to it. */
  glBindFramebufferEXT(
      GL_FRAMEBUFFER_EXT, static_cast<GLuint>(m_iFrameBufferHandle));
  glFramebufferTexture2DEXT(
      GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_TEXTURE_2D,
      static_cast<GLuint>(m_iTexHandle), 0);
  DebugAssertNoGLError();

  /* Attach a depth buffer, if requested. */
  if (param.bWithDepthBuffer) {
    glGenRenderbuffersEXT(1, reinterpret_cast<GLuint*>(&m_iDepthBufferHandle));
    ASSERT(m_iDepthBufferHandle != 0);

    glBindRenderbufferEXT(
        GL_RENDERBUFFER, static_cast<GLuint>(m_iDepthBufferHandle));
    glRenderbufferStorageEXT(
        GL_RENDERBUFFER_EXT, GL_DEPTH_COMPONENT16, iTextureWidth,
        iTextureHeight);
    glFramebufferRenderbufferEXT(
        GL_FRAMEBUFFER_EXT, GL_DEPTH_ATTACHMENT_EXT, GL_RENDERBUFFER_EXT,
        static_cast<GLuint>(m_iDepthBufferHandle));
  }

  GLenum status = glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT);
  switch (status) {
    case GL_FRAMEBUFFER_COMPLETE_EXT:
      break;
    case GL_FRAMEBUFFER_UNSUPPORTED_EXT:
      FAIL_M("GL_FRAMEBUFFER_UNSUPPORTED_EXT");
      break;
    case GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT_EXT:
      FAIL_M("GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT_EXT");
      break;
    case GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT_EXT:
      FAIL_M("GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT_EXT");
      break;
    case GL_FRAMEBUFFER_INCOMPLETE_DIMENSIONS_EXT:
      FAIL_M("GL_FRAMEBUFFER_INCOMPLETE_DIMENSIONS_EXT");
      break;
    case GL_FRAMEBUFFER_INCOMPLETE_FORMATS_EXT:
      FAIL_M("GL_FRAMEBUFFER_INCOMPLETE_FORMATS_EXT");
      break;
    case GL_FRAMEBUFFER_INCOMPLETE_DRAW_BUFFER_EXT:
      FAIL_M("GL_FRAMEBUFFER_INCOMPLETE_DRAW_BUFFER_EXT");
      break;
    case GL_FRAMEBUFFER_INCOMPLETE_READ_BUFFER_EXT:
      FAIL_M("GL_FRAMEBUFFER_INCOMPLETE_READ_BUFFER_EXT");
      break;
    default:
      FAIL_M(ssprintf("Unexpected GL framebuffer status: %i", status));
  }

  glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
}

void RenderTarget_FramebufferObject::StartRenderingTo() {
  glBindFramebufferEXT(
      GL_FRAMEBUFFER_EXT, static_cast<GLuint>(m_iFrameBufferHandle));
}

void RenderTarget_FramebufferObject::FinishRenderingTo() {
  glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
}

bool RageDisplay_Legacy::SupportsRenderToTexture() const {
  return GLEW_EXT_framebuffer_object || g_pWind->SupportsRenderToTexture();
}

bool RageDisplay_Legacy::SupportsFullscreenBorderlessWindow() const {
  // In order to support FSBW, we're going to need the LowLevelWindow
  // implementation to support creating a fullscreen borderless window, and
  // we're going to need RenderToTexture support in order to render in
  // alternative resolutions
  return g_pWind->SupportsFullscreenBorderlessWindow() &&
         SupportsRenderToTexture();
}

/*
 * Render-to-texture can be implemented in several ways: the generic
 * GL_ARB_pixel_buffer_object, or platform-specifically.  PBO is not available
 * on all hardware that supports RTT, particularly GeForce 2, but is simpler and
 * faster when available.
 */

uintptr_t RageDisplay_Legacy::CreateRenderTarget(
    const RenderTargetParam& param, int& iTextureWidthOut,
    int& iTextureHeightOut) {
  RenderTarget* pTarget;
  if (GLEW_EXT_framebuffer_object) {
    pTarget = new RenderTarget_FramebufferObject;
  } else {
    pTarget = g_pWind->CreateRenderTarget();
  }

  pTarget->Create(param, iTextureWidthOut, iTextureHeightOut);

  uintptr_t iTexture = pTarget->GetTexture();

  ASSERT(g_mapRenderTargets.find(iTexture) == g_mapRenderTargets.end());
  g_mapRenderTargets[iTexture] = pTarget;
  return iTexture;
}

uintptr_t RageDisplay_Legacy::GetRenderTarget() {
  for (std::map<uintptr_t, RenderTarget*>::const_iterator it =
           g_mapRenderTargets.begin();
       it != g_mapRenderTargets.end(); ++it) {
    if (it->second == g_pCurrentRenderTarget) {
      return it->first;
    }
  }
  return 0;
}

void RageDisplay_Legacy::SetRenderTarget(
    uintptr_t iTexture, bool bPreserveTexture) {
  if (iTexture == 0) {
    g_bInvertY = false;
    glFrontFace(GL_CCW);

    /* Pop matrixes affected by SetDefaultRenderStates. */
    DISPLAY->CameraPopMatrix();

    /* Reset the viewport. */
    int fWidth = g_pWind->GetActualVideoModeParams().windowWidth;
    int fHeight = g_pWind->GetActualVideoModeParams().windowHeight;
    glViewport(0, 0, fWidth, fHeight);

    if (g_pCurrentRenderTarget) {
      g_pCurrentRenderTarget->FinishRenderingTo();
    }
    g_pCurrentRenderTarget = nullptr;
    return;
  }

  /* If we already had a render target, disable it. */
  if (g_pCurrentRenderTarget != nullptr) {
    SetRenderTarget(0, true);
  }

  /* Enable the new render target. */
  ASSERT(g_mapRenderTargets.find(iTexture) != g_mapRenderTargets.end());
  RenderTarget* pTarget = g_mapRenderTargets[iTexture];
  pTarget->StartRenderingTo();
  g_pCurrentRenderTarget = pTarget;

  /* Set the viewport to the size of the render target. */
  glViewport(0, 0, pTarget->GetParam().iWidth, pTarget->GetParam().iHeight);

  /* If this render target implementation flips Y, compensate.   Inverting will
   * switch the winding order. */
  g_bInvertY = pTarget->InvertY();
  if (g_bInvertY) {
    glFrontFace(GL_CW);
  }

  /* The render target may be in a different OpenGL context, so re-send
   * state.  Push matrixes affected by SetDefaultRenderStates. */
  DISPLAY->CameraPushMatrix();
  SetDefaultRenderStates();

  /* Clear the texture, if requested.  Always set the associated state, for
   * consistency. */
  glClearColor(0, 0, 0, 0);
  SetZWrite(true);

  /* If bPreserveTexture is false, clear the render target.  Only clear the
   * depth buffer if the target has one; otherwise we're clearing the real depth
   * buffer. */
  if (!bPreserveTexture) {
    int iBit = GL_COLOR_BUFFER_BIT;
    if (pTarget->GetParam().bWithDepthBuffer) {
      iBit |= GL_DEPTH_BUFFER_BIT;
    }
    glClear(iBit);
  }
}

void RageDisplay_Legacy::SetPolygonMode(PolygonMode pm) {
  GLenum m;
  switch (pm) {
    case POLYGON_FILL:
      m = GL_FILL;
      break;
    case POLYGON_LINE:
      m = GL_LINE;
      break;
    default:
      FAIL_M(ssprintf("Invalid PolygonMode: %i", pm));
  }
  glPolygonMode(GL_FRONT_AND_BACK, m);
}

void RageDisplay_Legacy::SetLineWidth(float fWidth) { glLineWidth(fWidth); }

std::string RageDisplay_Legacy::GetTextureDiagnostics(
    uintptr_t iTexture) const {
  /*
          s << (bGenerateMipMaps? "gluBuild2DMipmaps":"glTexImage2D");
          s << "(format " << GLToString(glTexFormat) <<
                          ", " << pImg->w << "x" <<  pImg->h <<
                          ", format " << GLToString(iFormat) <<
                          ", type " << GLToString(glImageType) <<
                          ", pixfmt " << pixfmt <<
                          ", imgpixfmt " << SurfacePixFmt <<
                          ")";
          LOG->Trace( "%s", s.str().c_str() );

  glBindTexture( GL_TEXTURE_2D, iTexture );

          GLint iWidth;
          glGetTexLevelParameteriv( GL_TEXTURE_2D, 0, GLenum(GL_TEXTURE_WIDTH),
  (GLint *) &iWidth ); GLint iHeight; glGetTexLevelParameteriv( GL_TEXTURE_2D,
  0, GLenum(GL_TEXTURE_HEIGHT), (GLint *) &iHeight ); GLint iFormat;
          glGetTexLevelParameteriv( GL_TEXTURE_2D, 0,
  GLenum(GL_TEXTURE_INTERNAL_FORMAT), (GLint *) &iFormat );

          GL_CHECK_ERROR( "glGetTexLevelParameteriv(GL_TEXTURE_INTERNAL_FORMAT)"
  ); if (iFormat != glTexFormat)
          {
                  sError = ssprintf( "Expected format %s, got %s instead",
                                  GLToString(glTexFormat).c_str(),
  GLToString(iFormat).c_str() ); break;
          }
*/
  return std::string();
}

/*
 * XXX: Things like this only have to be set once per context - making
 * SetDefault call These kinds of functions is wasteful. -Colby
 */
void RageDisplay_Legacy::SetAlphaTest(bool b) {
  // Previously this was 0.01, rather than 0x01.
  glAlphaFunc(GL_GREATER, 0.00390625 /* 1/256 */);
  if (b) {
    glEnable(GL_ALPHA_TEST);
  } else {
    glDisable(GL_ALPHA_TEST);
  }
}

/*
 * Although we pair texture formats (eg. GL_RGB8) and surface formats
 * (pairs of eg. GL_RGB8,GL_UNSIGNED_SHORT_5_5_5_1), it's possible for
 * a format to be supported for a texture format but not a surface
 * format.  This is abstracted, so you don't need to know about this
 * as a user calling CreateTexture.
 *
 * One case of this is if packed pixels aren't supported.  We can still
 * use 16-bit color modes, but we have to send it in 32-bit.  Almost
 * everything supports packed pixels.
 *
 * Another case of this is incomplete packed pixels support.  Some
 * implementations neglect GL_UNSIGNED_SHORT_*_REV.
 */
bool RageDisplay_Legacy::SupportsSurfaceFormat(RagePixelFormat pixfmt) {
  switch (g_GLPixFmtInfo[pixfmt].type) {
    case GL_UNSIGNED_SHORT_1_5_5_5_REV:
      return GLEW_EXT_bgra && g_bReversePackedPixelsWorks;
    default:
      return true;
  }
}

bool RageDisplay_Legacy::SupportsTextureFormat(
    RagePixelFormat pixfmt, bool bRealtime) {
  /* If we support a pixfmt for texture formats but not for surface formats,
   * then we'll have to convert the texture to a supported surface format before
   * uploading. This is too slow for dynamic textures. */
  if (bRealtime && !SupportsSurfaceFormat(pixfmt)) {
    return false;
  }

  switch (g_GLPixFmtInfo[pixfmt].format) {
    case GL_COLOR_INDEX:
      return glColorTableEXT && glGetColorTableParameterivEXT;
    case GL_BGR:
    case GL_BGRA:
      return !!GLEW_EXT_bgra;
    default:
      return true;
  }
}

bool RageDisplay_Legacy::SupportsPerVertexMatrixScale() {
  // Intel i915 on OSX 10.4.4 supports vertex programs but not hardware vertex
  // buffers. Our software vertex rendering doesn't support vertex programs.
  return glGenBuffersARB && g_bTextureMatrixShader != 0;
}

void RageDisplay_Legacy::SetSphereEnvironmentMapping(TextureUnit tu, bool b) {
  if (!SetTextureUnit(tu)) {
    return;
  }

  if (b) {
    glTexGeni(GL_S, GL_TEXTURE_GEN_MODE, GL_SPHERE_MAP);
    glTexGeni(GL_T, GL_TEXTURE_GEN_MODE, GL_SPHERE_MAP);
    glEnable(GL_TEXTURE_GEN_S);
    glEnable(GL_TEXTURE_GEN_T);
  } else {
    glDisable(GL_TEXTURE_GEN_S);
    glDisable(GL_TEXTURE_GEN_T);
  }
}

GLint iCelTexture1, iCelTexture2 = 0;

void RageDisplay_Legacy::SetCelShaded(int stage) {
  if (!GLEW_ARB_fragment_program && !GL_ARB_shading_language_100) {
    return;  // not supported
  }

  switch (stage) {
    case 1:
      glUseProgramObjectARB(g_gShellShader);
      break;
    case 2:
      glUseProgramObjectARB(g_gCelShader);
      break;
    default:
      glUseProgramObjectARB(0);
      break;
  }
}

/*
 * Copyright (c) 2001-2011 Chris Danford, Glenn Maynard, Colby Klein
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
