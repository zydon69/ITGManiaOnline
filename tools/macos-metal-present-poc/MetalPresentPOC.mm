#import <AppKit/AppKit.h>
#import <QuartzCore/CADisplayLink.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <numeric>
#include <string>
#include <vector>

namespace {

struct Options {
  int width = 1280;
  int height = 720;
  double hz = 120.0;
  double seconds = 120.0;
  double warmupSeconds = 1.0;
};

struct TimingStats {
  std::mutex mutex;
  std::vector<double> presentTimes;
  std::vector<double> displayLinkTimes;
  uint64_t drawCalls = 0;
  uint64_t skippedNoDrawable = 0;
  uint64_t skippedBusy = 0;
};

double NowSeconds() {
  return CACurrentMediaTime();
}

bool ParseDouble(const char* text, double* out) {
  if (text == nullptr || out == nullptr) {
    return false;
  }
  char* end = nullptr;
  const double value = std::strtod(text, &end);
  if (end == text || !std::isfinite(value)) {
    return false;
  }
  *out = value;
  return true;
}

bool ParseInt(const char* text, int* out) {
  double value = 0.0;
  if (!ParseDouble(text, &value)) {
    return false;
  }
  *out = static_cast<int>(value);
  return true;
}

Options ParseOptions(int argc, char** argv) {
  Options options;
  for (int i = 1; i < argc; ++i) {
    const char* arg = argv[i];
    const bool hasValue = i + 1 < argc;
    if (std::strcmp(arg, "--width") == 0 && hasValue) {
      ParseInt(argv[++i], &options.width);
    } else if (std::strcmp(arg, "--height") == 0 && hasValue) {
      ParseInt(argv[++i], &options.height);
    } else if (std::strcmp(arg, "--hz") == 0 && hasValue) {
      ParseDouble(argv[++i], &options.hz);
    } else if (std::strcmp(arg, "--seconds") == 0 && hasValue) {
      ParseDouble(argv[++i], &options.seconds);
    } else if (std::strcmp(arg, "--warmup") == 0 && hasValue) {
      ParseDouble(argv[++i], &options.warmupSeconds);
    } else if (std::strcmp(arg, "--help") == 0) {
      std::printf(
          "Usage: metal_present_poc [--hz 120] [--seconds 120] "
          "[--warmup 1] [--width 1280] [--height 720]\n");
      std::exit(0);
    }
  }
  options.width = std::max(320, options.width);
  options.height = std::max(240, options.height);
  options.hz = std::clamp(options.hz, 30.0, 240.0);
  options.seconds = std::clamp(options.seconds, 5.0, 600.0);
  options.warmupSeconds = std::clamp(options.warmupSeconds, 0.0, options.seconds - 1.0);
  return options;
}

void PushTime(std::vector<double>* times, double value) {
  if (times != nullptr) {
    times->push_back(value);
  }
}

struct DeltaSummary {
  size_t samples = 0;
  double avgMs = 0.0;
  double maxMs = 0.0;
  double p95Ms = 0.0;
  double p99Ms = 0.0;
  uint64_t over15x = 0;
  uint64_t over2x = 0;
};

DeltaSummary SummarizeDeltas(const std::vector<double>& times, double budgetMs) {
  DeltaSummary summary;
  if (times.size() < 2) {
    return summary;
  }

  std::vector<double> deltasMs;
  deltasMs.reserve(times.size() - 1);
  for (size_t i = 1; i < times.size(); ++i) {
    const double deltaMs = (times[i] - times[i - 1]) * 1000.0;
    if (deltaMs <= 0.0 || !std::isfinite(deltaMs)) {
      continue;
    }
    deltasMs.push_back(deltaMs);
    summary.maxMs = std::max(summary.maxMs, deltaMs);
    if (deltaMs > budgetMs * 1.5) {
      ++summary.over15x;
    }
    if (deltaMs > budgetMs * 2.0) {
      ++summary.over2x;
    }
  }

  if (deltasMs.empty()) {
    return summary;
  }

  summary.samples = deltasMs.size();
  summary.avgMs = std::accumulate(deltasMs.begin(), deltasMs.end(), 0.0) /
                  static_cast<double>(deltasMs.size());
  std::sort(deltasMs.begin(), deltasMs.end());
  const auto percentile = [&](double p) {
    const size_t index = std::min(
        deltasMs.size() - 1,
        static_cast<size_t>(std::ceil(p * static_cast<double>(deltasMs.size()))) - 1);
    return deltasMs[index];
  };
  summary.p95Ms = percentile(0.95);
  summary.p99Ms = percentile(0.99);
  return summary;
}

uint64_t CountPresentOver2xNearDisplayLinkOver2x(
    const std::vector<double>& presentTimes,
    const std::vector<double>& displayLinkTimes,
    double budgetMs) {
  if (presentTimes.size() < 2 || displayLinkTimes.size() < 2) {
    return 0;
  }

  std::vector<double> displayLinkOverTimes;
  displayLinkOverTimes.reserve(displayLinkTimes.size());
  for (size_t i = 1; i < displayLinkTimes.size(); ++i) {
    const double deltaMs = (displayLinkTimes[i] - displayLinkTimes[i - 1]) * 1000.0;
    if (deltaMs > budgetMs * 2.0) {
      displayLinkOverTimes.push_back(displayLinkTimes[i]);
    }
  }

  uint64_t correlated = 0;
  for (size_t i = 1; i < presentTimes.size(); ++i) {
    const double deltaMs = (presentTimes[i] - presentTimes[i - 1]) * 1000.0;
    if (deltaMs <= budgetMs * 2.0) {
      continue;
    }

    const double presentTime = presentTimes[i];
    const auto nearby = std::find_if(
        displayLinkOverTimes.begin(), displayLinkOverTimes.end(),
        [presentTime](double displayLinkTime) {
          return std::fabs(displayLinkTime - presentTime) <= 0.050;
        });
    if (nearby != displayLinkOverTimes.end()) {
      ++correlated;
    }
  }
  return correlated;
}

void PrintSummary(const Options& options, const TimingStats& stats,
                  std::vector<double> presentTimes,
                  std::vector<double> displayLinkTimes) {
  const double budgetMs = 1000.0 / options.hz;
  const DeltaSummary present = SummarizeDeltas(presentTimes, budgetMs);
  const DeltaSummary displayLink = SummarizeDeltas(displayLinkTimes, budgetMs);
  const uint64_t presentOver2xNearDisplayLinkOver2x =
      CountPresentOver2xNearDisplayLinkOver2x(
          presentTimes, displayLinkTimes, budgetMs);

  std::printf(
      "METAL_POC_SUMMARY hz=%.3f seconds=%.1f budget_ms=%.3f "
      "warmup=%.1f "
      "draw_calls=%llu skipped_no_drawable=%llu skipped_busy=%llu "
      "present_samples=%zu avg_present_delta_ms=%.3f "
      "p95_present_delta_ms=%.3f p99_present_delta_ms=%.3f "
      "max_present_delta_ms=%.3f over_1_5x_budget=%llu over_2x_budget=%llu "
      "present_over_2x_near_displaylink_over_2x=%llu "
      "displaylink_samples=%zu avg_displaylink_delta_ms=%.3f "
      "p95_displaylink_delta_ms=%.3f p99_displaylink_delta_ms=%.3f "
      "max_displaylink_delta_ms=%.3f displaylink_over_2x_budget=%llu\n",
      options.hz, options.seconds, budgetMs, options.warmupSeconds,
      static_cast<unsigned long long>(stats.drawCalls),
      static_cast<unsigned long long>(stats.skippedNoDrawable),
      static_cast<unsigned long long>(stats.skippedBusy),
      present.samples, present.avgMs, present.p95Ms, present.p99Ms,
      present.maxMs, static_cast<unsigned long long>(present.over15x),
      static_cast<unsigned long long>(present.over2x),
      static_cast<unsigned long long>(presentOver2xNearDisplayLinkOver2x),
      displayLink.samples, displayLink.avgMs, displayLink.p95Ms,
      displayLink.p99Ms, displayLink.maxMs,
      static_cast<unsigned long long>(displayLink.over2x));
}

}  // namespace

@interface MetalPresentPOC : NSObject
- (instancetype)initWithOptions:(Options)options stats:(TimingStats*)stats;
- (void)start;
- (void)stop;
@end

@implementation MetalPresentPOC {
  Options _options;
  TimingStats* _stats;
  NSWindow* _window;
  CAMetalLayer* _layer;
  id<MTLDevice> _device;
  id<MTLCommandQueue> _queue;
  CADisplayLink* _displayLink;
  id _activityToken;
  std::atomic_bool _drawing;
  std::atomic_bool _stopping;
  uint64_t _frameIndex;
  double _collectAfterSeconds;
  double _stopAtSeconds;
}

- (instancetype)initWithOptions:(Options)options stats:(TimingStats*)stats {
  self = [super init];
  if (self) {
    _options = options;
    _stats = stats;
    _displayLink = nil;
    _activityToken = nil;
    _drawing = false;
    _stopping = false;
    _frameIndex = 0;
    _collectAfterSeconds = 0.0;
    _stopAtSeconds = 0.0;
  }
  return self;
}

- (void)dealloc {
  [self stop];
}

- (void)start {
  _device = MTLCreateSystemDefaultDevice();
  if (!_device) {
    std::fprintf(stderr, "Metal is not available on this Mac.\n");
    [NSApp terminate:nil];
    return;
  }

  _queue = [_device newCommandQueue];
  _activityToken = [[NSProcessInfo processInfo]
      beginActivityWithOptions:NSActivityUserInitiated |
                               NSActivityLatencyCritical |
                               NSActivityIdleSystemSleepDisabled
                    reason:@"ITGmania Metal present timing POC"];

  NSRect rect = NSMakeRect(100, 100, _options.width, _options.height);
  _window = [[NSWindow alloc]
      initWithContentRect:rect
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                          NSWindowStyleMaskMiniaturizable |
                          NSWindowStyleMaskResizable
                  backing:NSBackingStoreBuffered
                    defer:NO];
  [_window setTitle:@"ITGmania Metal Present POC"];
  [_window makeKeyAndOrderFront:nil];
  const double startSeconds = NowSeconds();
  _collectAfterSeconds = startSeconds + _options.warmupSeconds;
  _stopAtSeconds = startSeconds + _options.seconds;

  NSView* contentView = [_window contentView];
  [contentView setWantsLayer:YES];
  _layer = [CAMetalLayer layer];
  _layer.device = _device;
  _layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
  _layer.framebufferOnly = YES;
  _layer.displaySyncEnabled = YES;
  _layer.maximumDrawableCount = 3;
  _layer.frame = contentView.bounds;
  _layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
  contentView.layer = _layer;

  _displayLink = [_window displayLinkWithTarget:self selector:@selector(displayLinkTick:)];
  _displayLink.preferredFrameRateRange =
      CAFrameRateRangeMake(static_cast<float>(_options.hz),
                           static_cast<float>(_options.hz),
                           static_cast<float>(_options.hz));
  [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW,
                    static_cast<int64_t>(_options.seconds * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [self stop];
        [NSApp stop:nil];
        NSEvent* wakeEvent = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                                location:NSZeroPoint
                                           modifierFlags:0
                                               timestamp:0
                                            windowNumber:0
                                                 context:nil
                                                 subtype:0
                                                   data1:0
                                                   data2:0];
        [NSApp postEvent:wakeEvent atStart:NO];
      });
}

- (void)stop {
  _stopping = true;
  if (_displayLink != nil) {
    [_displayLink invalidate];
    _displayLink = nil;
  }
  if (_activityToken != nil) {
    [[NSProcessInfo processInfo] endActivity:_activityToken];
    _activityToken = nil;
  }
}

- (void)displayLinkTick:(CADisplayLink*)link {
  const double now = NowSeconds();
  if (now >= _stopAtSeconds) {
    [self stop];
    [NSApp stop:nil];
    return;
  }

  if (now >= _collectAfterSeconds) {
    std::lock_guard<std::mutex> lock(_stats->mutex);
    PushTime(&_stats->displayLinkTimes, now);
  }

  if (_stopping) {
    return;
  }

  bool expected = false;
  if (!_drawing.compare_exchange_strong(expected, true)) {
    ++_stats->skippedBusy;
    return;
  }

  [self drawFrame];
  _drawing = false;
}

- (void)drawFrame {
  if (_stopping) {
    return;
  }

  id<CAMetalDrawable> drawable = [_layer nextDrawable];
  if (!drawable) {
    ++_stats->skippedNoDrawable;
    return;
  }

  const double phase = static_cast<double>(_frameIndex % 360) / 360.0;
  const double red = 0.5 + 0.5 * std::sin(phase * M_PI * 2.0);
  const double green = 0.5 + 0.5 * std::sin((phase + 0.333) * M_PI * 2.0);
  const double blue = 0.5 + 0.5 * std::sin((phase + 0.666) * M_PI * 2.0);

  MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = drawable.texture;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(red, green, blue, 1.0);

  id<MTLCommandBuffer> commandBuffer = [_queue commandBuffer];
  id<MTLRenderCommandEncoder> encoder =
      [commandBuffer renderCommandEncoderWithDescriptor:pass];
  [encoder endEncoding];

  TimingStats* stats = _stats;
  const double collectAfter = _collectAfterSeconds;
  [drawable addPresentedHandler:^(id<MTLDrawable>) {
    const double now = NowSeconds();
    if (now >= collectAfter) {
      std::lock_guard<std::mutex> lock(stats->mutex);
      PushTime(&stats->presentTimes, now);
    }
  }];

  [commandBuffer presentDrawable:drawable afterMinimumDuration:(1.0 / _options.hz)];
  [commandBuffer commit];

  ++_stats->drawCalls;
  ++_frameIndex;
}

@end

int main(int argc, char** argv) {
  @autoreleasepool {
    const Options options = ParseOptions(argc, argv);
    TimingStats stats;

    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    MetalPresentPOC* poc = [[MetalPresentPOC alloc] initWithOptions:options stats:&stats];
    [poc start];
    [NSApp activateIgnoringOtherApps:YES];
    [NSApp run];

    std::vector<double> presentTimes;
    std::vector<double> displayLinkTimes;
    {
      std::lock_guard<std::mutex> lock(stats.mutex);
      presentTimes = stats.presentTimes;
      displayLinkTimes = stats.displayLinkTimes;
    }
    PrintSummary(options, stats, presentTimes, displayLinkTimes);
  }
  return 0;
}
