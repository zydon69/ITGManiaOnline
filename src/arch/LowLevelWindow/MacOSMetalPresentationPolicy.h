#ifndef MACOS_METAL_PRESENTATION_POLICY_H
#define MACOS_METAL_PRESENTATION_POLICY_H

namespace MacOSMetalPresentation {

enum class NativeWindowEvent : int {
  None = 0,
  WillEnterFullscreen = 1,
  DidEnterFullscreen = 2,
  WillExitFullscreen = 3,
  DidExitFullscreen = 4,
  ScreenChanged = 5,
  BackingChanged = 6,
};

enum class Mode {
  CompositedWindow,
  NativeFullscreen,
  ExclusiveFullscreen,
};

enum class CadenceOwner {
  WindowServer,
  Engine,
};

struct Policy {
  Mode mode = Mode::CompositedWindow;
  CadenceOwner cadenceOwner = CadenceOwner::WindowServer;
  bool displaySyncEnabled = true;
  bool scheduleMinimumPresentDuration = true;
};

NativeWindowEvent NativeWindowEventFromRaw(int value);
const char* NativeWindowEventName(NativeWindowEvent event);

Mode ResolveMode(
    bool engineWindowed, bool nativeStyleFullscreen,
    NativeWindowEvent event = NativeWindowEvent::None);
const char* ModeName(Mode mode);

Policy PolicyForMode(Mode mode);
const char* CadenceOwnerName(CadenceOwner owner);

double MinimumPresentDurationSeconds(
    const Policy& policy, double targetHz);

}  // namespace MacOSMetalPresentation

#endif
