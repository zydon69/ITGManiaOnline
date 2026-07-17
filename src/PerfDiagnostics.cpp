#include "PerfDiagnostics.h"

#include <atomic>
#include <cstdarg>
#include <cstdlib>
#include <string>

#include "Preference.h"
#include "RageLog.h"
#include "RageUtil.h"

static Preference<bool> g_bPerfDiagnostics("PerfDiagnostics", false);
static Preference<bool> g_bLogAudioUnderrunDiagnostics(
    "LogAudioUnderrunDiagnostics", false);
static Preference<bool> g_bLogTextureUploadDiagnostics(
    "LogTextureUploadDiagnostics", false);
static Preference<bool> g_bLogResourceSnapshotDiagnostics(
    "LogResourceSnapshotDiagnostics", false);
static Preference<bool> g_bLogBackgroundDiagnostics(
    "LogBackgroundDiagnostics", false);
static Preference<bool> g_bLogPlayOnceDiagnostics(
    "LogPlayOnceDiagnostics", false);
static Preference<bool> g_bLogNoteSkinDiagnostics(
    "LogNoteSkinDiagnostics", false);
static Preference<bool> g_bLogInputDiagnostics(
    "LogInputDiagnostics", false);
static Preference<bool> g_bLogMemoryCardDiagnostics(
    "LogMemoryCardDiagnostics", false);
static Preference<bool> g_bLogContentLoadDiagnostics(
    "LogContentLoadDiagnostics", false);
static Preference<bool> g_bLogThemeLuaDiagnostics(
    "LogThemeLuaDiagnostics", false);
static Preference<bool> g_bLogGlobalOffsetDiagnostics(
    "LogGlobalOffsetDiagnostics", false);
static Preference<bool> g_bLogWindowsEventDiagnostics(
    "LogWindowsEventDiagnostics", false);
static Preference<bool> g_bReviewSrc("review_src", true);

static std::atomic<bool> g_bPerfDiagnosticsCached{false};
static std::atomic<bool> g_bLogAudioUnderrunDiagnosticsCached{false};
static std::atomic<bool> g_bLogTextureUploadDiagnosticsCached{false};
static std::atomic<bool> g_bLogResourceSnapshotDiagnosticsCached{false};
static std::atomic<bool> g_bLogBackgroundDiagnosticsCached{false};
static std::atomic<bool> g_bLogPlayOnceDiagnosticsCached{false};
static std::atomic<bool> g_bLogNoteSkinDiagnosticsCached{false};
static std::atomic<bool> g_bLogInputDiagnosticsCached{false};
static std::atomic<bool> g_bLogMemoryCardDiagnosticsCached{false};
static std::atomic<bool> g_bLogContentLoadDiagnosticsCached{false};
static std::atomic<bool> g_bLogThemeLuaDiagnosticsCached{false};
static std::atomic<bool> g_bLogGlobalOffsetDiagnosticsCached{false};
static std::atomic<bool> g_bLogWindowsEventDiagnosticsCached{false};
static std::atomic<bool> g_bReviewSrcCached{true};

static bool EnvFlagEnabled(const char* name) {
  if (name == nullptr) {
    return false;
  }
  const char* value = std::getenv(name);
  return value != nullptr && std::string(value) == "1";
}

static const bool g_bEnvLogAudioUnderrun =
    EnvFlagEnabled("ITG_LOG_AUDIO_UNDERRUN");
static const bool g_bEnvLogTextureUpload =
    EnvFlagEnabled("ITG_LOG_TEXTURE_UPLOAD");
static const bool g_bEnvLogPlayOnce = EnvFlagEnabled("ITG_LOG_PLAY_ONCE");
static const bool g_bEnvLogNoteSkin = EnvFlagEnabled("ITG_LOG_NOTESKIN");
static const bool g_bEnvLogInput = EnvFlagEnabled("ITG_LOG_INPUT");
static const bool g_bEnvLogMemoryCard = EnvFlagEnabled("ITG_LOG_MEMORY_CARD");
static const bool g_bEnvLogContentLoad = EnvFlagEnabled("ITG_LOG_CONTENT_LOAD");
static const bool g_bEnvLogVerboseContentLoad =
    EnvFlagEnabled("ITG_LOG_VERBOSE_CONTENT_LOAD");
static const bool g_bEnvLogThemeLua = EnvFlagEnabled("ITG_LOG_THEME_LUA");
static const bool g_bEnvLogBackground = EnvFlagEnabled("ITG_LOG_BACKGROUND");
static const bool g_bEnvLogGlobalOffset =
    EnvFlagEnabled("ITG_LOG_GLOBAL_OFFSET");
static const bool g_bEnvWindowsEvents =
    EnvFlagEnabled("ITG_LOG_WINDOWS_EVENTS");
static const bool g_bEnvReviewSrc = EnvFlagEnabled("ITG_REVIEW_SRC") ||
                                    EnvFlagEnabled("ITG_LOG_REVIEW_SRC");
static const bool g_bEnvLegacyTraceGlUploads =
    EnvFlagEnabled("ITG_TRACE_GL_UPLOADS");
static const bool g_bEnvLegacyTraceResourceSnapshots =
    EnvFlagEnabled("ITG_TRACE_RESOURCE_SNAPSHOTS");
bool PerfDiagnosticsEnabled() {
  return g_bPerfDiagnosticsCached.load(std::memory_order_acquire);
}

void RefreshPerfDiagnosticsPreferenceCache() {
  g_bPerfDiagnosticsCached.store(
      g_bPerfDiagnostics.Get(), std::memory_order_release);
  g_bLogAudioUnderrunDiagnosticsCached.store(
      g_bLogAudioUnderrunDiagnostics.Get(), std::memory_order_release);
  g_bLogTextureUploadDiagnosticsCached.store(
      g_bLogTextureUploadDiagnostics.Get(), std::memory_order_release);
  g_bLogResourceSnapshotDiagnosticsCached.store(
      g_bLogResourceSnapshotDiagnostics.Get(), std::memory_order_release);
  g_bLogBackgroundDiagnosticsCached.store(
      g_bLogBackgroundDiagnostics.Get(), std::memory_order_release);
  g_bLogPlayOnceDiagnosticsCached.store(
      g_bLogPlayOnceDiagnostics.Get(), std::memory_order_release);
  g_bLogNoteSkinDiagnosticsCached.store(
      g_bLogNoteSkinDiagnostics.Get(), std::memory_order_release);
  g_bLogInputDiagnosticsCached.store(
      g_bLogInputDiagnostics.Get(), std::memory_order_release);
  g_bLogMemoryCardDiagnosticsCached.store(
      g_bLogMemoryCardDiagnostics.Get(), std::memory_order_release);
  g_bLogContentLoadDiagnosticsCached.store(
      g_bLogContentLoadDiagnostics.Get(), std::memory_order_release);
  g_bLogThemeLuaDiagnosticsCached.store(
      g_bLogThemeLuaDiagnostics.Get(), std::memory_order_release);
  g_bLogGlobalOffsetDiagnosticsCached.store(
      g_bLogGlobalOffsetDiagnostics.Get(), std::memory_order_release);
  g_bLogWindowsEventDiagnosticsCached.store(
      g_bLogWindowsEventDiagnostics.Get(), std::memory_order_release);
  g_bReviewSrcCached.store(g_bReviewSrc.Get(), std::memory_order_release);
}

/*
 * Most diagnostic categories are enabled when ANY of the following is true:
 *   1. its own "Log<Category>Diagnostics" preference is set, or
 *   2. the master "PerfDiagnostics" switch is on (it enables every category), or
 *   3. its dedicated "ITG_LOG_<CATEGORY>" environment variable is set to "1".
 * Hot-path categories may intentionally opt out of the master switch below when
 * enabling them can create extreme log volume during normal gameplay.
 *
 * The two legacy environment variables (ITG_TRACE_GL_UPLOADS,
 * ITG_TRACE_RESOURCE_SNAPSHOTS) are still honored so existing tooling keeps
 * working.
 */
static bool CategoryEnabled(
    const std::atomic<bool>& ownPreference, bool envEnabled,
    bool legacyEnvEnabled = false) {
  return ownPreference.load(std::memory_order_acquire) ||
         PerfDiagnosticsEnabled() || envEnabled || legacyEnvEnabled;
}

bool LogAudioUnderrunDiagnosticsEnabled() {
  return CategoryEnabled(
      g_bLogAudioUnderrunDiagnosticsCached, g_bEnvLogAudioUnderrun);
}

bool LogTextureUploadDiagnosticsEnabled() {
  return CategoryEnabled(
      g_bLogTextureUploadDiagnosticsCached, g_bEnvLogTextureUpload,
      g_bEnvLegacyTraceGlUploads);
}

bool LogResourceSnapshotDiagnosticsEnabled() {
  return CategoryEnabled(
      g_bLogResourceSnapshotDiagnosticsCached, false,
      g_bEnvLegacyTraceResourceSnapshots);
}

bool LogBackgroundDiagnosticsEnabled() {
  return CategoryEnabled(
      g_bLogBackgroundDiagnosticsCached, g_bEnvLogBackground);
}

bool LogPlayOnceDiagnosticsEnabled() {
  return CategoryEnabled(g_bLogPlayOnceDiagnosticsCached, g_bEnvLogPlayOnce);
}

bool LogNoteSkinDiagnosticsEnabled() {
  return CategoryEnabled(g_bLogNoteSkinDiagnosticsCached, g_bEnvLogNoteSkin);
}

bool LogInputDiagnosticsEnabled() {
  return CategoryEnabled(g_bLogInputDiagnosticsCached, g_bEnvLogInput);
}

bool LogMemoryCardDiagnosticsEnabled() {
  return CategoryEnabled(
      g_bLogMemoryCardDiagnosticsCached, g_bEnvLogMemoryCard);
}

bool LogContentLoadDiagnosticsEnabled() {
  return CategoryEnabled(
      g_bLogContentLoadDiagnosticsCached, g_bEnvLogContentLoad);
}

bool LogVerboseContentLoadDiagnosticsEnabled() {
  // This intentionally does not inherit from PerfDiagnostics.  Per-texture and
  // per-PNG-row checkpoints can produce thousands of lines in a normal boot,
  // so they are reserved for targeted low-level asset I/O investigations.
  return g_bEnvLogVerboseContentLoad;
}

bool LogThemeLuaDiagnosticsEnabled() {
  return CategoryEnabled(g_bLogThemeLuaDiagnosticsCached, g_bEnvLogThemeLua);
}

bool LogGlobalOffsetDiagnosticsEnabled() {
  // Global-offset diagnostics include timing hot paths that can produce massive
  // logs during gameplay, so this category intentionally does not inherit from
  // the master PerfDiagnostics switch.  Use the dedicated option or
  // ITG_LOG_GLOBAL_OFFSET=1 when investigating this system.
  return g_bLogGlobalOffsetDiagnosticsCached.load(std::memory_order_acquire) ||
         g_bEnvLogGlobalOffset;
}

bool LogWindowsEventDiagnosticsEnabled() {
  // The window procedure runs for every native message. This hot-path trace is
  // deliberately independent from PerfDiagnostics and generic checkpoints.
  return g_bLogWindowsEventDiagnosticsCached.load(std::memory_order_acquire) ||
         g_bEnvWindowsEvents;
}

bool ReviewSrcDiagnosticsEnabled() {
  return g_bReviewSrcCached.load(std::memory_order_acquire) || g_bEnvReviewSrc;
}

void LogReviewSrcDiagnostics(const char* fmt, ...) {
  if (!ReviewSrcDiagnosticsEnabled() || fmt == nullptr || LOG == nullptr) {
    return;
  }

  va_list va;
  va_start(va, fmt);
  const std::string message = vssprintf(fmt, va);
  va_end(va);

  LOG->Trace("SRC_REVIEW_TRACE %s", message.c_str());
}
