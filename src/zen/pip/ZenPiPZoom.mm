#import "ZenPictureInPictureInternal.h"
#import "ZenPiPThrowMath.h"
#import "ZenPiPZoomMath.h"

#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

using namespace zen_pip;

namespace zen_pip {
const void *const kZoomKey = &kZoomKey;
}

namespace {

// Safety nets for devices that never report a gesture end phase. They must be
// well behind the rate of a held gesture, or a short pause mid-pinch would end
// and snap the window while the fingers are still down.
constexpr CFTimeInterval kPinchIdle = 0.45;
constexpr CFTimeInterval kScrollIdle = 0.35;
// Time constants for the eased approach to the target scale. The pinch one is
// short enough to feel 1:1 while smoothing the event cadence; the wheel one is
// long enough to read as a glide.
constexpr double kPinchTau = 0.022;
constexpr double kScrollTau = 0.055;

}  // namespace

@implementation ZenPiPZoom {
  __unsafe_unretained NSWindow *_window;
  // Session state. Captured once at gesture start, never mutated, so every
  // frame is computed from the same reference frame.
  BOOL _resizing;
  NSRect _baseFrame;
  double _anchorX, _anchorY;
  double _aspect;
  double _scale;        // applied scale, relative to _baseFrame
  double _targetScale;  // eased destination for wheel steps
  double _scaleFloor, _scaleCeiling;
  NSRect _last;  // frame we last wrote, to notice movement from elsewhere
  NSPoint _pointer;
  // Corner the window was docked in when the gesture began. Only used to decide
  // where a finished resize snaps back to; it never constrains the resize.
  zen_pip_zoom::AnchorCorner _startCorner;
  // Visible frame of the screen the gesture started on, kept for the session.
  zen_pip_zoom::Rect _visible;
  NSTimer *_ease;
  id _easeDisplayLink;  // CADisplayLink on macOS 14+ for 120Hz ProMotion
  CFTimeInterval _easeLastAt;
  double _easeTau;      // seconds; time constant of the eased approach
  NSTimer *_idle;
  BOOL _endPending;
  NSTimeInterval _lastMagnifyAt;
  BOOL _hitMinHaptic;
  BOOL _hitMaxHaptic;
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
  [zoom abandon];
}

+ (BOOL)handle:(NSEvent *)event {
  return [self route:event];
}

+ (NSWindow *)windowFor:(NSEvent *)event {
  ZenPiPController *controller = [ZenPiPController controllerUnderPointer];
  NSWindow *window = controller.window;
  return (window && [self zooms:window]) ? window : nil;
}

static void CheckBoundaryHaptic(double value, double limit, BOOL isMin, BOOL *latch) {
  const BOOL hit = isMin ? (value <= limit + 0.0005) : (value >= limit - 0.0005);
  const BOOL clear = isMin ? (value > limit + 0.002) : (value < limit - 0.002);
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
    }
    if (gZoomGesture) window = gZoomGesture;
    if (!window || (!command && gZoomGesture != window)) return NO;
    if (![self zooms:window]) return NO;
    // Front once per gesture. A precise trackpad scroll arrives at up to 120 Hz
    // and an orderFront per event is a WindowServer round trip each time.
    if (gZoomGesture != window) [window orderFrontRegardless];
    if (!wheel) gZoomGesture = window;
    const BOOL ended = (momentum & (NSEventPhaseEnded | NSEventPhaseCancelled)) != 0;
    if (ended) gZoomGesture = nil;
    double dy = event.scrollingDeltaY;
    if (dy != 0) {
      [[self forWindow:window] zoomBy:zen_pip_zoom::ScrollFactor(dy, event.hasPreciseScrollingDeltas)
                                   at:[self screenPoint:event]
                                 ease:!event.hasPreciseScrollingDeltas];
    }
    if (ended) [[self forWindow:window] requestEnd];
    return YES;
  }
  if (!window || ![self zooms:window]) return NO;
  [[self forWindow:window] handleMagnify:event];
  return YES;
}

+ (NSPoint)screenPoint:(NSEvent *)event {
  return event.window ? [event.window convertPointToScreen:event.locationInWindow] : event.locationInWindow;
}

// The PiP window is created with `lockaspectratio`, so AppKit already knows the
// video's aspect. Honouring it keeps the picture full-bleed: deriving the aspect
// from a rounded frame instead would drift by a fraction of a pixel and make the
// video letterbox (the "picture breaking") as the window expands or shrinks.
- (double)lockedAspect {
  NSSize locked = _window ? _window.contentAspectRatio : NSZeroSize;
  if (locked.width > 0 && locked.height > 0) return locked.width / locked.height;
  const NSRect frame = _window ? _window.frame : NSZeroRect;
  return NSWidth(frame) / MAX(NSHeight(frame), 1.0);
}

- (void)beginResizeAt:(NSPoint)pointer {
  NSWindow *window = _window;
  if (!window || _resizing) return;
  // One front per gesture, before any frame changes: a PiP that sits behind
  // another window must come forward the moment the gesture starts, without
  // activating Zen.
  [window orderFrontRegardless];

  _resizing = YES;
  _endPending = NO;
  _pointer = pointer;
  _baseFrame = window.frame;
  _last = _baseFrame;
  // The screen is captured once. A cursor-anchored resize may overflow an edge,
  // and re-resolving the screen per tick could flip onto a neighbouring display
  // and change the size limits mid-gesture.
  const NSRect baseVisible = ScreenFor(_baseFrame).visibleFrame;
  _visible = {NSMinX(baseVisible), NSMinY(baseVisible), NSWidth(baseVisible), NSHeight(baseVisible)};
  _aspect = [self lockedAspect];
  if (!(_aspect > 0.01)) _aspect = 16.0 / 9.0;

  const double baseW = MAX(NSWidth(_baseFrame), 1.0);
  const double baseH = MAX(NSHeight(_baseFrame), 1.0);
  _anchorX = std::clamp((pointer.x - NSMinX(_baseFrame)) / baseW, 0.0, 1.0);
  _anchorY = std::clamp((pointer.y - NSMinY(_baseFrame)) / baseH, 0.0, 1.0);

  double low, high;
  zen_pip_zoom::WidthLimits(_aspect, [self minSize], [self maxSize], _visible, &low, &high);
  _scaleFloor = low / baseW;
  _scaleCeiling = high / baseW;
  _scale = 1.0;
  _targetScale = 1.0;

  _hitMinHaptic = (_scaleFloor >= 1.0 - 0.0005);
  _hitMaxHaptic = (_scaleCeiling <= 1.0 + 0.0005);
  // Where the window started decides where a finished resize goes: docked pairs
  // of (corner, frame) are captured from the untouched base frame.
  _startCorner = zen_pip_zoom::NearestDockCorner(
      {NSMinX(_baseFrame), NSMinY(_baseFrame), NSWidth(_baseFrame), NSHeight(_baseFrame)}, _visible,
      zen_pip_zoom::kSnapTolerance);

  ZenPiPController *controller = [ZenPiPController forWindow:window];
  [controller disarmSwipe];
  [controller pinchBegan];
  // Freeze the picture at its current size for the whole gesture. AppKit then
  // stretches the last composited frame with the card (the same path a mouse
  // edge-drag takes), so window and video change size in the same frame instead
  // of Gecko re-laying-out and re-resampling the video a frame or two behind.
  [controller beginOwnedLiveResize];
}

- (void)applyScale {
  NSWindow *window = _window;
  if (!window || !_resizing) return;
  // A gesture that has not changed the scale yet must not nudge the window by a
  // rounding pixel before it has moved.
  if (_scale == 1.0) return;

  const zen_pip_zoom::Result result = zen_pip_zoom::ResizeFromBase(
      {NSMinX(_baseFrame), NSMinY(_baseFrame), NSWidth(_baseFrame), NSHeight(_baseFrame)}, _aspect, _scale, _anchorX,
      _anchorY, {_pointer.x, _pointer.y}, _visible, [self minSize], [self maxSize], [self frameQuantum]);

  const NSRect next = NSMakeRect(result.frame.x, result.frame.y, result.frame.w, result.frame.h);
  if (!NSEqualRects(next, window.frame)) {
    // display:NO is critical: forcing a synchronous redraw at 90-120Hz clogs the
    // Cocoa runloop and drops frames. WindowServer / compositor handles async presentation smoothly.
    [window setFrame:next display:NO];
  }
  // No shadow work here. The shadow is switched off for the gesture (it is the
  // most expensive thing to rasterise per tick) and the live resize scales what
  // is already on screen with the card. It is rebuilt once from the final frame.
  _last = window.frame;

  CheckBoundaryHaptic(_scale, _scaleFloor, YES, &_hitMinHaptic);
  CheckBoundaryHaptic(_scale, _scaleCeiling, NO, &_hitMaxHaptic);
}

- (void)stopEase {
  if (_ease) {
    [_ease invalidate];
    [_ease release];
    _ease = nil;
  }
  if (_easeDisplayLink) {
    if (@available(macOS 14.0, *)) {
      [(CADisplayLink *)_easeDisplayLink invalidate];
    }
    [_easeDisplayLink release];
    _easeDisplayLink = nil;
  }
  _targetScale = _scale;
}

- (void)stopIdle {
  if (_idle) {
    [_idle invalidate];
    [_idle release];
    _idle = nil;
  }
}

- (void)resetSession {
  [self stopEase];
  [self stopIdle];
  // The gesture is over: leave live-resize mode so Gecko repaints the picture at
  // the final size. Always paired, including on the abandon/cancel paths.
  [[ZenPiPController forWindow:_window] endOwnedLiveResize];
  _resizing = NO;
  _endPending = NO;
  _baseFrame = NSZeroRect;
  _last = NSZeroRect;
  _scale = _targetScale = 1.0;
  _startCorner = zen_pip_zoom::kAnchorNone;
  _visible = {0, 0, 0, 0};
  _hitMinHaptic = NO;
  _hitMaxHaptic = NO;
}

- (void)restartIdle:(CFTimeInterval)delay {
  [self stopIdle];
  __unsafe_unretained ZenPiPZoom *weakSelf = self;
  _idle = [[NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) {
    ZenPiPZoom *strongSelf = weakSelf;
    if (!strongSelf) {
      [timer invalidate];
      return;
    }
    [strongSelf requestEnd];
  }] retain];
  [NSRunLoop.currentRunLoop addTimer:_idle forMode:NSRunLoopCommonModes];
}

// Ask for the gesture to end. If an ease is still running let it land first,
// otherwise a snap would be calculated from a half-finished size.
- (void)requestEnd {
  if (!_resizing) return;
  if (_ease || _easeDisplayLink) {
    _endPending = YES;
    return;
  }
  [self finishResize];
}

- (void)finishResize {
  if (!_resizing) return;
  NSWindow *window = _window;
  if (!window) {
    [self resetSession];
    return;
  }

  const NSRect frame = window.frame;
  const zen_pip_zoom::Rect current{NSMinX(frame), NSMinY(frame), NSWidth(frame), NSHeight(frame)};
  const zen_pip_zoom::Rect rest = zen_pip_zoom::KeepOnScreen(current, _visible);
  // A gesture that began docked goes home: the cursor-anchored scaling is the
  // only thing that moved it away from its corner. A gesture that began free
  // snaps only when it came to rest next to a corner, and stays put anywhere
  // else on the screen.
  zen_pip_zoom::AnchorCorner snap = _startCorner;
  if (snap == zen_pip_zoom::kAnchorNone) {
    snap = zen_pip_zoom::NearestDockCorner(rest, _visible, zen_pip_zoom::kSnapTolerance);
  }

  // Resolve the corner slot against the screen the gesture started on, never the
  // one the picture may have drifted onto while it overflowed an edge.
  NSRect target = NSZeroRect;
  if (snap != zen_pip_zoom::kAnchorNone) {
    const zen_pip_throw::Rect slot = zen_pip_throw::CornerFrame(
        static_cast<zen_pip_throw::Corner>(snap), current.w, current.h,
        {_visible.x, _visible.y, _visible.w, _visible.h});
    target = NSMakeRect(slot.x, slot.y, slot.w, slot.h);
  }
  [self resetSession];

  ZenPiPController *controller = [ZenPiPController forWindow:window];
  if (NSIsEmptyRect(target) && (rest.x != current.x || rest.y != current.y)) {
    // Nothing to dock into: undo any overflow in one step and stay right there.
    [window setFrame:NSMakeRect(rest.x, rest.y, rest.w, rest.h) display:NO];
  }
  [controller pinchEndedAtFrame:target];
}

// Cancellation never snaps: something else (a swipe, a drag, a close) owns the
// window now.
- (void)abandon {
  const BOOL wasResizing = _resizing;
  NSWindow *window = _window;
  [self resetSession];
  if (wasResizing && window) {
    [[ZenPiPController forWindow:window] pinchEndedAtFrame:NSZeroRect];
  }
}

- (void)handleMagnify:(NSEvent *)event {
  NSWindow *window = _window;
  if (!window) return;

  // A magnify can arrive twice: once through the global monitor while Zen is
  // inactive, once through the local monitor on the turn it becomes active. Zoom
  // once per event.
  if (event.timestamp <= _lastMagnifyAt) return;
  _lastMagnifyAt = event.timestamp;

  if (event.phase == NSEventPhaseEnded || event.phase == NSEventPhaseCancelled) {
    [self requestEnd];
    return;
  }

  const NSPoint pointer = [ZenPiPZoom screenPoint:event];
  [self beginResizeAt:pointer];
  _endPending = NO;

  // Prevent trackpad delta spikes by clamping the step factor.
  const double stepScale = std::clamp(1.0 + event.magnification, 0.90, 1.10);
  _targetScale = std::clamp(_targetScale * stepScale, _scaleFloor, _scaleCeiling);
  // The window is moved by a display link instead of once per event: trackpad
  // magnify events arrive at 60-90 Hz and in bursts, so applying them directly
  // makes the geometry step unevenly even on a 120 Hz display.
  [self startEase:kPinchTau];
  [self restartIdle:kPinchIdle];
}

- (void)dealloc {
  [self stopEase];
  [self stopIdle];
  [super dealloc];
}

- (void)easeTick:(id)sender {
  if (!_resizing || !_window || !_window.visible || !NSEqualRects(_window.frame, _last)) {
    if (_resizing) {
      [self finishResize];
    } else {
      [self stopEase];
    }
    return;
  }

  // A finished gesture lands on its target in one tick. The snap has to be
  // computed from the size the fingers asked for, never from a half-eased one.
  if (_endPending) {
    _scale = _targetScale;
    [self applyScale];
    [self stopEase];
    [self finishResize];
    return;
  }

  CFTimeInterval now = CACurrentMediaTime();
  if (@available(macOS 14.0, *)) {
    if ([sender isKindOfClass:[CADisplayLink class]]) {
      CADisplayLink *dl = (CADisplayLink *)sender;
      if (dl.targetTimestamp > 0) now = dl.targetTimestamp;
    }
  }
  // Clamp the step: a stalled main thread must not turn one tick into a jump.
  const double dt = std::clamp(now - _easeLastAt, 1.0 / 240.0, 1.0 / 30.0);
  _easeLastAt = now;

  const double delta = _targetScale - _scale;
  if (std::fabs(delta) < 0.0015) {
    _scale = _targetScale;
    [self applyScale];
    [self stopEase];
    return;
  }

  // Frame-rate independent approach with a fixed time constant, so the glide
  // feels the same on a 120 Hz ProMotion panel and on an external 60 Hz one.
  const double alpha = 1.0 - std::exp(-dt / _easeTau);
  _scale += delta * alpha;
  [self applyScale];
}

// Drive `_scale` towards `_targetScale` from a display link. One link per
// gesture: a newly arrived tau only retunes the approach already running.
- (void)startEase:(double)tau {
  if (!_resizing) return;
  _easeTau = tau;
  if (_ease || _easeDisplayLink) return;

  _easeLastAt = CACurrentMediaTime();
  if (@available(macOS 14.0, *)) {
    CADisplayLink *link = [_window.contentView displayLinkWithTarget:self selector:@selector(easeTick:)];
    link.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    _easeDisplayLink = [link retain];
    return;
  }

  __unsafe_unretained ZenPiPZoom *weakSelf = self;
  _ease = [[NSTimer timerWithTimeInterval:1.0 / 120 repeats:YES block:^(NSTimer *timer) {
    ZenPiPZoom *strongSelf = weakSelf;
    if (!strongSelf) {
      [timer invalidate];
      return;
    }
    [strongSelf easeTick:timer];
  }] retain];
  [NSRunLoop.currentRunLoop addTimer:_ease forMode:NSRunLoopCommonModes];
}

- (void)zoomBy:(double)factor at:(NSPoint)pointer ease:(BOOL)ease {
  NSWindow *window = _window;
  if (!window) return;
  [[ZenPiPController forWindow:window] cancelMotion];  // stop the spring, keep gesture chrome
  [self beginResizeAt:pointer];
  if (!_resizing) return;
  _endPending = NO;

  if (!ease) {
    // Precise trackpad scroll: 1:1 with the fingers. Land any glide still in
    // flight first, so this step is applied to the size actually on screen
    // (stopEase syncs the target down to the applied scale).
    [self stopEase];
    _targetScale = std::clamp(_targetScale * factor, _scaleFloor, _scaleCeiling);
    _scale = _targetScale;
    [self applyScale];
    [self restartIdle:kScrollIdle];
    return;
  }

  _targetScale = std::clamp(_targetScale * factor, _scaleFloor, _scaleCeiling);
  [self restartIdle:kScrollIdle];
  [self startEase:kScrollTau];
}

- (zen_pip_zoom::Size)minSize {
  NSSize size = _window.contentMinSize;
  return {size.width, size.height};
}

- (zen_pip_zoom::Size)maxSize {
  NSSize size = _window.contentMaxSize;
  return {size.width > 0 ? size.width : CGFLOAT_MAX, size.height > 0 ? size.height : CGFLOAT_MAX};
}

// One device pixel in points. A Retina screen gets half-point frames, which is
// what makes a slow zoom move one pixel at a time instead of two.
- (double)frameQuantum {
  const CGFloat scale = _window ? _window.backingScaleFactor : 1.0;
  return scale > 1.0 ? 1.0 / scale : 1.0;
}

@end
