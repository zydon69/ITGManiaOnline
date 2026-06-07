#ifndef MACOS_METAL_PRESENTER_H
#define MACOS_METAL_PRESENTER_H

#include <cstddef>
#include <string>

struct MacOSMetalSolidVertex {
  float x = 0.0f;
  float y = 0.0f;
  float z = 0.0f;
  float r = 1.0f;
  float g = 1.0f;
  float b = 1.0f;
  float a = 1.0f;
};

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
  bool IsInteropSurfaceBusy(int index) const;
  void SetLayerVisible(bool visible);
  bool AttachLayerToWindow(void* nsWindow);
  void DetachLayer();
  bool PresentClearFrame(
      double red, double green, double blue, double alpha, double targetHz);
  bool PresentSolidVertices(
      const MacOSMetalSolidVertex* vertices, size_t vertexCount,
      double clearRed, double clearGreen, double clearBlue, double clearAlpha,
      double targetHz);
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
