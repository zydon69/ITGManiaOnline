#ifndef PERF_DIAGNOSTICS_H
#define PERF_DIAGNOSTICS_H

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
bool LogMusicWheelDiagnosticsEnabled();

#endif
