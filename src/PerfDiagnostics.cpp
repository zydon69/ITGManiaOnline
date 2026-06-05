#include "PerfDiagnostics.h"

#include "Preference.h"

static Preference<bool> g_bPerfDiagnostics("PerfDiagnostics", false);

bool PerfDiagnosticsEnabled() {
  return g_bPerfDiagnostics.Get();
}
