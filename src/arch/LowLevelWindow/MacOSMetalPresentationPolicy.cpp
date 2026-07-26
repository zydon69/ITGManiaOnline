#include "MacOSMetalPresentationPolicy.h"

#include <cmath>

namespace MacOSMetalPresentation {

NativeWindowEvent NativeWindowEventFromRaw(int value) {
  switch (value) {
    case static_cast<int>(NativeWindowEvent::WillEnterFullscreen):
      return NativeWindowEvent::WillEnterFullscreen;
    case static_cast<int>(NativeWindowEvent::DidEnterFullscreen):
      return NativeWindowEvent::DidEnterFullscreen;
    case static_cast<int>(NativeWindowEvent::WillExitFullscreen):
      return NativeWindowEvent::WillExitFullscreen;
    case static_cast<int>(NativeWindowEvent::DidExitFullscreen):
      return NativeWindowEvent::DidExitFullscreen;
    case static_cast<int>(NativeWindowEvent::ScreenChanged):
      return NativeWindowEvent::ScreenChanged;
    case static_cast<int>(NativeWindowEvent::BackingChanged):
      return NativeWindowEvent::BackingChanged;
    default:
      return NativeWindowEvent::None;
  }
}

const char* NativeWindowEventName(NativeWindowEvent event) {
  switch (event) {
    case NativeWindowEvent::WillEnterFullscreen:
      return "will_enter_fullscreen";
    case NativeWindowEvent::DidEnterFullscreen:
      return "did_enter_fullscreen";
    case NativeWindowEvent::WillExitFullscreen:
      return "will_exit_fullscreen";
    case NativeWindowEvent::DidExitFullscreen:
      return "did_exit_fullscreen";
    case NativeWindowEvent::ScreenChanged:
      return "screen_changed";
    case NativeWindowEvent::BackingChanged:
      return "backing_changed";
    default:
      return "none";
  }
}

Mode ResolveMode(
    bool engineWindowed, bool nativeStyleFullscreen,
    NativeWindowEvent event) {
  if (!engineWindowed) {
    return Mode::ExclusiveFullscreen;
  }

  switch (event) {
    case NativeWindowEvent::WillEnterFullscreen:
    case NativeWindowEvent::DidEnterFullscreen:
      return Mode::NativeFullscreen;
    case NativeWindowEvent::WillExitFullscreen:
    case NativeWindowEvent::DidExitFullscreen:
      return Mode::CompositedWindow;
    default:
      return nativeStyleFullscreen ? Mode::NativeFullscreen
                                   : Mode::CompositedWindow;
  }
}

const char* ModeName(Mode mode) {
  switch (mode) {
    case Mode::NativeFullscreen:
      return "native_fullscreen";
    case Mode::ExclusiveFullscreen:
      return "exclusive_fullscreen";
    default:
      return "composited_window";
  }
}

Policy PolicyForMode(Mode mode) {
  Policy policy;
  policy.mode = mode;
  switch (mode) {
    case Mode::NativeFullscreen:
    case Mode::ExclusiveFullscreen:
      policy.cadenceOwner = CadenceOwner::Engine;
      policy.displaySyncEnabled = false;
      policy.scheduleMinimumPresentDuration = false;
      break;
    case Mode::CompositedWindow:
    default:
      policy.cadenceOwner = CadenceOwner::WindowServer;
      policy.displaySyncEnabled = true;
      policy.scheduleMinimumPresentDuration = true;
      break;
  }
  return policy;
}

const char* CadenceOwnerName(CadenceOwner owner) {
  switch (owner) {
    case CadenceOwner::Engine:
      return "engine";
    default:
      return "window_server";
  }
}

double MinimumPresentDurationSeconds(
    const Policy& policy, double targetHz) {
  if (!policy.scheduleMinimumPresentDuration) {
    return 0.0;
  }
  const double safeTargetHz =
      std::isfinite(targetHz) && targetHz > 1.0 ? targetHz : 60.0;
  return 1.0 / safeTargetHz;
}

}  // namespace MacOSMetalPresentation
