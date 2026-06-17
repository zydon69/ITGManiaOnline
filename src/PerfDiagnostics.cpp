#include "PerfDiagnostics.h"

#include <atomic>
#include <cstdlib>
#include <string>

#include "Preference.h"

static Preference<bool> g_bPerfDiagnostics("PerfDiagnostics", true);
static Preference<bool> g_bLogAudioUnderrunDiagnostics(
    "LogAudioUnderrunDiagnostics", true);
static Preference<bool> g_bLogTextureUploadDiagnostics(
    "LogTextureUploadDiagnostics", true);
static Preference<bool> g_bLogResourceSnapshotDiagnostics(
    "LogResourceSnapshotDiagnostics", true);
static Preference<bool> g_bLogBackgroundDiagnostics(
    "LogBackgroundDiagnostics", true);
static Preference<bool> g_bLogPlayOnceDiagnostics(
    "LogPlayOnceDiagnostics", true);
static Preference<bool> g_bLogNoteSkinDiagnostics(
    "LogNoteSkinDiagnostics", true);
static Preference<bool> g_bLogInputDiagnostics(
    "LogInputDiagnostics", true);
static Preference<bool> g_bLogMemoryCardDiagnostics(
    "LogMemoryCardDiagnostics", true);
static Preference<bool> g_bLogContentLoadDiagnostics(
    "LogContentLoadDiagnostics", true);
static Preference<bool> g_bLogThemeLuaDiagnostics(
    "LogThemeLuaDiagnostics", true);
static Preference<bool> g_bLogGlobalOffsetDiagnostics(
    "LogGlobalOffsetDiagnostics", true);

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
static const bool g_bEnvLegacyTraceGlUploads =
    EnvFlagEnabled("ITG_TRACE_GL_UPLOADS");
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
  // Memory leak detection relies on these snapshots, so keep them enabled
  // regardless of the preference value.
  g_bLogResourceSnapshotDiagnosticsCached.store(true, std::memory_order_release);
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

bool LogResourceSnapshotDiagnosticsEnabled() { return true; }

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
