#include "arch/LowLevelWindow/MacOSMetalPresentationPolicy.h"

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <string>

namespace {

void Require(bool condition, const std::string& message) {
  if (!condition) {
    std::cerr << "macOS Metal presentation policy: " << message << std::endl;
    std::exit(1);
  }
}

bool Near(double lhs, double rhs) {
  return std::abs(lhs - rhs) <= 0.0000001;
}

}  // namespace

int main() {
  using namespace MacOSMetalPresentation;

  const Policy windowed =
      PolicyForMode(ResolveMode(true, false, NativeWindowEvent::None));
  Require(
      windowed.mode == Mode::CompositedWindow,
      "a regular NSWindow must use the composited policy");
  Require(
      windowed.cadenceOwner == CadenceOwner::WindowServer,
      "WindowServer must own composited-window presentation cadence");
  Require(
      windowed.displaySyncEnabled,
      "a composited CAMetalLayer must stay display-synchronized");
  Require(
      windowed.scheduleMinimumPresentDuration,
      "a composited present must retain a refresh-duration guard");
  Require(
      Near(MinimumPresentDurationSeconds(windowed, 120.0), 1.0 / 120.0),
      "the minimum duration must follow the physical refresh target");
  Require(
      Near(
          MinimumPresentDurationSeconds(
              windowed, std::numeric_limits<double>::quiet_NaN()),
          1.0 / 60.0),
      "an invalid refresh target must use the safe 60 Hz fallback");

  const Policy nativeFullscreen =
      PolicyForMode(ResolveMode(true, true, NativeWindowEvent::None));
  Require(
      nativeFullscreen.mode == Mode::NativeFullscreen,
      "a macOS fullscreen Space must be distinguished from a regular window");
  Require(
      nativeFullscreen.cadenceOwner == CadenceOwner::Engine &&
          !nativeFullscreen.displaySyncEnabled &&
          !nativeFullscreen.scheduleMinimumPresentDuration,
      "native fullscreen must keep a single engine cadence owner");
  Require(
      MinimumPresentDurationSeconds(nativeFullscreen, 120.0) == 0.0,
      "engine-owned cadence must present immediately");

  const Policy exclusive =
      PolicyForMode(ResolveMode(false, false, NativeWindowEvent::None));
  Require(
      exclusive.mode == Mode::ExclusiveFullscreen,
      "CGDisplayCapture fullscreen must have an explicit policy");
  Require(
      exclusive.cadenceOwner == CadenceOwner::Engine &&
          !exclusive.displaySyncEnabled &&
          !exclusive.scheduleMinimumPresentDuration,
      "exclusive fullscreen must keep a single engine cadence owner");

  Require(
      ResolveMode(
          true, false, NativeWindowEvent::WillEnterFullscreen) ==
          Mode::NativeFullscreen,
      "will-enter must switch policy before AppKit updates the style mask");
  Require(
      ResolveMode(
          true, false, NativeWindowEvent::DidEnterFullscreen) ==
          Mode::NativeFullscreen,
      "did-enter must confirm native fullscreen");
  Require(
      ResolveMode(
          true, true, NativeWindowEvent::WillExitFullscreen) ==
          Mode::CompositedWindow,
      "will-exit must restore WindowServer synchronization before the window returns");
  Require(
      ResolveMode(
          true, true, NativeWindowEvent::DidExitFullscreen) ==
          Mode::CompositedWindow,
      "did-exit must confirm the composited policy");
  Require(
      ResolveMode(
          true, true, NativeWindowEvent::ScreenChanged) ==
          Mode::NativeFullscreen,
      "screen changes must preserve the observed native fullscreen state");
  Require(
      ResolveMode(
          true, false, NativeWindowEvent::BackingChanged) ==
          Mode::CompositedWindow,
      "backing changes must preserve the observed window state");
  Require(
      ResolveMode(
          false, true, NativeWindowEvent::WillExitFullscreen) ==
          Mode::ExclusiveFullscreen,
      "engine-exclusive fullscreen must override AppKit transition events");

  for (int raw = 0; raw <= 6; ++raw) {
    Require(
        static_cast<int>(NativeWindowEventFromRaw(raw)) == raw,
        "known native-window event values must round-trip");
  }
  Require(
      NativeWindowEventFromRaw(-1) == NativeWindowEvent::None &&
          NativeWindowEventFromRaw(99) == NativeWindowEvent::None,
      "unknown native-window events must fail closed");

  std::cout << "macOS Metal presentation policy: ok" << std::endl;
  return 0;
}
