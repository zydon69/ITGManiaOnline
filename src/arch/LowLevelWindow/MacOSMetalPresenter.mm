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
  CAMetalLayer* layer = nil;
  std::array<MacOSMetalInteropSurface, kMetalInteropSurfaceCount> surfaces;
  bool interopReady = false;
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
  impl->layer.framebufferOnly = YES;
  impl->layer.displaySyncEnabled = YES;
  impl->layer.maximumDrawableCount = 3;
  impl->layer.frame = bounds;

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
