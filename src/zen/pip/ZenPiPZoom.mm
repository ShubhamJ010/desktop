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

// Idle timeouts for devices that never send an end phase. They must be well behind
// a held gesture's event rate, or a pause would snap the window mid-pinch.
constexpr CFTimeInterval kPinchIdle = 0.45;
constexpr CFTimeInterval kScrollIdle = 0.35;
// Time constants for the eased approach: pinch short enough to feel 1:1, wheel
// long enough to read as a glide.
constexpr double kPinchTau = 0.022;
constexpr double kScrollTau = 0.055;

}  // namespace

@implementation ZenPiPZoom {
  __unsafe_unretained NSWindow *_window;
  // Session state: captured once at gesture start, never mutated.
  BOOL _resizing;
  NSRect _baseFrame;
  double _anchorX, _anchorY;
  double _aspect;
  double _scale;        // applied scale, relative to _baseFrame
  double _targetScale;  // eased destination for wheel steps
  double _scaleFloor, _scaleCeiling;
  NSRect _last;  // frame we last wrote, to notice movement from elsewhere
  NSPoint _pointer;
  // Corner the window was docked in at gesture start. Only decides where a finished
  // resize snaps; it never constrains the resize.
  zen_pip_zoom::AnchorCorner _startCorner;
  // Visible frame of the gesture's screen, kept for the session.
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

// Zoomable when on screen and not stashed against an edge. `styleMask` is not
// checked: attach makes every PiP resizable, and the resize runs through AppKit's
// live-resize machinery rather than a drag handle.
+ (BOOL)zooms:(NSWindow *)window {
  if (!window || ![window isKindOfClass:[NSWindow class]]) return NO;
  if (!window.visible) return NO;
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
  ZenPiPController *controller = [ZenPiPController controllerUnderPointerAllowingOccluded:YES];
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

// Two resize kinds. A trackpad scroll is offered to the swipe handler first and
// resizes only while Command is held; a mouse wheel always resizes. A magnify
// always resizes. `gZoomGesture` keeps the window for one continuous gesture,
// including the momentum phase that ends it.
+ (BOOL)route:(NSEvent *)event {
  if (event.type == NSEventTypeMagnify) return [self routeMagnify:event];
  if (event.type == NSEventTypeScrollWheel) return [self routeScroll:event];
  return NO;
}

+ (BOOL)routeScroll:(NSEvent *)event {
  NSWindow *window = [self windowFor:event];
  const BOOL command = (event.modifierFlags & NSEventModifierFlagCommand) != 0;
  const NSEventPhase phase = event.phase, momentum = event.momentumPhase;
  // A mouse wheel has no phases: each tick is a gesture of its own.
  const BOOL wheel = phase == NSEventPhaseNone && momentum == NSEventPhaseNone;
  if (wheel || (phase & (NSEventPhaseBegan | NSEventPhaseMayBegin))) gZoomGesture = nil;
  if (gZoomGesture) window = gZoomGesture;
  if (![self zooms:window]) return NO;
  // Command is the explicit resize request; without it a scroll only continues a
  // resize already under way.
  if (!command && gZoomGesture != window) return NO;
  // Front once per gesture: a precise scroll arrives at up to 120 Hz, and each
  // orderFront is a WindowServer round trip.
  if (gZoomGesture != window) {
    ZenPiPController *controller = [ZenPiPController forWindow:window];
    if (controller) {
      [controller frontForGesture];
      [controller focusPiP];
    } else {
      [window orderFrontRegardless];
    }
  }
  if (!wheel) gZoomGesture = window;
  const BOOL ended = (momentum & (NSEventPhaseEnded | NSEventPhaseCancelled)) != 0;
  if (ended) gZoomGesture = nil;
  const double dy = event.scrollingDeltaY;
  if (dy != 0) {
    [[self forWindow:window] zoomBy:zen_pip_zoom::ScrollFactor(dy, event.hasPreciseScrollingDeltas)
                                 at:[self screenPoint:event]
                               ease:!event.hasPreciseScrollingDeltas];
  }
  if (ended) [[self forWindow:window] requestEnd];
  return YES;
}

+ (BOOL)routeMagnify:(NSEvent *)event {
  NSWindow *window = [self windowFor:event];
  const NSEventPhase phase = event.phase;
  if (phase & (NSEventPhaseBegan | NSEventPhaseMayBegin)) gZoomGesture = nil;
  if (gZoomGesture) window = gZoomGesture;
  if (![self zooms:window]) return NO;
  ZenPiPController *controller = [ZenPiPController forWindow:window];
  if (controller) {
    [controller frontForGesture];
    [controller focusPiP];
  } else if (gZoomGesture != window) {
    [window orderFrontRegardless];
  }
  gZoomGesture = window;
  if (phase & (NSEventPhaseEnded | NSEventPhaseCancelled)) gZoomGesture = nil;
  [[self forWindow:window] handleMagnify:event];
  return YES;
}

+ (NSPoint)screenPoint:(NSEvent *)event {
  return event.window ? [event.window convertPointToScreen:event.locationInWindow] : NSEvent.mouseLocation;
}

// AppKit knows the video aspect from `lockaspectratio`. Deriving it from a rounded
// frame would drift and letterbox the picture as the window resizes.
- (double)lockedAspect {
  NSSize locked = _window ? _window.contentAspectRatio : NSZeroSize;
  if (locked.width > 0 && locked.height > 0) return locked.width / locked.height;
  const NSRect frame = _window ? _window.frame : NSZeroRect;
  return NSWidth(frame) / MAX(NSHeight(frame), 1.0);
}

- (void)beginResizeAt:(NSPoint)pointer {
  NSWindow *window = _window;
  if (!window || _resizing) return;
  // One front per gesture, before any frame change, so the card is above another
  // app's windows for the whole gesture.
  ZenPiPController *controller = [ZenPiPController forWindow:window];
  [controller frontForGesture];
  [controller focusPiP];

  _resizing = YES;
  _endPending = NO;
  _pointer = pointer;
  _baseFrame = window.frame;
  _last = _baseFrame;
  // The screen is captured once. Re-resolving per tick could flip onto a
  // neighbouring display and change the size limits mid-gesture.
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
  // The starting corner decides where a finished resize goes, measured from the
  // untouched base frame.
  _startCorner = zen_pip_zoom::NearestDockCorner(
      {NSMinX(_baseFrame), NSMinY(_baseFrame), NSWidth(_baseFrame), NSHeight(_baseFrame)}, _visible,
      zen_pip_zoom::kSnapTolerance);

  [controller disarmSwipe];
  [controller pinchBegan];
  // Freeze the picture for the gesture so AppKit stretches the last frame with the
  // card, instead of Gecko laying out a frame or two behind.
  [controller beginOwnedLiveResize];
}

- (void)applyScale {
  NSWindow *window = _window;
  if (!window || !_resizing) return;
  // A gesture that has not changed scale must not move the window by a rounding
  // pixel.
  if (_scale == 1.0) return;

  const zen_pip_zoom::Result result = zen_pip_zoom::ResizeFromBase(
      {NSMinX(_baseFrame), NSMinY(_baseFrame), NSWidth(_baseFrame), NSHeight(_baseFrame)}, _aspect, _scale, _anchorX,
      _anchorY, {_pointer.x, _pointer.y}, _visible, [self minSize], [self maxSize], [self frameQuantum]);

  const NSRect next = NSMakeRect(result.frame.x, result.frame.y, result.frame.w, result.frame.h);
  if (!NSEqualRects(next, window.frame)) {
    // display:NO avoids a synchronous redraw at 90-120 Hz; the compositor presents
    // asynchronously.
    [window setFrame:next display:NO];
  }
  // No shadow work here: it is off for the gesture and the live resize scales what
  // is on screen. Rebuilt once from the final frame.
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
  // Leave live-resize mode so Gecko repaints at the final size. Always paired,
  // including the abandon path.
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

// Let a running ease land first, or the snap is computed from a half-finished size.
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
  // A gesture that began docked goes home; one that began free snaps only when it
  // stops next to a corner.
  zen_pip_zoom::AnchorCorner snap = _startCorner;
  if (snap == zen_pip_zoom::kAnchorNone) {
    snap = zen_pip_zoom::NearestDockCorner(rest, _visible, zen_pip_zoom::kSnapTolerance);
  }

  // Resolve the corner slot on the gesture's screen, not the one the picture drifted
  // onto.
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
    // Nothing to dock into: undo any overflow in one step.
    [window setFrame:NSMakeRect(rest.x, rest.y, rest.w, rest.h) display:NO];
  }
  [controller pinchEndedAtFrame:target];
}

// Cancellation never snaps: something else owns the window now.
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

  // A magnify can arrive twice, from the global and the local monitor, on the turn
  // Zen activates. Zoom once per event.
  if (event.timestamp <= _lastMagnifyAt) return;
  _lastMagnifyAt = event.timestamp;

  if (event.phase == NSEventPhaseEnded || event.phase == NSEventPhaseCancelled) {
    [self requestEnd];
    return;
  }

  const NSPoint pointer = [ZenPiPZoom screenPoint:event];
  [self beginResizeAt:pointer];
  _endPending = NO;

  // Clamp the step factor against trackpad delta spikes.
  const double stepScale = std::clamp(1.0 + event.magnification, 0.90, 1.10);
  _targetScale = std::clamp(_targetScale * stepScale, _scaleFloor, _scaleCeiling);
  // A display link moves the window: magnify events arrive at 60-90 Hz in bursts,
  // so applying them directly steps unevenly.
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

  // A finished gesture lands on its target in one tick; the snap uses the size the
  // fingers asked for.
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
  // Clamp the step so a stalled main thread cannot turn one tick into a jump.
  const double dt = std::clamp(now - _easeLastAt, 1.0 / 240.0, 1.0 / 30.0);
  _easeLastAt = now;

  const double delta = _targetScale - _scale;
  if (std::fabs(delta) < 0.0015) {
    _scale = _targetScale;
    [self applyScale];
    [self stopEase];
    return;
  }

  // Frame-rate independent approach, so the glide feels the same at 120 Hz and 60 Hz.
  const double alpha = 1.0 - std::exp(-dt / _easeTau);
  _scale += delta * alpha;
  [self applyScale];
}

// Drive `_scale` towards `_targetScale` from a display link, one per gesture. A
// newly arrived tau only retunes the approach already running.
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
    // Precise scroll: 1:1 with the fingers. Land any glide first so the step applies
    // to the size on screen.
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

// One device pixel in points, so a slow zoom moves one pixel at a time on Retina.
- (double)frameQuantum {
  const CGFloat scale = _window ? _window.backingScaleFactor : 1.0;
  return scale > 1.0 ? 1.0 / scale : 1.0;
}

@end
