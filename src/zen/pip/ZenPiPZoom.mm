#import "ZenPictureInPictureInternal.h"
#import "ZenPiPThrowMath.h"
#import "ZenPiPZoomMath.h"

#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

using namespace zen_pip;

namespace zen_pip {
const void *const kZoomKey = &kZoomKey;
}

@implementation ZenPiPZoom {
  __unsafe_unretained NSWindow *_window;
  NSRect _last;
  double _width;
  double _aspect;
  double _target;
  NSPoint _pointer;
  NSTimer *_ease;
  NSTimer *_pinchEndTimer;
  BOOL _isPinching;
  NSTimeInterval _lastMagnifyAt;
  BOOL _hitMinHaptic;
  BOOL _hitMaxHaptic;
  zen_pip_zoom::AnchorCorner _anchorCorner;

  // Fixed baseline frame tracking for jitter-free pinch zoom (FloatyMPV pattern)
  NSRect _pinchBaseFrame;
  NSPoint _pinchBaseCenter;
  double _pinchAccumulatedScale;
}

+ (BOOL)zooms:(NSWindow *)window {
  if (!window || ![window isKindOfClass:[NSWindow class]]) return NO;
  if (!window.visible || !(window.styleMask & NSWindowStyleMaskResizable)) return NO;
  ZenPiPController *controller = [ZenPiPController forWindow:window];
  if (controller) return controller.stashedEdge == ZenPiPEdgeNone;
  return NO;
}

+ (instancetype)forWindow:(NSWindow *)window {
  if (!window || ![window isKindOfClass:[NSWindow class]]) return nil;
  ZenPiPZoom *zoom = objc_getAssociatedObject(window, kZoomKey);
  if (!zoom) {
    zoom = [[[ZenPiPZoom alloc] init] autorelease];
    zoom->_window = window;
    objc_setAssociatedObject(window, kZoomKey, zoom, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return zoom;
}

static __unsafe_unretained NSWindow *gZoomGesture = nil;

+ (void)abandonZoomOn:(NSWindow *)window {
  if (gZoomGesture == window) gZoomGesture = nil;
  ZenPiPZoom *zoom = window ? objc_getAssociatedObject(window, kZoomKey) : nil;
  [zoom stopEase];
  [zoom cancelPinch];
}

+ (BOOL)handle:(NSEvent *)event {
  return [self route:event];
}

+ (NSWindow *)windowFor:(NSEvent *)event {
  ZenPiPController *controller = [ZenPiPController controllerUnderPointer];
  NSWindow *window = controller.window;
  return (window && [self zooms:window]) ? window : nil;
}

static void CheckBoundaryHaptic(double width, double limit, BOOL isMin, BOOL *latch) {
  const BOOL hit = isMin ? (width <= limit + 0.5) : (width >= limit - 0.5);
  const BOOL clear = isMin ? (width > limit + 2.0) : (width < limit - 2.0);
  if (hit) {
    if (!*latch) {
      [[NSHapticFeedbackManager defaultPerformer] performFeedbackPattern:NSHapticFeedbackPatternAlignment
                                                         performanceTime:NSHapticFeedbackPerformanceTimeNow];
      *latch = YES;
    }
  } else if (clear) {
    *latch = NO;
  }
}

+ (BOOL)route:(NSEvent *)event {
  NSWindow *window = [self windowFor:event];
  BOOL command = (event.modifierFlags & NSEventModifierFlagCommand) != 0;
  BOOL scroll = event.type == NSEventTypeScrollWheel;
  if (scroll) {
    NSEventPhase phase = event.phase, momentum = event.momentumPhase;
    BOOL wheel = phase == NSEventPhaseNone && momentum == NSEventPhaseNone;
    if (wheel || (phase & (NSEventPhaseBegan | NSEventPhaseMayBegin))) {
      gZoomGesture = nil;
      [[self forWindow:window] prepareAnchorCorner];
    }
    if (gZoomGesture) window = gZoomGesture;
    if (!window || (!command && gZoomGesture != window)) return NO;
    if (![self zooms:window]) return NO;
    if (!wheel) gZoomGesture = window;
    if (momentum & (NSEventPhaseEnded | NSEventPhaseCancelled)) {
      gZoomGesture = nil;
      [[self forWindow:window] resetAnchorCorner];
    }
    double dy = event.scrollingDeltaY;
    if (dy == 0) return YES;
    [[self forWindow:window] zoomBy:zen_pip_zoom::ScrollFactor(dy, event.hasPreciseScrollingDeltas)
                                 at:[self screenPoint:event]
                               ease:!event.hasPreciseScrollingDeltas];
    return YES;
  }
  if (!window || ![self zooms:window]) return NO;
  [[self forWindow:window] handleMagnify:event];
  return YES;
}

+ (NSPoint)screenPoint:(NSEvent *)event {
  return event.window ? [event.window convertPointToScreen:event.locationInWindow] : event.locationInWindow;
}

- (zen_pip_zoom::AnchorCorner)detectAnchorCorner {
  NSWindow *window = _window;
  if (!window) return zen_pip_zoom::kAnchorNone;
  const zen_pip_throw::Rect frameRect = zen_pip::ThrowRect(window.frame);
  const zen_pip_throw::Rect visRect = zen_pip::ThrowRect(ScreenFor(window.frame).visibleFrame);
  for (zen_pip_throw::Corner c :
       {zen_pip_throw::kTopLeft, zen_pip_throw::kTopRight, zen_pip_throw::kBottomLeft, zen_pip_throw::kBottomRight}) {
    const zen_pip_throw::Rect target = zen_pip_throw::CornerFrame(c, frameRect.w, frameRect.h, visRect);
    if (std::hypot(target.x - frameRect.x, target.y - frameRect.y) <= 25.0) {
      return static_cast<zen_pip_zoom::AnchorCorner>(c);
    }
  }
  return zen_pip_zoom::kAnchorNone;
}

- (void)prepareAnchorCorner {
  _anchorCorner = [self detectAnchorCorner];
}

- (void)resetAnchorCorner {
  _anchorCorner = zen_pip_zoom::kAnchorNone;
  _hitMinHaptic = NO;
  _hitMaxHaptic = NO;
}

- (void)stopEase {
  if (_ease) {
    [_ease invalidate];
    [_ease release];
    _ease = nil;
  }
  _target = 0;
  _hitMinHaptic = NO;
  _hitMaxHaptic = NO;
  if (!_isPinching) {
    _anchorCorner = zen_pip_zoom::kAnchorNone;
  }
}

- (void)cancelPinch {
  if (_pinchEndTimer) {
    [_pinchEndTimer invalidate];
    [_pinchEndTimer release];
    _pinchEndTimer = nil;
  }
  _anchorCorner = zen_pip_zoom::kAnchorNone;
  _hitMinHaptic = NO;
  _hitMaxHaptic = NO;
  _pinchBaseFrame = NSZeroRect;
  _pinchBaseCenter = NSZeroPoint;
  _pinchAccumulatedScale = 1.0;
  if (_isPinching) {
    _isPinching = NO;
    // Shared tail; a no-op while a swipe owns the window.
    [[ZenPiPController forWindow:_window] endGestureChrome:YES];
  }
}

- (void)finishPinch {
  if (_pinchEndTimer) {
    [_pinchEndTimer invalidate];
    [_pinchEndTimer release];
    _pinchEndTimer = nil;
  }
  if (!_isPinching) return;
  _isPinching = NO;
  _pinchBaseFrame = NSZeroRect;
  _pinchBaseCenter = NSZeroPoint;
  _pinchAccumulatedScale = 1.0;
  const zen_pip_zoom::AnchorCorner corner = _anchorCorner;
  _anchorCorner = zen_pip_zoom::kAnchorNone;
  _hitMinHaptic = NO;
  _hitMaxHaptic = NO;
  ZenPiPController *controller = [ZenPiPController forWindow:_window];
  if (controller) {
    [controller pinchEndedAtAnchor:corner];
  }
}

- (void)stepPinch {
  NSWindow *window = _window;
  if (!window || !_isPinching) return;

  const zen_pip_zoom::Size minSz = [self minSize];
  const zen_pip_zoom::Size maxSz = [self maxSize];
  const zen_pip_zoom::Rect vis = [self visible];

  double low, high;
  zen_pip_zoom::WidthLimits(_aspect, minSz, maxSz, vis, &low, &high);

  const double baseW = NSWidth(_pinchBaseFrame);
  if (baseW <= 0) return;

  const double scaleFloor = low / baseW;
  const double scaleCeiling = high / baseW;

  // FloatyMPV-style edge-triggered alignment haptics at min/max boundary
  if (_pinchAccumulatedScale <= scaleFloor + 0.001) {
    if (!_hitMinHaptic) {
      [[NSHapticFeedbackManager defaultPerformer] performFeedbackPattern:NSHapticFeedbackPatternAlignment
                                                         performanceTime:NSHapticFeedbackPerformanceTimeNow];
      _hitMinHaptic = YES;
    }
  } else {
    _hitMinHaptic = NO;
  }

  if (_pinchAccumulatedScale >= scaleCeiling - 0.001) {
    if (!_hitMaxHaptic) {
      [[NSHapticFeedbackManager defaultPerformer] performFeedbackPattern:NSHapticFeedbackPatternAlignment
                                                         performanceTime:NSHapticFeedbackPerformanceTimeNow];
      _hitMaxHaptic = YES;
    }
  } else {
    _hitMaxHaptic = NO;
  }

  zen_pip_zoom::Rect baseRect = {NSMinX(_pinchBaseFrame), NSMinY(_pinchBaseFrame), NSWidth(_pinchBaseFrame), NSHeight(_pinchBaseFrame)};
  zen_pip_zoom::Point basePt = {_pinchBaseCenter.x, _pinchBaseCenter.y};

  zen_pip_zoom::Result result = zen_pip_zoom::ZoomFromBase(
      baseRect, basePt, _aspect, _pinchAccumulatedScale, vis, minSz, maxSz, _anchorCorner);

  _width = result.width;

  NSRect next = NSMakeRect(result.frame.x, result.frame.y, result.frame.w, result.frame.h);
  if (!NSEqualRects(next, window.frame)) {
    // display:NO is critical: forcing synchronous redraw at 90-120Hz clogs the Cocoa
    // runloop and drops frames. WindowServer / compositor handles async presentation smoothly.
    [window setFrame:next display:NO];
    [ZenPiPController updateShadowPathForWindow:window size:next.size radius:10];
  }
  _last = window.frame;
}

- (void)handleMagnify:(NSEvent *)event {
  NSWindow *window = _window;
  if (!window) return;

  // A magnify can arrive twice: once through the global monitor while Zen is
  // inactive, once through the local monitor on the turn it becomes active. Zoom
  // once per event.
  if (event.timestamp <= _lastMagnifyAt) return;
  _lastMagnifyAt = event.timestamp;
  ZenPiPController *controller = [ZenPiPController forWindow:window];

  if (event.phase == NSEventPhaseEnded || event.phase == NSEventPhaseCancelled) {
    [self finishPinch];
    return;
  }

  if (!_isPinching) {
    _isPinching = YES;
    // Capture baseline frame and center once at gesture begin (FloatyMPV pattern).
    // All subsequent scale updates derive from this immutable base, preventing integer drift.
    _pinchBaseFrame = window.frame;
    _pinchBaseCenter = NSMakePoint(NSMidX(_pinchBaseFrame), NSMidY(_pinchBaseFrame));
    _pinchAccumulatedScale = 1.0;
    _aspect = NSWidth(_pinchBaseFrame) / MAX(NSHeight(_pinchBaseFrame), 1.0);
    _anchorCorner = [self detectAnchorCorner];

    // Seed boundary latches if already at edge to avoid initial touch-down click
    double low, high;
    zen_pip_zoom::WidthLimits(_aspect, [self minSize], [self maxSize], [self visible], &low, &high);
    _hitMinHaptic = (NSWidth(_pinchBaseFrame) <= low + 0.5);
    _hitMaxHaptic = (NSWidth(_pinchBaseFrame) >= high - 0.5);

    if (controller) {
      [controller disarmSwipe];
      [controller pinchBegan];
    }
  }

  if (_pinchEndTimer) {
    [_pinchEndTimer invalidate];
    [_pinchEndTimer release];
    _pinchEndTimer = nil;
  }

  __unsafe_unretained ZenPiPZoom *weakSelf = self;
  _pinchEndTimer = [[NSTimer timerWithTimeInterval:0.12 repeats:NO block:^(NSTimer *timer) {
    ZenPiPZoom *strongSelf = weakSelf;
    if (strongSelf) {
      [strongSelf finishPinch];
    }
  }] retain];
  [NSRunLoop.currentRunLoop addTimer:_pinchEndTimer forMode:NSRunLoopCommonModes];

  // Prevent trackpad delta spikes by clamping step factor
  const double stepScale = std::clamp(1.0 + event.magnification, 0.90, 1.10);
  _pinchAccumulatedScale *= stepScale;

  [self stepPinch];
}

- (void)dealloc {
  [self stopEase];
  [self cancelPinch];
  [super dealloc];
}

- (void)zoomBy:(double)factor at:(NSPoint)pointer ease:(BOOL)ease {
  NSWindow *window = _window;
  if (!window) return;
  [[ZenPiPController forWindow:window] cancelMotion];  // stop the spring, keep gesture chrome
  NSRect frame = window.frame;
  if (!NSEqualRects(frame, _last) || _width <= 0) {
    double aspect = NSWidth(frame) / MAX(NSHeight(frame), 1);
    if (!(_aspect > 0 && fabs(NSWidth(frame) / _aspect - NSHeight(frame)) <= 1)) _aspect = aspect;
    _width = NSWidth(frame), _target = 0;
    [self stopEase];
  }
  _pointer = pointer;
  if (!ease) {
    [self stopEase];
    return [self step:factor];
  }
  double low, high;
  zen_pip_zoom::WidthLimits(_aspect, [self minSize], [self maxSize], [self visible], &low, &high);
  _target = MIN(MAX((_target > 0 ? _target : _width) * factor, low), high);
  if (_ease) return;
  __unsafe_unretained ZenPiPZoom *weakSelf = self;
  _ease = [[NSTimer timerWithTimeInterval:1.0 / 120 repeats:YES block:^(NSTimer *timer) {
    ZenPiPZoom *strongSelf = weakSelf;
    if (!strongSelf || !strongSelf->_window || !strongSelf->_window.visible || !NSEqualRects(strongSelf->_window.frame, strongSelf->_last)) {
      if (strongSelf) [strongSelf stopEase];
      else [timer invalidate];
      return;
    }
    double width = strongSelf->_width, target = strongSelf->_target;
    BOOL done = fabs(target - width) < 0.25;
    [strongSelf step:(done ? target : width + (target - width) * 0.25) / width];
    if (!done) return;
    [strongSelf stopEase];
  }] retain];
  [NSRunLoop.currentRunLoop addTimer:_ease forMode:NSRunLoopCommonModes];
  _last = frame;
}

- (zen_pip_zoom::Size)minSize {
  NSSize size = _window.contentMinSize;
  return {size.width, size.height};
}

- (zen_pip_zoom::Size)maxSize {
  NSSize size = _window.contentMaxSize;
  return {size.width > 0 ? size.width : CGFLOAT_MAX, size.height > 0 ? size.height : CGFLOAT_MAX};
}

- (zen_pip_zoom::Rect)visible {
  NSRect visible = ScreenFor(_window.frame).visibleFrame;
  return {NSMinX(visible), NSMinY(visible), NSWidth(visible), NSHeight(visible)};
}

- (void)step:(double)factor {
  NSWindow *window = _window;
  NSRect frame = window.frame;
  const zen_pip_zoom::Size minSz = [self minSize];
  const zen_pip_zoom::Size maxSz = [self maxSize];
  const zen_pip_zoom::Rect vis = [self visible];

  double low, high;
  zen_pip_zoom::WidthLimits(_aspect, minSz, maxSz, vis, &low, &high);

  zen_pip_zoom::Result result = zen_pip_zoom::Zoom(
      {NSMinX(frame), NSMinY(frame), NSWidth(frame), NSHeight(frame)}, _width, _aspect, factor, {_pointer.x, _pointer.y},
      vis, minSz, maxSz, _anchorCorner);
  _width = result.width;

  // FloatyMPV-style edge-triggered alignment haptics when hitting min/max boundary
  CheckBoundaryHaptic(_width, low, YES, &_hitMinHaptic);
  CheckBoundaryHaptic(_width, high, NO, &_hitMaxHaptic);

  NSRect next = NSMakeRect(result.frame.x, result.frame.y, result.frame.w, result.frame.h);
  if (!NSEqualRects(next, frame)) {
    [window setFrame:next display:NO];
    [ZenPiPController updateShadowPathForWindow:window size:next.size radius:10];
  }
  _last = window.frame;
}

@end
