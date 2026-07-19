#ifndef PERF_DIAGNOSTICS_H
#define PERF_DIAGNOSTICS_H

#include "Compiler.h"

bool PerfDiagnosticsEnabled();
void RefreshPerfDiagnosticsPreferenceCache();
bool LogAudioUnderrunDiagnosticsEnabled();
bool LogTextureUploadDiagnosticsEnabled();
bool LogResourceSnapshotDiagnosticsEnabled();
bool LogBackgroundDiagnosticsEnabled();
bool LogPlayOnceDiagnosticsEnabled();
bool LogNoteSkinDiagnosticsEnabled();
bool LogInputDiagnosticsEnabled();
bool LogMemoryCardDiagnosticsEnabled();
bool LogContentLoadDiagnosticsEnabled();
bool LogVerboseContentLoadDiagnosticsEnabled();
bool LogThemeLuaDiagnosticsEnabled();
bool LogGlobalOffsetDiagnosticsEnabled();
bool LogWindowsEventDiagnosticsEnabled();
bool ReviewSrcDiagnosticsEnabled();
void LogReviewSrcDiagnostics(const char* fmt, ...) PRINTF(1, 2);
bool RoutineCoupleDiagnosticsEnabled();
void LogRoutineCoupleDiagnostics(const char* fmt, ...) PRINTF(1, 2);

#endif
