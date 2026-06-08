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
#include <limits>
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
constexpr int kMetalReconfigureDrainWaitMs = 24;
constexpr int kMetalShutdownDrainWaitMs = 250;
constexpr int kMetalDrawablePrefetchRenderWaitUs = 500;
constexpr int kMetalInteropDrawablePrefetchRenderWaitUs = 500;
constexpr uint64_t kMetalDisplayPacingRefreshUsec = 2000000;

bool ShouldTraceMetalRenderThreadPrefetchWait(float waitMs, int waitUsec) {
  return waitUsec > 0 && waitMs >= static_cast<float>(waitUsec) / 1000.0f;
}

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
std::atomic<uint64_t> g_iMetalOffscreenPresentSubmittedFrames{0};
std::atomic<uint64_t> g_iMetalOffscreenPresentSkippedNoDrawableFrames{0};
std::atomic<uint64_t> g_iMetalOffscreenPresentSkippedFrameLimiterFrames{0};
std::atomic<uint64_t> g_iMetalPrefetchedDrawables{0};
std::atomic<uint64_t> g_iMetalConsumedDrawables{0};
std::atomic<uint64_t> g_iMetalSlowDrawableAcquires{0};
std::atomic<uint64_t> g_iMetalDrawableMisses{0};
std::atomic_bool g_bMetalPresenterRuntimeActive{false};
std::atomic<int> g_iMetalNativePresentationChangeReason{0};

void ResetMetalRuntimeStats() {
  g_iMetalDirectPresentSubmittedFrames.store(0, std::memory_order_relaxed);
  g_iMetalDirectPresentCompletedFrames.store(0, std::memory_order_relaxed);
  g_iMetalDirectPresentSkippedNoDrawableFrames.store(
      0, std::memory_order_relaxed);
  g_iMetalOffscreenPresentSubmittedFrames.store(0, std::memory_order_relaxed);
  g_iMetalOffscreenPresentSkippedNoDrawableFrames.store(
      0, std::memory_order_relaxed);
  g_iMetalOffscreenPresentSkippedFrameLimiterFrames.store(
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

struct MacOSMetalTimingBuckets {
  uint64_t samples = 0;
  uint64_t below1ms = 0;
  uint64_t below2ms = 0;
  uint64_t below4ms = 0;
  uint64_t below8ms = 0;
  uint64_t over8ms = 0;
  double totalMs = 0.0;
  float maxMs = 0.0f;
};

struct MacOSMetalTimingState {
  std::mutex mutex;
  MacOSMetalTimingBuckets renderThreadNextDrawableTimings;
  MacOSMetalTimingBuckets prefetchAcquireTimings;
  MacOSMetalTimingBuckets encodeSubmitTimings;
  MacOSMetalTimingBuckets commandBufferTimings;
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

bool WaitForMetalFrameLimiterIdle(
    const std::shared_ptr<MacOSMetalFrameLimiter>& limiter, int timeoutMs,
    const char* label, const char* action) {
  if (!limiter) {
    return true;
  }

  std::unique_lock<std::mutex> lock(limiter->mutex);
  const bool idle = limiter->condition.wait_for(
      lock, std::chrono::milliseconds(timeoutMs), [&limiter]() {
        return limiter->framesInFlight == 0;
      });
  if (!idle) {
    LOG->Warn(
        "MacOS Metal presenter %s while %s frames remain in flight: %d after "
        "%dms.",
        action != nullptr ? action : "wait timed out",
        label != nullptr ? label : "unknown",
        limiter->framesInFlight, timeoutMs);
  }
  return idle;
}

struct MacOSMetalPresenterImpl {
  MacOSMetalPresenterImpl() {
    solidPipelines.fill(nil);
    offscreenPresentPipelines.fill(nil);
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
  std::array<id<MTLRenderPipelineState>, 4> offscreenPresentPipelines;
  std::array<id<MTLRenderPipelineState>, NUM_BlendMode> solidPipelines;
  std::array<id<MTLRenderPipelineState>, NUM_BlendMode>
      distanceFieldPipelines;
  std::array<std::array<id<MTLDepthStencilState>, 2>, NUM_ZTestMode> depthStates;
  std::array<std::array<id<MTLSamplerState>, 2>, 2> samplerStates;
  std::array<id<MTLBuffer>, kMetalMaxSolidFramesInFlight> solidVertexBuffers =
      {};
  std::array<NSUInteger, kMetalMaxSolidFramesInFlight>
      solidVertexBufferCapacities = {};
  std::array<id<MTLBuffer>, kMetalMaxSolidFramesInFlight>
      renderTargetVertexBuffers = {};
  std::array<NSUInteger, kMetalMaxSolidFramesInFlight>
      renderTargetVertexBufferCapacities = {};
  id<MTLTexture> whiteTexture = nil;
  id<MTLTexture> depthTexture = nil;
  id<MTLTexture> offscreenPresentTexture = nil;
  id<MTLTexture> offscreenPresentDepthTexture = nil;
  int offscreenPresentWidth = 0;
  int offscreenPresentHeight = 0;
  CAMetalLayer* layer = nil;
  NSView* layerView = nil;
  NSView* replacedContentView = nil;
  std::array<MacOSMetalInteropSurface, kMetalInteropSurfaceCount> surfaces;
  std::shared_ptr<MacOSMetalSurfaceBusyFlags> surfaceBusy;
  std::shared_ptr<MacOSMetalFrameLimiter> solidFrameLimiter =
      std::make_shared<MacOSMetalFrameLimiter>();
  std::shared_ptr<MacOSMetalFrameLimiter> renderTargetFrameLimiter =
      std::make_shared<MacOSMetalFrameLimiter>();
  std::shared_ptr<MacOSMetalFrameLimiter> interopFrameLimiter =
      std::make_shared<MacOSMetalFrameLimiter>();
  std::mutex drawableMutex;
  std::condition_variable drawableCondition;
  std::shared_ptr<MacOSMetalTimingState> timingState =
      std::make_shared<MacOSMetalTimingState>();
  std::thread drawablePrefetchThread;
  id<CAMetalDrawable> prefetchedDrawable = nil;
  float prefetchedDrawableAcquireMs = 0.0f;
  uint64_t prefetchedDrawableSerial = 0;
  uint64_t prefetchedDrawableConsumed = 0;
  uint64_t prefetchedDrawableMisses = 0;
  uint64_t prefetchedDrawableSlowAcquires = 0;
  uint64_t directPresentSkippedNoDrawable = 0;
  uint64_t offscreenPresentSkippedNoDrawable = 0;
  uint64_t offscreenPresentSkippedFrameLimiter = 0;
  uint64_t offscreenPresentSubmittedFrames = 0;
  uint64_t directPresentSyncDrawableAcquires = 0;
  uint64_t prefetchRenderThreadWaits = 0;
  uint64_t prefetchRenderThreadWaitHits = 0;
  uint64_t directPresentBusySurfaceFrames = 0;
  uint64_t displayPacingLastQueryUsec = 0;
  double displayPacingMaxHz = 0.0;
  double displayPacingTargetHz = 0.0;
  uint64_t stagingCopySerial = 0;
  uint64_t renderTargetSubmitSerial = 0;
  bool drawablePrefetchStarted = false;
  bool drawablePrefetchStop = false;
  bool useDrawablePrefetch = false;
  bool interopReady = false;
  bool layerOwnsContentView = false;
  bool loggedFirstDirectPresent = false;
  std::atomic_bool layerVisible { true };
};

struct MacOSMetalDrawableAcquireInfo {
  float prefetchAcquireMs = 0.0f;
  float renderThreadWaitMs = 0.0f;
  float renderThreadNextDrawableMs = 0.0f;
  uint64_t serial = 0;
  uint64_t misses = 0;
  bool fromPrefetch = false;
  bool waitedForPrefetch = false;
};

std::shared_ptr<MacOSMetalFrameLimiter> FrameLimiterForVertexFrame(
    MacOSMetalPresenterImpl* impl, const MacOSMetalVertexFrame& frame) {
  if (impl == nullptr) {
    return nullptr;
  }
  return frame.renderTarget ? impl->renderTargetFrameLimiter
                            : impl->solidFrameLimiter;
}

void ClearVertexFrameToken(MacOSMetalVertexFrame* frame) {
  if (frame == nullptr) {
    return;
  }
  frame->vertexBuffer = nullptr;
  frame->frameSlot = -1;
  frame->capacityVertices = 0;
  frame->renderTarget = false;
}

bool ConsumeVertexFrameForCompletion(
    MacOSMetalPresenterImpl* impl, MacOSMetalVertexFrame* frame,
    std::shared_ptr<MacOSMetalFrameLimiter>* limiterOut, int* frameSlotOut) {
  if (limiterOut != nullptr) {
    *limiterOut = nullptr;
  }
  if (frameSlotOut != nullptr) {
    *frameSlotOut = -1;
  }
  if (impl == nullptr || frame == nullptr || frame->frameSlot < 0) {
    return false;
  }

  std::shared_ptr<MacOSMetalFrameLimiter> limiter =
      FrameLimiterForVertexFrame(impl, *frame);
  const int frameSlot = frame->frameSlot;
  ClearVertexFrameToken(frame);
  if (!limiter) {
    return false;
  }
  if (limiterOut != nullptr) {
    *limiterOut = limiter;
  }
  if (frameSlotOut != nullptr) {
    *frameSlotOut = frameSlot;
  }
  return true;
}

void ReleaseVertexFrameNow(
    MacOSMetalPresenterImpl* impl, MacOSMetalVertexFrame* frame) {
  std::shared_ptr<MacOSMetalFrameLimiter> limiter;
  int frameSlot = -1;
  if (ConsumeVertexFrameForCompletion(impl, frame, &limiter, &frameSlot)) {
    ReleaseMetalFrameSlot(limiter, frameSlot);
  }
}

double DetectMetalPresenterScreenMaxHz(MacOSMetalPresenterImpl* impl) {
  if (impl == nullptr) {
    return 0.0;
  }

  NSScreen* screen = nil;
  if (impl->layerView != nil && [impl->layerView window] != nil) {
    screen = [[impl->layerView window] screen];
  }
  if (screen == nil) {
    screen = [NSScreen mainScreen];
  }

  double detectedHz = 0.0;
  if (@available(macOS 12.0, *)) {
    if (screen != nil &&
        [screen respondsToSelector:@selector(maximumFramesPerSecond)]) {
      const NSInteger maxFps = [screen maximumFramesPerSecond];
      if (maxFps > 1) {
        detectedHz = static_cast<double>(maxFps);
      }
    }
  }

  if (detectedHz <= 1.0 && screen != nil) {
    NSNumber* screenNumber =
        [[screen deviceDescription] objectForKey:@"NSScreenNumber"];
    if (screenNumber != nil) {
      const CGDirectDisplayID displayID =
          static_cast<CGDirectDisplayID>([screenNumber unsignedIntValue]);
      CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
      if (mode != nullptr) {
        const double refreshRate = CGDisplayModeGetRefreshRate(mode);
        if (refreshRate > 1.0) {
          detectedHz = refreshRate;
        }
        CGDisplayModeRelease(mode);
      }
    }
  }

  return detectedHz;
}

void RecordMetalTiming(MacOSMetalTimingBuckets* buckets, float ms) {
  if (buckets == nullptr || ms < 0.0f) {
    return;
  }
  ++buckets->samples;
  buckets->totalMs += ms;
  buckets->maxMs = std::max(buckets->maxMs, ms);
  if (ms < 1.0f) {
    ++buckets->below1ms;
  } else if (ms < 2.0f) {
    ++buckets->below2ms;
  } else if (ms < 4.0f) {
    ++buckets->below4ms;
  } else if (ms < 8.0f) {
    ++buckets->below8ms;
  } else {
    ++buckets->over8ms;
  }
}

void RecordMetalTiming(
    const std::shared_ptr<MacOSMetalTimingState>& timingState,
    MacOSMetalTimingBuckets MacOSMetalTimingState::* buckets,
    float ms) {
  if (!timingState || buckets == nullptr || !PerfDiagnosticsEnabled()) {
    return;
  }
  std::lock_guard<std::mutex> lock(timingState->mutex);
  RecordMetalTiming(&(timingState.get()->*buckets), ms);
}

void AppendMetalTimingSummary(
    std::string* out, const char* label,
    const MacOSMetalTimingBuckets& buckets) {
  if (out == nullptr || label == nullptr) {
    return;
  }
  const double avgMs =
      buckets.samples > 0 ? buckets.totalMs / static_cast<double>(buckets.samples)
                          : 0.0;
  out->append(ssprintf(
      " %s_samples=%llu %s_avg_ms=%.3f %s_max_ms=%.3f "
      "%s_lt1=%llu %s_lt2=%llu %s_lt4=%llu %s_lt8=%llu %s_ge8=%llu",
      label, static_cast<unsigned long long>(buckets.samples),
      label, avgMs, label, buckets.maxMs,
      label, static_cast<unsigned long long>(buckets.below1ms),
      label, static_cast<unsigned long long>(buckets.below2ms),
      label, static_cast<unsigned long long>(buckets.below4ms),
      label, static_cast<unsigned long long>(buckets.below8ms),
      label, static_cast<unsigned long long>(buckets.over8ms)));
}

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

CGSize DrawableSizeForLayerView(NSView* layerView) {
  if (layerView == nil) {
    return CGSizeMake(1, 1);
  }
  const NSRect bounds = [layerView bounds];
  return CGSizeMake(
      std::max<CGFloat>(1, bounds.size.width),
      std::max<CGFloat>(1, bounds.size.height));
}

void PurgePrefetchedDrawable(MacOSMetalPresenterImpl* impl) {
  if (impl == nullptr) {
    return;
  }

  std::lock_guard<std::mutex> lock(impl->drawableMutex);
  if (impl->prefetchedDrawable != nil) {
    [impl->prefetchedDrawable release];
    impl->prefetchedDrawable = nil;
  }
  impl->prefetchedDrawableAcquireMs = 0.0f;
  impl->drawableCondition.notify_all();
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
        RecordMetalTiming(
            impl->timingState,
            &MacOSMetalTimingState::prefetchAcquireTimings, acquireMs);
        impl->drawableCondition.notify_all();

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

void LogMetalPresenterTimingSummary(MacOSMetalPresenterImpl* impl) {
  if (impl == nullptr || !PerfDiagnosticsEnabled()) {
    return;
  }

  std::string summary = ssprintf(
      "PERF_SUMMARY: macos_metal_drawable_prefetch acquired=%llu "
      "consumed=%llu direct_skipped_no_drawable=%llu "
      "slow_acquires=%llu misses=%llu render_waits=%llu "
      "render_wait_hits=%llu sync_acquires=%llu busy_iosurface=%llu "
      "offscreen_submitted=%llu offscreen_skipped_no_drawable=%llu "
      "offscreen_skipped_frame_limiter=%llu "
      "render_wait_budget_ms=%.3f slow_threshold_ms=%.3f "
      "trace_threshold_ms=%.3f",
      static_cast<unsigned long long>(impl->prefetchedDrawableSerial),
      static_cast<unsigned long long>(impl->prefetchedDrawableConsumed),
      static_cast<unsigned long long>(impl->directPresentSkippedNoDrawable),
      static_cast<unsigned long long>(impl->prefetchedDrawableSlowAcquires),
      static_cast<unsigned long long>(impl->prefetchedDrawableMisses),
      static_cast<unsigned long long>(impl->prefetchRenderThreadWaits),
      static_cast<unsigned long long>(impl->prefetchRenderThreadWaitHits),
      static_cast<unsigned long long>(impl->directPresentSyncDrawableAcquires),
      static_cast<unsigned long long>(impl->directPresentBusySurfaceFrames),
      static_cast<unsigned long long>(impl->offscreenPresentSubmittedFrames),
      static_cast<unsigned long long>(
          impl->offscreenPresentSkippedNoDrawable),
      static_cast<unsigned long long>(
          impl->offscreenPresentSkippedFrameLimiter),
      static_cast<float>(kMetalInteropDrawablePrefetchRenderWaitUs) / 1000.0f,
      kMetalSlowNextDrawableSummaryMs, kMetalTraceNextDrawableMs);

  const std::shared_ptr<MacOSMetalTimingState> timingState = impl->timingState;
  if (timingState) {
    std::lock_guard<std::mutex> timingLock(timingState->mutex);
    AppendMetalTimingSummary(
        &summary, "render_next_drawable",
        timingState->renderThreadNextDrawableTimings);
    AppendMetalTimingSummary(
        &summary, "prefetch_acquire", timingState->prefetchAcquireTimings);
    AppendMetalTimingSummary(
        &summary, "encode_submit", timingState->encodeSubmitTimings);
    AppendMetalTimingSummary(
        &summary, "command_buffer", timingState->commandBufferTimings);
  }
  LOG->Trace("%s", summary.c_str());
}

id<CAMetalDrawable> TakePrefetchedDrawable(
    MacOSMetalPresenterImpl* impl, MacOSMetalDrawableAcquireInfo* info,
    int waitUsec) {
  if (info != nullptr) {
    *info = MacOSMetalDrawableAcquireInfo();
  }
  if (impl == nullptr) {
    return nil;
  }

  id<CAMetalDrawable> drawable = nil;
  {
    std::unique_lock<std::mutex> lock(impl->drawableMutex);
    if (impl->prefetchedDrawable == nil && waitUsec > 0 &&
        impl->drawablePrefetchStarted && !impl->drawablePrefetchStop) {
      if (info != nullptr) {
        info->waitedForPrefetch = true;
      }
      ++impl->prefetchRenderThreadWaits;
      lock.unlock();
      impl->drawableCondition.notify_one();
      RageTimer waitTimer;
      lock.lock();
      impl->drawableCondition.wait_for(
          lock, std::chrono::microseconds(waitUsec), [impl]() {
            return impl->drawablePrefetchStop ||
                   impl->prefetchedDrawable != nil;
          });
      if (info != nullptr) {
        info->renderThreadWaitMs = waitTimer.GetDeltaTime() * 1000.0f;
      }
    }

    drawable = impl->prefetchedDrawable;
    impl->prefetchedDrawable = nil;
    if (info != nullptr) {
      info->misses = impl->prefetchedDrawableMisses;
    }
    if (drawable != nil) {
      if (info != nullptr) {
        info->fromPrefetch = true;
        info->prefetchAcquireMs = impl->prefetchedDrawableAcquireMs;
        info->serial = impl->prefetchedDrawableSerial;
      }
      ++impl->prefetchedDrawableConsumed;
      if (info != nullptr && info->waitedForPrefetch) {
        ++impl->prefetchRenderThreadWaitHits;
      }
      g_iMetalConsumedDrawables.store(impl->prefetchedDrawableConsumed);
    }
    impl->prefetchedDrawableAcquireMs = 0.0f;
  }

  impl->drawableCondition.notify_one();
  return drawable;
}

id<CAMetalDrawable> AcquireDrawableForPresent(
    MacOSMetalPresenterImpl* impl, MacOSMetalDrawableAcquireInfo* info) {
  id<CAMetalDrawable> drawable = TakePrefetchedDrawable(
      impl, info, kMetalDrawablePrefetchRenderWaitUs);
  if (drawable != nil || impl == nullptr || impl->layer == nil) {
    return drawable;
  }

  RageTimer acquireTimer;
  drawable = [impl->layer nextDrawable];
  if (info != nullptr) {
    info->renderThreadNextDrawableMs =
        acquireTimer.GetDeltaTime() * 1000.0f;
  }
  RecordMetalTiming(
      impl->timingState,
      &MacOSMetalTimingState::renderThreadNextDrawableTimings,
      info != nullptr ? info->renderThreadNextDrawableMs : 0.0f);
  if (drawable != nil) {
    [drawable retain];
    ++impl->directPresentSyncDrawableAcquires;
  }
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
    id<MTLDevice> device,
    const char* vertexFunctionName,
    std::string* failureReason) {
  NSError* error = nil;
  id<MTLLibrary> library = LoadMetalLibrary(
      device, "Data/Shaders/MSL/PresentPassthrough.metal", failureReason);
  if (library == nil) {
    return nil;
  }

  id<MTLFunction> vertexFunction =
      [library newFunctionWithName:[NSString stringWithUTF8String:
                                      vertexFunctionName != nullptr
                                          ? vertexFunctionName
                                          : "vertex_main"]];
  id<MTLFunction> fragmentFunction =
      [library newFunctionWithName:@"fragment_main"];
  if (vertexFunction == nil || fragmentFunction == nil) {
    if (failureReason != nullptr) {
      *failureReason = ssprintf(
          "Metal present shader entry point lookup failed: vertex=%s.",
          vertexFunctionName != nullptr ? vertexFunctionName : "vertex_main");
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

id<MTLRenderPipelineState> CreatePresentPipeline(
    id<MTLDevice> device, std::string* failureReason) {
  return CreatePresentPipeline(device, "vertex_main", failureReason);
}

const char* OffscreenPresentVertexFunctionName(int flipMode) {
  switch (flipMode) {
    case 0:
      return "vertex_main";
    case 1:
      return "vertex_main_flip_x";
    case 2:
      return "vertex_main_flip_y";
    case 3:
      return "vertex_main_flip_xy";
    default:
      return "vertex_main_flip_x";
  }
}

int OffscreenPresentFlipMode() {
  /*
   * Solid batches are rendered into an offscreen Metal texture before being
   * copied into the CAMetalDrawable.  That intermediate texture uses Metal's
   * texture coordinate origin, while the final fullscreen triangle presents in
   * layer space; flip Y preserves the same orientation as the direct drawable
   * path and was validated against gameplay, menus, and ActorFrameTextures.
   */
  return 2;
}

id<MTLRenderPipelineState> OffscreenPresentPipeline(
    MacOSMetalPresenterImpl* impl) {
  if (impl == nullptr) {
    return nil;
  }
  const int flipMode = OffscreenPresentFlipMode();
  return impl->offscreenPresentPipelines[flipMode];
}

void ResetDisplayPacingTarget(MacOSMetalPresenterImpl* impl) {
  if (impl == nullptr) {
    return;
  }
  impl->displayPacingLastQueryUsec = 0;
  impl->displayPacingMaxHz = 0.0;
  impl->displayPacingTargetHz = 0.0;
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

id<MTLTexture> CreateBGRA8OffscreenTexture(
    id<MTLDevice> device, int width, int height) {
  if (device == nil || width <= 0 || height <= 0) {
    return nil;
  }

  MTLTextureDescriptor* descriptor =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                         width:width
                                                        height:height
                                                     mipmapped:NO];
  descriptor.usage =
      MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  descriptor.storageMode = MTLStorageModePrivate;
  return [device newTextureWithDescriptor:descriptor];
}

void ReleaseOffscreenPresentTextures(MacOSMetalPresenterImpl* impl) {
  if (impl == nullptr) {
    return;
  }
  if (impl->offscreenPresentTexture != nil) {
    [impl->offscreenPresentTexture release];
    impl->offscreenPresentTexture = nil;
  }
  if (impl->offscreenPresentDepthTexture != nil) {
    [impl->offscreenPresentDepthTexture release];
    impl->offscreenPresentDepthTexture = nil;
  }
  impl->offscreenPresentWidth = 0;
  impl->offscreenPresentHeight = 0;
}

bool EnsureOffscreenPresentTextures(
    MacOSMetalPresenterImpl* impl, int width, int height) {
  if (impl == nullptr || impl->device == nil || width <= 0 || height <= 0) {
    return false;
  }
  if (impl->offscreenPresentTexture != nil &&
      impl->offscreenPresentDepthTexture != nil &&
      impl->offscreenPresentWidth == width &&
      impl->offscreenPresentHeight == height) {
    return true;
  }

  ReleaseOffscreenPresentTextures(impl);
  impl->offscreenPresentTexture =
      CreateBGRA8OffscreenTexture(impl->device, width, height);
  impl->offscreenPresentDepthTexture =
      CreateDepthTexture(impl->device, width, height);
  if (impl->offscreenPresentTexture == nil ||
      impl->offscreenPresentDepthTexture == nil) {
    ReleaseOffscreenPresentTextures(impl);
    return false;
  }

  impl->offscreenPresentWidth = width;
  impl->offscreenPresentHeight = height;
  if (PerfDiagnosticsEnabled()) {
    LOG->Trace(
        "PERF_TRACE: macos_metal_offscreen_present_recreated size=%dx%d",
        width, height);
  }
  return true;
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
    NSMutableArray* retainedBuffers,
    std::array<id<MTLBuffer>, kMetalMaxSolidFramesInFlight>* ringBuffers,
    std::array<NSUInteger, kMetalMaxSolidFramesInFlight>* ringCapacities,
    const char* ringLabel) {
  if (impl == nullptr || impl->device == nil || requiredLength == 0) {
    return nil;
  }

  if (frameSlot >= 0 && frameSlot < kMetalMaxSolidFramesInFlight &&
      ringBuffers != nullptr && ringCapacities != nullptr) {
    id<MTLBuffer>& buffer = (*ringBuffers)[frameSlot];
    NSUInteger& capacity = (*ringCapacities)[frameSlot];
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
            "ring=%s required_bytes=%lu capacity_bytes=%lu ok=%d",
            frameSlot, ringLabel != nullptr ? ringLabel : "unknown",
            static_cast<unsigned long>(requiredLength),
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

void TrackTextureForCommandBuffer(
    NSMutableSet* retainedTextures, id<MTLTexture> texture) {
  if (retainedTextures != nil && texture != nil) {
    [retainedTextures addObject:texture];
  }
}

void ReleaseVertexBufferRing(
    std::array<id<MTLBuffer>, kMetalMaxSolidFramesInFlight>* buffers,
    std::array<NSUInteger, kMetalMaxSolidFramesInFlight>* capacities) {
  if (buffers == nullptr || capacities == nullptr) {
    return;
  }

  for (int i = 0; i < kMetalMaxSolidFramesInFlight; ++i) {
    if ((*buffers)[i] != nil) {
      [(*buffers)[i] release];
      (*buffers)[i] = nil;
    }
    (*capacities)[i] = 0;
  }
}

bool EncodeSolidBatches(
    MacOSMetalPresenterImpl* impl, id<MTLRenderCommandEncoder> encoder,
    const MacOSMetalDrawBatch* batches, size_t batchCount,
    NSMutableArray* retainedBuffers, NSMutableSet* retainedTextures,
    int frameSlot = -1,
    std::array<id<MTLBuffer>, kMetalMaxSolidFramesInFlight>* ringBuffers =
        nullptr,
    std::array<NSUInteger, kMetalMaxSolidFramesInFlight>* ringCapacities =
        nullptr,
    const char* ringLabel = nullptr,
    size_t* frameVertexOffsetInOut = nullptr,
    size_t requiredVertexCapacity = 0) {
  if (impl == nullptr || encoder == nil || batches == nullptr) {
    return false;
  }

  size_t totalVertexCount = 0;
  size_t cpuVertexCount = 0;
  for (size_t i = 0; i < batchCount; ++i) {
    const MacOSMetalDrawBatch& batch = batches[i];
    if (batch.vertexCount == 0) {
      continue;
    }
    if (batch.vertexBuffer != nullptr || batch.vertices != nullptr) {
      totalVertexCount += batch.vertexCount;
      if (batch.vertexBuffer == nullptr) {
        cpuVertexCount += batch.vertexCount;
      }
    }
  }
  if (totalVertexCount == 0) {
    return false;
  }

  const size_t initialVertexOffset =
      frameVertexOffsetInOut != nullptr ? *frameVertexOffsetInOut : 0;
  const size_t requiredVertexCount =
      std::max(requiredVertexCapacity, initialVertexOffset + cpuVertexCount);
  id<MTLBuffer> frameVertexBuffer = nil;
  MacOSMetalSolidVertex* frameVertices = nullptr;
  if (cpuVertexCount > 0) {
    const NSUInteger vertexBufferLength = static_cast<NSUInteger>(
        sizeof(MacOSMetalSolidVertex) * requiredVertexCount);
    frameVertexBuffer = PrepareSolidVertexBuffer(
        impl, vertexBufferLength, frameSlot, retainedBuffers, ringBuffers,
        ringCapacities, ringLabel);
    if (frameVertexBuffer == nil) {
      return false;
    }
    frameVertices =
        static_cast<MacOSMetalSolidVertex*>([frameVertexBuffer contents]);
    if (frameVertices == nullptr) {
      return false;
    }
  }

  size_t frameVertexOffset = initialVertexOffset;
  size_t copiedVertexCount = 0;
  size_t copiedBatchCount = 0;
  size_t directVertexCount = 0;
  size_t directBatchCount = 0;
  RageTimer stagingCopyTimer;

  id<MTLRenderPipelineState> currentPipeline = nil;
  id<MTLDepthStencilState> currentDepthState = nil;
  id<MTLTexture> currentTexture0 = nil;
  id<MTLTexture> currentTexture1 = nil;
  id<MTLSamplerState> currentSampler = nil;
  MTLCullMode currentCullMode = MTLCullModeNone;
  bool hasCurrentDepthState = false;
  bool hasCurrentCullMode = false;
  uint32_t currentTextureMode = std::numeric_limits<uint32_t>::max();
  uint32_t currentAlphaTest = std::numeric_limits<uint32_t>::max();
  uint32_t currentCelStage = std::numeric_limits<uint32_t>::max();
  uint32_t currentEffectMode = std::numeric_limits<uint32_t>::max();
  uint32_t currentTextureWidth = std::numeric_limits<uint32_t>::max();
  MacOSMetalTransformUniforms currentTransform;
  bool hasCurrentTransform = false;

  [encoder setFrontFacingWinding:MTLWindingCounterClockwise];

  bool encodedAny = false;
  for (size_t i = 0; i < batchCount; ++i) {
    const MacOSMetalDrawBatch& batch = batches[i];
    if (batch.vertexCount == 0 ||
        (batch.vertexBuffer == nullptr && batch.vertices == nullptr)) {
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

    id<MTLBuffer> drawVertexBuffer = nil;
    NSUInteger drawVertexBufferOffset = 0;
    if (batch.vertexBuffer != nullptr) {
      drawVertexBuffer = (id<MTLBuffer>)batch.vertexBuffer;
      drawVertexBufferOffset =
          static_cast<NSUInteger>(batch.vertexBufferOffsetBytes);
      if (retainedBuffers != nil) {
        [retainedBuffers addObject:drawVertexBuffer];
      }
      directVertexCount += batch.vertexCount;
      ++directBatchCount;
    } else {
      const size_t batchVertexOffset = frameVertexOffset;
      std::memcpy(
          frameVertices + batchVertexOffset, batch.vertices,
          sizeof(MacOSMetalSolidVertex) * batch.vertexCount);
      frameVertexOffset += batch.vertexCount;
      copiedVertexCount += batch.vertexCount;
      ++copiedBatchCount;
      drawVertexBuffer = frameVertexBuffer;
      drawVertexBufferOffset =
          sizeof(MacOSMetalSolidVertex) * batchVertexOffset;
    }
    if (drawVertexBuffer == nil) {
      continue;
    }

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
    TrackTextureForCommandBuffer(retainedTextures, sourceTexture);
    TrackTextureForCommandBuffer(retainedTextures, sourceTexture2);

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

    if (pipeline != currentPipeline) {
      [encoder setRenderPipelineState:pipeline];
      currentPipeline = pipeline;
    }
    if (!hasCurrentDepthState || depthState != currentDepthState) {
      [encoder setDepthStencilState:depthState];
      currentDepthState = depthState;
      hasCurrentDepthState = true;
    }
    MTLCullMode metalCullMode = MTLCullModeNone;
    switch (cullMode) {
      case CULL_BACK:
        metalCullMode = MTLCullModeBack;
        break;
      case CULL_FRONT:
        metalCullMode = MTLCullModeFront;
        break;
      case CULL_NONE:
      default:
        metalCullMode = MTLCullModeNone;
        break;
    }
    if (!hasCurrentCullMode || metalCullMode != currentCullMode) {
      [encoder setCullMode:metalCullMode];
      currentCullMode = metalCullMode;
      hasCurrentCullMode = true;
    }
    [encoder setVertexBuffer:drawVertexBuffer
                      offset:drawVertexBufferOffset
                     atIndex:0];
    if (!hasCurrentTransform ||
        std::memcmp(
            &currentTransform, &batch.transform,
            sizeof(MacOSMetalTransformUniforms)) != 0) {
      [encoder setVertexBytes:&batch.transform
                       length:sizeof(MacOSMetalTransformUniforms)
                      atIndex:1];
      currentTransform = batch.transform;
      hasCurrentTransform = true;
    }
    if (textureMode != currentTextureMode) {
      [encoder setFragmentBytes:&textureMode
                         length:sizeof(textureMode)
                        atIndex:1];
      currentTextureMode = textureMode;
    }
    if (alphaTest != currentAlphaTest) {
      [encoder setFragmentBytes:&alphaTest
                         length:sizeof(alphaTest)
                        atIndex:2];
      currentAlphaTest = alphaTest;
    }
    if (celStage != currentCelStage) {
      [encoder setFragmentBytes:&celStage
                         length:sizeof(celStage)
                        atIndex:3];
      currentCelStage = celStage;
    }
    if (effectMode != currentEffectMode) {
      [encoder setFragmentBytes:&effectMode
                         length:sizeof(effectMode)
                        atIndex:4];
      currentEffectMode = effectMode;
    }
    if (textureWidth != currentTextureWidth) {
      [encoder setFragmentBytes:&textureWidth
                         length:sizeof(textureWidth)
                        atIndex:5];
      currentTextureWidth = textureWidth;
    }
    if (sourceTexture != currentTexture0) {
      [encoder setFragmentTexture:sourceTexture atIndex:0];
      currentTexture0 = sourceTexture;
    }
    if (sourceTexture2 != currentTexture1) {
      [encoder setFragmentTexture:sourceTexture2 atIndex:1];
      currentTexture1 = sourceTexture2;
    }
    if (sampler != nil && sampler != currentSampler) {
      [encoder setFragmentSamplerState:sampler atIndex:0];
      currentSampler = sampler;
    }
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:static_cast<NSUInteger>(batch.vertexCount)];
    encodedAny = true;
  }
  const float stagingCopyMs = stagingCopyTimer.Ago() * 1000.0f;
  if (PerfDiagnosticsEnabled()) {
    const uint64_t stagingCopySerial = ++impl->stagingCopySerial;
    if (stagingCopySerial <= kMetalInitialTraceFrames ||
        stagingCopySerial % 600 == 0 || stagingCopyMs >= 1.0f) {
      LOG->Trace(
          "PERF_TRACE: macos_metal_staging_copy serial=%llu ring=%s "
          "frame_slot=%d input_batches=%zu copied_batches=%zu vertices=%zu "
          "bytes=%zu direct_batches=%zu direct_vertices=%zu copy_ms=%.3f",
          static_cast<unsigned long long>(stagingCopySerial),
          ringLabel != nullptr ? ringLabel : "unknown", frameSlot, batchCount,
          copiedBatchCount, copiedVertexCount,
          copiedVertexCount * sizeof(MacOSMetalSolidVertex),
          directBatchCount, directVertexCount, stagingCopyMs);
    }
  }
  if (frameVertexOffsetInOut != nullptr) {
    *frameVertexOffsetInOut = frameVertexOffset;
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
  g_iMetalNativePresentationChangeReason.store(
      0, std::memory_order_release);

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
  for (int i = 0; i < 4; ++i) {
    std::string offscreenPipelineFailure;
    impl->offscreenPresentPipelines[i] =
        CreatePresentPipeline(
            impl->device, OffscreenPresentVertexFunctionName(i),
            &offscreenPipelineFailure);
    if (impl->offscreenPresentPipelines[i] == nil) {
      LOG->Warn(
          "MacOS Metal presenter offscreen-present pipeline unavailable: "
          "mode=%d vertex=%s error=%s",
          i, OffscreenPresentVertexFunctionName(i),
          offscreenPipelineFailure.c_str());
    }
  }
  if (!createInteropSurfaces) {
    for (id<MTLRenderPipelineState> pipeline :
         impl->offscreenPresentPipelines) {
      if (pipeline == nil) {
        m_FailureReason =
            "Native Metal renderer requires the offscreen-present pipeline.";
        LOG->Warn(
            "MacOS Metal presenter unavailable: %s",
            m_FailureReason.c_str());
        if (impl->presentPipeline != nil) {
          [impl->presentPipeline release];
          impl->presentPipeline = nil;
        }
        for (id<MTLRenderPipelineState>& releasePipeline :
             impl->offscreenPresentPipelines) {
          if (releasePipeline != nil) {
            [releasePipeline release];
            releasePipeline = nil;
          }
        }
        [impl->commandQueue release];
        [impl->device release];
        delete impl;
        return false;
      }
    }
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
  const bool fixedFunctionLibraryAvailable = fixedFunctionLibrary != nil;
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

  auto cleanupFailedImpl = [&impl]() {
    for (auto& surface : impl->surfaces) {
      ReleaseInteropSurface(&surface);
    }
    ReleaseVertexBufferRing(
        &impl->solidVertexBuffers, &impl->solidVertexBufferCapacities);
    ReleaseVertexBufferRing(
        &impl->renderTargetVertexBuffers,
        &impl->renderTargetVertexBufferCapacities);
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
    ReleaseOffscreenPresentTextures(impl);
    if (impl->presentPipeline != nil) {
      [impl->presentPipeline release];
      impl->presentPipeline = nil;
    }
    for (id<MTLRenderPipelineState>& pipeline :
         impl->offscreenPresentPipelines) {
      if (pipeline != nil) {
        [pipeline release];
        pipeline = nil;
      }
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
    impl = nullptr;
  };

  if (!createInteropSurfaces &&
      (!fixedFunctionLibraryAvailable ||
       impl->solidPipelines[BLEND_NORMAL] == nil ||
       impl->distanceFieldPipelines[BLEND_NORMAL] == nil)) {
    m_FailureReason =
        "Native Metal renderer requires the fixed-function Metal shader "
        "library and normal/distance-field pipelines.";
    cleanupFailedImpl();
    LOG->Warn("MacOS Metal presenter unavailable: %s", m_FailureReason.c_str());
    return false;
  }
  if (createInteropSurfaces && impl->presentPipeline == nil) {
    m_FailureReason =
        "OpenGL-to-Metal presentation bridge requires the Metal present "
        "pipeline.";
    cleanupFailedImpl();
    LOG->Warn("MacOS Metal presenter unavailable: %s", m_FailureReason.c_str());
    return false;
  }

  impl->whiteTexture = CreateWhiteTexture(impl->device);
  if (impl->whiteTexture == nil) {
    m_FailureReason = "Failed to create native Metal fallback texture.";
    cleanupFailedImpl();
    LOG->Warn("MacOS Metal presenter unavailable: %s", m_FailureReason.c_str());
    return false;
  }
  impl->depthTexture = CreateDepthTexture(impl->device, width, height);
  if (impl->depthTexture == nil) {
    m_FailureReason = "Failed to create native Metal depth texture.";
    cleanupFailedImpl();
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
  /*
   * Keep drawable acquisition off the render thread for both native Metal and
   * the OpenGL->Metal bridge.  CAMetalLayer::nextDrawable can block for one or
   * more refresh intervals during native macOS fullscreen/window transitions;
   * prefetching lets the render thread consume a ready drawable and only wait a
   * small bounded budget before falling back to synchronous acquisition.
   */
  impl->useDrawablePrefetch = true;

  m_Impl = impl;
  m_Available = true;
  m_FailureReason.clear();
  g_bMetalPresenterRuntimeActive.store(true, std::memory_order_release);

  LOG->Trace(
      "MacOS Metal presenter initialized: device='%s' target_hz=%.3f "
      "requested_size=%dx%d layer_size=%dx%d attached=0 "
      "iosurface_ring=%d iosurface_count=%d drawable_prefetch=%d "
      "total_ms=%.3f",
      [[impl->device name] UTF8String], targetHz, width, height,
      static_cast<int>(bounds.size.width), static_cast<int>(bounds.size.height),
      impl->interopReady ? 1 : 0,
      createInteropSurfaces ? kMetalInteropSurfaceCount : 0,
      impl->useDrawablePrefetch ? 1 : 0,
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
  WaitForMetalFrameLimiterIdle(
      impl->solidFrameLimiter, kMetalShutdownDrainWaitMs, "solid",
      "shutdown timed out");
  WaitForMetalFrameLimiterIdle(
      impl->renderTargetFrameLimiter, kMetalShutdownDrainWaitMs,
      "render_target", "shutdown timed out");
  WaitForMetalFrameLimiterIdle(
      impl->interopFrameLimiter, kMetalShutdownDrainWaitMs, "interop",
      "shutdown timed out");
  LogMetalPresenterTimingSummary(impl);
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
  for (id<MTLRenderPipelineState>& pipeline :
       impl->offscreenPresentPipelines) {
    if (pipeline != nil) {
      [pipeline release];
      pipeline = nil;
    }
  }
  ReleaseVertexBufferRing(
      &impl->solidVertexBuffers, &impl->solidVertexBufferCapacities);
  ReleaseVertexBufferRing(
      &impl->renderTargetVertexBuffers,
      &impl->renderTargetVertexBufferCapacities);
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
  ReleaseOffscreenPresentTextures(impl);
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

double MacOSMetalPresenter::DisplayPacingTargetHz(
    double fallbackHz, double headroomFactor) {
  const double safeFallbackHz =
      std::isfinite(fallbackHz) && fallbackHz > 1.0 ? fallbackHz : 60.0;
  const double safeHeadroomFactor =
      std::isfinite(headroomFactor) && headroomFactor > 0.0
          ? headroomFactor
          : 1.0;
  if (m_Impl == nullptr) {
    return safeFallbackHz * safeHeadroomFactor;
  }

  MacOSMetalPresenterImpl* impl =
      static_cast<MacOSMetalPresenterImpl*>(m_Impl);
  const uint64_t nowUsec = RageTimer::GetTimeSinceStartMicroseconds();
  if (impl->displayPacingMaxHz <= 1.0 ||
      impl->displayPacingLastQueryUsec == 0 ||
      nowUsec - impl->displayPacingLastQueryUsec >=
          kMetalDisplayPacingRefreshUsec) {
    const double detectedHz = DetectMetalPresenterScreenMaxHz(impl);
    impl->displayPacingMaxHz =
        detectedHz > 1.0 ? detectedHz : safeFallbackHz;
    impl->displayPacingLastQueryUsec = nowUsec;
  }

  const double targetHz = impl->displayPacingMaxHz * safeHeadroomFactor;
  if (PerfDiagnosticsEnabled() &&
      std::abs(impl->displayPacingTargetHz - targetHz) >= 0.5) {
    LOG->Trace(
        "PERF_TRACE: macos_metal_display_pacing "
        "screen_hz=%.3f target_hz=%.3f fallback_hz=%.3f headroom=%.3f",
        impl->displayPacingMaxHz, targetHz, safeFallbackHz,
        safeHeadroomFactor);
  }
  impl->displayPacingTargetHz = targetHz;
  return targetHz;
}

void MacOSMetalPresenter::SetLayerVisible(bool visible) {
  if (![NSThread isMainThread]) {
    dispatch_sync(dispatch_get_main_queue(), ^{
      SetLayerVisible(visible);
    });
    return;
  }

  if (m_Impl == nullptr) {
    return;
  }

  MacOSMetalPresenterImpl* impl =
      static_cast<MacOSMetalPresenterImpl*>(m_Impl);
  if (impl->layerVisible.exchange(visible, std::memory_order_acq_rel) ==
      visible) {
    return;
  }

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
    ResetDisplayPacingTarget(impl);
    [impl->layerView setFrame:bounds];
    impl->layer.frame = [impl->layerView bounds];
    [impl->layerView setHidden:NO];
    impl->layerVisible.store(true, std::memory_order_release);
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
    return false;
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
  impl->layerVisible.store(true, std::memory_order_release);
  [contentView addSubview:layerView positioned:NSWindowAbove relativeTo:nil];
  impl->layerView = layerView;
  ResetDisplayPacingTarget(impl);
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
    ResetDisplayPacingTarget(impl);
    [impl->layerView setFrame:bounds];
    impl->layer.frame = [impl->layerView bounds];
    [impl->layerView setHidden:NO];
    impl->layerVisible.store(true, std::memory_order_release);
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
  ResetDisplayPacingTarget(impl);
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
    if (impl->replacedContentView != nil) {
      [impl->replacedContentView release];
      impl->replacedContentView = nil;
    }
    m_FailureReason =
        "Cannot attach native Metal layer: SMMetalLayerView did not create a CAMetalLayer.";
    LOG->Warn("MacOS Metal presenter unavailable: %s", m_FailureReason.c_str());
    return false;
  }
  [layerView setHidden:NO];
  impl->layerVisible.store(true, std::memory_order_release);
  impl->layerView = layerView;
  impl->layerOwnsContentView = true;
  [window setContentView:layerView];
  ResetDisplayPacingTarget(impl);
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

bool MacOSMetalPresenter::ReconfigureAttachedLayer(
    void* nsWindow, const char* reason) {
  RageTimer reconfigureTimer;
  if (![NSThread isMainThread]) {
    __block bool reconfigured = false;
    dispatch_sync(dispatch_get_main_queue(), ^{
      reconfigured = ReconfigureAttachedLayer(nsWindow, reason);
    });
    return reconfigured;
  }

  if (!IsAvailable() || nsWindow == nullptr) {
    return false;
  }

  MacOSMetalPresenterImpl* impl =
      static_cast<MacOSMetalPresenterImpl*>(m_Impl);
  if (impl->layer == nil || impl->layerView == nil) {
    return false;
  }

  NSWindow* window = (__bridge NSWindow*)nsWindow;
  NSView* contentView = [window contentView];
  NSView* geometryView = impl->layerOwnsContentView ? impl->layerView
                                                    : contentView;
  if (geometryView == nil) {
    return false;
  }

  const NSRect beforeFrame = impl->layer.frame;
  const CGSize beforeDrawableSize = impl->layer.drawableSize;
  const bool wasPrefetchStarted = impl->drawablePrefetchStarted;

  StopDrawablePrefetcher(impl);
  ResetDisplayPacingTarget(impl);
  WaitForMetalFrameLimiterIdle(
      impl->solidFrameLimiter, kMetalReconfigureDrainWaitMs, "solid",
      "reconfigure timed out");

  const NSRect bounds = [geometryView bounds];
  [impl->layerView setFrame:bounds];
  [impl->layerView setHidden:NO];
  impl->layerVisible.store(true, std::memory_order_release);

  const CGSize drawableSize = DrawableSizeForLayerView(impl->layerView);
  ConfigureMetalLayer(impl, impl->layer, [impl->layerView bounds], drawableSize);

  const bool depthSizeChanged =
      impl->depthTexture == nil ||
      static_cast<int>(beforeDrawableSize.width) !=
          static_cast<int>(drawableSize.width) ||
      static_cast<int>(beforeDrawableSize.height) !=
          static_cast<int>(drawableSize.height);
  if (depthSizeChanged) {
    id<MTLTexture> replacementDepth = CreateDepthTexture(
        impl->device, static_cast<int>(drawableSize.width),
        static_cast<int>(drawableSize.height));
    if (replacementDepth != nil) {
      if (impl->depthTexture != nil) {
        [impl->depthTexture release];
      }
      impl->depthTexture = replacementDepth;
    } else {
      LOG->Warn(
          "MacOS Metal presenter could not recreate depth texture after "
          "window presentation change: size=%dx%d.",
          static_cast<int>(drawableSize.width),
          static_cast<int>(drawableSize.height));
    }
    ReleaseOffscreenPresentTextures(impl);
  }

  PurgePrefetchedDrawable(impl);
  if (wasPrefetchStarted || impl->useDrawablePrefetch) {
    StartDrawablePrefetcher(impl);
  }

  if (PerfDiagnosticsEnabled()) {
    NSScreen* screen = [window screen];
    const CGFloat backingScale =
        screen != nil ? [screen backingScaleFactor] : [window backingScaleFactor];
    LOG->Trace(
        "PERF_TRACE: macos_metal_layer_reconfigured reason=%s "
        "total_ms=%.3f before_frame=%dx%d after_frame=%dx%d "
        "before_drawable=%dx%d after_drawable=%dx%d backing_scale=%.3f "
        "depth_recreated=%d drain_budget_ms=%d prefetch_was_started=%d "
        "prefetch_started=%d",
        reason != nullptr ? reason : "unknown",
        reconfigureTimer.GetDeltaTime() * 1000.0f,
        static_cast<int>(beforeFrame.size.width),
        static_cast<int>(beforeFrame.size.height),
        static_cast<int>(impl->layer.frame.size.width),
        static_cast<int>(impl->layer.frame.size.height),
        static_cast<int>(beforeDrawableSize.width),
        static_cast<int>(beforeDrawableSize.height),
        static_cast<int>(impl->layer.drawableSize.width),
        static_cast<int>(impl->layer.drawableSize.height),
        static_cast<double>(backingScale),
        depthSizeChanged ? 1 : 0,
        kMetalReconfigureDrainWaitMs,
        wasPrefetchStarted ? 1 : 0,
        impl->drawablePrefetchStarted ? 1 : 0);
  }

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
  ResetDisplayPacingTarget(impl);
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
    impl->layerVisible.store(false, std::memory_order_release);
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

  MacOSMetalDrawableAcquireInfo drawableInfo;
  id<CAMetalDrawable> drawable = AcquireDrawableForPresent(impl, &drawableInfo);
  if (drawable == nil) {
    const uint64_t skippedFrames = ++impl->directPresentSkippedNoDrawable;
    g_iMetalDirectPresentSkippedNoDrawableFrames.store(
        skippedFrames, std::memory_order_relaxed);
    if (PerfDiagnosticsEnabled() &&
        (skippedFrames <= kMetalInitialTraceFrames ||
         skippedFrames % kMetalRareSkipTraceInterval == 0)) {
      LOG->Trace(
          "PERF_TRACE: macos_metal_clear_present skipped_no_drawable=1 "
          "skipped_frames=%llu prefetch_misses=%llu target_hz=%.3f "
          "prefetch_wait_ms=%.3f render_thread_next_drawable_ms=%.3f",
          static_cast<unsigned long long>(skippedFrames),
          static_cast<unsigned long long>(drawableInfo.misses), targetHz,
          drawableInfo.renderThreadWaitMs,
          drawableInfo.renderThreadNextDrawableMs);
    }
    ReleaseMetalFrameSlot(frameLimiter, frameSlot);
    return false;
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
  const std::shared_ptr<MacOSMetalTimingState> completionTimingState =
      impl->timingState;
  RecordMetalTiming(
      completionTimingState, &MacOSMetalTimingState::encodeSubmitTimings,
      encodeSubmitMs);
  id<CAMetalDrawable> completionDrawable = [drawable retain];
  id<MTLTexture> completionColorAttachment = [[drawable texture] retain];
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
    RecordMetalTiming(
        completionTimingState,
        &MacOSMetalTimingState::commandBufferTimings, commandBufferMs);
    const bool traceCompletion =
        completedIndex <= kMetalInitialTraceFrames ||
        commandBufferMs >= kMetalSlowCommandBufferMs;
    if (PerfDiagnosticsEnabled() && traceCompletion) {
      LOG->Trace(
          "PERF_TRACE: macos_metal_clear_present_completed "
          "frame=%llu completed=%llu status=%lu command_buffer_ms=%.3f "
          "drawable_source=%s prefetch_acquire_ms=%.3f "
          "prefetch_wait_ms=%.3f render_thread_next_drawable_ms=%.3f "
          "encode_submit_ms=%.3f target_hz=%.3f",
          static_cast<unsigned long long>(frameIndex),
          static_cast<unsigned long long>(completedIndex),
          static_cast<unsigned long>([completedCommandBuffer status]),
          commandBufferMs,
          drawableInfo.fromPrefetch ? "prefetch" : "sync",
          drawableInfo.prefetchAcquireMs, drawableInfo.renderThreadWaitMs,
          drawableInfo.renderThreadNextDrawableMs, encodeSubmitMs, targetHz);
    }
    [completionColorAttachment release];
    [completionDrawable release];
    ReleaseMetalFrameSlot(completionFrameLimiter, completionFrameSlot);
  }];
  [commandBuffer commit];
  [drawable release];

  const bool traceSubmit =
      !impl->loggedFirstDirectPresent ||
      frameIndex <= kMetalInitialTraceFrames ||
      drawableInfo.renderThreadNextDrawableMs >= kMetalTraceNextDrawableMs ||
      ShouldTraceMetalRenderThreadPrefetchWait(
          drawableInfo.renderThreadWaitMs, kMetalDrawablePrefetchRenderWaitUs);
  if (PerfDiagnosticsEnabled() && traceSubmit) {
    LOG->Trace(
        "PERF_TRACE: macos_metal_clear_present_submitted "
        "target_hz=%.3f minimum_duration_ms=%.3f frame=%llu "
        "frame_slot=%d drawable_source=%s prefetched_drawable_serial=%llu "
        "prefetch_misses=%llu prefetch_acquire_ms=%.3f "
        "prefetch_wait_ms=%.3f render_thread_next_drawable_ms=%.3f "
        "encode_submit_ms=%.3f",
        targetHz, minimumDuration * 1000.0,
        static_cast<unsigned long long>(frameIndex), frameSlot,
        drawableInfo.fromPrefetch ? "prefetch" : "sync",
        static_cast<unsigned long long>(drawableInfo.serial),
        static_cast<unsigned long long>(drawableInfo.misses),
        drawableInfo.prefetchAcquireMs, drawableInfo.renderThreadWaitMs,
        drawableInfo.renderThreadNextDrawableMs, encodeSubmitMs);
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

  MacOSMetalDrawableAcquireInfo drawableInfo;
  id<CAMetalDrawable> drawable = AcquireDrawableForPresent(impl, &drawableInfo);
  if (drawable == nil) {
    const uint64_t skippedFrames = ++impl->directPresentSkippedNoDrawable;
    g_iMetalDirectPresentSkippedNoDrawableFrames.store(
        skippedFrames, std::memory_order_relaxed);
    if (PerfDiagnosticsEnabled() &&
        (skippedFrames <= kMetalInitialTraceFrames ||
         skippedFrames % kMetalRareSkipTraceInterval == 0)) {
      LOG->Trace(
          "PERF_TRACE: macos_metal_solid_present skipped_no_drawable=1 "
          "skipped_frames=%llu prefetch_misses=%llu target_hz=%.3f "
          "prefetch_wait_ms=%.3f render_thread_next_drawable_ms=%.3f "
          "batches=%zu vertices=%zu",
          static_cast<unsigned long long>(skippedFrames),
          static_cast<unsigned long long>(drawableInfo.misses), targetHz,
          drawableInfo.renderThreadWaitMs,
          drawableInfo.renderThreadNextDrawableMs, batchCount,
          totalVertexCount);
    }
    ReleaseMetalFrameSlot(frameLimiter, frameSlot);
    return false;
  }

  RageTimer submitTimer;
  id<MTLCommandBuffer> commandBuffer = [impl->commandQueue commandBuffer];
  if (commandBuffer == nil) {
    [drawable release];
    ReleaseMetalFrameSlot(frameLimiter, frameSlot);
    return false;
  }
  NSMutableArray* retainedBuffers = [NSMutableArray arrayWithCapacity:batchCount];
  NSMutableSet* retainedTextures =
      [NSMutableSet setWithCapacity:batchCount * 2];
  bool encoded = false;
  bool firstPass = true;
  size_t frameVertexOffset = 0;
  size_t passStart = 0;
  while (passStart < batchCount) {
    size_t passEnd = passStart + 1;
    while (passEnd < batchCount && !batches[passEnd].clearDepthBefore) {
      ++passEnd;
    }
    bool passHasVertices = false;
    for (size_t i = passStart; i < passEnd; ++i) {
      passHasVertices =
          passHasVertices ||
          ((batches[i].vertices != nullptr ||
            batches[i].vertexBuffer != nullptr) &&
           batches[i].vertexCount > 0);
    }

    MTLRenderPassDescriptor* passDescriptor =
        [MTLRenderPassDescriptor renderPassDescriptor];
    passDescriptor.colorAttachments[0].texture = [drawable texture];
    passDescriptor.colorAttachments[0].loadAction =
        firstPass ? MTLLoadActionClear : MTLLoadActionLoad;
    passDescriptor.colorAttachments[0].clearColor =
        MTLClearColorMake(clearRed, clearGreen, clearBlue, clearAlpha);
    passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    if (impl->depthTexture != nil) {
      const bool clearThisPass =
          (firstPass && clearDepth) || batches[passStart].clearDepthBefore;
      passDescriptor.depthAttachment.texture = impl->depthTexture;
      passDescriptor.depthAttachment.loadAction =
          clearThisPass ? MTLLoadActionClear : MTLLoadActionLoad;
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

    const bool encodedPass =
        !passHasVertices ||
        EncodeSolidBatches(
            impl, encoder, batches + passStart, passEnd - passStart,
            retainedBuffers, retainedTextures, frameSlot,
            &impl->solidVertexBuffers, &impl->solidVertexBufferCapacities,
            "solid", &frameVertexOffset, totalVertexCount);
    [encoder endEncoding];
    if (!encodedPass) {
      [drawable release];
      ReleaseMetalFrameSlot(frameLimiter, frameSlot);
      return false;
    }
    encoded = true;
    firstPass = false;
    passStart = passEnd;
  }
  if (!encoded) {
    [drawable release];
    ReleaseMetalFrameSlot(frameLimiter, frameSlot);
    return false;
  }

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
  const std::shared_ptr<MacOSMetalTimingState> completionTimingState =
      impl->timingState;
  RecordMetalTiming(
      completionTimingState, &MacOSMetalTimingState::encodeSubmitTimings,
      encodeSubmitMs);
  id<CAMetalDrawable> completionDrawable = [drawable retain];
  id<MTLTexture> completionColorAttachment = [[drawable texture] retain];
  id<MTLTexture> completionDepthAttachment =
      impl->depthTexture != nil ? [impl->depthTexture retain] : nil;
  NSArray* completionBuffers = [retainedBuffers copy];
  NSSet* completionTextures = [retainedTextures copy];
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
    RecordMetalTiming(
        completionTimingState,
        &MacOSMetalTimingState::commandBufferTimings, commandBufferMs);
    const bool traceCompletion =
        completedIndex <= kMetalInitialTraceFrames ||
        commandBufferMs >= kMetalSlowCommandBufferMs;
    if (PerfDiagnosticsEnabled() && traceCompletion) {
      LOG->Trace(
          "PERF_TRACE: macos_metal_solid_present_completed "
          "frame=%llu frame_slot=%d completed=%llu status=%lu "
          "command_buffer_ms=%.3f drawable_source=%s "
          "prefetch_acquire_ms=%.3f prefetch_wait_ms=%.3f "
          "render_thread_next_drawable_ms=%.3f "
          "encode_submit_ms=%.3f target_hz=%.3f "
          "vertices=%zu",
          static_cast<unsigned long long>(frameIndex), completionFrameSlot,
          static_cast<unsigned long long>(completedIndex),
          static_cast<unsigned long>([completedCommandBuffer status]),
          commandBufferMs,
          drawableInfo.fromPrefetch ? "prefetch" : "sync",
          drawableInfo.prefetchAcquireMs, drawableInfo.renderThreadWaitMs,
          drawableInfo.renderThreadNextDrawableMs, encodeSubmitMs, targetHz,
          totalVertexCount);
    }
    [completionBuffers release];
    [completionTextures release];
    [completionDepthAttachment release];
    [completionColorAttachment release];
    [completionDrawable release];
    ReleaseMetalFrameSlot(completionFrameLimiter, completionFrameSlot);
  }];
  [commandBuffer commit];
  [drawable release];

  const bool traceSubmit =
      !impl->loggedFirstDirectPresent ||
      frameIndex <= kMetalInitialTraceFrames ||
      drawableInfo.renderThreadNextDrawableMs >= kMetalTraceNextDrawableMs ||
      ShouldTraceMetalRenderThreadPrefetchWait(
          drawableInfo.renderThreadWaitMs, kMetalDrawablePrefetchRenderWaitUs);
  if (PerfDiagnosticsEnabled() && traceSubmit) {
    LOG->Trace(
        "PERF_TRACE: macos_metal_solid_present_submitted "
        "target_hz=%.3f minimum_duration_ms=%.3f frame=%llu frame_slot=%d "
        "drawable_source=%s prefetched_drawable_serial=%llu "
        "prefetch_misses=%llu prefetch_acquire_ms=%.3f "
        "prefetch_wait_ms=%.3f render_thread_next_drawable_ms=%.3f "
        "encode_submit_ms=%.3f batches=%zu "
        "vertices=%zu",
        targetHz, minimumDuration * 1000.0,
        static_cast<unsigned long long>(frameIndex), frameSlot,
        drawableInfo.fromPrefetch ? "prefetch" : "sync",
        static_cast<unsigned long long>(drawableInfo.serial),
        static_cast<unsigned long long>(drawableInfo.misses),
        drawableInfo.prefetchAcquireMs, drawableInfo.renderThreadWaitMs,
        drawableInfo.renderThreadNextDrawableMs, encodeSubmitMs, batchCount,
        totalVertexCount);
  }
  impl->loggedFirstDirectPresent = true;
  return true;
}

bool MacOSMetalPresenter::PresentSolidBatchesOffscreenFirst(
    const MacOSMetalDrawBatch* batches, size_t batchCount,
    bool clearDepth,
    double clearRed, double clearGreen, double clearBlue, double clearAlpha,
    double targetHz,
    MacOSMetalVertexFrame* preparedVertexFrame) {
  ScopedAutoreleasePool autoreleasePool;

  if (!IsAvailable() || (batches == nullptr && batchCount > 0)) {
    return false;
  }

  MacOSMetalPresenterImpl* impl =
      static_cast<MacOSMetalPresenterImpl*>(m_Impl);
  if (impl->layer == nil || impl->layerView == nil ||
      impl->commandQueue == nil) {
    return false;
  }
  id<MTLRenderPipelineState> presentPipeline =
      OffscreenPresentPipeline(impl);
  if (presentPipeline == nil) {
    LOG->Warn(
        "MacOS Metal offscreen present skipped: present pipeline unavailable.");
    return false;
  }

  const CGSize drawableSize = impl->layer.drawableSize;
  const int width = std::max(1, static_cast<int>(drawableSize.width));
  const int height = std::max(1, static_cast<int>(drawableSize.height));
  if (!EnsureOffscreenPresentTextures(impl, width, height)) {
    LOG->Warn(
        "MacOS Metal offscreen present unavailable: size=%dx%d.",
        width, height);
    return false;
  }

  if (!RenderSolidBatchesToTexture(
          impl->offscreenPresentTexture,
          impl->offscreenPresentDepthTexture, batches, batchCount,
          false, clearDepth, clearRed, clearGreen, clearBlue, clearAlpha,
          width, height, nullptr, preparedVertexFrame)) {
    return false;
  }

  MacOSMetalDrawableAcquireInfo drawableInfo;
  id<CAMetalDrawable> drawable = TakePrefetchedDrawable(
      impl, &drawableInfo, kMetalDrawablePrefetchRenderWaitUs);
  if (drawable == nil) {
    const uint64_t skippedFrames = ++impl->offscreenPresentSkippedNoDrawable;
    g_iMetalOffscreenPresentSkippedNoDrawableFrames.store(
        skippedFrames, std::memory_order_relaxed);
    if (PerfDiagnosticsEnabled() &&
        (skippedFrames <= kMetalInitialTraceFrames ||
         skippedFrames % kMetalRareSkipTraceInterval == 0)) {
      LOG->Trace(
          "PERF_TRACE: macos_metal_offscreen_present "
          "skipped_no_drawable=1 skipped_frames=%llu "
          "prefetch_misses=%llu render_wait_ms=%.3f "
          "render_wait_budget_us=%d target_hz=%.3f size=%dx%d",
          static_cast<unsigned long long>(skippedFrames),
          static_cast<unsigned long long>(drawableInfo.misses),
          drawableInfo.renderThreadWaitMs, kMetalDrawablePrefetchRenderWaitUs,
          targetHz, width, height);
    }
    return true;
  }

  std::shared_ptr<MacOSMetalFrameLimiter> frameLimiter =
      impl->solidFrameLimiter;
  int frameSlot = -1;
  if (!AcquireMetalFrameSlot(frameLimiter, "offscreen_present", &frameSlot)) {
    [drawable release];
    const uint64_t skippedFrames =
        ++impl->offscreenPresentSkippedFrameLimiter;
    g_iMetalOffscreenPresentSkippedFrameLimiterFrames.store(
        skippedFrames, std::memory_order_relaxed);
    if (PerfDiagnosticsEnabled() &&
        (skippedFrames <= kMetalInitialTraceFrames ||
         skippedFrames % kMetalRareSkipTraceInterval == 0)) {
      LOG->Trace(
          "PERF_TRACE: macos_metal_offscreen_present "
          "skipped_frame_limiter=1 skipped_frames=%llu target_hz=%.3f "
          "size=%dx%d",
          static_cast<unsigned long long>(skippedFrames), targetHz,
          width, height);
    }
    return true;
  }

  RageTimer submitTimer;
  id<MTLCommandBuffer> commandBuffer = [impl->commandQueue commandBuffer];
  if (commandBuffer == nil) {
    [drawable release];
    ReleaseMetalFrameSlot(frameLimiter, frameSlot);
    return false;
  }

  id<MTLTexture> sourceTexture = [impl->offscreenPresentTexture retain];
  MTLRenderPassDescriptor* passDescriptor =
      [MTLRenderPassDescriptor renderPassDescriptor];
  passDescriptor.colorAttachments[0].texture = [drawable texture];
  passDescriptor.colorAttachments[0].loadAction = MTLLoadActionDontCare;
  passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> encoder =
      [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
  if (encoder == nil) {
    [sourceTexture release];
    [drawable release];
    ReleaseMetalFrameSlot(frameLimiter, frameSlot);
    return false;
  }
  [encoder setRenderPipelineState:presentPipeline];
  [encoder setFragmentTexture:sourceTexture atIndex:0];
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

  const uint64_t frameIndex = ++impl->offscreenPresentSubmittedFrames;
  g_iMetalOffscreenPresentSubmittedFrames.store(
      frameIndex, std::memory_order_relaxed);
  const uint64_t submitUsec = RageTimer::GetTimeSinceStartMicroseconds();
  const float encodeSubmitMs = submitTimer.GetDeltaTime() * 1000.0f;
  const std::shared_ptr<MacOSMetalTimingState> completionTimingState =
      impl->timingState;
  RecordMetalTiming(
      completionTimingState, &MacOSMetalTimingState::encodeSubmitTimings,
      encodeSubmitMs);
  std::shared_ptr<MacOSMetalFrameLimiter> completionFrameLimiter =
      frameLimiter;
  const int completionFrameSlot = frameSlot;
  id<CAMetalDrawable> completionDrawable = [drawable retain];
  [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completedCommandBuffer) {
    const uint64_t completedUsec = RageTimer::GetTimeSinceStartMicroseconds();
    const float commandBufferMs =
        completedUsec >= submitUsec
            ? static_cast<float>(completedUsec - submitUsec) / 1000.0f
            : 0.0f;
    RecordMetalTiming(
        completionTimingState,
        &MacOSMetalTimingState::commandBufferTimings, commandBufferMs);
    const bool traceCompletion =
        frameIndex <= kMetalInitialTraceFrames ||
        commandBufferMs >= kMetalSlowCommandBufferMs;
    if (PerfDiagnosticsEnabled() && traceCompletion) {
      LOG->Trace(
          "PERF_TRACE: macos_metal_offscreen_present_completed "
          "frame=%llu frame_slot=%d status=%lu command_buffer_ms=%.3f "
          "flip_mode=%d drawable_source=%s render_thread_next_drawable_ms=%.3f "
          "encode_submit_ms=%.3f target_hz=%.3f",
          static_cast<unsigned long long>(frameIndex), completionFrameSlot,
          static_cast<unsigned long>([completedCommandBuffer status]),
          commandBufferMs, OffscreenPresentFlipMode(),
          drawableInfo.fromPrefetch ? "prefetch" : "sync",
          drawableInfo.renderThreadNextDrawableMs, encodeSubmitMs, targetHz);
    }
    [sourceTexture release];
    [completionDrawable release];
    ReleaseMetalFrameSlot(completionFrameLimiter, completionFrameSlot);
  }];
  [commandBuffer commit];
  [drawable release];

  const bool traceSubmit =
      frameIndex <= kMetalInitialTraceFrames ||
      drawableInfo.renderThreadNextDrawableMs >= kMetalTraceNextDrawableMs ||
      encodeSubmitMs >= 2.0f;
  if (PerfDiagnosticsEnabled() && traceSubmit) {
    LOG->Trace(
        "PERF_TRACE: macos_metal_offscreen_present_submitted "
        "frame=%llu frame_slot=%d target_hz=%.3f "
        "minimum_duration_ms=%.3f flip_mode=%d drawable_source=%s "
        "prefetch_misses=%llu prefetch_acquire_ms=%.3f "
        "render_thread_next_drawable_ms=%.3f encode_submit_ms=%.3f "
        "size=%dx%d skipped_no_drawable=%llu",
        static_cast<unsigned long long>(frameIndex), frameSlot, targetHz,
        minimumDuration * 1000.0, OffscreenPresentFlipMode(),
        drawableInfo.fromPrefetch ? "prefetch" : "sync",
        static_cast<unsigned long long>(drawableInfo.misses),
        drawableInfo.prefetchAcquireMs,
        drawableInfo.renderThreadNextDrawableMs, encodeSubmitMs,
        width, height,
        static_cast<unsigned long long>(
            impl->offscreenPresentSkippedNoDrawable));
  }
  return true;
}

bool MacOSMetalPresenter::BeginSolidVertexFrame(
    size_t vertexCapacity, MacOSMetalVertexFrame* frame,
    MacOSMetalSolidVertex** vertices) {
  if (frame != nullptr && frame->frameSlot >= 0) {
    LOG->Warn(
        "MacOS Metal solid vertex writer refused to overwrite an active "
        "frame token slot=%d.",
        frame->frameSlot);
    if (vertices != nullptr) {
      *vertices = nullptr;
    }
    return false;
  }
  if (frame != nullptr) {
    frame->vertexBuffer = nullptr;
    frame->frameSlot = -1;
    frame->capacityVertices = 0;
    frame->renderTarget = false;
  }
  if (vertices != nullptr) {
    *vertices = nullptr;
  }
  if (!IsAvailable() || frame == nullptr || vertices == nullptr ||
      vertexCapacity == 0) {
    return false;
  }

  MacOSMetalPresenterImpl* impl =
      static_cast<MacOSMetalPresenterImpl*>(m_Impl);
  if (impl == nullptr || impl->device == nil) {
    return false;
  }
  if (vertexCapacity >
      std::numeric_limits<NSUInteger>::max() /
          sizeof(MacOSMetalSolidVertex)) {
    return false;
  }

  int frameSlot = -1;
  std::shared_ptr<MacOSMetalFrameLimiter> frameLimiter =
      impl->solidFrameLimiter;
  if (!AcquireMetalFrameSlot(frameLimiter, "solid_vertex_writer",
                             &frameSlot)) {
    return false;
  }

  const NSUInteger requiredLength = static_cast<NSUInteger>(
      sizeof(MacOSMetalSolidVertex) * vertexCapacity);
  id<MTLBuffer> vertexBuffer = PrepareSolidVertexBuffer(
      impl, requiredLength, frameSlot, nil, &impl->solidVertexBuffers,
      &impl->solidVertexBufferCapacities, "solid_direct");
  if (vertexBuffer == nil) {
    ReleaseMetalFrameSlot(frameLimiter, frameSlot);
    return false;
  }

  MacOSMetalSolidVertex* writableVertices =
      static_cast<MacOSMetalSolidVertex*>([vertexBuffer contents]);
  if (writableVertices == nullptr) {
    ReleaseMetalFrameSlot(frameLimiter, frameSlot);
    return false;
  }

  frame->vertexBuffer = vertexBuffer;
  frame->frameSlot = frameSlot;
  frame->capacityVertices = vertexCapacity;
  frame->renderTarget = false;
  *vertices = writableVertices;
  return true;
}

bool MacOSMetalPresenter::BeginRenderTargetVertexFrame(
    size_t vertexCapacity, MacOSMetalVertexFrame* frame,
    MacOSMetalSolidVertex** vertices) {
  if (frame != nullptr && frame->frameSlot >= 0) {
    LOG->Warn(
        "MacOS Metal render-target vertex writer refused to overwrite an "
        "active frame token slot=%d.",
        frame->frameSlot);
    if (vertices != nullptr) {
      *vertices = nullptr;
    }
    return false;
  }
  if (frame != nullptr) {
    frame->vertexBuffer = nullptr;
    frame->frameSlot = -1;
    frame->capacityVertices = 0;
    frame->renderTarget = true;
  }
  if (vertices != nullptr) {
    *vertices = nullptr;
  }
  if (!IsAvailable() || frame == nullptr || vertices == nullptr ||
      vertexCapacity == 0) {
    return false;
  }

  MacOSMetalPresenterImpl* impl =
      static_cast<MacOSMetalPresenterImpl*>(m_Impl);
  if (impl == nullptr || impl->device == nil) {
    return false;
  }
  if (vertexCapacity >
      std::numeric_limits<NSUInteger>::max() /
          sizeof(MacOSMetalSolidVertex)) {
    return false;
  }

  int frameSlot = -1;
  std::shared_ptr<MacOSMetalFrameLimiter> frameLimiter =
      impl->renderTargetFrameLimiter;
  if (!AcquireMetalFrameSlot(frameLimiter, "render_target_vertex_writer",
                             &frameSlot)) {
    return false;
  }

  const NSUInteger requiredLength = static_cast<NSUInteger>(
      sizeof(MacOSMetalSolidVertex) * vertexCapacity);
  id<MTLBuffer> vertexBuffer = PrepareSolidVertexBuffer(
      impl, requiredLength, frameSlot, nil, &impl->renderTargetVertexBuffers,
      &impl->renderTargetVertexBufferCapacities, "render_target_direct");
  if (vertexBuffer == nil) {
    ReleaseMetalFrameSlot(frameLimiter, frameSlot);
    return false;
  }

  MacOSMetalSolidVertex* writableVertices =
      static_cast<MacOSMetalSolidVertex*>([vertexBuffer contents]);
  if (writableVertices == nullptr) {
    ReleaseMetalFrameSlot(frameLimiter, frameSlot);
    return false;
  }

  frame->vertexBuffer = vertexBuffer;
  frame->frameSlot = frameSlot;
  frame->capacityVertices = vertexCapacity;
  frame->renderTarget = true;
  *vertices = writableVertices;
  return true;
}

void MacOSMetalPresenter::CancelVertexFrame(
    MacOSMetalVertexFrame* frame) {
  if (!IsAvailable() || frame == nullptr || frame->frameSlot < 0) {
    return;
  }
  MacOSMetalPresenterImpl* impl =
      static_cast<MacOSMetalPresenterImpl*>(m_Impl);
  ReleaseVertexFrameNow(impl, frame);
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
    int viewportWidth, int viewportHeight,
    MacOSMetalVertexFrame* preparedVertexFrame,
    MacOSMetalVertexFrame* externalVertexFrameToRelease) {
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

  std::shared_ptr<MacOSMetalFrameLimiter> externalFrameLimiter;
  int externalFrameSlot = -1;
  const bool hasExternalVertexFrame =
      ConsumeVertexFrameForCompletion(
          impl, externalVertexFrameToRelease, &externalFrameLimiter,
          &externalFrameSlot);
  auto releaseExternalVertexFrameNow = [&]() {
    if (hasExternalVertexFrame) {
      ReleaseMetalFrameSlot(externalFrameLimiter, externalFrameSlot);
    }
  };

  size_t totalVertexCount = 0;
  size_t cpuVertexCount = 0;
  bool hasExplicitClearCommand = false;
  for (size_t i = 0; i < batchCount; ++i) {
    const MacOSMetalDrawBatch& batch = batches[i];
    totalVertexCount += batch.vertexCount;
    if (batch.vertexCount > 0 && batch.vertexBuffer == nullptr &&
        batch.vertices != nullptr) {
      cpuVertexCount += batch.vertexCount;
    }
    hasExplicitClearCommand = hasExplicitClearCommand ||
                              batch.clearDepthBefore;
  }
  const bool hasDepthTexture = depthTexture != nullptr;
  const bool shouldEncodeClearOnlyPass =
      !preserveColor || (hasDepthTexture && clearDepth) ||
      (hasDepthTexture && hasExplicitClearCommand);
  if (totalVertexCount == 0 && batchCount == 0 &&
      !shouldEncodeClearOnlyPass) {
    releaseExternalVertexFrameNow();
    return false;
  }
  if (totalVertexCount == 0 && batchCount > 0 &&
      !hasExplicitClearCommand && !shouldEncodeClearOnlyPass) {
    releaseExternalVertexFrameNow();
    return false;
  }

  std::shared_ptr<MacOSMetalFrameLimiter> frameLimiter =
      impl->renderTargetFrameLimiter;
  const bool usingPreparedVertexFrame =
      preparedVertexFrame != nullptr && preparedVertexFrame->renderTarget &&
      preparedVertexFrame->frameSlot >= 0;
  int frameSlot =
      usingPreparedVertexFrame ? preparedVertexFrame->frameSlot : -1;
  if (!usingPreparedVertexFrame &&
      !AcquireMetalFrameSlot(frameLimiter, "render_target", &frameSlot)) {
    releaseExternalVertexFrameNow();
    return false;
  }
  if (usingPreparedVertexFrame) {
    preparedVertexFrame->vertexBuffer = nullptr;
    preparedVertexFrame->frameSlot = -1;
    preparedVertexFrame->capacityVertices = 0;
    preparedVertexFrame->renderTarget = false;
  }

  id<MTLTexture> targetTexture = (id<MTLTexture>)colorTexture;
  id<MTLTexture> targetDepth = (id<MTLTexture>)depthTexture;
  id<MTLCommandBuffer> commandBuffer = [impl->commandQueue commandBuffer];
  if (commandBuffer == nil) {
    ReleaseMetalFrameSlot(frameLimiter, frameSlot);
    releaseExternalVertexFrameNow();
    return false;
  }

  NSMutableArray* retainedBuffers = [NSMutableArray arrayWithCapacity:batchCount];
  NSMutableSet* retainedTextures =
      [NSMutableSet setWithCapacity:batchCount * 2];
  bool encoded = false;
  bool firstPass = true;
  size_t frameVertexOffset = 0;
  if (batchCount == 0) {
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
      ReleaseMetalFrameSlot(frameLimiter, frameSlot);
      releaseExternalVertexFrameNow();
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
    [encoder endEncoding];
    encoded = true;
  }
  size_t passStart = 0;
  while (passStart < batchCount) {
    size_t passEnd = passStart + 1;
    while (passEnd < batchCount && !batches[passEnd].clearDepthBefore) {
      ++passEnd;
    }
    bool passHasVertices = false;
    for (size_t i = passStart; i < passEnd; ++i) {
      passHasVertices =
          passHasVertices ||
          ((batches[i].vertices != nullptr ||
            batches[i].vertexBuffer != nullptr) &&
           batches[i].vertexCount > 0);
    }

    MTLRenderPassDescriptor* passDescriptor =
        [MTLRenderPassDescriptor renderPassDescriptor];
    passDescriptor.colorAttachments[0].texture = targetTexture;
    passDescriptor.colorAttachments[0].loadAction =
        (firstPass && !preserveColor) ? MTLLoadActionClear : MTLLoadActionLoad;
    passDescriptor.colorAttachments[0].clearColor =
        MTLClearColorMake(clearRed, clearGreen, clearBlue, clearAlpha);
    passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    if (targetDepth != nil) {
      const bool clearThisPass =
          (firstPass && clearDepth) || batches[passStart].clearDepthBefore;
      passDescriptor.depthAttachment.texture = targetDepth;
      passDescriptor.depthAttachment.loadAction =
          clearThisPass ? MTLLoadActionClear : MTLLoadActionLoad;
      passDescriptor.depthAttachment.clearDepth = 1.0;
      passDescriptor.depthAttachment.storeAction = MTLStoreActionStore;
    }

    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
    if (encoder == nil) {
      ReleaseMetalFrameSlot(frameLimiter, frameSlot);
      releaseExternalVertexFrameNow();
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

    const bool encodedPass =
        !passHasVertices ||
        [&]() {
          /*
           * When direct render-target vertices are already stored in the frame
           * slot buffer, CPU fallback vertices must not be copied into the same
           * slot.  A resize or memcpy at offset zero would overwrite the direct
           * data that these batches reference.  Use a transient retained buffer
           * for the fallback portion in that mixed frame.
           */
          const bool mixedPreparedAndCpuFallback =
              usingPreparedVertexFrame && cpuVertexCount > 0;
          return EncodeSolidBatches(
              impl, encoder, batches + passStart, passEnd - passStart,
              retainedBuffers, retainedTextures,
              mixedPreparedAndCpuFallback ? -1 : frameSlot,
              mixedPreparedAndCpuFallback
                  ? nullptr
                  : &impl->renderTargetVertexBuffers,
              mixedPreparedAndCpuFallback
                  ? nullptr
                  : &impl->renderTargetVertexBufferCapacities,
              mixedPreparedAndCpuFallback ? "render_target_fallback"
                                          : "render_target",
              &frameVertexOffset,
              mixedPreparedAndCpuFallback ? cpuVertexCount
                                          : totalVertexCount);
        }();
    [encoder endEncoding];
    if (!encodedPass) {
      ReleaseMetalFrameSlot(frameLimiter, frameSlot);
      releaseExternalVertexFrameNow();
      return false;
    }
    encoded = true;
    firstPass = false;
    passStart = passEnd;
  }
  if (!encoded) {
    ReleaseMetalFrameSlot(frameLimiter, frameSlot);
    releaseExternalVertexFrameNow();
    return false;
  }

  NSArray* completionBuffers = [retainedBuffers copy];
  NSSet* completionTextures = [retainedTextures copy];
  id<MTLTexture> completionColorAttachment = [targetTexture retain];
  id<MTLTexture> completionDepthAttachment =
      targetDepth != nil ? [targetDepth retain] : nil;
  std::shared_ptr<MacOSMetalFrameLimiter> completionFrameLimiter =
      frameLimiter;
  const int completionFrameSlot = frameSlot;
  std::shared_ptr<MacOSMetalFrameLimiter> completionExternalFrameLimiter =
      externalFrameLimiter;
  const int completionExternalFrameSlot = externalFrameSlot;
  const bool completionHasExternalFrame = hasExternalVertexFrame;
  [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer>) {
    [completionBuffers release];
    [completionTextures release];
    [completionDepthAttachment release];
    [completionColorAttachment release];
    ReleaseMetalFrameSlot(completionFrameLimiter, completionFrameSlot);
    if (completionHasExternalFrame) {
      ReleaseMetalFrameSlot(
          completionExternalFrameLimiter, completionExternalFrameSlot);
    }
  }];
  [commandBuffer commit];
  if (PerfDiagnosticsEnabled()) {
    const uint64_t renderTargetSubmitSerial =
        ++impl->renderTargetSubmitSerial;
    const float submitMs = timer.Ago() * 1000.0f;
    if (renderTargetSubmitSerial <= kMetalInitialTraceFrames ||
        renderTargetSubmitSerial % 600 == 0 || submitMs >= 2.0f) {
      LOG->Trace(
          "PERF_TRACE: macos_metal_render_target_submitted serial=%llu "
          "frame_slot=%d batches=%zu preserve=%d clear_depth=%d viewport=%dx%d "
          "submit_ms=%.3f",
          static_cast<unsigned long long>(renderTargetSubmitSerial), frameSlot,
          batchCount,
          preserveColor ? 1 : 0, clearDepth ? 1 : 0,
          viewportWidth, viewportHeight, submitMs);
    }
  }
  return true;
}

bool MacOSMetalPresenter::ReadBackOffscreenPresentTextureBGRA8(
    std::vector<uint8_t>* pixels, int* width, int* height) {
  ScopedAutoreleasePool autoreleasePool;

  if (!IsAvailable() || pixels == nullptr || width == nullptr ||
      height == nullptr) {
    return false;
  }

  pixels->clear();
  *width = 0;
  *height = 0;

  MacOSMetalPresenterImpl* impl =
      static_cast<MacOSMetalPresenterImpl*>(m_Impl);
  if (impl == nullptr || impl->commandQueue == nil ||
      impl->offscreenPresentTexture == nil) {
    return false;
  }

  id<MTLTexture> sourceTexture = [impl->offscreenPresentTexture retain];
  const NSUInteger textureWidth = [sourceTexture width];
  const NSUInteger textureHeight = [sourceTexture height];
  if (textureWidth == 0 || textureHeight == 0 ||
      textureWidth > static_cast<NSUInteger>(std::numeric_limits<int>::max()) ||
      textureHeight > static_cast<NSUInteger>(std::numeric_limits<int>::max())) {
    [sourceTexture release];
    return false;
  }

  constexpr NSUInteger kMetalReadbackRowAlignment = 256;
  const NSUInteger compactBytesPerRow = textureWidth * 4;
  if (compactBytesPerRow / 4 != textureWidth) {
    [sourceTexture release];
    return false;
  }
  const NSUInteger alignedBytesPerRow =
      (compactBytesPerRow + kMetalReadbackRowAlignment - 1) &
      ~(kMetalReadbackRowAlignment - 1);
  if (alignedBytesPerRow < compactBytesPerRow ||
      textureHeight >
          std::numeric_limits<NSUInteger>::max() / alignedBytesPerRow) {
    [sourceTexture release];
    return false;
  }
  const NSUInteger readbackLength = alignedBytesPerRow * textureHeight;
  id<MTLBuffer> readbackBuffer =
      [impl->device newBufferWithLength:readbackLength
                                options:MTLResourceStorageModeShared];
  if (readbackBuffer == nil) {
    [sourceTexture release];
    return false;
  }

  id<MTLCommandBuffer> commandBuffer = [impl->commandQueue commandBuffer];
  if (commandBuffer == nil) {
    [readbackBuffer release];
    [sourceTexture release];
    return false;
  }

  id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];
  if (blitEncoder == nil) {
    [readbackBuffer release];
    [sourceTexture release];
    return false;
  }

  [blitEncoder
        copyFromTexture:sourceTexture
            sourceSlice:0
            sourceLevel:0
           sourceOrigin:MTLOriginMake(0, 0, 0)
             sourceSize:MTLSizeMake(textureWidth, textureHeight, 1)
               toBuffer:readbackBuffer
      destinationOffset:0
 destinationBytesPerRow:alignedBytesPerRow
destinationBytesPerImage:alignedBytesPerRow * textureHeight];
  [blitEncoder endEncoding];
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];

  const bool completed =
      [commandBuffer status] == MTLCommandBufferStatusCompleted;
  if (!completed) {
    LOG->Warn(
        "MacOS Metal screenshot readback failed: command buffer status=%lu.",
        static_cast<unsigned long>([commandBuffer status]));
    [readbackBuffer release];
    [sourceTexture release];
    return false;
  }

  const uint8_t* src =
      static_cast<const uint8_t*>([readbackBuffer contents]);
  if (src == nullptr) {
    [readbackBuffer release];
    [sourceTexture release];
    return false;
  }

  std::vector<uint8_t> compactPixels;
  compactPixels.resize(static_cast<size_t>(compactBytesPerRow * textureHeight));
  const int presentFlipMode = OffscreenPresentFlipMode();
  const bool flipX = presentFlipMode == 1 || presentFlipMode == 3;
  const bool flipY = presentFlipMode == 2 || presentFlipMode == 3;
  for (NSUInteger row = 0; row < textureHeight; ++row) {
    const NSUInteger sourceRow = flipY ? textureHeight - 1 - row : row;
    std::memcpy(
        compactPixels.data() + static_cast<size_t>(row * compactBytesPerRow),
        src + static_cast<size_t>(sourceRow * alignedBytesPerRow),
        static_cast<size_t>(compactBytesPerRow));
  }
  if (flipX) {
    for (NSUInteger row = 0; row < textureHeight; ++row) {
      uint8_t* rowStart =
          compactPixels.data() + static_cast<size_t>(row * compactBytesPerRow);
      for (NSUInteger left = 0, right = textureWidth - 1; left < right;
           ++left, --right) {
        uint8_t* leftPixel = rowStart + static_cast<size_t>(left * 4);
        uint8_t* rightPixel = rowStart + static_cast<size_t>(right * 4);
        for (int channel = 0; channel < 4; ++channel) {
          std::swap(leftPixel[channel], rightPixel[channel]);
        }
      }
    }
  }

  *width = static_cast<int>(textureWidth);
  *height = static_cast<int>(textureHeight);
  *pixels = std::move(compactPixels);

  [readbackBuffer release];
  [sourceTexture release];
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

  MacOSMetalDrawableAcquireInfo drawableInfo;
  id<CAMetalDrawable> drawable = TakePrefetchedDrawable(
      impl, &drawableInfo, kMetalInteropDrawablePrefetchRenderWaitUs);
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
          static_cast<unsigned long long>(drawableInfo.misses), targetHz);
    }
    return false;
  }

  const MacOSMetalInteropSurface& surface = impl->surfaces[index];
  std::shared_ptr<MacOSMetalSurfaceBusyFlags> busyFlags = impl->surfaceBusy;
  std::shared_ptr<MacOSMetalFrameLimiter> frameLimiter =
      impl->interopFrameLimiter;
  int frameSlot = -1;
  if (!AcquireMetalFrameSlot(frameLimiter, "interop", &frameSlot)) {
    [drawable release];
    return false;
  }
  if (busyFlags &&
      busyFlags->busy[index].exchange(true, std::memory_order_acq_rel)) {
    if (PerfDiagnosticsEnabled()) {
      ++impl->directPresentBusySurfaceFrames;
      if (impl->directPresentBusySurfaceFrames <= kMetalInitialTraceFrames ||
          impl->directPresentBusySurfaceFrames % kMetalRareSkipTraceInterval ==
              0) {
        LOG->Trace(
            "PERF_TRACE: macos_metal_direct_present "
            "skipped_busy_iosurface=1 surface_index=%d frames=%llu",
            index,
            static_cast<unsigned long long>(
                impl->directPresentBusySurfaceFrames));
      }
    }
    [drawable release];
    ReleaseMetalFrameSlot(frameLimiter, frameSlot);
    return false;
  }

  RageTimer submitTimer;
  id<MTLCommandBuffer> commandBuffer = [impl->commandQueue commandBuffer];
  if (commandBuffer == nil) {
    if (busyFlags) {
      busyFlags->busy[index].store(false, std::memory_order_release);
    }
    [drawable release];
    ReleaseMetalFrameSlot(frameLimiter, frameSlot);
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
    ReleaseMetalFrameSlot(frameLimiter, frameSlot);
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
  const std::shared_ptr<MacOSMetalTimingState> completionTimingState =
      impl->timingState;
  RecordMetalTiming(
      completionTimingState, &MacOSMetalTimingState::encodeSubmitTimings,
      encodeSubmitMs);
  id<CAMetalDrawable> completionDrawable = [drawable retain];
  id<MTLTexture> completionSurfaceTexture =
      surface.metalTexture != nil ? [surface.metalTexture retain] : nil;
  std::shared_ptr<MacOSMetalFrameLimiter> completionFrameLimiter =
      frameLimiter;
  const int completionFrameSlot = frameSlot;
  [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completedCommandBuffer) {
    const uint64_t completedIndex =
        g_iMetalDirectPresentCompletedFrames.fetch_add(1) + 1;
    const uint64_t completedUsec = RageTimer::GetTimeSinceStartMicroseconds();
    const float commandBufferMs =
        (completedUsec >= submitUsec)
            ? static_cast<float>(completedUsec - submitUsec) / 1000.0f
            : 0.0f;
    RecordMetalTiming(
        completionTimingState,
        &MacOSMetalTimingState::commandBufferTimings, commandBufferMs);
    const bool traceCompletion =
        completedIndex <= kMetalInitialTraceFrames ||
        commandBufferMs >= kMetalSlowCommandBufferMs;
    if (PerfDiagnosticsEnabled() && traceCompletion) {
      LOG->Trace(
          "PERF_TRACE: macos_metal_direct_present_completed "
          "frame=%llu completed=%llu status=%lu command_buffer_ms=%.3f "
          "drawable_source=%s prefetch_acquire_ms=%.3f "
          "prefetch_wait_ms=%.3f render_thread_next_drawable_ms=%.3f "
          "encode_submit_ms=%.3f target_hz=%.3f",
          static_cast<unsigned long long>(frameIndex),
          static_cast<unsigned long long>(completedIndex),
          static_cast<unsigned long>([completedCommandBuffer status]),
          commandBufferMs,
          drawableInfo.fromPrefetch ? "prefetch" : "sync",
          drawableInfo.prefetchAcquireMs, drawableInfo.renderThreadWaitMs,
          drawableInfo.renderThreadNextDrawableMs, encodeSubmitMs, targetHz);
    }
    if (busyFlags) {
      busyFlags->busy[index].store(false, std::memory_order_release);
    }
    [completionSurfaceTexture release];
    [completionDrawable release];
    ReleaseMetalFrameSlot(completionFrameLimiter, completionFrameSlot);
  }];
  [commandBuffer commit];
  [drawable release];

  const bool traceSubmit =
      !impl->loggedFirstDirectPresent ||
      frameIndex <= kMetalInitialTraceFrames ||
      drawableInfo.renderThreadNextDrawableMs >= kMetalTraceNextDrawableMs ||
      ShouldTraceMetalRenderThreadPrefetchWait(
          drawableInfo.renderThreadWaitMs,
          kMetalInteropDrawablePrefetchRenderWaitUs);
  if (PerfDiagnosticsEnabled() && traceSubmit) {
    LOG->Trace(
        "PERF_TRACE: macos_metal_direct_present_submitted surface_index=%d "
        "size=%dx%d target_hz=%.3f minimum_duration_ms=%.3f "
        "path=opengl_interop frame=%llu drawable_source=%s "
        "prefetched_drawable_serial=%llu prefetch_misses=%llu "
        "prefetch_acquire_ms=%.3f prefetch_wait_ms=%.3f "
        "render_thread_next_drawable_ms=%.3f encode_submit_ms=%.3f",
        index, surface.width, surface.height, targetHz,
        minimumDuration * 1000.0,
        static_cast<unsigned long long>(frameIndex),
        drawableInfo.fromPrefetch ? "prefetch" : "sync",
        static_cast<unsigned long long>(drawableInfo.serial),
        static_cast<unsigned long long>(drawableInfo.misses),
        drawableInfo.prefetchAcquireMs, drawableInfo.renderThreadWaitMs,
        drawableInfo.renderThreadNextDrawableMs, encodeSubmitMs);
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
  stats.offscreenSubmittedFrames =
      g_iMetalOffscreenPresentSubmittedFrames.load(std::memory_order_relaxed);
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
  stats.offscreenSkippedNoDrawableFrames =
      g_iMetalOffscreenPresentSkippedNoDrawableFrames.load(
          std::memory_order_relaxed);
  stats.offscreenSkippedFrameLimiterFrames =
      g_iMetalOffscreenPresentSkippedFrameLimiterFrames.load(
          std::memory_order_relaxed);
  return stats;
}

std::string MacOSMetalPresenterGetRuntimeStatsLine() {
  if (!g_bMetalPresenterRuntimeActive.load(std::memory_order_acquire)) {
    return std::string();
  }

  const MacOSMetalPresenterRuntimeStats stats =
      MacOSMetalPresenterGetRuntimeStats();
  if (stats.submittedFrames == 0 && stats.offscreenSubmittedFrames == 0 &&
      stats.prefetchedDrawables == 0 &&
      stats.skippedNoPrefetchedDrawableFrames == 0 &&
      stats.offscreenSkippedNoDrawableFrames == 0 &&
      stats.offscreenSkippedFrameLimiterFrames == 0) {
    return std::string();
  }

  return ssprintf(
      "Metal present: direct_submitted=%llu direct_completed=%llu "
      "direct_skipped=%llu offscreen_submitted=%llu "
      "offscreen_skipped_drawable=%llu offscreen_skipped_limiter=%llu "
      "prefetched=%llu consumed=%llu slow=%llu misses=%llu",
      stats.submittedFrames, stats.completedFrames,
      stats.skippedNoPrefetchedDrawableFrames,
      stats.offscreenSubmittedFrames,
      stats.offscreenSkippedNoDrawableFrames,
      stats.offscreenSkippedFrameLimiterFrames,
      stats.prefetchedDrawables, stats.consumedDrawables,
      stats.slowDrawableAcquires, stats.drawableMisses);
}

void MacOSMetalPresenterMarkNativePresentationChange(int reason) {
  g_iMetalNativePresentationChangeReason.store(
      reason, std::memory_order_release);
}

int MacOSMetalPresenterConsumeNativePresentationChangeReason() {
  return g_iMetalNativePresentationChangeReason.exchange(
      0, std::memory_order_acq_rel);
}
