#include "MacOSMetalPresenter.h"

#include "PerfDiagnostics.h"
#include "RageLog.h"
#include "RageTimer.h"
#include "RageUtil.h"

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <thread>

@interface SMMetalLayerView : NSView
@end

@implementation SMMetalLayerView
- (CALayer*)makeBackingLayer {
  return [CAMetalLayer layer];
}
@end

namespace {

constexpr int kMetalInteropSurfaceCount = 3;
constexpr float kMetalSlowNextDrawableSummaryMs = 8.0f;
constexpr float kMetalTraceNextDrawableMs = 16.0f;
constexpr float kMetalSlowCommandBufferMs = 12.0f;
constexpr uint64_t kMetalInitialTraceFrames = 3;
constexpr uint64_t kMetalRareSkipTraceInterval = 5000;
constexpr int kMetalMaxSolidFramesInFlight = 3;
constexpr int kMetalFrameLimiterWaitMs = 8;

id<MTLLibrary> LoadMetalLibrary(
    id<MTLDevice> device, const std::string& path, std::string* failureReason) {
  if (device == nil) {
    if (failureReason != nullptr) {
      *failureReason = "Metal device is not available.";
    }
    return nil;
  }

  std::string shaderSource;
  if (!GetFileContents(path, shaderSource)) {
    if (failureReason != nullptr) {
      *failureReason = "Failed to read " + path + ".";
    }
    return nil;
  }

  NSError* error = nil;
  NSString* source = [NSString stringWithUTF8String:shaderSource.c_str()];
  if (source == nil) {
    if (failureReason != nullptr) {
      *failureReason = path + ": Metal shader source is not valid UTF-8.";
    }
    return nil;
  }
  id<MTLLibrary> library = [device newLibraryWithSource:source
                                                options:nil
                                                  error:&error];
  if (library == nil && failureReason != nullptr) {
    *failureReason =
        path + ": " +
        (error != nil ? [[error localizedDescription] UTF8String]
                      : "Metal shader compilation failed.");
  }
  return library;
}

std::atomic<uint64_t> g_iMetalDirectPresentSubmittedFrames{0};
std::atomic<uint64_t> g_iMetalDirectPresentCompletedFrames{0};
std::atomic<uint64_t> g_iMetalDirectPresentSkippedNoDrawableFrames{0};
std::atomic<uint64_t> g_iMetalPrefetchedDrawables{0};
std::atomic<uint64_t> g_iMetalConsumedDrawables{0};
std::atomic<uint64_t> g_iMetalSlowDrawableAcquires{0};
std::atomic<uint64_t> g_iMetalDrawableMisses{0};
std::atomic_bool g_bMetalPresenterRuntimeActive{false};

void ResetMetalRuntimeStats() {
  g_iMetalDirectPresentSubmittedFrames.store(0, std::memory_order_relaxed);
  g_iMetalDirectPresentCompletedFrames.store(0, std::memory_order_relaxed);
  g_iMetalDirectPresentSkippedNoDrawableFrames.store(
      0, std::memory_order_relaxed);
  g_iMetalPrefetchedDrawables.store(0, std::memory_order_relaxed);
  g_iMetalConsumedDrawables.store(0, std::memory_order_relaxed);
  g_iMetalSlowDrawableAcquires.store(0, std::memory_order_relaxed);
  g_iMetalDrawableMisses.store(0, std::memory_order_relaxed);
}

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

struct MacOSMetalSurfaceBusyFlags {
  MacOSMetalSurfaceBusyFlags() {
    for (std::atomic_bool& flag : busy) {
      flag.store(false, std::memory_order_relaxed);
    }
  }

  std::array<std::atomic_bool, kMetalInteropSurfaceCount> busy;
};

struct ScopedAutoreleasePool {
  ScopedAutoreleasePool() : pool([[NSAutoreleasePool alloc] init]) {}
  ~ScopedAutoreleasePool() { [pool drain]; }

  NSAutoreleasePool* pool = nil;
};

struct MacOSMetalFrameLimiter {
  MacOSMetalFrameLimiter() { slotBusy.fill(false); }

  std::mutex mutex;
  std::condition_variable condition;
  int framesInFlight = 0;
  std::array<bool, kMetalMaxSolidFramesInFlight> slotBusy;
};

bool AcquireMetalFrameSlot(
    const std::shared_ptr<MacOSMetalFrameLimiter>& limiter,
    const char* label, int* slotOut = nullptr) {
  if (slotOut != nullptr) {
    *slotOut = -1;
  }
  if (!limiter) {
    return true;
  }

  std::unique_lock<std::mutex> lock(limiter->mutex);
  const bool ready = limiter->condition.wait_for(
      lock, std::chrono::milliseconds(kMetalFrameLimiterWaitMs),
      [&limiter]() {
        return limiter->framesInFlight < kMetalMaxSolidFramesInFlight;
      });
  if (!ready) {
    if (PerfDiagnosticsEnabled()) {
      LOG->Warn(
          "MacOS Metal presenter skipped %s frame: %d frames are still in "
          "flight after %dms.",
          label, limiter->framesInFlight, kMetalFrameLimiterWaitMs);
    }
    return false;
  }
  ++limiter->framesInFlight;
  for (int i = 0; i < kMetalMaxSolidFramesInFlight; ++i) {
    if (!limiter->slotBusy[i]) {
      limiter->slotBusy[i] = true;
      if (slotOut != nullptr) {
        *slotOut = i;
      }
      return true;
    }
  }

  --limiter->framesInFlight;
  if (PerfDiagnosticsEnabled()) {
    LOG->Warn(
        "MacOS Metal presenter skipped %s frame: no free frame slot after "
        "limiter acquisition.",
        label);
  }
  limiter->condition.notify_one();
  return false;
}

void ReleaseMetalFrameSlot(
    const std::shared_ptr<MacOSMetalFrameLimiter>& limiter,
    int slot = -1) {
  if (!limiter) {
    return;
  }

  {
    std::lock_guard<std::mutex> lock(limiter->mutex);
    if (slot >= 0 && slot < kMetalMaxSolidFramesInFlight) {
      limiter->slotBusy[slot] = false;
    }
    if (limiter->framesInFlight > 0) {
      --limiter->framesInFlight;
    }
  }
  limiter->condition.notify_one();
}

struct MacOSMetalPresenterImpl {
  MacOSMetalPresenterImpl() {
    solidPipelines.fill(nil);
    distanceFieldPipelines.fill(nil);
    for (auto& row : depthStates) {
      row.fill(nil);
    }
    for (auto& row : samplerStates) {
      row.fill(nil);
    }
  }

  id<MTLDevice> device = nil;
  id<MTLCommandQueue> commandQueue = nil;
  id<MTLRenderPipelineState> presentPipeline = nil;
  std::array<id<MTLRenderPipelineState>, NUM_BlendMode> solidPipelines;
  std::array<id<MTLRenderPipelineState>, NUM_BlendMode>
      distanceFieldPipelines;
  std::array<std::array<id<MTLDepthStencilState>, 2>, NUM_ZTestMode> depthStates;
  std::array<std::array<id<MTLSamplerState>, 2>, 2> samplerStates;
  std::array<id<MTLBuffer>, kMetalMaxSolidFramesInFlight> solidVertexBuffers =
      {};
  std::array<NSUInteger, kMetalMaxSolidFramesInFlight>
      solidVertexBufferCapacities = {};
  id<MTLTexture> whiteTexture = nil;
  id<MTLTexture> depthTexture = nil;
  CAMetalLayer* layer = nil;
  NSView* layerView = nil;
  NSView* replacedContentView = nil;
  std::array<MacOSMetalInteropSurface, kMetalInteropSurfaceCount> surfaces;
  std::shared_ptr<MacOSMetalSurfaceBusyFlags> surfaceBusy;
  std::shared_ptr<MacOSMetalFrameLimiter> solidFrameLimiter =
      std::make_shared<MacOSMetalFrameLimiter>();
  std::mutex drawableMutex;
  std::condition_variable drawableCondition;
  std::thread drawablePrefetchThread;
  id<CAMetalDrawable> prefetchedDrawable = nil;
  float prefetchedDrawableAcquireMs = 0.0f;
  uint64_t prefetchedDrawableSerial = 0;
  uint64_t prefetchedDrawableConsumed = 0;
  uint64_t prefetchedDrawableMisses = 0;
  uint64_t prefetchedDrawableSlowAcquires = 0;
  uint64_t directPresentSkippedNoDrawable = 0;
  bool drawablePrefetchStarted = false;
  bool drawablePrefetchStop = false;
  bool useDrawablePrefetch = false;
  bool interopReady = false;
  bool layerOwnsContentView = false;
  bool loggedFirstDirectPresent = false;
};

void ConfigureMetalLayer(
    MacOSMetalPresenterImpl* impl, CAMetalLayer* layer, NSRect bounds,
    CGSize drawableSize) {
  if (impl == nullptr || layer == nil) {
    return;
  }

  layer.device = impl->device;
  layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
  layer.opaque = YES;
  CGColorSpaceRef srgbColorSpace =
      CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  if (srgbColorSpace != nullptr) {
    layer.colorspace = srgbColorSpace;
    CGColorSpaceRelease(srgbColorSpace);
  }
  layer.framebufferOnly = YES;
  layer.displaySyncEnabled = YES;
  layer.allowsNextDrawableTimeout = YES;
  layer.maximumDrawableCount = 3;
  layer.frame = bounds;
  layer.drawableSize = drawableSize;
}

bool AdoptLayerFromView(
    MacOSMetalPresenterImpl* impl, NSView* layerView, NSRect bounds) {
  if (impl == nullptr || layerView == nil) {
    return false;
  }

  [layerView setWantsLayer:YES];
  CALayer* backingLayer = [layerView layer];
  if (![backingLayer isKindOfClass:[CAMetalLayer class]]) {
    return false;
  }

  CAMetalLayer* metalLayer = (CAMetalLayer*)backingLayer;
  const CGSize drawableSize =
      impl->layer != nil ? impl->layer.drawableSize
                         : CGSizeMake(bounds.size.width, bounds.size.height);
  [metalLayer retain];
  if (impl->layer != nil) {
    [impl->layer release];
  }
  impl->layer = metalLayer;
  ConfigureMetalLayer(impl, impl->layer, [layerView bounds], drawableSize);
  return true;
}

void StartDrawablePrefetcher(MacOSMetalPresenterImpl* impl) {
  if (impl == nullptr || impl->layer == nil || impl->drawablePrefetchStarted ||
      !impl->useDrawablePrefetch) {
    return;
  }

  RageTimer startTimer;
  impl->drawablePrefetchStop = false;
  impl->drawablePrefetchStarted = true;
  impl->drawablePrefetchThread = std::thread([impl]() {
    @autoreleasepool {
      for (;;) {
        {
          std::unique_lock<std::mutex> lock(impl->drawableMutex);
          impl->drawableCondition.wait(lock, [impl]() {
            return impl->drawablePrefetchStop ||
                   impl->prefetchedDrawable == nil;
          });
          if (impl->drawablePrefetchStop) {
            break;
          }
        }

        CAMetalLayer* layer = nil;
        {
          std::lock_guard<std::mutex> lock(impl->drawableMutex);
          layer = [impl->layer retain];
        }
        if (layer == nil) {
          std::lock_guard<std::mutex> lock(impl->drawableMutex);
          if (impl->drawablePrefetchStop) {
            break;
          }
          continue;
        }

        RageTimer acquireTimer;
        id<CAMetalDrawable> drawable = [layer nextDrawable];
        const float acquireMs = acquireTimer.GetDeltaTime() * 1000.0f;
        [layer release];

        if (drawable == nil) {
          std::lock_guard<std::mutex> lock(impl->drawableMutex);
          if (impl->drawablePrefetchStop) {
            break;
          }
          ++impl->prefetchedDrawableMisses;
          g_iMetalDrawableMisses.store(impl->prefetchedDrawableMisses);
          continue;
        }

        [drawable retain];
        bool shouldTrace = false;
        uint64_t serial = 0;
        uint64_t misses = 0;
        uint64_t slowAcquires = 0;
        {
          std::lock_guard<std::mutex> lock(impl->drawableMutex);
          if (impl->drawablePrefetchStop) {
            [drawable release];
            break;
          }
          if (impl->prefetchedDrawable != nil) {
            [drawable release];
            continue;
          }
          impl->prefetchedDrawable = drawable;
          impl->prefetchedDrawableAcquireMs = acquireMs;
          serial = ++impl->prefetchedDrawableSerial;
          g_iMetalPrefetchedDrawables.store(serial);
          if (acquireMs >= kMetalSlowNextDrawableSummaryMs) {
            slowAcquires = ++impl->prefetchedDrawableSlowAcquires;
            g_iMetalSlowDrawableAcquires.store(slowAcquires);
          } else {
            slowAcquires = impl->prefetchedDrawableSlowAcquires;
          }
          misses = impl->prefetchedDrawableMisses;
          shouldTrace =
              serial <= kMetalInitialTraceFrames ||
              acquireMs >= kMetalTraceNextDrawableMs;
        }

        if (PerfDiagnosticsEnabled() && shouldTrace) {
          LOG->Trace(
              "PERF_TRACE: macos_metal_drawable_prefetched serial=%llu "
              "acquire_ms=%.3f slow_acquires=%llu misses=%llu",
              static_cast<unsigned long long>(serial), acquireMs,
              static_cast<unsigned long long>(slowAcquires),
              static_cast<unsigned long long>(misses));
        }
      }
    }
  });

  impl->drawableCondition.notify_all();
  if (PerfDiagnosticsEnabled()) {
    LOG->Trace(
        "PERF_TRACE: macos_metal_drawable_prefetch_start total_ms=%.3f",
        startTimer.GetDeltaTime() * 1000.0f);
  }
}

void StopDrawablePrefetcher(MacOSMetalPresenterImpl* impl) {
  if (impl == nullptr || !impl->drawablePrefetchStarted) {
    return;
  }

  RageTimer stopTimer;
  {
    std::lock_guard<std::mutex> lock(impl->drawableMutex);
    impl->drawablePrefetchStop = true;
  }
  impl->drawableCondition.notify_all();
  if (impl->drawablePrefetchThread.joinable()) {
    impl->drawablePrefetchThread.join();
  }

  {
    std::lock_guard<std::mutex> lock(impl->drawableMutex);
    if (impl->prefetchedDrawable != nil) {
      [impl->prefetchedDrawable release];
      impl->prefetchedDrawable = nil;
    }
    if (PerfDiagnosticsEnabled()) {
      LOG->Trace(
          "PERF_SUMMARY: macos_metal_drawable_prefetch acquired=%llu "
          "consumed=%llu skipped_no_prefetched=%llu slow_acquires=%llu "
          "misses=%llu slow_threshold_ms=%.3f trace_threshold_ms=%.3f",
          static_cast<unsigned long long>(impl->prefetchedDrawableSerial),
          static_cast<unsigned long long>(impl->prefetchedDrawableConsumed),
          static_cast<unsigned long long>(
              impl->directPresentSkippedNoDrawable),
          static_cast<unsigned long long>(
              impl->prefetchedDrawableSlowAcquires),
          static_cast<unsigned long long>(impl->prefetchedDrawableMisses),
          kMetalSlowNextDrawableSummaryMs, kMetalTraceNextDrawableMs);
    }
    impl->prefetchedDrawableAcquireMs = 0.0f;
    impl->drawablePrefetchStarted = false;
    impl->drawablePrefetchStop = false;
  }
  if (PerfDiagnosticsEnabled()) {
    LOG->Trace(
        "PERF_TRACE: macos_metal_drawable_prefetch_stop total_ms=%.3f",
        stopTimer.GetDeltaTime() * 1000.0f);
  }
}

id<CAMetalDrawable> TakePrefetchedDrawable(
    MacOSMetalPresenterImpl* impl, float* acquireMs, uint64_t* serial,
    uint64_t* misses) {
  if (impl == nullptr) {
    return nil;
  }

  id<CAMetalDrawable> drawable = nil;
  {
    std::lock_guard<std::mutex> lock(impl->drawableMutex);
    drawable = impl->prefetchedDrawable;
    impl->prefetchedDrawable = nil;
    if (acquireMs != nullptr) {
      *acquireMs = impl->prefetchedDrawableAcquireMs;
    }
    if (serial != nullptr) {
      *serial = impl->prefetchedDrawableSerial;
    }
    if (misses != nullptr) {
      *misses = impl->prefetchedDrawableMisses;
    }
    if (drawable != nil) {
      ++impl->prefetchedDrawableConsumed;
      g_iMetalConsumedDrawables.store(impl->prefetchedDrawableConsumed);
    }
    impl->prefetchedDrawableAcquireMs = 0.0f;
  }

  impl->drawableCondition.notify_one();
  return drawable;
}

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
  NSError* error = nil;
  id<MTLLibrary> library = LoadMetalLibrary(
      device, "Data/Shaders/MSL/PresentPassthrough.metal", failureReason);
  if (library == nil) {
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

void ConfigureBlendAttachment(
    MTLRenderPipelineColorAttachmentDescriptor* attachment,
    BlendMode blendMode) {
  attachment.blendingEnabled = YES;

  MTLBlendFactor sourceRGB = MTLBlendFactorSourceAlpha;
  MTLBlendFactor destRGB = MTLBlendFactorOneMinusSourceAlpha;
  MTLBlendFactor sourceAlpha = MTLBlendFactorOne;
  MTLBlendFactor destAlpha = MTLBlendFactorOneMinusSourceAlpha;
  MTLBlendOperation rgbOperation = MTLBlendOperationAdd;
  MTLBlendOperation alphaOperation = MTLBlendOperationAdd;

  switch (blendMode) {
    case BLEND_NORMAL:
      break;
    case BLEND_ADD:
      sourceRGB = MTLBlendFactorSourceAlpha;
      destRGB = MTLBlendFactorOne;
      break;
    case BLEND_SUBTRACT:
      sourceRGB = MTLBlendFactorSourceAlpha;
      destRGB = MTLBlendFactorOneMinusSourceAlpha;
      rgbOperation = MTLBlendOperationReverseSubtract;
      break;
    case BLEND_MODULATE:
      sourceRGB = MTLBlendFactorZero;
      destRGB = MTLBlendFactorSourceColor;
      break;
    case BLEND_COPY_SRC:
      sourceRGB = MTLBlendFactorOne;
      destRGB = MTLBlendFactorZero;
      sourceAlpha = MTLBlendFactorOne;
      destAlpha = MTLBlendFactorZero;
      break;
    case BLEND_ALPHA_MASK:
      sourceRGB = MTLBlendFactorZero;
      destRGB = MTLBlendFactorOne;
      sourceAlpha = MTLBlendFactorZero;
      destAlpha = MTLBlendFactorSourceAlpha;
      break;
    case BLEND_ALPHA_KNOCK_OUT:
      sourceRGB = MTLBlendFactorZero;
      destRGB = MTLBlendFactorOne;
      sourceAlpha = MTLBlendFactorZero;
      destAlpha = MTLBlendFactorOneMinusSourceAlpha;
      break;
    case BLEND_ALPHA_MULTIPLY:
      sourceRGB = MTLBlendFactorSourceAlpha;
      destRGB = MTLBlendFactorZero;
      break;
    case BLEND_WEIGHTED_MULTIPLY:
      sourceRGB = MTLBlendFactorDestinationColor;
      destRGB = MTLBlendFactorSourceColor;
      break;
    case BLEND_INVERT_DEST:
      sourceRGB = MTLBlendFactorOne;
      destRGB = MTLBlendFactorOne;
      rgbOperation = MTLBlendOperationSubtract;
      break;
    case BLEND_NO_EFFECT:
      sourceRGB = MTLBlendFactorZero;
      destRGB = MTLBlendFactorOne;
      sourceAlpha = MTLBlendFactorZero;
      destAlpha = MTLBlendFactorOne;
      break;
    default:
      break;
  }

  attachment.sourceRGBBlendFactor = sourceRGB;
  attachment.destinationRGBBlendFactor = destRGB;
  attachment.rgbBlendOperation = rgbOperation;
  attachment.sourceAlphaBlendFactor = sourceAlpha;
  attachment.destinationAlphaBlendFactor = destAlpha;
  attachment.alphaBlendOperation = alphaOperation;
}

id<MTLRenderPipelineState> CreateSolidPipelineFromLibrary(
    id<MTLDevice> device, id<MTLLibrary> library, BlendMode blendMode,
    EffectMode effectMode, std::string* failureReason) {
  if (device == nil || library == nil) {
    if (failureReason != nullptr) {
      *failureReason = "Metal fixed-function shader library is not available.";
    }
    return nil;
  }

  const bool useDistanceField = effectMode == EffectMode_DistanceField;
  NSError* error = nil;

  id<MTLFunction> vertexFunction =
      [library newFunctionWithName:@"solid_vertex"];
  id<MTLFunction> fragmentFunction =
      [library newFunctionWithName:useDistanceField ? @"distance_field_fragment"
                                                    : @"solid_fragment"];
  if (vertexFunction == nil || fragmentFunction == nil) {
    if (failureReason != nullptr) {
      *failureReason = "Metal solid shader entry point lookup failed.";
    }
    [vertexFunction release];
    [fragmentFunction release];
    return nil;
  }

  MTLRenderPipelineDescriptor* descriptor =
      [[[MTLRenderPipelineDescriptor alloc] init] autorelease];
  descriptor.vertexFunction = vertexFunction;
  descriptor.fragmentFunction = fragmentFunction;
  descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
  ConfigureBlendAttachment(descriptor.colorAttachments[0], blendMode);

  id<MTLRenderPipelineState> pipeline =
      [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
  if (pipeline == nil && failureReason != nullptr) {
    *failureReason = error != nil ? [[error localizedDescription] UTF8String]
                                  : "Metal solid pipeline creation failed.";
  }

  [vertexFunction release];
  [fragmentFunction release];
  return pipeline;
}

id<MTLTexture> CreateWhiteTexture(id<MTLDevice> device) {
  if (device == nil) {
    return nil;
  }

  MTLTextureDescriptor* descriptor =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                         width:1
                                                        height:1
                                                     mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
  if (texture == nil) {
    return nil;
  }

  const uint8_t whitePixel[4] = {255, 255, 255, 255};
  [texture replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
             mipmapLevel:0
               withBytes:whitePixel
             bytesPerRow:4];
  return texture;
}

id<MTLTexture> CreateDepthTexture(id<MTLDevice> device, int width, int height) {
  if (device == nil || width <= 0 || height <= 0) {
    return nil;
  }

  MTLTextureDescriptor* descriptor =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                         width:width
                                                        height:height
                                                     mipmapped:NO];
  descriptor.usage = MTLTextureUsageRenderTarget;
  descriptor.storageMode = MTLStorageModePrivate;
  return [device newTextureWithDescriptor:descriptor];
}

id<MTLDepthStencilState> CreateDepthState(
    id<MTLDevice> device, ZTestMode mode, bool write) {
  if (device == nil) {
    return nil;
  }

  MTLDepthStencilDescriptor* descriptor =
      [[[MTLDepthStencilDescriptor alloc] init] autorelease];
  descriptor.depthWriteEnabled = write ? YES : NO;
  switch (mode) {
    case ZTEST_OFF:
      descriptor.depthCompareFunction = MTLCompareFunctionAlways;
      break;
    case ZTEST_WRITE_ON_PASS:
      descriptor.depthCompareFunction = MTLCompareFunctionLessEqual;
      break;
    case ZTEST_WRITE_ON_FAIL:
      descriptor.depthCompareFunction = MTLCompareFunctionGreater;
      break;
    default:
      descriptor.depthCompareFunction = MTLCompareFunctionAlways;
      break;
  }
  return [device newDepthStencilStateWithDescriptor:descriptor];
}

id<MTLSamplerState> CreateSamplerState(
    id<MTLDevice> device, bool wrapping, bool filtering) {
  if (device == nil) {
    return nil;
  }

  MTLSamplerDescriptor* descriptor =
      [[[MTLSamplerDescriptor alloc] init] autorelease];
  descriptor.sAddressMode =
      wrapping ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge;
  descriptor.tAddressMode =
      wrapping ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge;
  descriptor.minFilter =
      filtering ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
  descriptor.magFilter =
      filtering ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
  descriptor.mipFilter = MTLSamplerMipFilterNotMipmapped;
  return [device newSamplerStateWithDescriptor:descriptor];
}

id<MTLBuffer> PrepareSolidVertexBuffer(
    MacOSMetalPresenterImpl* impl, NSUInteger requiredLength, int frameSlot,
    NSMutableArray* retainedBuffers) {
  if (impl == nullptr || impl->device == nil || requiredLength == 0) {
    return nil;
  }

  if (frameSlot >= 0 && frameSlot < kMetalMaxSolidFramesInFlight) {
    id<MTLBuffer>& buffer = impl->solidVertexBuffers[frameSlot];
    NSUInteger& capacity = impl->solidVertexBufferCapacities[frameSlot];
    if (buffer == nil || capacity < requiredLength) {
      if (buffer != nil) {
        [buffer release];
        buffer = nil;
      }
      const NSUInteger grownCapacity =
          std::max<NSUInteger>(requiredLength, std::max<NSUInteger>(
                                                   capacity * 2, 256 * 1024));
      buffer = [impl->device newBufferWithLength:grownCapacity
                                         options:MTLResourceStorageModeShared];
      capacity = buffer != nil ? grownCapacity : 0;
      if (PerfDiagnosticsEnabled()) {
        LOG->Trace(
            "PERF_TRACE: macos_metal_vertex_ring_resize slot=%d "
            "required_bytes=%lu capacity_bytes=%lu ok=%d",
            frameSlot, static_cast<unsigned long>(requiredLength),
            static_cast<unsigned long>(capacity), buffer != nil ? 1 : 0);
      }
    }
    return buffer;
  }

  id<MTLBuffer> buffer =
      [impl->device newBufferWithLength:requiredLength
                                options:MTLResourceStorageModeShared];
  if (buffer != nil && retainedBuffers != nil) {
    [retainedBuffers addObject:buffer];
    [buffer release];
  }
  return buffer;
}

bool EncodeSolidBatches(
    MacOSMetalPresenterImpl* impl, id<MTLRenderCommandEncoder> encoder,
    const MacOSMetalDrawBatch* batches, size_t batchCount,
    NSMutableArray* retainedBuffers, NSMutableArray* retainedTextures,
    int frameSlot = -1) {
  if (impl == nullptr || encoder == nil || batches == nullptr) {
    return false;
  }

  size_t totalVertexCount = 0;
  for (size_t i = 0; i < batchCount; ++i) {
    const MacOSMetalDrawBatch& batch = batches[i];
    if (batch.vertices != nullptr && batch.vertexCount > 0) {
      totalVertexCount += batch.vertexCount;
    }
  }
  if (totalVertexCount == 0) {
    return false;
  }

  const NSUInteger vertexBufferLength = static_cast<NSUInteger>(
      sizeof(MacOSMetalSolidVertex) * totalVertexCount);
  id<MTLBuffer> frameVertexBuffer = PrepareSolidVertexBuffer(
      impl, vertexBufferLength, frameSlot, retainedBuffers);
  if (frameVertexBuffer == nil) {
    return false;
  }

  MacOSMetalSolidVertex* frameVertices =
      static_cast<MacOSMetalSolidVertex*>([frameVertexBuffer contents]);
  size_t frameVertexOffset = 0;

  bool encodedAny = false;
  for (size_t i = 0; i < batchCount; ++i) {
    const MacOSMetalDrawBatch& batch = batches[i];
    if (batch.vertices == nullptr || batch.vertexCount == 0) {
      continue;
    }
    const BlendMode blendMode =
        batch.blendMode >= 0 && batch.blendMode < NUM_BlendMode
            ? batch.blendMode
            : BLEND_NORMAL;
    const ZTestMode zTestMode =
        batch.zTestMode >= 0 && batch.zTestMode < NUM_ZTestMode
            ? batch.zTestMode
            : ZTEST_OFF;
    const CullMode cullMode =
        batch.cullMode >= 0 && batch.cullMode < NUM_CullMode
            ? batch.cullMode
            : CULL_NONE;
    id<MTLRenderPipelineState> pipeline =
        batch.effectMode == EffectMode_DistanceField
            ? impl->distanceFieldPipelines[blendMode]
            : impl->solidPipelines[blendMode];
    if (pipeline == nil) {
      pipeline = impl->solidPipelines[BLEND_NORMAL];
    }
    if (pipeline == nil) {
      continue;
    }

    const size_t batchVertexOffset = frameVertexOffset;
    std::memcpy(
        frameVertices + batchVertexOffset, batch.vertices,
        sizeof(MacOSMetalSolidVertex) * batch.vertexCount);
    frameVertexOffset += batch.vertexCount;

    id<MTLTexture> sourceTexture =
        batch.texture != nullptr ? (id<MTLTexture>)batch.texture
                                 : impl->whiteTexture;
    id<MTLTexture> sourceTexture2 =
        batch.texture2 != nullptr ? (id<MTLTexture>)batch.texture2
                                  : impl->whiteTexture;
    const int wrappingIndex = batch.textureWrapping ? 1 : 0;
    const int filteringIndex = batch.textureFiltering ? 1 : 0;
    id<MTLSamplerState> sampler =
        impl->samplerStates[wrappingIndex][filteringIndex];
    id<MTLDepthStencilState> depthState =
        impl->depthStates[zTestMode][batch.zWrite ? 1 : 0];
    [sourceTexture retain];
    [sourceTexture2 retain];
    [retainedTextures addObject:sourceTexture];
    [retainedTextures addObject:sourceTexture2];

    const uint32_t textureMode =
        batch.textureMode == TextureMode_Glow
            ? 1
            : (batch.textureMode == TextureMode_Add ? 2 : 0);
    const uint32_t alphaTest = batch.alphaTest ? 1 : 0;
    const uint32_t celStage =
        batch.celStage > 0 ? static_cast<uint32_t>(batch.celStage) : 0;
    const uint32_t effectMode = static_cast<uint32_t>(batch.effectMode);
    const uint32_t textureWidth =
        static_cast<uint32_t>(std::max(1, batch.textureWidth));

    [encoder setRenderPipelineState:pipeline];
    if (depthState != nil) {
      [encoder setDepthStencilState:depthState];
    }
    [encoder setFrontFacingWinding:MTLWindingCounterClockwise];
    switch (cullMode) {
      case CULL_BACK:
        [encoder setCullMode:MTLCullModeBack];
        break;
      case CULL_FRONT:
        [encoder setCullMode:MTLCullModeFront];
        break;
      case CULL_NONE:
      default:
        [encoder setCullMode:MTLCullModeNone];
        break;
    }
    [encoder setVertexBuffer:frameVertexBuffer
                      offset:sizeof(MacOSMetalSolidVertex) * batchVertexOffset
                     atIndex:0];
    [encoder setFragmentBytes:&textureMode
                       length:sizeof(textureMode)
                      atIndex:1];
    [encoder setFragmentBytes:&alphaTest
                       length:sizeof(alphaTest)
                      atIndex:2];
    [encoder setFragmentBytes:&celStage
                       length:sizeof(celStage)
                      atIndex:3];
    [encoder setFragmentBytes:&effectMode
                       length:sizeof(effectMode)
                      atIndex:4];
    [encoder setFragmentBytes:&textureWidth
                       length:sizeof(textureWidth)
                      atIndex:5];
    [encoder setFragmentTexture:sourceTexture atIndex:0];
    [encoder setFragmentTexture:sourceTexture2 atIndex:1];
    if (sampler != nil) {
      [encoder setFragmentSamplerState:sampler atIndex:0];
    }
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:static_cast<NSUInteger>(batch.vertexCount)];
    [sourceTexture release];
    [sourceTexture2 release];
    encodedAny = true;
  }
  return encodedAny;
}

}  // namespace

MacOSMetalPresenter::MacOSMetalPresenter()
    : m_Impl(nullptr), m_Available(false) {}

MacOSMetalPresenter::~MacOSMetalPresenter() {
  Shutdown();
}

bool MacOSMetalPresenter::Initialize(
    void* nsWindow, int width, int height, double targetHz,
    bool createInteropSurfaces) {
  RageTimer initTimer;
  Shutdown();
  ResetMetalRuntimeStats();

  MacOSMetalPresenterImpl* impl = new MacOSMetalPresenterImpl();
  impl->surfaceBusy = std::make_shared<MacOSMetalSurfaceBusyFlags>();
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

  std::string fixedFunctionLibraryFailure;
  id<MTLLibrary> fixedFunctionLibrary = LoadMetalLibrary(
      impl->device, "Data/Shaders/MSL/FixedFunction.metal",
      &fixedFunctionLibraryFailure);
  if (fixedFunctionLibrary == nil) {
    LOG->Warn(
        "MacOS Metal presenter fixed-function shader library unavailable: %s",
        fixedFunctionLibraryFailure.c_str());
  }

  for (int i = 0; i < NUM_BlendMode; ++i) {
    if (fixedFunctionLibrary != nil) {
      std::string solidPipelineFailure;
      impl->solidPipelines[i] = CreateSolidPipelineFromLibrary(
          impl->device, fixedFunctionLibrary, static_cast<BlendMode>(i),
          EffectMode_Normal, &solidPipelineFailure);
      if (impl->solidPipelines[i] == nil) {
        LOG->Warn(
            "MacOS Metal presenter solid pipeline unavailable for blend=%d: %s",
            i, solidPipelineFailure.c_str());
      }
      std::string distanceFieldPipelineFailure;
      impl->distanceFieldPipelines[i] = CreateSolidPipelineFromLibrary(
          impl->device, fixedFunctionLibrary, static_cast<BlendMode>(i),
          EffectMode_DistanceField, &distanceFieldPipelineFailure);
      if (impl->distanceFieldPipelines[i] == nil) {
        LOG->Warn(
            "MacOS Metal presenter distance-field pipeline unavailable for "
            "blend=%d: %s",
            i, distanceFieldPipelineFailure.c_str());
      }
    }
  }
  if (fixedFunctionLibrary != nil) {
    [fixedFunctionLibrary release];
  }
  for (int mode = 0; mode < NUM_ZTestMode; ++mode) {
    for (int write = 0; write < 2; ++write) {
      impl->depthStates[mode][write] = CreateDepthState(
          impl->device, static_cast<ZTestMode>(mode), write != 0);
      if (impl->depthStates[mode][write] == nil) {
        LOG->Warn(
            "MacOS Metal presenter depth state unavailable: mode=%d "
            "write=%d",
            mode, write);
      }
    }
  }
  for (int wrapping = 0; wrapping < 2; ++wrapping) {
    for (int filtering = 0; filtering < 2; ++filtering) {
      impl->samplerStates[wrapping][filtering] =
          CreateSamplerState(impl->device, wrapping != 0, filtering != 0);
      if (impl->samplerStates[wrapping][filtering] == nil) {
        LOG->Warn(
            "MacOS Metal presenter sampler unavailable: wrapping=%d "
            "filtering=%d",
            wrapping, filtering);
      }
    }
  }
  impl->whiteTexture = CreateWhiteTexture(impl->device);
  if (impl->whiteTexture == nil) {
    m_FailureReason = "Failed to create native Metal fallback texture.";
    for (auto& row : impl->samplerStates) {
      for (id<MTLSamplerState>& sampler : row) {
        if (sampler != nil) {
          [sampler release];
        }
      }
    }
    for (auto& row : impl->depthStates) {
      for (id<MTLDepthStencilState>& state : row) {
        if (state != nil) {
          [state release];
        }
      }
    }
    for (id<MTLRenderPipelineState>& pipeline : impl->solidPipelines) {
      if (pipeline != nil) {
        [pipeline release];
      }
    }
    for (id<MTLRenderPipelineState>& pipeline :
         impl->distanceFieldPipelines) {
      if (pipeline != nil) {
        [pipeline release];
      }
    }
    if (impl->presentPipeline != nil) {
      [impl->presentPipeline release];
    }
    [impl->commandQueue release];
    [impl->device release];
    delete impl;
    LOG->Warn("MacOS Metal presenter unavailable: %s", m_FailureReason.c_str());
    return false;
  }
  impl->depthTexture = CreateDepthTexture(impl->device, width, height);
  if (impl->depthTexture == nil) {
    m_FailureReason = "Failed to create native Metal depth texture.";
    [impl->whiteTexture release];
    for (auto& row : impl->samplerStates) {
      for (id<MTLSamplerState>& sampler : row) {
        if (sampler != nil) {
          [sampler release];
        }
      }
    }
    for (auto& row : impl->depthStates) {
      for (id<MTLDepthStencilState>& state : row) {
        if (state != nil) {
          [state release];
        }
      }
    }
    for (id<MTLRenderPipelineState>& pipeline : impl->solidPipelines) {
      if (pipeline != nil) {
        [pipeline release];
      }
    }
    for (id<MTLRenderPipelineState>& pipeline :
         impl->distanceFieldPipelines) {
      if (pipeline != nil) {
        [pipeline release];
      }
    }
    if (impl->presentPipeline != nil) {
      [impl->presentPipeline release];
    }
    [impl->commandQueue release];
    [impl->device release];
    delete impl;
    LOG->Warn("MacOS Metal presenter unavailable: %s", m_FailureReason.c_str());
    return false;
  }

  NSWindow* window = (__bridge NSWindow*)nsWindow;
  NSView* contentView = [window contentView];
  const NSRect bounds = contentView != nil ? [contentView bounds] : NSZeroRect;

  impl->layer = [[CAMetalLayer layer] retain];
  ConfigureMetalLayer(impl, impl->layer, bounds, CGSizeMake(width, height));

  bool interopReady = false;
  if (createInteropSurfaces) {
    std::string interopFailure;
    interopReady = true;
    for (auto& surface : impl->surfaces) {
      if (!CreateInteropSurface(
              impl->device, width, height, &surface, &interopFailure)) {
        interopReady = false;
        break;
      }
    }
    if (!interopReady) {
      for (auto& surface : impl->surfaces) {
        ReleaseInteropSurface(&surface);
      }
      LOG->Warn(
          "MacOS Metal presenter IOSurface ring unavailable: %s",
          interopFailure.c_str());
    }
  }
  impl->interopReady = interopReady;
  impl->useDrawablePrefetch = createInteropSurfaces;

  m_Impl = impl;
  m_Available = true;
  m_FailureReason.clear();
  g_bMetalPresenterRuntimeActive.store(true, std::memory_order_release);

  LOG->Trace(
      "MacOS Metal presenter initialized: device='%s' target_hz=%.3f "
      "requested_size=%dx%d layer_size=%dx%d attached=0 "
      "iosurface_ring=%d iosurface_count=%d total_ms=%.3f",
      [[impl->device name] UTF8String], targetHz, width, height,
      static_cast<int>(bounds.size.width), static_cast<int>(bounds.size.height),
      impl->interopReady ? 1 : 0,
      createInteropSurfaces ? kMetalInteropSurfaceCount : 0,
      initTimer.GetDeltaTime() * 1000.0f);
  return true;
}

void MacOSMetalPresenter::Shutdown() {
  if (m_Impl == nullptr) {
    m_Available = false;
    return;
  }

  RageTimer shutdownTimer;
  MacOSMetalPresenterImpl* impl =
      static_cast<MacOSMetalPresenterImpl*>(m_Impl);
  StopDrawablePrefetcher(impl);
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
  for (int i = 0; i < kMetalMaxSolidFramesInFlight; ++i) {
    if (impl->solidVertexBuffers[i] != nil) {
      [impl->solidVertexBuffers[i] release];
      impl->solidVertexBuffers[i] = nil;
    }
    impl->solidVertexBufferCapacities[i] = 0;
  }
  for (id<MTLRenderPipelineState>& pipeline : impl->solidPipelines) {
    if (pipeline != nil) {
      [pipeline release];
      pipeline = nil;
    }
  }
  for (id<MTLRenderPipelineState>& pipeline :
       impl->distanceFieldPipelines) {
    if (pipeline != nil) {
      [pipeline release];
      pipeline = nil;
    }
  }
  for (auto& row : impl->samplerStates) {
    for (id<MTLSamplerState>& sampler : row) {
      if (sampler != nil) {
        [sampler release];
        sampler = nil;
      }
    }
  }
  for (auto& row : impl->depthStates) {
    for (id<MTLDepthStencilState>& state : row) {
      if (state != nil) {
        [state release];
        state = nil;
      }
    }
  }
  if (impl->whiteTexture != nil) {
    [impl->whiteTexture release];
    impl->whiteTexture = nil;
  }
  if (impl->depthTexture != nil) {
    [impl->depthTexture release];
    impl->depthTexture = nil;
  }
  if (impl->device != nil) {
    [impl->device release];
    impl->device = nil;
  }
  delete impl;

  m_Impl = nullptr;
  m_Available = false;
  g_bMetalPresenterRuntimeActive.store(false, std::memory_order_release);
  ResetMetalRuntimeStats();
  if (PerfDiagnosticsEnabled()) {
    LOG->Trace(
        "PERF_TRACE: macos_metal_presenter_shutdown total_ms=%.3f",
        shutdownTimer.GetDeltaTime() * 1000.0f);
  }
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

bool MacOSMetalPresenter::IsLayerAttached() const {
  if (m_Impl == nullptr) {
    return false;
  }
  return static_cast<MacOSMetalPresenterImpl*>(m_Impl)->layerView != nil;
}

bool MacOSMetalPresenter::IsInteropSurfaceBusy(int index) const {
  if (!IsInteropReady() || index < 0 || index >= kMetalInteropSurfaceCount) {
    return false;
  }

  MacOSMetalPresenterImpl* impl =
      static_cast<MacOSMetalPresenterImpl*>(m_Impl);
  if (!impl->surfaceBusy) {
    return false;
  }

  return impl->surfaceBusy->busy[index].load(std::memory_order_acquire);
}

void MacOSMetalPresenter::SetLayerVisible(bool visible) {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      SetLayerVisible(visible);
    });
    return;
  }

  if (m_Impl == nullptr) {
    return;
  }

  MacOSMetalPresenterImpl* impl =
      static_cast<MacOSMetalPresenterImpl*>(m_Impl);
  if (impl->layerView != nil) {
    [impl->layerView setHidden:visible ? NO : YES];
  }
}

bool MacOSMetalPresenter::AttachLayerToWindow(void* nsWindow) {
  RageTimer attachTimer;
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
  NSWindow* window = (__bridge NSWindow*)nsWindow;
  NSView* contentView = [window contentView];
  if (contentView == nil) {
    m_FailureReason = "Cannot attach Metal layer: window has no content view.";
    LOG->Warn("MacOS Metal presenter unavailable: %s", m_FailureReason.c_str());
    return false;
  }

  const NSRect bounds = [contentView bounds];
  if (impl->layerView != nil) {
    StopDrawablePrefetcher(impl);
    [impl->layerView setFrame:bounds];
    impl->layer.frame = [impl->layerView bounds];
    [impl->layerView setHidden:NO];
    StartDrawablePrefetcher(impl);
    if (PerfDiagnosticsEnabled()) {
      LOG->Trace(
          "PERF_TRACE: macos_metal_layer_reattached total_ms=%.3f "
          "view_size=%dx%d drawable_size=%dx%d",
          attachTimer.GetDeltaTime() * 1000.0f,
          static_cast<int>(bounds.size.width),
          static_cast<int>(bounds.size.height),
          static_cast<int>(impl->layer.drawableSize.width),
          static_cast<int>(impl->layer.drawableSize.height));
    }
    return true;
  }

  NSView* layerView = [[SMMetalLayerView alloc] initWithFrame:bounds];
  [layerView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
  if (!AdoptLayerFromView(impl, layerView, [layerView bounds])) {
    [layerView release];
    m_FailureReason = "Cannot attach Metal layer: SMMetalLayerView did not create a CAMetalLayer.";
    LOG->Warn("MacOS Metal presenter unavailable: %s", m_FailureReason.c_str());
    return false;
  }
  [layerView setHidden:NO];
  [contentView addSubview:layerView positioned:NSWindowAbove relativeTo:nil];
  impl->layerView = layerView;
  StartDrawablePrefetcher(impl);

  LOG->Trace(
      "MacOS Metal presenter layer attached: view_size=%dx%d "
      "drawable_size=%dx%d total_ms=%.3f",
      static_cast<int>(bounds.size.width), static_cast<int>(bounds.size.height),
      static_cast<int>(impl->layer.drawableSize.width),
      static_cast<int>(impl->layer.drawableSize.height),
      attachTimer.GetDeltaTime() * 1000.0f);
  return true;
}

bool MacOSMetalPresenter::AttachLayerAsContentView(void* nsWindow) {
  RageTimer attachTimer;
  if (![NSThread isMainThread]) {
    __block bool attached = false;
    dispatch_sync(dispatch_get_main_queue(), ^{
      attached = AttachLayerAsContentView(nsWindow);
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

  NSWindow* window = (__bridge NSWindow*)nsWindow;
  NSView* contentView = [window contentView];
  if (contentView == nil) {
    m_FailureReason =
        "Cannot attach native Metal layer: window has no content view.";
    LOG->Warn("MacOS Metal presenter unavailable: %s", m_FailureReason.c_str());
    return false;
  }

  const NSRect bounds = [contentView bounds];
  if (impl->layerView != nil && impl->layerOwnsContentView &&
      [window contentView] == impl->layerView) {
    StopDrawablePrefetcher(impl);
    [impl->layerView setFrame:bounds];
    impl->layer.frame = [impl->layerView bounds];
    [impl->layerView setHidden:NO];
    StartDrawablePrefetcher(impl);
    LOG->Trace(
        "MacOS Metal presenter content layer reattached: view_size=%dx%d "
        "drawable_size=%dx%d total_ms=%.3f",
        static_cast<int>(bounds.size.width),
        static_cast<int>(bounds.size.height),
        static_cast<int>(impl->layer.drawableSize.width),
        static_cast<int>(impl->layer.drawableSize.height),
        attachTimer.GetDeltaTime() * 1000.0f);
    return true;
  }

  StopDrawablePrefetcher(impl);
  if (impl->layerView != nil) {
    [impl->layerView removeFromSuperview];
    [impl->layerView release];
    impl->layerView = nil;
  }
  if (impl->replacedContentView == nil) {
    impl->replacedContentView = [contentView retain];
  }

  NSView* layerView = [[SMMetalLayerView alloc] initWithFrame:bounds];
  [layerView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
  if (!AdoptLayerFromView(impl, layerView, [layerView bounds])) {
    [layerView release];
    m_FailureReason =
        "Cannot attach native Metal layer: SMMetalLayerView did not create a CAMetalLayer.";
    LOG->Warn("MacOS Metal presenter unavailable: %s", m_FailureReason.c_str());
    return false;
  }
  [layerView setHidden:NO];
  impl->layerView = layerView;
  impl->layerOwnsContentView = true;
  [window setContentView:layerView];
  StartDrawablePrefetcher(impl);

  LOG->Trace(
      "MacOS Metal presenter content layer attached: old_content_class=%s "
      "view_size=%dx%d drawable_size=%dx%d total_ms=%.3f",
      [[[impl->replacedContentView class] description] UTF8String],
      static_cast<int>(bounds.size.width),
      static_cast<int>(bounds.size.height),
      static_cast<int>(impl->layer.drawableSize.width),
      static_cast<int>(impl->layer.drawableSize.height),
      attachTimer.GetDeltaTime() * 1000.0f);
  return true;
}

void MacOSMetalPresenter::DetachLayer() {
  RageTimer detachTimer;
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
  StopDrawablePrefetcher(impl);
  NSWindow* owningWindow =
      impl->layerView != nil ? [impl->layerView window] : nil;
  if (impl->layerOwnsContentView && owningWindow != nil &&
      [owningWindow contentView] == impl->layerView &&
      impl->replacedContentView != nil) {
    [owningWindow setContentView:impl->replacedContentView];
  }
  if (impl->layerView != nil) {
    if (!impl->layerOwnsContentView) {
      [impl->layerView removeFromSuperview];
    }
    [impl->layerView release];
    impl->layerView = nil;
    impl->layerOwnsContentView = false;
    LOG->Trace(
        "MacOS Metal presenter layer detached. total_ms=%.3f",
        detachTimer.GetDeltaTime() * 1000.0f);
  }
  if (impl->replacedContentView != nil) {
    [impl->replacedContentView release];
    impl->replacedContentView = nil;
  }
}

bool MacOSMetalPresenter::PresentClearFrame(
    double red, double green, double blue, double alpha, double targetHz) {
  ScopedAutoreleasePool autoreleasePool;

  if (!IsAvailable()) {
    return false;
  }

  MacOSMetalPresenterImpl* impl =
      static_cast<MacOSMetalPresenterImpl*>(m_Impl);
  if (impl->layer == nil || impl->layerView == nil ||
      impl->commandQueue == nil) {
    return false;
  }

  std::shared_ptr<MacOSMetalFrameLimiter> frameLimiter =
      impl->solidFrameLimiter;
  int frameSlot = -1;
  if (!AcquireMetalFrameSlot(frameLimiter, "clear", &frameSlot)) {
    return false;
  }

  float nextDrawableMs = 0.0f;
  uint64_t drawableSerial = 0;
  uint64_t drawableMisses = 0;
  id<CAMetalDrawable> drawable = TakePrefetchedDrawable(
      impl, &nextDrawableMs, &drawableSerial, &drawableMisses);
  if (drawable == nil) {
    RageTimer acquireTimer;
    drawable = [impl->layer nextDrawable];
    nextDrawableMs = acquireTimer.GetDeltaTime() * 1000.0f;
    if (drawable != nil) {
      [drawable retain];
    } else {
      const uint64_t skippedFrames = ++impl->directPresentSkippedNoDrawable;
      g_iMetalDirectPresentSkippedNoDrawableFrames.store(
          skippedFrames, std::memory_order_relaxed);
      if (PerfDiagnosticsEnabled() &&
          (skippedFrames <= kMetalInitialTraceFrames ||
           skippedFrames % kMetalRareSkipTraceInterval == 0)) {
        LOG->Trace(
            "PERF_TRACE: macos_metal_clear_present "
            "skipped_no_drawable=1 skipped_frames=%llu "
            "prefetch_misses=%llu target_hz=%.3f next_drawable_ms=%.3f",
            static_cast<unsigned long long>(skippedFrames),
            static_cast<unsigned long long>(drawableMisses), targetHz,
            nextDrawableMs);
      }
      ReleaseMetalFrameSlot(frameLimiter, frameSlot);
      return false;
    }
  }

  RageTimer submitTimer;
  id<MTLCommandBuffer> commandBuffer = [impl->commandQueue commandBuffer];
  if (commandBuffer == nil) {
    [drawable release];
    ReleaseMetalFrameSlot(frameLimiter, frameSlot);
    return false;
  }

  MTLRenderPassDescriptor* passDescriptor =
      [MTLRenderPassDescriptor renderPassDescriptor];
  passDescriptor.colorAttachments[0].texture = [drawable texture];
  passDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
  passDescriptor.colorAttachments[0].clearColor =
      MTLClearColorMake(red, green, blue, alpha);
  passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;

  id<MTLRenderCommandEncoder> encoder =
      [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
  if (encoder == nil) {
    [drawable release];
    ReleaseMetalFrameSlot(frameLimiter, frameSlot);
    return false;
  }
  [encoder endEncoding];

  const double minimumDuration =
      targetHz > 1.0 ? (1.0 / targetHz) : (1.0 / 60.0);
  if (@available(macOS 10.15, *)) {
    [commandBuffer presentDrawable:drawable
               afterMinimumDuration:minimumDuration];
  } else {
    [commandBuffer presentDrawable:drawable];
  }

  const uint64_t frameIndex =
      g_iMetalDirectPresentSubmittedFrames.fetch_add(1) + 1;
  const uint64_t submitUsec = RageTimer::GetTimeSinceStartMicroseconds();
  const float encodeSubmitMs = submitTimer.GetDeltaTime() * 1000.0f;
  id<CAMetalDrawable> completionDrawable = [drawable retain];
  std::shared_ptr<MacOSMetalFrameLimiter> completionFrameLimiter =
      frameLimiter;
  const int completionFrameSlot = frameSlot;
  [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completedCommandBuffer) {
    const uint64_t completedIndex =
        g_iMetalDirectPresentCompletedFrames.fetch_add(1) + 1;
    const uint64_t completedUsec = RageTimer::GetTimeSinceStartMicroseconds();
    const float commandBufferMs =
        completedUsec >= submitUsec
            ? static_cast<float>(completedUsec - submitUsec) / 1000.0f
            : 0.0f;
    const bool traceCompletion =
        completedIndex <= kMetalInitialTraceFrames ||
        commandBufferMs >= kMetalSlowCommandBufferMs;
    if (PerfDiagnosticsEnabled() && traceCompletion) {
      LOG->Trace(
          "PERF_TRACE: macos_metal_clear_present_completed "
          "frame=%llu completed=%llu status=%lu command_buffer_ms=%.3f "
          "next_drawable_ms=%.3f encode_submit_ms=%.3f target_hz=%.3f",
          static_cast<unsigned long long>(frameIndex),
          static_cast<unsigned long long>(completedIndex),
          static_cast<unsigned long>([completedCommandBuffer status]),
          commandBufferMs, nextDrawableMs, encodeSubmitMs, targetHz);
    }
    [completionDrawable release];
    ReleaseMetalFrameSlot(completionFrameLimiter, completionFrameSlot);
  }];
  [commandBuffer commit];
  [drawable release];

  const bool traceSubmit =
      !impl->loggedFirstDirectPresent ||
      frameIndex <= kMetalInitialTraceFrames ||
      nextDrawableMs >= kMetalTraceNextDrawableMs;
  if (PerfDiagnosticsEnabled() && traceSubmit) {
    LOG->Trace(
        "PERF_TRACE: macos_metal_clear_present_submitted "
        "target_hz=%.3f minimum_duration_ms=%.3f frame=%llu "
        "frame_slot=%d prefetched_drawable_serial=%llu prefetch_misses=%llu "
        "next_drawable_ms=%.3f encode_submit_ms=%.3f",
        targetHz, minimumDuration * 1000.0,
        static_cast<unsigned long long>(frameIndex), frameSlot,
        static_cast<unsigned long long>(drawableSerial),
        static_cast<unsigned long long>(drawableMisses), nextDrawableMs,
        encodeSubmitMs);
  }
  impl->loggedFirstDirectPresent = true;
  return true;
}

bool MacOSMetalPresenter::PresentSolidBatches(
    const MacOSMetalDrawBatch* batches, size_t batchCount,
    bool clearDepth,
    double clearRed, double clearGreen, double clearBlue, double clearAlpha,
    double targetHz) {
  ScopedAutoreleasePool autoreleasePool;

  if (!IsAvailable() || batches == nullptr || batchCount == 0) {
    return PresentClearFrame(clearRed, clearGreen, clearBlue, clearAlpha,
                             targetHz);
  }
  size_t totalVertexCount = 0;
  for (size_t i = 0; i < batchCount; ++i) {
    totalVertexCount += batches[i].vertexCount;
  }
  if (totalVertexCount == 0) {
    return PresentClearFrame(clearRed, clearGreen, clearBlue, clearAlpha,
                             targetHz);
  }

  MacOSMetalPresenterImpl* impl =
      static_cast<MacOSMetalPresenterImpl*>(m_Impl);
  if (impl->layer == nil || impl->layerView == nil ||
      impl->commandQueue == nil || impl->solidPipelines[BLEND_NORMAL] == nil) {
    return false;
  }

  std::shared_ptr<MacOSMetalFrameLimiter> frameLimiter =
      impl->solidFrameLimiter;
  int frameSlot = -1;
  if (!AcquireMetalFrameSlot(frameLimiter, "solid", &frameSlot)) {
    return false;
  }

  float nextDrawableMs = 0.0f;
  uint64_t drawableSerial = 0;
  uint64_t drawableMisses = 0;
  id<CAMetalDrawable> drawable = TakePrefetchedDrawable(
      impl, &nextDrawableMs, &drawableSerial, &drawableMisses);
  if (drawable == nil) {
    RageTimer acquireTimer;
    drawable = [impl->layer nextDrawable];
    nextDrawableMs = acquireTimer.GetDeltaTime() * 1000.0f;
    if (drawable != nil) {
      [drawable retain];
    } else {
      const uint64_t skippedFrames = ++impl->directPresentSkippedNoDrawable;
      g_iMetalDirectPresentSkippedNoDrawableFrames.store(
          skippedFrames, std::memory_order_relaxed);
      if (PerfDiagnosticsEnabled() &&
          (skippedFrames <= kMetalInitialTraceFrames ||
           skippedFrames % kMetalRareSkipTraceInterval == 0)) {
        LOG->Trace(
            "PERF_TRACE: macos_metal_solid_present skipped_no_drawable=1 "
            "skipped_frames=%llu prefetch_misses=%llu target_hz=%.3f "
            "next_drawable_ms=%.3f batches=%zu vertices=%zu",
            static_cast<unsigned long long>(skippedFrames),
            static_cast<unsigned long long>(drawableMisses), targetHz,
            nextDrawableMs, batchCount, totalVertexCount);
      }
      ReleaseMetalFrameSlot(frameLimiter, frameSlot);
      return false;
    }
  }

  RageTimer submitTimer;
  id<MTLCommandBuffer> commandBuffer = [impl->commandQueue commandBuffer];
  if (commandBuffer == nil) {
    [drawable release];
    ReleaseMetalFrameSlot(frameLimiter, frameSlot);
    return false;
  }
  MTLRenderPassDescriptor* passDescriptor =
      [MTLRenderPassDescriptor renderPassDescriptor];
  passDescriptor.colorAttachments[0].texture = [drawable texture];
  passDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
  passDescriptor.colorAttachments[0].clearColor =
      MTLClearColorMake(clearRed, clearGreen, clearBlue, clearAlpha);
  passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
  if (impl->depthTexture != nil) {
    passDescriptor.depthAttachment.texture = impl->depthTexture;
    passDescriptor.depthAttachment.loadAction =
        clearDepth ? MTLLoadActionClear : MTLLoadActionLoad;
    passDescriptor.depthAttachment.clearDepth = 1.0;
    passDescriptor.depthAttachment.storeAction = MTLStoreActionStore;
  }

  id<MTLRenderCommandEncoder> encoder =
      [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
  if (encoder == nil) {
    [drawable release];
    ReleaseMetalFrameSlot(frameLimiter, frameSlot);
    return false;
  }

  NSMutableArray* retainedBuffers = [NSMutableArray arrayWithCapacity:batchCount];
  NSMutableArray* retainedTextures = [NSMutableArray arrayWithCapacity:batchCount];
  EncodeSolidBatches(
      impl, encoder, batches, batchCount, retainedBuffers, retainedTextures,
      frameSlot);
  [encoder endEncoding];

  const double minimumDuration =
      targetHz > 1.0 ? (1.0 / targetHz) : (1.0 / 60.0);
  if (@available(macOS 10.15, *)) {
    [commandBuffer presentDrawable:drawable
               afterMinimumDuration:minimumDuration];
  } else {
    [commandBuffer presentDrawable:drawable];
  }

  const uint64_t frameIndex =
      g_iMetalDirectPresentSubmittedFrames.fetch_add(1) + 1;
  const uint64_t submitUsec = RageTimer::GetTimeSinceStartMicroseconds();
  const float encodeSubmitMs = submitTimer.GetDeltaTime() * 1000.0f;
  id<CAMetalDrawable> completionDrawable = [drawable retain];
  NSArray* completionBuffers = [retainedBuffers copy];
  NSArray* completionTextures = [retainedTextures copy];
  std::shared_ptr<MacOSMetalFrameLimiter> completionFrameLimiter =
      frameLimiter;
  const int completionFrameSlot = frameSlot;
  [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completedCommandBuffer) {
    const uint64_t completedIndex =
        g_iMetalDirectPresentCompletedFrames.fetch_add(1) + 1;
    const uint64_t completedUsec = RageTimer::GetTimeSinceStartMicroseconds();
    const float commandBufferMs =
        completedUsec >= submitUsec
            ? static_cast<float>(completedUsec - submitUsec) / 1000.0f
            : 0.0f;
    const bool traceCompletion =
        completedIndex <= kMetalInitialTraceFrames ||
        commandBufferMs >= kMetalSlowCommandBufferMs;
    if (PerfDiagnosticsEnabled() && traceCompletion) {
      LOG->Trace(
          "PERF_TRACE: macos_metal_solid_present_completed "
          "frame=%llu frame_slot=%d completed=%llu status=%lu "
          "command_buffer_ms=%.3f "
          "next_drawable_ms=%.3f encode_submit_ms=%.3f target_hz=%.3f "
          "vertices=%zu",
          static_cast<unsigned long long>(frameIndex), completionFrameSlot,
          static_cast<unsigned long long>(completedIndex),
          static_cast<unsigned long>([completedCommandBuffer status]),
          commandBufferMs, nextDrawableMs, encodeSubmitMs, targetHz,
          totalVertexCount);
    }
    [completionBuffers release];
    [completionTextures release];
    [completionDrawable release];
    ReleaseMetalFrameSlot(completionFrameLimiter, completionFrameSlot);
  }];
  [commandBuffer commit];
  [drawable release];

  const bool traceSubmit =
      !impl->loggedFirstDirectPresent ||
      frameIndex <= kMetalInitialTraceFrames ||
      nextDrawableMs >= kMetalTraceNextDrawableMs;
  if (PerfDiagnosticsEnabled() && traceSubmit) {
    LOG->Trace(
        "PERF_TRACE: macos_metal_solid_present_submitted "
        "target_hz=%.3f minimum_duration_ms=%.3f frame=%llu frame_slot=%d "
        "prefetched_drawable_serial=%llu prefetch_misses=%llu "
        "next_drawable_ms=%.3f encode_submit_ms=%.3f batches=%zu "
        "vertices=%zu",
        targetHz, minimumDuration * 1000.0,
        static_cast<unsigned long long>(frameIndex), frameSlot,
        static_cast<unsigned long long>(drawableSerial),
        static_cast<unsigned long long>(drawableMisses), nextDrawableMs,
        encodeSubmitMs, batchCount, totalVertexCount);
  }
  impl->loggedFirstDirectPresent = true;
  return true;
}

void* MacOSMetalPresenter::CreateBGRA8RenderTargetTexture(
    int width, int height) {
  ScopedAutoreleasePool autoreleasePool;

  if (!IsAvailable() || width <= 0 || height <= 0) {
    return nullptr;
  }

  MacOSMetalPresenterImpl* impl =
      static_cast<MacOSMetalPresenterImpl*>(m_Impl);
  if (impl->device == nil) {
    return nullptr;
  }

  MTLTextureDescriptor* descriptor =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                         width:width
                                                        height:height
                                                     mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
  descriptor.storageMode = MTLStorageModePrivate;
  return [impl->device newTextureWithDescriptor:descriptor];
}

void* MacOSMetalPresenter::CreateDepthRenderTargetTexture(
    int width, int height) {
  ScopedAutoreleasePool autoreleasePool;

  if (!IsAvailable() || width <= 0 || height <= 0) {
    return nullptr;
  }

  MacOSMetalPresenterImpl* impl =
      static_cast<MacOSMetalPresenterImpl*>(m_Impl);
  return CreateDepthTexture(impl->device, width, height);
}

bool MacOSMetalPresenter::RenderSolidBatchesToTexture(
    void* colorTexture, void* depthTexture,
    const MacOSMetalDrawBatch* batches, size_t batchCount,
    bool preserveColor, bool clearDepth,
    double clearRed, double clearGreen, double clearBlue, double clearAlpha,
    int viewportWidth, int viewportHeight) {
  ScopedAutoreleasePool autoreleasePool;
  RageTimer timer;

  if (!IsAvailable() || colorTexture == nullptr ||
      (batches == nullptr && batchCount > 0) ||
      viewportWidth <= 0 || viewportHeight <= 0) {
    return false;
  }

  MacOSMetalPresenterImpl* impl =
      static_cast<MacOSMetalPresenterImpl*>(m_Impl);
  if (impl->commandQueue == nil || impl->solidPipelines[BLEND_NORMAL] == nil) {
    return false;
  }

  id<MTLTexture> targetTexture = (id<MTLTexture>)colorTexture;
  id<MTLTexture> targetDepth = (id<MTLTexture>)depthTexture;
  id<MTLCommandBuffer> commandBuffer = [impl->commandQueue commandBuffer];
  if (commandBuffer == nil) {
    return false;
  }

  MTLRenderPassDescriptor* passDescriptor =
      [MTLRenderPassDescriptor renderPassDescriptor];
  passDescriptor.colorAttachments[0].texture = targetTexture;
  passDescriptor.colorAttachments[0].loadAction =
      preserveColor ? MTLLoadActionLoad : MTLLoadActionClear;
  passDescriptor.colorAttachments[0].clearColor =
      MTLClearColorMake(clearRed, clearGreen, clearBlue, clearAlpha);
  passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
  if (targetDepth != nil) {
    passDescriptor.depthAttachment.texture = targetDepth;
    passDescriptor.depthAttachment.loadAction =
        clearDepth ? MTLLoadActionClear : MTLLoadActionLoad;
    passDescriptor.depthAttachment.clearDepth = 1.0;
    passDescriptor.depthAttachment.storeAction = MTLStoreActionStore;
  }

  id<MTLRenderCommandEncoder> encoder =
      [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
  if (encoder == nil) {
    return false;
  }

  MTLViewport viewport;
  viewport.originX = 0.0;
  viewport.originY = 0.0;
  viewport.width = static_cast<double>(viewportWidth);
  viewport.height = static_cast<double>(viewportHeight);
  viewport.znear = 0.0;
  viewport.zfar = 1.0;
  [encoder setViewport:viewport];

  NSMutableArray* retainedBuffers = [NSMutableArray arrayWithCapacity:batchCount];
  NSMutableArray* retainedTextures = [NSMutableArray arrayWithCapacity:batchCount];
  EncodeSolidBatches(
      impl, encoder, batches, batchCount, retainedBuffers, retainedTextures);
  [encoder endEncoding];

  NSArray* completionBuffers = [retainedBuffers copy];
  NSArray* completionTextures = [retainedTextures copy];
  [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer>) {
    [completionBuffers release];
    [completionTextures release];
  }];
  [commandBuffer commit];
  if (PerfDiagnosticsEnabled()) {
    static uint64_t s_RenderTargetSubmits = 0;
    ++s_RenderTargetSubmits;
    const float submitMs = timer.Ago() * 1000.0f;
    if (s_RenderTargetSubmits <= kMetalInitialTraceFrames ||
        s_RenderTargetSubmits % 600 == 0 || submitMs >= 2.0f) {
      LOG->Trace(
          "PERF_TRACE: macos_metal_render_target_submitted serial=%llu "
          "batches=%zu preserve=%d clear_depth=%d viewport=%dx%d "
          "submit_ms=%.3f",
          static_cast<unsigned long long>(s_RenderTargetSubmits), batchCount,
          preserveColor ? 1 : 0, clearDepth ? 1 : 0,
          viewportWidth, viewportHeight, submitMs);
    }
  }
  return true;
}

void* MacOSMetalPresenter::CreateRGBA8Texture(
    int width, int height, const void* pixels, size_t bytesPerRow) {
  ScopedAutoreleasePool autoreleasePool;

  if (!IsAvailable() || width <= 0 || height <= 0 || pixels == nullptr) {
    return nullptr;
  }

  MacOSMetalPresenterImpl* impl =
      static_cast<MacOSMetalPresenterImpl*>(m_Impl);
  if (impl->device == nil) {
    return nullptr;
  }

  MTLTextureDescriptor* descriptor =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                         width:width
                                                        height:height
                                                     mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> texture = [impl->device newTextureWithDescriptor:descriptor];
  if (texture == nil) {
    return nullptr;
  }

  [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
             mipmapLevel:0
               withBytes:pixels
             bytesPerRow:bytesPerRow];
  return texture;
}

bool MacOSMetalPresenter::UpdateRGBA8Texture(
    void* texture, int xoffset, int yoffset, int width, int height,
    const void* pixels, size_t bytesPerRow) {
  if (texture == nullptr || pixels == nullptr || width <= 0 || height <= 0 ||
      xoffset < 0 || yoffset < 0) {
    return false;
  }

  id<MTLTexture> metalTexture = (id<MTLTexture>)texture;
  if (xoffset + width > static_cast<int>([metalTexture width]) ||
      yoffset + height > static_cast<int>([metalTexture height])) {
    return false;
  }

  [metalTexture replaceRegion:MTLRegionMake2D(xoffset, yoffset, width, height)
                  mipmapLevel:0
                    withBytes:pixels
                  bytesPerRow:bytesPerRow];
  return true;
}

void MacOSMetalPresenter::ReleaseTexture(void* texture) {
  if (texture == nullptr) {
    return;
  }
  [(id<MTLTexture>)texture release];
}

bool MacOSMetalPresenter::PresentInteropSurfaceAt(int index, double targetHz) {
  ScopedAutoreleasePool autoreleasePool;

  if (!IsInteropReady() || index < 0 || index >= kMetalInteropSurfaceCount) {
    return false;
  }

  MacOSMetalPresenterImpl* impl =
      static_cast<MacOSMetalPresenterImpl*>(m_Impl);
  if (impl->layer == nil || impl->layerView == nil ||
      impl->commandQueue == nil || impl->presentPipeline == nil) {
    return false;
  }

  float nextDrawableMs = 0.0f;
  uint64_t drawableSerial = 0;
  uint64_t drawableMisses = 0;
  id<CAMetalDrawable> drawable = TakePrefetchedDrawable(
      impl, &nextDrawableMs, &drawableSerial, &drawableMisses);
  if (drawable == nil) {
    const uint64_t skippedFrames = ++impl->directPresentSkippedNoDrawable;
    g_iMetalDirectPresentSkippedNoDrawableFrames.store(
        skippedFrames, std::memory_order_relaxed);
    if (PerfDiagnosticsEnabled() &&
        (skippedFrames <= kMetalInitialTraceFrames ||
         skippedFrames % kMetalRareSkipTraceInterval == 0)) {
      LOG->Trace(
          "PERF_TRACE: macos_metal_direct_present skipped_no_prefetched_drawable=1 "
          "skipped_frames=%llu prefetch_misses=%llu target_hz=%.3f",
          static_cast<unsigned long long>(skippedFrames),
          static_cast<unsigned long long>(drawableMisses), targetHz);
    }
    return false;
  }

  const MacOSMetalInteropSurface& surface = impl->surfaces[index];
  std::shared_ptr<MacOSMetalSurfaceBusyFlags> busyFlags = impl->surfaceBusy;
  if (busyFlags &&
      busyFlags->busy[index].exchange(true, std::memory_order_acq_rel)) {
    if (PerfDiagnosticsEnabled()) {
      static uint64_t s_iMetalDirectPresentBusySurfaceFrames = 0;
      ++s_iMetalDirectPresentBusySurfaceFrames;
      if (s_iMetalDirectPresentBusySurfaceFrames <= kMetalInitialTraceFrames ||
          s_iMetalDirectPresentBusySurfaceFrames %
                  kMetalRareSkipTraceInterval ==
              0) {
        LOG->Trace(
            "PERF_TRACE: macos_metal_direct_present "
            "skipped_busy_iosurface=1 surface_index=%d frames=%llu",
            index,
            static_cast<unsigned long long>(
                s_iMetalDirectPresentBusySurfaceFrames));
      }
    }
    [drawable release];
    return false;
  }

  RageTimer submitTimer;
  id<MTLCommandBuffer> commandBuffer = [impl->commandQueue commandBuffer];
  if (commandBuffer == nil) {
    if (busyFlags) {
      busyFlags->busy[index].store(false, std::memory_order_release);
    }
    [drawable release];
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
    if (busyFlags) {
      busyFlags->busy[index].store(false, std::memory_order_release);
    }
    [drawable release];
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
  const uint64_t frameIndex =
      g_iMetalDirectPresentSubmittedFrames.fetch_add(1) + 1;
  const uint64_t submitUsec = RageTimer::GetTimeSinceStartMicroseconds();
  const float encodeSubmitMs = submitTimer.GetDeltaTime() * 1000.0f;
  id<CAMetalDrawable> completionDrawable = [drawable retain];
  [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completedCommandBuffer) {
    const uint64_t completedIndex =
        g_iMetalDirectPresentCompletedFrames.fetch_add(1) + 1;
    const uint64_t completedUsec = RageTimer::GetTimeSinceStartMicroseconds();
    const float commandBufferMs =
        (completedUsec >= submitUsec)
            ? static_cast<float>(completedUsec - submitUsec) / 1000.0f
            : 0.0f;
    const bool traceCompletion =
        completedIndex <= kMetalInitialTraceFrames ||
        commandBufferMs >= kMetalSlowCommandBufferMs;
    if (PerfDiagnosticsEnabled() && traceCompletion) {
      LOG->Trace(
          "PERF_TRACE: macos_metal_direct_present_completed "
          "frame=%llu completed=%llu status=%lu command_buffer_ms=%.3f "
          "next_drawable_ms=%.3f encode_submit_ms=%.3f target_hz=%.3f",
          static_cast<unsigned long long>(frameIndex),
          static_cast<unsigned long long>(completedIndex),
          static_cast<unsigned long>([completedCommandBuffer status]),
          commandBufferMs, nextDrawableMs, encodeSubmitMs, targetHz);
    }
    if (busyFlags) {
      busyFlags->busy[index].store(false, std::memory_order_release);
    }
    [completionDrawable release];
  }];
  [commandBuffer commit];
  [drawable release];

  const bool traceSubmit =
      !impl->loggedFirstDirectPresent ||
      frameIndex <= kMetalInitialTraceFrames ||
      nextDrawableMs >= kMetalTraceNextDrawableMs;
  if (PerfDiagnosticsEnabled() && traceSubmit) {
    LOG->Trace(
        "PERF_TRACE: macos_metal_direct_present_submitted surface_index=%d "
        "size=%dx%d target_hz=%.3f minimum_duration_ms=%.3f "
        "orientation=native frame=%llu prefetched_drawable_serial=%llu "
        "prefetch_misses=%llu next_drawable_ms=%.3f encode_submit_ms=%.3f",
        index, surface.width, surface.height, targetHz,
        minimumDuration * 1000.0,
        static_cast<unsigned long long>(frameIndex),
        static_cast<unsigned long long>(drawableSerial),
        static_cast<unsigned long long>(drawableMisses), nextDrawableMs,
        encodeSubmitMs);
  }
  impl->loggedFirstDirectPresent = true;
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

MacOSMetalPresenterRuntimeStats MacOSMetalPresenterGetRuntimeStats() {
  MacOSMetalPresenterRuntimeStats stats;
  stats.submittedFrames =
      g_iMetalDirectPresentSubmittedFrames.load(std::memory_order_relaxed);
  stats.completedFrames =
      g_iMetalDirectPresentCompletedFrames.load(std::memory_order_relaxed);
  stats.prefetchedDrawables =
      g_iMetalPrefetchedDrawables.load(std::memory_order_relaxed);
  stats.consumedDrawables =
      g_iMetalConsumedDrawables.load(std::memory_order_relaxed);
  stats.slowDrawableAcquires =
      g_iMetalSlowDrawableAcquires.load(std::memory_order_relaxed);
  stats.drawableMisses =
      g_iMetalDrawableMisses.load(std::memory_order_relaxed);
  stats.skippedNoPrefetchedDrawableFrames =
      g_iMetalDirectPresentSkippedNoDrawableFrames.load(
          std::memory_order_relaxed);
  return stats;
}

std::string MacOSMetalPresenterGetRuntimeStatsLine() {
  if (!g_bMetalPresenterRuntimeActive.load(std::memory_order_acquire)) {
    return std::string();
  }

  const MacOSMetalPresenterRuntimeStats stats =
      MacOSMetalPresenterGetRuntimeStats();
  if (stats.submittedFrames == 0 && stats.prefetchedDrawables == 0 &&
      stats.skippedNoPrefetchedDrawableFrames == 0) {
    return std::string();
  }

  return ssprintf(
      "Metal present: submitted=%llu completed=%llu skipped=%llu "
      "prefetched=%llu consumed=%llu slow=%llu misses=%llu",
      stats.submittedFrames, stats.completedFrames,
      stats.skippedNoPrefetchedDrawableFrames, stats.prefetchedDrawables,
      stats.consumedDrawables, stats.slowDrawableAcquires,
      stats.drawableMisses);
}
