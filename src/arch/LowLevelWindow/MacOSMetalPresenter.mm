#include "MacOSMetalPresenter.h"

#include "RageLog.h"

#import <AppKit/AppKit.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <array>
#include <cstdint>

namespace {

constexpr int kMetalInteropSurfaceCount = 3;

uint32_t FourCC(char a, char b, char c, char d) {
  return (static_cast<uint32_t>(a) << 24) |
         (static_cast<uint32_t>(b) << 16) |
         (static_cast<uint32_t>(c) << 8) |
         static_cast<uint32_t>(d);
}

struct MacOSMetalInteropSurface {
  IOSurfaceRef ioSurface = nullptr;
  id<MTLTexture> metalTexture = nil;
  int width = 0;
  int height = 0;
};

struct MacOSMetalPresenterImpl {
  id<MTLDevice> device = nil;
  id<MTLCommandQueue> commandQueue = nil;
  id<MTLRenderPipelineState> presentPipeline = nil;
  CAMetalLayer* layer = nil;
  NSView* layerView = nil;
  std::array<MacOSMetalInteropSurface, kMetalInteropSurfaceCount> surfaces;
  bool interopReady = false;
  bool loggedFirstDirectPresent = false;
};

void ReleaseInteropSurface(MacOSMetalInteropSurface* surface) {
  if (surface == nullptr) {
    return;
  }
  if (surface->metalTexture != nil) {
    [surface->metalTexture release];
    surface->metalTexture = nil;
  }
  if (surface->ioSurface != nullptr) {
    CFRelease(surface->ioSurface);
    surface->ioSurface = nullptr;
  }
  surface->width = 0;
  surface->height = 0;
}

bool CreateInteropSurface(
    id<MTLDevice> device, int width, int height,
    MacOSMetalInteropSurface* surface, std::string* failureReason) {
  if (surface == nullptr) {
    if (failureReason != nullptr) {
      *failureReason = "Internal error: null interop surface slot.";
    }
    return false;
  }
  ReleaseInteropSurface(surface);

  const int bytesPerPixel = 4;
  const int bytesPerRow = width * bytesPerPixel;
  NSDictionary* properties = @{
    (NSString*)kIOSurfaceWidth: @(width),
    (NSString*)kIOSurfaceHeight: @(height),
    (NSString*)kIOSurfaceBytesPerElement: @(bytesPerPixel),
    (NSString*)kIOSurfaceBytesPerRow: @(bytesPerRow),
    (NSString*)kIOSurfaceAllocSize: @(bytesPerRow * height),
    (NSString*)kIOSurfacePixelFormat: @(FourCC('B', 'G', 'R', 'A'))
  };

  surface->ioSurface = IOSurfaceCreate((CFDictionaryRef)properties);
  if (surface->ioSurface == nullptr) {
    if (failureReason != nullptr) {
      *failureReason = "IOSurfaceCreate failed.";
    }
    return false;
  }

  MTLTextureDescriptor* descriptor =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                         width:width
                                                        height:height
                                                     mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;

  surface->metalTexture =
      [device newTextureWithDescriptor:descriptor
                             iosurface:surface->ioSurface
                                 plane:0];
  if (surface->metalTexture == nil) {
    if (failureReason != nullptr) {
      *failureReason = "Failed to import IOSurface as MTLTexture.";
    }
    ReleaseInteropSurface(surface);
    return false;
  }

  surface->width = width;
  surface->height = height;
  return true;
}

id<MTLRenderPipelineState> CreatePresentPipeline(
    id<MTLDevice> device, std::string* failureReason) {
  static NSString* const shaderSource =
      @"#include <metal_stdlib>\n"
       "using namespace metal;\n"
       "struct VertexOut {\n"
       "  float4 position [[position]];\n"
       "  float2 texcoord;\n"
       "};\n"
       "vertex VertexOut vertex_main(uint vertexID [[vertex_id]]) {\n"
       "  const float2 positions[3] = {\n"
       "    float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0)\n"
       "  };\n"
       "  const float2 texcoords[3] = {\n"
       "    float2(1.0, 1.0), float2(-1.0, 1.0), float2(1.0, -1.0)\n"
       "  };\n"
       "  VertexOut out;\n"
       "  out.position = float4(positions[vertexID], 0.0, 1.0);\n"
       "  out.texcoord = texcoords[vertexID];\n"
       "  return out;\n"
       "}\n"
       "fragment float4 fragment_main(VertexOut in [[stage_in]],\n"
       "                              texture2d<float> source [[texture(0)]]) {\n"
       "  constexpr sampler sourceSampler(address::clamp_to_edge,\n"
       "                                  filter::nearest);\n"
       "  return source.sample(sourceSampler, in.texcoord);\n"
       "}\n";

  NSError* error = nil;
  id<MTLLibrary> library = [device newLibraryWithSource:shaderSource
                                                options:nil
                                                  error:&error];
  if (library == nil) {
    if (failureReason != nullptr) {
      *failureReason = error != nil ? [[error localizedDescription] UTF8String]
                                    : "Metal shader compilation failed.";
    }
    return nil;
  }

  id<MTLFunction> vertexFunction =
      [library newFunctionWithName:@"vertex_main"];
  id<MTLFunction> fragmentFunction =
      [library newFunctionWithName:@"fragment_main"];
  if (vertexFunction == nil || fragmentFunction == nil) {
    if (failureReason != nullptr) {
      *failureReason = "Metal present shader entry point lookup failed.";
    }
    [vertexFunction release];
    [fragmentFunction release];
    [library release];
    return nil;
  }

  MTLRenderPipelineDescriptor* descriptor =
      [[[MTLRenderPipelineDescriptor alloc] init] autorelease];
  descriptor.vertexFunction = vertexFunction;
  descriptor.fragmentFunction = fragmentFunction;
  descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

  id<MTLRenderPipelineState> pipeline =
      [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
  if (pipeline == nil && failureReason != nullptr) {
    *failureReason = error != nil ? [[error localizedDescription] UTF8String]
                                  : "Metal present pipeline creation failed.";
  }

  [vertexFunction release];
  [fragmentFunction release];
  [library release];
  return pipeline;
}

}  // namespace

MacOSMetalPresenter::MacOSMetalPresenter()
    : m_Impl(nullptr), m_Available(false) {}

MacOSMetalPresenter::~MacOSMetalPresenter() {
  Shutdown();
}

bool MacOSMetalPresenter::Initialize(
    void* nsWindow, int width, int height, double targetHz) {
  Shutdown();

  MacOSMetalPresenterImpl* impl = new MacOSMetalPresenterImpl();
  impl->device = MTLCreateSystemDefaultDevice();
  if (impl->device == nil) {
    m_FailureReason = "Metal is not available on this Mac.";
    delete impl;
    LOG->Warn("MacOS Metal presenter unavailable: %s", m_FailureReason.c_str());
    return false;
  }

  [impl->device retain];

  impl->commandQueue = [impl->device newCommandQueue];
  if (impl->commandQueue == nil) {
    m_FailureReason = "Failed to create Metal command queue.";
    [impl->device release];
    delete impl;
    LOG->Warn("MacOS Metal presenter unavailable: %s", m_FailureReason.c_str());
    return false;
  }

  std::string pipelineFailure;
  impl->presentPipeline =
      CreatePresentPipeline(impl->device, &pipelineFailure);
  if (impl->presentPipeline == nil) {
    LOG->Warn(
        "MacOS Metal presenter direct-present pipeline unavailable: %s",
        pipelineFailure.c_str());
  }

  NSWindow* window = (__bridge NSWindow*)nsWindow;
  NSView* contentView = [window contentView];
  const NSRect bounds = contentView != nil ? [contentView bounds] : NSZeroRect;

  // Phase 2 infrastructure only: create the layer object and validate the Metal
  // device/queue, but do not attach it yet. Attaching the layer before the
  // OpenGL->IOSurface->Metal path exists would replace the current OpenGL
  // presentation surface and break the stable renderer.
  impl->layer = [[CAMetalLayer layer] retain];
  impl->layer.device = impl->device;
  impl->layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
  impl->layer.framebufferOnly = NO;
  impl->layer.displaySyncEnabled = YES;
  impl->layer.maximumDrawableCount = 3;
  impl->layer.frame = bounds;
  impl->layer.drawableSize = CGSizeMake(width, height);

  std::string interopFailure;
  bool interopReady = true;
  for (auto& surface : impl->surfaces) {
    if (!CreateInteropSurface(
            impl->device, width, height, &surface, &interopFailure)) {
      interopReady = false;
      break;
    }
  }
  impl->interopReady = interopReady;
  if (!interopReady) {
    for (auto& surface : impl->surfaces) {
      ReleaseInteropSurface(&surface);
    }
    LOG->Warn(
        "MacOS Metal presenter IOSurface ring unavailable: %s",
        interopFailure.c_str());
  }

  m_Impl = impl;
  m_Available = true;
  m_FailureReason.clear();

  LOG->Trace(
      "MacOS Metal presenter initialized: device='%s' target_hz=%.3f "
      "requested_size=%dx%d layer_size=%dx%d attached=0 "
      "iosurface_ring=%d iosurface_count=%d",
      [[impl->device name] UTF8String], targetHz, width, height,
      static_cast<int>(bounds.size.width), static_cast<int>(bounds.size.height),
      impl->interopReady ? 1 : 0, kMetalInteropSurfaceCount);
  return true;
}

void MacOSMetalPresenter::Shutdown() {
  if (m_Impl == nullptr) {
    m_Available = false;
    return;
  }

  MacOSMetalPresenterImpl* impl =
      static_cast<MacOSMetalPresenterImpl*>(m_Impl);
  DetachLayer();
  for (auto& surface : impl->surfaces) {
    ReleaseInteropSurface(&surface);
  }
  if (impl->layer != nil) {
    [impl->layer release];
    impl->layer = nil;
  }
  if (impl->commandQueue != nil) {
    [impl->commandQueue release];
    impl->commandQueue = nil;
  }
  if (impl->presentPipeline != nil) {
    [impl->presentPipeline release];
    impl->presentPipeline = nil;
  }
  if (impl->device != nil) {
    [impl->device release];
    impl->device = nil;
  }
  delete impl;

  m_Impl = nullptr;
  m_Available = false;
}

bool MacOSMetalPresenter::IsAvailable() const {
  return m_Available;
}

bool MacOSMetalPresenter::IsInteropReady() const {
  if (m_Impl == nullptr) {
    return false;
  }
  return static_cast<MacOSMetalPresenterImpl*>(m_Impl)->interopReady;
}

bool MacOSMetalPresenter::AttachLayerToWindow(void* nsWindow) {
  if (![NSThread isMainThread]) {
    __block bool attached = false;
    dispatch_sync(dispatch_get_main_queue(), ^{
      attached = AttachLayerToWindow(nsWindow);
    });
    return attached;
  }

  if (!IsAvailable() || nsWindow == nullptr) {
    return false;
  }

  MacOSMetalPresenterImpl* impl =
      static_cast<MacOSMetalPresenterImpl*>(m_Impl);
  if (impl->layer == nil) {
    return false;
  }
  if (impl->layerView != nil) {
    return true;
  }

  NSWindow* window = (__bridge NSWindow*)nsWindow;
  NSView* contentView = [window contentView];
  if (contentView == nil) {
    m_FailureReason = "Cannot attach Metal layer: window has no content view.";
    LOG->Warn("MacOS Metal presenter unavailable: %s", m_FailureReason.c_str());
    return false;
  }

  const NSRect bounds = [contentView bounds];
  NSView* layerView = [[NSView alloc] initWithFrame:bounds];
  [layerView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
  [layerView setWantsLayer:YES];
  [layerView setLayer:impl->layer];
  [layerView setHidden:NO];
  [contentView addSubview:layerView positioned:NSWindowAbove relativeTo:nil];
  impl->layerView = layerView;
  impl->layer.frame = bounds;

  LOG->Trace(
      "MacOS Metal presenter layer attached: view_size=%dx%d "
      "drawable_size=%dx%d",
      static_cast<int>(bounds.size.width), static_cast<int>(bounds.size.height),
      static_cast<int>(impl->layer.drawableSize.width),
      static_cast<int>(impl->layer.drawableSize.height));
  return true;
}

void MacOSMetalPresenter::DetachLayer() {
  if (![NSThread isMainThread]) {
    dispatch_sync(dispatch_get_main_queue(), ^{
      DetachLayer();
    });
    return;
  }

  if (m_Impl == nullptr) {
    return;
  }
  MacOSMetalPresenterImpl* impl =
      static_cast<MacOSMetalPresenterImpl*>(m_Impl);
  if (impl->layerView != nil) {
    [impl->layerView removeFromSuperview];
    [impl->layerView release];
    impl->layerView = nil;
    LOG->Trace("MacOS Metal presenter layer detached.");
  }
}

bool MacOSMetalPresenter::PresentInteropSurfaceAt(int index, double targetHz) {
  if (!IsInteropReady() || index < 0 || index >= kMetalInteropSurfaceCount) {
    return false;
  }

  MacOSMetalPresenterImpl* impl =
      static_cast<MacOSMetalPresenterImpl*>(m_Impl);
  if (impl->layer == nil || impl->layerView == nil ||
      impl->commandQueue == nil || impl->presentPipeline == nil) {
    return false;
  }

  id<CAMetalDrawable> drawable = [impl->layer nextDrawable];
  if (drawable == nil) {
    static bool s_warnedNoDrawable = false;
    if (!s_warnedNoDrawable) {
      LOG->Warn(
          "MacOS Metal direct-present validation skipped: "
          "CAMetalLayer returned no drawable.");
      s_warnedNoDrawable = true;
    }
    return false;
  }

  const MacOSMetalInteropSurface& surface = impl->surfaces[index];
  id<MTLCommandBuffer> commandBuffer = [impl->commandQueue commandBuffer];
  if (commandBuffer == nil) {
    return false;
  }

  MTLRenderPassDescriptor* passDescriptor =
      [MTLRenderPassDescriptor renderPassDescriptor];
  passDescriptor.colorAttachments[0].texture = [drawable texture];
  passDescriptor.colorAttachments[0].loadAction = MTLLoadActionDontCare;
  passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;

  id<MTLRenderCommandEncoder> encoder =
      [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
  if (encoder == nil) {
    return false;
  }
  [encoder setRenderPipelineState:impl->presentPipeline];
  [encoder setFragmentTexture:surface.metalTexture atIndex:0];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  [encoder endEncoding];

  const double minimumDuration =
      targetHz > 1.0 ? (1.0 / targetHz) : (1.0 / 60.0);
  if (@available(macOS 10.15, *)) {
    [commandBuffer presentDrawable:drawable
               afterMinimumDuration:minimumDuration];
  } else {
    [commandBuffer presentDrawable:drawable];
  }
  [commandBuffer commit];

  if (!impl->loggedFirstDirectPresent) {
    LOG->Trace(
        "MacOS Metal direct-present validation submitted: surface_index=%d "
        "size=%dx%d target_hz=%.3f minimum_duration_ms=%.3f "
        "orientation=flip_x_flip_y",
        index, surface.width, surface.height, targetHz,
        minimumDuration * 1000.0);
    impl->loggedFirstDirectPresent = true;
  }
  return true;
}

int MacOSMetalPresenter::InteropSurfaceCount() const {
  if (!IsInteropReady()) {
    return 0;
  }
  return kMetalInteropSurfaceCount;
}

void* MacOSMetalPresenter::InteropIOSurfaceAt(int index) const {
  if (!IsInteropReady() || index < 0 || index >= kMetalInteropSurfaceCount) {
    return nullptr;
  }
  MacOSMetalPresenterImpl* impl =
      static_cast<MacOSMetalPresenterImpl*>(m_Impl);
  return impl->surfaces[index].ioSurface;
}

int MacOSMetalPresenter::InteropSurfaceWidth() const {
  if (!IsInteropReady()) {
    return 0;
  }
  MacOSMetalPresenterImpl* impl =
      static_cast<MacOSMetalPresenterImpl*>(m_Impl);
  return impl->surfaces[0].width;
}

int MacOSMetalPresenter::InteropSurfaceHeight() const {
  if (!IsInteropReady()) {
    return 0;
  }
  MacOSMetalPresenterImpl* impl =
      static_cast<MacOSMetalPresenterImpl*>(m_Impl);
  return impl->surfaces[0].height;
}

const std::string& MacOSMetalPresenter::FailureReason() const {
  return m_FailureReason;
}
