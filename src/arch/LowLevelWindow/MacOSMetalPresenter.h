#ifndef MACOS_METAL_PRESENTER_H
#define MACOS_METAL_PRESENTER_H

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "MacOSMetalPresentationPolicy.h"
#include "RageTypes.h"

struct MacOSMetalSolidVertex {
  float x = 0.0f;
  float y = 0.0f;
  float z = 0.0f;
  float w = 1.0f;
  float u = 0.0f;
  float v = 0.0f;
  float u2 = 0.0f;
  float v2 = 0.0f;
  float textureMatrixScaleX = 1.0f;
  float textureMatrixScaleY = 1.0f;
  float r = 1.0f;
  float g = 1.0f;
  float b = 1.0f;
  float a = 1.0f;
};

struct MacOSMetalTransformUniforms {
  float modelViewProjection[16] = {};
  float textureMatrix[16] = {};
  float zBias = 0.0f;
  float padding[3] = {};
};

static_assert(
    sizeof(MacOSMetalSolidVertex) == 56,
    "MacOSMetalSolidVertex must match FixedFunction.metal::VertexIn");
static_assert(
    offsetof(MacOSMetalSolidVertex, u) == 16 &&
        offsetof(MacOSMetalSolidVertex, u2) == 24 &&
        offsetof(MacOSMetalSolidVertex, textureMatrixScaleX) == 32 &&
        offsetof(MacOSMetalSolidVertex, r) == 40,
    "MacOSMetalSolidVertex field offsets must match the packed MSL layout");
static_assert(
    sizeof(MacOSMetalTransformUniforms) == 144,
    "MacOSMetalTransformUniforms must match FixedFunction.metal::TransformUniforms");
static_assert(
    offsetof(MacOSMetalTransformUniforms, textureMatrix) == 64 &&
        offsetof(MacOSMetalTransformUniforms, zBias) == 128 &&
        offsetof(MacOSMetalTransformUniforms, padding) == 132,
    "MacOSMetalTransformUniforms field offsets must match the MSL layout");

struct MacOSMetalPresenterRuntimeStats {
  unsigned long long submittedFrames = 0;
  unsigned long long completedFrames = 0;
  unsigned long long offscreenSubmittedFrames = 0;
  unsigned long long offscreenCompletedFrames = 0;
  unsigned long long commandBufferErrors = 0;
  unsigned long long prefetchedDrawables = 0;
  unsigned long long consumedDrawables = 0;
  unsigned long long slowDrawableAcquires = 0;
  unsigned long long drawableMisses = 0;
  unsigned long long skippedNoPrefetchedDrawableFrames = 0;
  unsigned long long offscreenSkippedNoDrawableFrames = 0;
  unsigned long long offscreenSkippedFrameLimiterFrames = 0;
  MacOSMetalPresentation::Mode presentationMode =
      MacOSMetalPresentation::Mode::CompositedWindow;
  bool displaySyncEnabled = true;
  bool schedulesMinimumPresentDuration = true;
};

enum class MacOSMetalPresentResult {
  Presented,
  Skipped,
  Failed,
};

struct MacOSMetalDrawBatch {
  const MacOSMetalSolidVertex* vertices = nullptr;
  void* vertexBuffer = nullptr;
  size_t vertexBufferOffsetBytes = 0;
  size_t vertexCount = 0;
  void* texture = nullptr;
  int textureWidth = 1;
  void* texture2 = nullptr;
  TextureMode textureMode2 = TextureMode_Modulate;
  bool hasTexture2 = false;
  BlendMode blendMode = BLEND_NORMAL;
  TextureMode textureMode = TextureMode_Modulate;
  EffectMode effectMode = EffectMode_Normal;
  int celStage = 0;
  ZTestMode zTestMode = ZTEST_OFF;
  CullMode cullMode = CULL_NONE;
  bool textureWrapping = false;
  bool textureFiltering = true;
  bool texture2Wrapping = false;
  bool texture2Filtering = true;
  bool zWrite = false;
  bool alphaTest = false;
  bool clearDepthBefore = false;
  MacOSMetalTransformUniforms transform;
};

struct MacOSMetalVertexFrame {
  void* vertexBuffer = nullptr;
  int frameSlot = -1;
  size_t capacityVertices = 0;
  bool renderTarget = false;
};

// The native Metal renderer owns the window's CAMetalLayer directly.  The
// OpenGL-to-Metal presentation bridge must stay disabled while that renderer
// is alive or both presenters will race to replace the same NSWindow content.
void MacOSMetalPresenterSetNativeRendererActive(bool active);
bool MacOSMetalPresenterNativeRendererActive();

class MacOSMetalPresenter {
 public:
  MacOSMetalPresenter();
  ~MacOSMetalPresenter();

  bool Initialize(
      void* nsWindow, int width, int height, double targetHz,
      bool createInteropSurfaces,
      MacOSMetalPresentation::Mode presentationMode);
  void Shutdown();

  bool IsAvailable() const;
  bool IsInteropReady() const;
  bool IsLayerAttached() const;
  bool IsInteropSurfaceBusy(int index) const;
  double DisplayPacingTargetHz(double fallbackHz, double headroomFactor);
  void SetLayerVisible(bool visible);
  bool AttachLayerToWindow(void* nsWindow);
  bool AttachLayerAsContentView(void* nsWindow);
  bool ReconfigureAttachedLayer(
      void* nsWindow, const char* reason,
      MacOSMetalPresentation::Mode presentationMode);
  void DetachLayer();
  MacOSMetalPresentResult PresentSolidBatchesOffscreenFirst(
      const MacOSMetalDrawBatch* batches, size_t batchCount,
      bool clearDepth,
      double clearRed, double clearGreen, double clearBlue, double clearAlpha,
      double targetHz,
      MacOSMetalVertexFrame* preparedVertexFrame = nullptr);
  bool BeginSolidVertexFrame(
      size_t vertexCapacity, MacOSMetalVertexFrame* frame,
      MacOSMetalSolidVertex** vertices);
  bool BeginRenderTargetVertexFrame(
      size_t vertexCapacity, MacOSMetalVertexFrame* frame,
      MacOSMetalSolidVertex** vertices);
  void CancelVertexFrame(MacOSMetalVertexFrame* frame);
  void* CreateBGRA8RenderTargetTexture(int width, int height);
  void* CreateDepthRenderTargetTexture(int width, int height);
  bool RenderSolidBatchesToTexture(
      void* colorTexture, void* depthTexture,
      const MacOSMetalDrawBatch* batches, size_t batchCount,
      bool preserveColor, bool clearDepth,
      double clearRed, double clearGreen, double clearBlue, double clearAlpha,
      int viewportWidth, int viewportHeight,
      MacOSMetalVertexFrame* preparedVertexFrame = nullptr,
      MacOSMetalVertexFrame* externalVertexFrameToRelease = nullptr);
  bool ReadBackOffscreenPresentTextureBGRA8(
      std::vector<uint8_t>* pixels, int* width, int* height);
  void* CreateRGBA8Texture(
      int width, int height, const void* pixels, size_t bytesPerRow,
      bool generateMipMaps);
  bool UpdateRGBA8Texture(
      void* texture, int xoffset, int yoffset, int width, int height,
      const void* pixels, size_t bytesPerRow);
  void ReleaseTexture(void* texture);
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
MacOSMetalPresentation::Mode MacOSMetalPresentationModeForWindow(
    void* nsWindow, bool engineWindowed,
    MacOSMetalPresentation::NativeWindowEvent event =
        MacOSMetalPresentation::NativeWindowEvent::None);
void MacOSMetalPresenterMarkNativePresentationChange(
    MacOSMetalPresentation::NativeWindowEvent event);
MacOSMetalPresentation::NativeWindowEvent
MacOSMetalPresenterConsumeNativePresentationChange();

#endif
