#include "PerfDiagnostics.h"

#include <cstdlib>
#include <string>

#include "Preference.h"

static Preference<bool> g_bPerfDiagnostics("PerfDiagnostics", false);
static Preference<bool> g_bLogAudioUnderrunDiagnostics(
    "LogAudioUnderrunDiagnostics", false);
static Preference<bool> g_bLogTextureUploadDiagnostics(
    "LogTextureUploadDiagnostics", false);
static Preference<bool> g_bLogResourceSnapshotDiagnostics(
    "LogResourceSnapshotDiagnostics", false);
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

static bool EnvFlagEnabled(const char* name) {
  if (name == nullptr) {
    return false;
  }
  const char* value = std::getenv(name);
  return value != nullptr && std::string(value) == "1";
}

bool PerfDiagnosticsEnabled() {
  return g_bPerfDiagnostics.Get();
}

/*
 * A diagnostic category is enabled when ANY of the following is true, applied
 * uniformly to every category:
 *   1. its own "Log<Category>Diagnostics" preference is set, or
 *   2. the master "PerfDiagnostics" switch is on (it enables every category), or
 *   3. its dedicated "ITG_LOG_<CATEGORY>" environment variable is set to "1".
 *
 * The two legacy environment variables (ITG_TRACE_GL_UPLOADS,
 * ITG_TRACE_RESOURCE_SNAPSHOTS) are still honored so existing tooling keeps
 * working.  Keeping this logic identical across categories is intentional:
 * previously only audio-underrun fell back to the master and only two
 * categories had an environment override, which made the toggles behave
 * inconsistently.
 */
static bool CategoryEnabled(
    bool ownPreference, const char* envName,
    const char* legacyEnvName = nullptr) {
  return ownPreference || PerfDiagnosticsEnabled() || EnvFlagEnabled(envName) ||
         EnvFlagEnabled(legacyEnvName);
}

bool LogAudioUnderrunDiagnosticsEnabled() {
  return CategoryEnabled(
      g_bLogAudioUnderrunDiagnostics.Get(), "ITG_LOG_AUDIO_UNDERRUN");
}

bool LogTextureUploadDiagnosticsEnabled() {
  return CategoryEnabled(
      g_bLogTextureUploadDiagnostics.Get(), "ITG_LOG_TEXTURE_UPLOAD",
      "ITG_TRACE_GL_UPLOADS");
}

bool LogResourceSnapshotDiagnosticsEnabled() {
  return CategoryEnabled(
      g_bLogResourceSnapshotDiagnostics.Get(), "ITG_LOG_RESOURCE_SNAPSHOT",
      "ITG_TRACE_RESOURCE_SNAPSHOTS");
}

bool LogPlayOnceDiagnosticsEnabled() {
  return CategoryEnabled(g_bLogPlayOnceDiagnostics.Get(), "ITG_LOG_PLAY_ONCE");
}

bool LogNoteSkinDiagnosticsEnabled() {
  return CategoryEnabled(g_bLogNoteSkinDiagnostics.Get(), "ITG_LOG_NOTESKIN");
}

bool LogInputDiagnosticsEnabled() {
  return CategoryEnabled(g_bLogInputDiagnostics.Get(), "ITG_LOG_INPUT");
}

bool LogMemoryCardDiagnosticsEnabled() {
  return CategoryEnabled(
      g_bLogMemoryCardDiagnostics.Get(), "ITG_LOG_MEMORY_CARD");
}

bool LogContentLoadDiagnosticsEnabled() {
  return CategoryEnabled(
      g_bLogContentLoadDiagnostics.Get(), "ITG_LOG_CONTENT_LOAD");
}

bool LogThemeLuaDiagnosticsEnabled() {
  return CategoryEnabled(g_bLogThemeLuaDiagnostics.Get(), "ITG_LOG_THEME_LUA");
}
