#ifndef MACOS_METAL_PRESENTER_H
#define MACOS_METAL_PRESENTER_H

#include <string>

struct MacOSMetalPresenterRuntimeStats {
  unsigned long long submittedFrames = 0;
  unsigned long long completedFrames = 0;
  unsigned long long prefetchedDrawables = 0;
  unsigned long long consumedDrawables = 0;
  unsigned long long slowDrawableAcquires = 0;
  unsigned long long drawableMisses = 0;
  unsigned long long skippedNoPrefetchedDrawableFrames = 0;
};

class MacOSMetalPresenter {
 public:
  MacOSMetalPresenter();
  ~MacOSMetalPresenter();

  bool Initialize(void* nsWindow, int width, int height, double targetHz);
  void Shutdown();

  bool IsAvailable() const;
  bool IsInteropReady() const;
  bool IsLayerAttached() const;
  bool AttachLayerToWindow(void* nsWindow);
  void DetachLayer();
  bool PresentInteropSurfaceAt(int index, double targetHz);
  int InteropSurfaceCount() const;
  void* InteropIOSurfaceAt(int index) const;
  int InteropSurfaceWidth() const;
  int InteropSurfaceHeight() const;
  const std::string& FailureReason() const;

 private:
  void* m_Impl;
  bool m_Available;
  std::string m_FailureReason;
};

MacOSMetalPresenterRuntimeStats MacOSMetalPresenterGetRuntimeStats();
std::string MacOSMetalPresenterGetRuntimeStatsLine();

#endif
