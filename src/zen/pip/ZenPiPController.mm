#import "ZenPictureInPictureInternal.h"
#import "ZenPiPThrowMath.h"
#import "ZenPiPZoomMath.h"

#if __has_include("mozilla/Services.h")
#include "mozilla/Services.h"
#include "nsCOMPtr.h"
#include "nsIObserverService.h"
#endif

#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import <os/log.h>
#import <os/signpost.h>

using namespace zen_pip;

namespace {

NSString *const kKeepOnTopDefault = @"ZenPictureInPictureKeepOnTop";
NSString *const kGestureTimingDefault = @"ZenPictureInPictureGestureTiming";
const void *const kControllerKey = &kControllerKey;

os_log_t PiPGestureLog() {
  static os_log_t log;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    log = os_log_create("app.zen-browser.pip", "gesture");
  });
  return log;
}

// Gated probe: `defaults write app.zen-browser.zen-custom ZenPictureInPictureGestureTiming -bool YES`
// or `ZEN_PIP_GESTURE_TIMING=1`. Read once; restart the app to toggle.
BOOL GestureTimingEnabled() {
  static BOOL enabled;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    enabled = NSProcessInfo.processInfo.environment[@"ZEN_PIP_GESTURE_TIMING"] != nil ||
              [NSUserDefaults.standardUserDefaults boolForKey:kGestureTimingDefault];
  });
  return enabled;
}

BOOL KeepOnTop() {
  id value = [NSUserDefaults.standardUserDefaults objectForKey:kKeepOnTopDefault];
  return value ? [value boolValue] : YES;
}

os_signpost_id_t gGestureSignpost = OS_SIGNPOST_ID_NULL;

NSScreen *OverlappingScreen(NSRect frame) {
  NSScreen *best = nil;
  CGFloat bestArea = 0;
  for (NSScreen *screen in NSScreen.screens) {
    NSRect overlap = NSIntersectionRect(frame, screen.frame);
    CGFloat area = overlap.size.width * overlap.size.height;
    if (area > bestArea) best = screen, bestArea = area;
  }
  return best;
}

BOOL ScreenAt(CGFloat x, CGFloat y) {
  for (NSScreen *screen in NSScreen.screens)
    if (NSPointInRect(NSMakePoint(x, y), screen.frame)) return YES;
  return NO;
}

static __unsafe_unretained NSWindow *gDragged = nil;
NSPoint gLastMouse;
NSPoint gGrabLocal;
static __unsafe_unretained NSScreen *gDragHome = nil;
std::vector<zen_pip_throw::Sample> gDragSamples;

NSPoint ScreenLocation(NSEvent *event) {
  CGPoint point = CGEventGetLocation(event.CGEvent);
  return NSMakePoint(point.x, NSMaxY(NSScreen.screens.firstObject.frame) - point.y);
}

void SampleDrag(NSEvent *event, NSPoint mouse) {
  if (gDragSamples.size() >= 64) gDragSamples.erase(gDragSamples.begin(), gDragSamples.begin() + 32);
  gDragSamples.push_back({event.timestamp, mouse.x, mouse.y});
}

}

namespace zen_pip {

NSScreen *ScreenFor(NSRect frame) { return OverlappingScreen(frame) ?: NSScreen.mainScreen; }

zen_pip_throw::Rect ThrowRect(NSRect r) { return {NSMinX(r), NSMinY(r), NSWidth(r), NSHeight(r)}; }

int ScreenIndex(NSScreen *screen) {
  const NSUInteger index = screen ? [NSScreen.screens indexOfObjectIdenticalTo:screen] : NSNotFound;
  return index == NSNotFound ? -1 : (int)index;
}

std::vector<zen_pip_throw::Screen> ThrowScreens() {
  std::vector<zen_pip_throw::Screen> screens;
  for (NSScreen *screen in NSScreen.screens) screens.push_back({ThrowRect(screen.frame), ThrowRect(screen.visibleFrame)});
  return screens;
}

}

@implementation ZenPiPController

+ (instancetype)forWindow:(NSWindow *)window {
  if (!window || ![window isKindOfClass:[NSWindow class]]) return nil;
  return objc_getAssociatedObject(window, kControllerKey);
}

+ (BOOL)attachToWindow:(NSWindow *)window {
  if (!window || ![window isKindOfClass:[NSWindow class]]) return NO;
  ZenPiPController *existing = [self forWindow:window];
  if (existing) return YES;
  ZenPiPController *controller = [[[ZenPiPController alloc] initWithWindow:window] autorelease];
  // Clicking or gesturing the PiP must front the window, not the whole app.
  [window _setPreventsActivation:YES];
  [controller roundCorners];
  InstallMonitors();
  return YES;
}

+ (void)detachFromWindow:(NSWindow *)window {
  if (!window || ![window isKindOfClass:[NSWindow class]]) return;
  ZenPiPController *controller = [self forWindow:window];
  if (controller) {
    [controller detach];
  }
  [ZenPiPZoom abandonZoomOn:window];
}

- (instancetype)initWithWindow:(NSWindow *)window {
  if ((self = [super init])) {
    _window = window;
    NSView *root = window.contentView;
    _overlay = [[ZenPiPOverlay alloc] initWithFrame:root.bounds];
    __unsafe_unretained ZenPiPController *weakSelf = self;
    _overlay.handle.onClick = ^{ [weakSelf unstash]; };
    [root addSubview:_overlay];
    objc_setAssociatedObject(window, kControllerKey, self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    _observers = [[NSMutableArray alloc] init];
    for (NSNotificationName name in @[ NSWindowDidMoveNotification, NSWindowDidResizeNotification ]) {
      [_observers addObject:[center addObserverForName:name object:window queue:nil usingBlock:^(NSNotification *) {
                    [weakSelf windowMoved];
                  }]];
    }
    [_observers addObject:[center addObserverForName:NSWindowDidResizeNotification
                                              object:window
                                               queue:nil
                                          usingBlock:^(NSNotification *) { [weakSelf roundCorners]; }]];
    [_observers addObject:[center addObserverForName:NSWindowDidChangeScreenNotification
                                              object:window
                                               queue:nil
                                          usingBlock:^(NSNotification *) { [weakSelf screenChanged]; }]];
    [_observers addObject:[center addObserverForName:NSApplicationDidChangeScreenParametersNotification
                                              object:NSApp
                                               queue:nil
                                          usingBlock:^(NSNotification *) { [weakSelf screenChanged]; }]];
    [_observers addObject:[center addObserverForName:NSWindowWillStartLiveResizeNotification
                                              object:window
                                               queue:nil
                                          usingBlock:^(NSNotification *) { [weakSelf stopMotion]; }]];
    [_observers addObject:[center addObserverForName:NSWindowWillCloseNotification
                                              object:window
                                               queue:nil
                                          usingBlock:^(NSNotification *) { [weakSelf detach]; }]];
    self.keepOnTop = KeepOnTop();
  }
  return self;
}

- (void)detach {
  if (_detached) return;
  _detached = YES;
  [self retain];
  [self disarmSwipe];
  [self showCursorIfNeeded];
  [ZenPiPController abandonSwipeOn:_window];
  [ZenPiPZoom abandonZoomOn:_window];
  if (gDragged == _window) {
    gDragged = nil;
    gDragHome = nil;
    gDragSamples.clear();
  }
  [self stopMotion];
  if (_observers) {
    for (id observer in _observers) [NSNotificationCenter.defaultCenter removeObserver:observer];
    [_observers removeAllObjects];
    [_observers release];
    _observers = nil;
  }
  [NSObject cancelPreviousPerformRequestsWithTarget:self];
  if (_overlay) {
    [_overlay removeFromSuperview];
    [_overlay release];
    _overlay = nil;
  }
  if (_window) {
    NSWindow *win = _window;
    _window = nil;
    objc_setAssociatedObject(win, kControllerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  [self release];
}

- (void)dealloc {
  [self showCursorIfNeeded];
  if (!_detached) {
    [self detach];
  }
  [_lastScreenFit release];
  _lastScreenFit = nil;
  [_host release];
  _host = nil;
  [super dealloc];
}

+ (void)updateShadowPathForWindow:(NSWindow *)window size:(CGSize)size radius:(CGFloat)radius {
  if (!window) return;
  CALayer *layer = window.contentView.layer;
  if (!layer) return;
  CGPathRef p = CGPathCreateWithRoundedRect(CGRectMake(0, 0, size.width, size.height), radius, radius, NULL);
  layer.shadowPath = p;
  CGPathRelease(p);
}

+ (void)updateShadowPathForWindow:(NSWindow *)window radius:(CGFloat)radius {
  if (!window) return;
  [self updateShadowPathForWindow:window size:window.contentView.layer.bounds.size radius:radius];
}

static void NotifyPiPGestureActive(bool active) {
#if __has_include("mozilla/Services.h")
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{
      NotifyPiPGestureActive(active);
    });
    return;
  }
  if (nsCOMPtr<nsIObserverService> obs = mozilla::services::GetObserverService()) {
    obs->NotifyObservers(nullptr, active ? "zen-pip-gesture-begin" : "zen-pip-gesture-end", nullptr);
  }
#endif
}

- (void)setOverlayVisible:(BOOL)visible animated:(BOOL)animated {
  if (!_overlay) return;
  if (!animated) {
    _overlay.alphaValue = visible ? 1.0 : 0.0;
    return;
  }
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
    ctx.duration = 0.15;
    ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    _overlay.animator.alphaValue = visible ? 1.0 : 0.0;
  } completionHandler:nil];
}

- (void)setPiPUIVisible:(BOOL)visible {
  [self setOverlayVisible:visible animated:YES];
  NotifyPiPGestureActive(!visible);
}

- (void)setElevated:(BOOL)elevated animated:(BOOL)animated {
  if (_isElevated == elevated || !_window) return;
  _isElevated = elevated;
  CALayer *layer = _window.contentView.layer;
  if (!layer) return;

  const CGFloat targetOpacity = elevated ? 0.38 : 0.20;
  const CGFloat targetRadius = elevated ? 24.0 : 10.0;
  const CGSize targetOffset = elevated ? CGSizeMake(0, -10) : CGSizeMake(0, -4);

  [ZenPiPController updateShadowPathForWindow:_window radius:10];

  if (!animated) {
    layer.shadowColor = [NSColor blackColor].CGColor;
    layer.shadowOpacity = targetOpacity;
    layer.shadowRadius = targetRadius;
    layer.shadowOffset = targetOffset;
    return;
  }

  [CATransaction begin];
  [CATransaction setAnimationDuration:0.20];
  [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];

  CABasicAnimation *opacityAnim = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
  opacityAnim.fromValue = @(layer.shadowOpacity);
  opacityAnim.toValue = @(targetOpacity);
  [layer addAnimation:opacityAnim forKey:@"shadowOpacity"];

  CABasicAnimation *radiusAnim = [CABasicAnimation animationWithKeyPath:@"shadowRadius"];
  radiusAnim.fromValue = @(layer.shadowRadius);
  radiusAnim.toValue = @(targetRadius);
  [layer addAnimation:radiusAnim forKey:@"shadowRadius"];

  CABasicAnimation *offsetAnim = [CABasicAnimation animationWithKeyPath:@"shadowOffset"];
  offsetAnim.fromValue = [NSValue valueWithSize:layer.shadowOffset];
  offsetAnim.toValue = [NSValue valueWithSize:targetOffset];
  [layer addAnimation:offsetAnim forKey:@"shadowOffset"];

  layer.shadowColor = [NSColor blackColor].CGColor;
  layer.shadowOpacity = targetOpacity;
  layer.shadowRadius = targetRadius;
  layer.shadowOffset = targetOffset;
  [CATransaction commit];
}

- (void)roundCorners {
  if (!_window) return;
  // During a snap/resize animation the layer setup is already in place; rebuilding
  // the shadow path on every resize tick is pure per-frame cost.
  if (_animating) return;
  NSView *content = _window.contentView;
  content.wantsLayer = YES;
  CALayer *layer = content.layer;
  if (layer.cornerCurve != kCACornerCurveCircular || layer.masksToBounds) {
    layer.cornerCurve = kCACornerCurveCircular;
    layer.masksToBounds = NO; // Allow shadow to cast outside content
  }
  CALayer *rim = _overlay.layer;
  rim.cornerCurve = kCACornerCurveCircular;
  rim.borderWidth = 1;
  rim.borderColor = [NSColor colorWithWhite:1 alpha:kRimAlpha].CGColor;
  [self fitCorners:NO];
  _window.opaque = NO;
  _window.backgroundColor = NSColor.clearColor;

  layer.shadowColor = [NSColor blackColor].CGColor;
  layer.shadowOpacity = _isElevated ? 0.38 : 0.20;
  layer.shadowRadius = _isElevated ? 24.0 : 10.0;
  layer.shadowOffset = _isElevated ? CGSizeMake(0, -10) : CGSizeMake(0, -4);
  [ZenPiPController updateShadowPathForWindow:_window radius:10];

  NSWindow *window = [_window retain];
  dispatch_async(dispatch_get_main_queue(), ^{
    [window invalidateShadow];
    [window release];
  });
}

- (CGFloat)cornerRadius {
  return zen_pip_throw::CornerRadius(ThrowRect(_window.frame), ThrowRect([self homeScreen].visibleFrame));
}

- (void)fitCorners:(BOOL)animated {
  [self bendCornersTo:[self cornerRadius] animated:animated];
}

- (void)bendCornersTo:(CGFloat)radius animated:(BOOL)animated {
  CALayer *content = _window.contentView.layer, *rim = _overlay.layer;
  if (!content || !rim) return;
  if (animated && content.cornerRadius == radius && rim.cornerRadius == radius) return;
  __unsafe_unretained NSWindow *window = _window;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [CATransaction setCompletionBlock:^{ [window invalidateShadow]; }];
  for (CALayer *layer in @[ content, rim ]) {
    if (animated) {
      CABasicAnimation *bend = [CABasicAnimation animationWithKeyPath:@"cornerRadius"];
      bend.fromValue = @((layer.presentationLayer ?: layer).cornerRadius);
      bend.toValue = @(radius);
      bend.duration = kCornerBendDuration;
      bend.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
      [layer addAnimation:bend forKey:@"cornerRadius"];
    } else {
      [layer removeAnimationForKey:@"cornerRadius"];
    }
    layer.cornerRadius = radius;
  }
  [CATransaction commit];
}

- (void)setKeepOnTop:(BOOL)keepOnTop {
  _keepOnTop = keepOnTop;
  _window.level = keepOnTop ? NSFloatingWindowLevel : NSNormalWindowLevel;
}

- (void)toggleKeepOnTop:(id)sender {
  self.keepOnTop = !_keepOnTop;
  [NSUserDefaults.standardUserDefaults setBool:_keepOnTop forKey:kKeepOnTopDefault];
}

- (NSMenu *)menu {
  NSMenu *menu = [[[NSMenu alloc] initWithTitle:@""] autorelease];
  NSMenuItem *back = [menu addItemWithTitle:@"Back to Tab" action:@selector(backToTabFromMenu:) keyEquivalent:@""];
  back.target = self;
  [menu addItem:NSMenuItem.separatorItem];
  NSMenuItem *top = [menu addItemWithTitle:@"Keep Window on Top" action:@selector(toggleKeepOnTop:) keyEquivalent:@""];
  top.target = self;
  top.state = _keepOnTop ? NSControlStateValueOn : NSControlStateValueOff;
  return menu;
}

- (void)backToTabFromMenu:(id)sender { [self backToTab]; }

- (void)backToTab {
  [_window performClose:nil];
}

- (void)screenChanged {
  // A cached hover screen may no longer exist after a display reconfiguration.
  [self disarmSwipe];
  NSScreen *screen = [self homeScreen];
  if (_animating || _swiping) return;
  [self fitCorners:YES];
  [_lastScreenFit release];
  _lastScreenFit = [@{
    @"radius" : @([self cornerRadius]),
    @"frame" : NSStringFromRect(_window.frame),
    @"visibleFrame" : NSStringFromRect(screen.visibleFrame),
  } retain];
}

- (void)windowMoved {
  // Watchdog: a missed gesture end must not leave the window permanently frozen.
  // This is a timestamp compare, not chrome work.
  if (_swiping && NSProcessInfo.processInfo.systemUptime - _swipeLastAt > 1.0) {
    [self abandonSwipe];
  }
  // Chrome is frozen for the whole gesture: no screen lookups, no corner bends and
  // no shadow invalidation may run inside a per-frame `setFrameOrigin:`. Everything
  // is applied once when the motion settles.
  if (_swiping || _animating) return;
  [self homeScreen];
  [self fitCorners:YES];
  if (NSEvent.pressedMouseButtons & 1) _sawDrag = YES;
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(settle) object:nil];
  [self performSelector:@selector(settle) withObject:nil afterDelay:0.12];
}

- (NSScreen *)homeScreen {
  NSScreen *screen = OverlappingScreen(_window.frame);
  if (screen) _lastScreen = screen;
  return screen ?: _lastScreen ?: NSScreen.mainScreen;
}

- (ZenPiPEdge)edgeBeyond {
  NSRect frame = _window.frame;
  NSRect visible = [self homeScreen].visibleFrame;
  CGFloat half = NSWidth(frame) / 2;
  if (NSMaxX(frame) - NSMaxX(visible) > half && !ScreenAt(NSMaxX(visible) + 1, NSMidY(frame))) return ZenPiPEdgeRight;
  if (NSMinX(visible) - NSMinX(frame) > half && !ScreenAt(NSMinX(visible) - 1, NSMidY(frame))) return ZenPiPEdgeLeft;
  return ZenPiPEdgeNone;
}

- (void)settle {
  if (NSEvent.pressedMouseButtons & 1) {
    [self performSelector:@selector(settle) withObject:nil afterDelay:0.12];
    return;
  }
  BOOL dragged = _sawDrag;
  _sawDrag = NO;
  ZenPiPEdge edge = [self edgeBeyond];
  if (edge != ZenPiPEdgeNone) return [self stashAt:edge];
  if (_stashedEdge != ZenPiPEdgeNone && !dragged) return [self stashAt:_stashedEdge];
  if (_stashedEdge != ZenPiPEdgeNone) [self setStashedEdge:ZenPiPEdgeNone];
  [self rescueIfLost];
}

- (NSScreen *)gestureHome {
  return _stashedEdge != ZenPiPEdgeNone && _stashScreen ? _stashScreen : [self homeScreen];
}

- (void)rescueIfLost {
  if (_stashedEdge != ZenPiPEdgeNone || _animating || _swiping || !_window.visible) return;
  const auto screens = ThrowScreens();
  const auto rescued =
      zen_pip_throw::Rescue(ThrowRect(_window.frame), screens.data(), (int)screens.size(), ScreenIndex([self homeScreen]));
  const NSRect target = NSMakeRect(rescued.x, rescued.y, rescued.w, rescued.h);
  if (!NSEqualRects(target, _window.frame)) [self animateTo:target];
}

- (NSRect)frameStashedAt:(ZenPiPEdge)edge {
  NSRect frame = _window.frame;
  NSRect visible = [self homeScreen].visibleFrame;
  frame.origin.x = edge == ZenPiPEdgeRight ? NSMaxX(visible) - kPeek : NSMinX(visible) - NSWidth(frame) + kPeek;
  frame.origin.y = MIN(MAX(NSMinY(frame), NSMinY(visible)), NSMaxY(visible) - NSHeight(frame));
  return frame;
}

- (void)stashAt:(ZenPiPEdge)edge {
  _stashScreen = [self homeScreen];
  [self setStashedEdge:edge];
  [self animateTo:[self frameStashedAt:edge]];
}

- (void)unstash {
  ZenPiPEdge edge = _stashedEdge;
  if (edge == ZenPiPEdgeNone) return;
  NSRect frame = _window.frame;
  NSRect visible = [self homeScreen].visibleFrame;
  frame.origin.x = edge == ZenPiPEdgeRight ? NSMaxX(visible) - NSWidth(frame) - kReturnMargin : NSMinX(visible) + kReturnMargin;
  [self setStashedEdge:ZenPiPEdgeNone];
  [self animateTo:frame];
}

- (void)setStashedEdge:(ZenPiPEdge)edge {
  _stashedEdge = edge;
  ZenPiPHandle *handle = _overlay.handle;
  if (edge != ZenPiPEdgeNone) {
    handle.edge = edge;
    handle.hidden = NO;
    _overlay.needsLayout = YES;
  }
  [NSAnimationContext
      runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.25;
        handle.animator.alphaValue = edge != ZenPiPEdgeNone ? 1 : 0;
      }
      completionHandler:^{
        if (self->_stashedEdge == ZenPiPEdgeNone) handle.hidden = YES;
      }];
}

// Motion only: stop the spring/timer but leave cursor, PiP UI and elevation alone.
// Safe to call synchronously on the gesture-start path.
- (void)cancelMotion {
  if (_slide) {
    [_slide invalidate];
    [_slide release];
    _slide = nil;
  }
  if (_displayLink) {
    // The ivar is `id` because the class is built for macOS 11; invalidate only
    // on systems where CADisplayLink exists.
    if (@available(macOS 14.0, *)) {
      [(CADisplayLink *)_displayLink invalidate];
    }
    [_displayLink release];
    _displayLink = nil;
  }
  _animating = NO;
  _throwActive = NO;
}

- (void)stopMotion {
  [self cancelMotion];
  _carrying = NO;
  _swiping = NO;
  [self showCursorIfNeeded];
  [self setPiPUIVisible:YES];
}

- (void)animateTo:(NSRect)target {
  [self stopMotion];
  [_window orderFrontRegardless];
  NSRect from = _window.frame;
  if (NSEqualRects(from, target)) {
    [self setPiPUIVisible:YES];
    [self showCursorIfNeeded];
    return;
  }
  _animating = YES;
  [self setElevated:YES animated:YES];
  [self bendCornersTo:zen_pip_throw::kFreeRadius animated:NO];
  [self setPiPUIVisible:NO];
  const CFTimeInterval start = CACurrentMediaTime();
  const double initialDistX = NSMinX(from) - NSMinX(target);
  const double initialDistY = NSMinY(from) - NSMinY(target);
  const double initialDistW = NSWidth(from) - NSWidth(target);
  const double initialDistH = NSHeight(from) - NSHeight(target);
  const BOOL sizeChanges = (fabs(initialDistW) > 0.5 || fabs(initialDistH) > 0.5);

  // Pin edges that remain stationary between source and destination frames.
  // Independent rounding of opposite offsets causes stationary edges to vibrate by ±1px;
  // edge-pinning guarantees the anchored screen corner remains dead-still throughout the animation.
  const BOOL pinRight = fabs(NSMaxX(from) - NSMaxX(target)) < 5.0;
  const BOOL pinLeft = fabs(NSMinX(from) - NSMinX(target)) < 5.0;
  const BOOL pinTop = fabs(NSMaxY(from) - NSMaxY(target)) < 5.0;
  const BOOL pinBottom = fabs(NSMinY(from) - NSMinY(target)) < 5.0;
  const CGFloat aspect = NSWidth(from) / MAX(NSHeight(from), 1.0);

  __unsafe_unretained ZenPiPController *weakSelf = self;
  _slide = [[NSTimer scheduledTimerWithTimeInterval:1.0 / 120 repeats:YES block:^(NSTimer *timer) {
    ZenPiPController *strongSelf = weakSelf;
    if (!strongSelf || !strongSelf->_window || !strongSelf->_window.visible) {
      if (strongSelf) [strongSelf stopMotion];
      else [timer invalidate];
      return;
    }
    const double t = CACurrentMediaTime() - start;

    if (sizeChanges) {
      // Single scalar spring drives the animation progress [1.0 -> 0.0].
      // Response = 0.38s, Damping = 0.76 provides smooth spring pop with subtle natural overshoot.
      // Computing height strictly from aspect ratio locks the video quad, eliminating letterbox flicker.
      const auto s = zen_pip_throw::SpringAt(1.0, 0, t, 0.38, 0.76);
      const BOOL done = (std::fabs(s.offset) < 0.005 && std::fabs(s.velocity) < 0.05) || t > 0.55;

      if (done) {
        [strongSelf->_window setFrame:target display:NO];
        [strongSelf->_window.contentView setNeedsDisplay:YES];
        [ZenPiPController updateShadowPathForWindow:strongSelf->_window size:target.size radius:10];
        [strongSelf stopMotion];
        strongSelf->_sawDrag = NO;
        [strongSelf fitCorners:YES];
        [strongSelf rescueIfLost];
        [strongSelf setElevated:NO animated:YES];
        [strongSelf setPiPUIVisible:YES];
        [strongSelf showCursorIfNeeded];
        return;
      }

      const double progress = 1.0 - s.offset;
      const CGFloat curW = MAX(round(NSWidth(from) + (NSWidth(target) - NSWidth(from)) * progress), 100.0);
      const CGFloat curH = MAX(round(curW / aspect), 60.0);

      CGFloat curX;
      if (pinRight && !pinLeft) {
        curX = NSMaxX(target) - curW;
      } else if (pinLeft && !pinRight) {
        curX = NSMinX(target);
      } else {
        curX = round(NSMinX(from) + (NSMinX(target) - NSMinX(from)) * progress);
      }

      CGFloat curY;
      if (pinTop && !pinBottom) {
        curY = NSMaxY(target) - curH;
      } else if (pinBottom && !pinTop) {
        curY = NSMinY(target);
      } else {
        curY = round(NSMinY(from) + (NSMinY(target) - NSMinY(from)) * progress);
      }

      NSRect current = NSMakeRect(curX, curY, curW, curH);
      [strongSelf->_window setFrame:current display:NO];
      [ZenPiPController updateShadowPathForWindow:strongSelf->_window size:current.size radius:10];
    } else {
      // Pure position translation (e.g. corner snap glide)
      const auto sx = zen_pip_throw::SpringAt(initialDistX, 0, t, 0.38, 0.76);
      const auto sy = zen_pip_throw::SpringAt(initialDistY, 0, t, 0.38, 0.76);
      const BOOL done = zen_pip_throw::Resolved(sx, sy);

      if (done) {
        [strongSelf->_window setFrame:target display:NO];
        [strongSelf->_window.contentView setNeedsDisplay:YES];
        [ZenPiPController updateShadowPathForWindow:strongSelf->_window size:target.size radius:10];
        [strongSelf stopMotion];
        strongSelf->_sawDrag = NO;
        [strongSelf fitCorners:YES];
        [strongSelf rescueIfLost];
        [strongSelf setElevated:NO animated:YES];
        [strongSelf setPiPUIVisible:YES];
        [strongSelf showCursorIfNeeded];
        return;
      }

      NSRect current = NSMakeRect(
          round(NSMinX(target) + sx.offset),
          round(NSMinY(target) + sy.offset),
          NSWidth(target),
          NSHeight(target));
      [strongSelf->_window setFrame:current display:NO];
    }
  }] retain];
  [NSRunLoop.currentRunLoop addTimer:_slide forMode:NSRunLoopCommonModes];
}

- (BOOL)throwFrom:(NSPoint)grab velocity:(NSPoint)velocity {
  NSRect frame = _window.frame;
  NSScreen *screen = [self homeScreen];
  zen_pip_throw::Corner corner =
      zen_pip_throw::PickCorner({grab.x, grab.y}, {velocity.x, velocity.y}, ThrowRect(screen.frame));
  if (corner == zen_pip_throw::kNoCorner) return NO;
  zen_pip_throw::Rect target =
      zen_pip_throw::CornerFrame(corner, NSWidth(frame), NSHeight(frame), ThrowRect(screen.visibleFrame));
  [self throwTo:NSMakeRect(target.x, target.y, target.w, target.h) velocity:velocity corner:corner];
  return YES;
}

- (void)throwTo:(NSRect)target velocity:(NSPoint)velocity corner:(int)corner {
  [self cancelMotion];
  [self bendCornersTo:zen_pip_throw::kFreeRadius animated:NO];
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(settle) object:nil];
  _sawDrag = NO;
  _carrying = NO;
  if (_stashedEdge != ZenPiPEdgeNone) [self setStashedEdge:ZenPiPEdgeNone];
  [self setOverlayVisible:NO animated:YES];

  // Keep the throw on the instance so a chained swipe can read the spring's
  // velocity instead of killing it outright.
  _throwFrom = _window.frame;
  _throwTarget = target;
  _throwVelocity = velocity;
  _throwCorner = corner;
  _throwStartAt = CACurrentMediaTime();
  _throwActive = YES;
  _animating = YES;

  if (@available(macOS 14.0, *)) {
    CADisplayLink *link = [_window.contentView displayLinkWithTarget:self selector:@selector(throwTick:)];
    link.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    _displayLink = [link retain];
    return;
  }

  // Fallback for pre-14 macOS: timer, still origin-only and never display:YES.
  __unsafe_unretained ZenPiPController *weakSelf = self;
  _slide = [[NSTimer scheduledTimerWithTimeInterval:1.0 / 120 repeats:YES block:^(NSTimer *timer) {
    [weakSelf throwTick:timer];
  }] retain];
  [NSRunLoop.currentRunLoop addTimer:_slide forMode:NSRunLoopCommonModes];
}

- (void)throwTick:(id)sender {
  if (!_window || !_window.visible) {
    [self stopMotion];
    return;
  }
  CFTimeInterval now = CACurrentMediaTime();
  if (@available(macOS 14.0, *)) {
    if ([sender isKindOfClass:[CADisplayLink class]]) {
      CADisplayLink *dl = (CADisplayLink *)sender;
      if (dl.targetTimestamp > 0) {
        now = dl.targetTimestamp;
      }
    }
  }
  const double t = now - _throwStartAt;
  const auto x = zen_pip_throw::SpringAt(NSMinX(_throwFrom) - NSMinX(_throwTarget), _throwVelocity.x, t);
  const auto y = zen_pip_throw::SpringAt(NSMinY(_throwFrom) - NSMinY(_throwTarget), _throwVelocity.y, t);
  const BOOL done = zen_pip_throw::Resolved(x, y);
  const NSPoint origin = done ? _throwTarget.origin
                              : NSMakePoint(round(NSMinX(_throwTarget) + x.offset), round(NSMinY(_throwTarget) + y.offset));
  if (!NSEqualPoints(origin, _window.frame.origin)) {
    [_window setFrameOrigin:origin];
  }
  if (!done) return;
  [self stopMotion];
  [self endGestureChrome:YES];
  [self rescueIfLost];
}

- (void)dragReleasedAt:(NSPoint)pointer velocity:(NSPoint)velocity {
  const BOOL reduceMotion = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
  const BOOL flings = !reduceMotion && zen_pip_throw::DragFlings({velocity.x, velocity.y}) &&
                      [self edgeBeyond] == ZenPiPEdgeNone;
  const BOOL thrown = flings && [self throwFrom:pointer velocity:velocity];
  if (!thrown) [self rescueIfLost];
}

- (void)swipeBegan:(NSEvent *)event {
  // A throw still in flight means this is a chained flick ("flick to the next
  // corner"): read the spring's current velocity before cancelling it so the
  // window keeps moving instead of stopping dead.
  const BOOL chainedSwipe = _throwActive;
  const NSPoint carry = chainedSwipe ? [self throwVelocityAt:CACurrentMediaTime()] : NSZeroPoint;

  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(settle) object:nil];

  _gestureEventAt = event.timestamp;
  _gestureHandlerAt = CACurrentMediaTime();
  _gestureFirstMoveAt = 0;
  gGestureSignpost = os_signpost_id_generate(PiPGestureLog());

  // A pinch cannot stay active under a swipe; its end timer would otherwise snap
  // the window mid-flick.
  _isPinching = NO;

  // Motion-critical part only. Activation, window reordering, Gecko observers,
  // elevation, cursor and PiP-UI changes are all deferred (see beginGestureChrome).
  [self cancelMotion];
  _swiping = YES;
  // Any pinch still in flight loses: its idle timer would otherwise snap the window
  // in the middle of this flick. Safe here because endGestureChrome no-ops while
  // `_swiping` is set.
  [ZenPiPZoom abandonZoomOn:_window];
  _swipeStart = _window.frame;
  _swipeHome = (_armed && _armedHome) ? _armedHome : [self gestureHome];
  [self disarmSwipe];

  CGPoint point = CGEventGetLocation(event.CGEvent);
  NSPoint pointer = NSMakePoint(point.x, NSMaxY(NSScreen.screens.firstObject.frame) - point.y);
  _swipeGrab = NSMakePoint(MIN(MAX(pointer.x - NSMinX(_swipeStart), 0), NSWidth(_swipeStart)),
                           MIN(MAX(pointer.y - NSMinY(_swipeStart), 0), NSHeight(_swipeStart)));
  _swipePointer = NSEvent.mouseLocation;
  _swipeBeganAt = CACurrentMediaTime();
  _swipeLastDelta = NSZeroPoint;

  if (chainedSwipe && (carry.x != 0 || carry.y != 0)) {
    _swipeCarry = carry;
    _carrying = YES;
    _carryStart = _carryLastAt = CACurrentMediaTime();
  } else {
    _carrying = NO;
  }

  // Move first: this is the only thing the user can see on frame one.
  [self swipeMoved:event];
  [self beginGestureChrome:ZenPiPGestureSwipe chained:chainedSwipe];
}

- (NSPoint)throwVelocityAt:(CFTimeInterval)now {
  if (!_throwActive) return NSZeroPoint;
  const double t = MAX(0.0, now - _throwStartAt);
  const auto x = zen_pip_throw::SpringAt(NSMinX(_throwFrom) - NSMinX(_throwTarget), _throwVelocity.x, t);
  const auto y = zen_pip_throw::SpringAt(NSMinY(_throwFrom) - NSMinY(_throwTarget), _throwVelocity.y, t);
  return NSMakePoint(x.velocity, y.velocity);
}

+ (ZenPiPController *)controllerUnderPointer {
  NSPoint mouse = NSEvent.mouseLocation;
  for (NSWindow *candidate in NSApp.orderedWindows) {
    if (!candidate.visible) continue;
    if (NSPointInRect(mouse, candidate.frame)) {
      ZenPiPController *controller = [self forWindow:candidate];
      if (controller) return controller;
    }
  }
  return nil;
}

// Chrome for both gesture kinds: activate, front the window, hide the PiP UI, the
// cursor and raise the shadow. Always runs one main-loop turn after the first moved
// frame, and is dropped if that gesture is already over.
- (void)beginGestureChrome:(ZenPiPGesture)kind chained:(BOOL)chained {
  const uint64_t generation = ++_gestureGeneration;
  [self retain];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (_gestureGeneration == generation) {
      if ((kind == ZenPiPGestureSwipe && _swiping) ||
          (kind == ZenPiPGesturePinch && _isPinching)) {
        [self applyGestureChrome:kind chained:chained];
      }
    }
    [self release];
  });
}

- (void)applyGestureChrome:(ZenPiPGesture)kind chained:(BOOL)chained {
  if (!_window) return;
  // Window, not app: the PiP is floating level, so orderFrontRegardless puts it
  // above the other app without dragging Zen's browser window forward.
  [_window orderFrontRegardless];
  [self setPiPUIVisible:NO];
  [self setElevated:YES animated:YES];
  [self hideCursorIfNeeded];
  if (GestureTimingEnabled()) {
    const CFTimeInterval moved = _gestureFirstMoveAt;
    NSLog(@"[pip-gesture] chrome applied %@%@, first-move %+.2f ms, event->handler %.2f ms, front: "
           "activated=%d key=%d",
          kind == ZenPiPGesturePinch ? @"(pinch) " : @"",
          chained ? @"(chained)" : @"",
          moved > 0 ? (CACurrentMediaTime() - moved) * 1000.0 : 0.0,
          (_gestureHandlerAt - _gestureEventAt) * 1000.0, NSApp.isActive, _window.isKeyWindow);
  }
}

// Shared tail: controls and shadow back on, corner radius unfrozen, cursor back.
// Idempotent, and a no-op while a swipe still owns the window. `restoreUI:NO` is for
// when another animation (the pinch snap) is about to own the controls itself.
- (void)endGestureChrome:(BOOL)restoreUI {
  if (!_window || _swiping) return;
  [self showCursorIfNeeded];
  if (restoreUI) [self setPiPUIVisible:YES];
  [self setElevated:NO animated:YES];
  if (!_animating) [self fitCorners:YES];
}

- (void)armSwipe {
  if (!_window || _swiping || _animating || _isPinching) return;
  _armed = YES;
  // Resolve the target screen while the pointer is merely hovering, so gesture
  // start never has to walk the screen list.
  _armedHome = [self gestureHome];
}

- (void)disarmSwipe {
  _armed = NO;
  _armedHome = nil;
}

- (void)moveBy:(zen_pip_throw::Point)delta {
  zen_pip_throw::Point d = delta;
  if (_carrying) {
    // Blend the cancelled throw's momentum into the new swipe for ~120 ms.
    const CFTimeInterval now = CACurrentMediaTime();
    const double age = MAX(0.0, now - _carryStart);
    const double dt = MIN(MAX(now - _carryLastAt, 0.0), 0.05);
    _carryLastAt = now;
    const double decay = std::exp(-age / 0.06);
    d.x += _swipeCarry.x * decay * dt;
    d.y += _swipeCarry.y * decay * dt;
    if (decay < 0.02) _carrying = NO;
  }
  if (d.x == 0 && d.y == 0) return;
  const auto screens = ThrowScreens();
  const auto next =
      zen_pip_throw::SwipeStep(ThrowRect(_window.frame), d, screens.data(), (int)screens.size(), ScreenIndex(_swipeHome));
  const NSPoint origin = NSMakePoint(next.x, next.y);
  if (NSEqualPoints(origin, _window.frame.origin)) return;

  [_window setFrameOrigin:origin];
  if (_swiping && _gestureFirstMoveAt == 0) {
    _gestureFirstMoveAt = CACurrentMediaTime();
    os_signpost_event_emit(PiPGestureLog(), gGestureSignpost, "first-move");
    if (GestureTimingEnabled()) {
      NSLog(@"[pip-gesture] first move: %.2f ms after handler (%.2f ms after event)", (self->_gestureFirstMoveAt - _gestureHandlerAt) * 1000.0,
            (self->_gestureFirstMoveAt - _gestureEventAt) * 1000.0);
    }
  }
}

- (void)abandonSwipe {
  [self disarmSwipe];
  if (!_swiping) return;
  _swiping = NO;
  _carrying = NO;
  [self endGestureChrome:YES];
}

- (void)swipeMoved:(NSEvent *)event {
  const auto delta = zen_pip_throw::FingerDelta(event.scrollingDeltaX, event.scrollingDeltaY, event.isDirectionInvertedFromDevice);
  _swipeLastDelta = NSMakePoint(delta.x, delta.y);
  _swipeLastAt = NSProcessInfo.processInfo.systemUptime;
  [self moveBy:delta];
}

- (void)swipeEnded:(NSEvent *)event cancelled:(BOOL)cancelled {
  [self moveBy:zen_pip_throw::FingerDelta(event.scrollingDeltaX, event.scrollingDeltaY, event.isDirectionInvertedFromDevice)];
  // No 80 ms debounce: the throw starts on this event. A fast re-touch is handled
  // by swipeBegan carrying the spring velocity instead of dropping the frame.
  [self completeSwipeEnded:event cancelled:cancelled];
}

- (void)completeSwipeEnded:(NSEvent *)event cancelled:(BOOL)cancelled {
  _swiping = NO;
  _carrying = NO;
  // Fingers are off the trackpad: the cursor comes back now, even if the window
  // keeps gliding into a corner. Only the PiP controls stay hidden until settle.
  [self showCursorIfNeeded];
  const NSPoint last = _swipeLastDelta;
  const BOOL fresh = NSProcessInfo.processInfo.systemUptime - _swipeLastAt <= zen_pip_throw::kVelocityWindow;
  const BOOL flings = !cancelled && fresh && !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion &&
                      zen_pip_throw::SwipeFlings({last.x, last.y});
  const NSRect frame = _window.frame;
  const NSPoint grab = NSMakePoint(NSMinX(frame) + _swipeGrab.x, NSMinY(frame) + _swipeGrab.y);
  const ZenPiPEdge edge = [self edgeBeyond];
  BOOL thrown = NO;
  NSRect destination = frame;
  if (edge != ZenPiPEdgeNone) {
    destination = [self frameStashedAt:edge];
    [self stashAt:edge];
  } else {
    if (_stashedEdge != ZenPiPEdgeNone) [self setStashedEdge:ZenPiPEdgeNone];
    const auto velocity = zen_pip_throw::SwipeVelocity({last.x, last.y});
    thrown = flings && [self throwFrom:grab velocity:NSMakePoint(velocity.x, velocity.y)];
  }
  if (thrown || edge != ZenPiPEdgeNone) {
    // Motion owns the chrome: the throw/snap restores it when it settles. The cursor
    // already returned on lift.
  } else {
    [self endGestureChrome:YES];
  }
  os_signpost_event_emit(PiPGestureLog(), gGestureSignpost, "end");
  if (GestureTimingEnabled()) {
    NSLog(@"[pip-gesture] end: %.1f ms total, thrown=%d edge=%ld", (CACurrentMediaTime() - _swipeBeganAt) * 1000.0, (int)thrown, (long)edge);
  }
  [self rescueIfLost];
}

- (void)hideCursorIfNeeded {
  if (_cursorHidden) return;
  [NSCursor hide];
  _cursorHidden = YES;
}

- (void)showCursorIfNeeded {
  if (!_cursorHidden) return;
  [NSCursor unhide];
  _cursorHidden = NO;
}

- (void)mouseEnteredWindow {
  if (!_window) return;
  // Freeze hover while the window is already moving.
  if (_swiping || _animating) return;
  [self armSwipe];
}

- (void)mouseExitedWindow {
  [self disarmSwipe];
}

- (void)pinchBegan {
  if (_swiping) [self abandonSwipe];
  _isPinching = YES;
  _gestureEventAt = _gestureHandlerAt = CACurrentMediaTime();
  _gestureFirstMoveAt = 0;
  // Same lifecycle as a swipe: kill any spring, then let the resize land before the
  // chrome (activation, UI hide, cursor hide, elevation) is applied.
  [self cancelMotion];
  [self beginGestureChrome:ZenPiPGesturePinch chained:NO];
}

- (void)pinchEnded {
  [self pinchEndedAtAnchor:zen_pip_zoom::kAnchorNone];
}

- (void)pinchEndedAtAnchor:(int)anchorCorner {
  _isPinching = NO;
  _isSmartMagnified = NO; // Invalidate smart magnify state so next double-tap scales from current frame
  // A swipe that started meanwhile owns the window now; do not snap under it.
  if (_swiping) return;
  if (anchorCorner >= 0 && anchorCorner <= 3) {
    // Docked corner: settle back into the originating dock corner (0=TopLeft, 1=TopRight, 2=BottomLeft, 3=BottomRight)
    NSScreen *screen = [self homeScreen];
    zen_pip_throw::Rect visible = ThrowRect(screen.visibleFrame);
    zen_pip_throw::Corner corner = static_cast<zen_pip_throw::Corner>(anchorCorner);
    zen_pip_throw::Rect target = zen_pip_throw::CornerFrame(corner, NSWidth(_window.frame), NSHeight(_window.frame), visible);
    [self endGestureChrome:NO];
    [self animateTo:NSMakeRect(target.x, target.y, target.w, target.h)];
  } else {
    // Free-floating: leave window right where user zoomed it
    [self endGestureChrome:YES];
  }
}

- (void)snapToNearestCorner {
  if (!_window || !_window.visible) return;
  NSScreen *screen = [self homeScreen];
  zen_pip_throw::Rect visible = ThrowRect(screen.visibleFrame);
  zen_pip_throw::Corner corner = zen_pip_throw::NearestCorner(ThrowRect(_window.frame), visible);
  zen_pip_throw::Rect target = zen_pip_throw::CornerFrame(corner, NSWidth(_window.frame), NSHeight(_window.frame), visible);
  NSRect targetRect = NSMakeRect(target.x, target.y, target.w, target.h);
  [self animateTo:targetRect];
}

- (void)toggleSmartMagnify {
  [self stopMotion];
  [_window orderFrontRegardless];
  NSScreen *screen = [self homeScreen];
  NSRect visible = screen.visibleFrame;
  NSRect current = _window.frame;
  const CGFloat aspect = NSWidth(current) / MAX(NSHeight(current), 1.0);

  if (_isSmartMagnified) {
    _isSmartMagnified = NO;
    NSRect target = _unmagnifiedFrame;
    if (NSIsEmptyRect(target) || NSWidth(target) < 100 || NSHeight(target) < 60) {
      target = NSMakeRect(current.origin.x, current.origin.y, current.size.width / 1.75, current.size.height / 1.75);
    }
    // Strictly preserve aspect ratio on unmagnify
    target.size.width = round(target.size.width);
    target.size.height = round(target.size.width / aspect);

    // Anchor unmagnify to the current screen quadrant so pinned corners do not jump
    if (NSMidX(current) > NSMidX(visible)) {
      target.origin.x = NSMaxX(current) - target.size.width;
    } else {
      target.origin.x = NSMinX(current);
    }
    if (NSMidY(current) > NSMidY(visible)) {
      target.origin.y = NSMaxY(current) - target.size.height;
    } else {
      target.origin.y = NSMinY(current);
    }

    target.origin.x = std::clamp(target.origin.x, NSMinX(visible), NSMaxX(visible) - target.size.width);
    target.origin.y = std::clamp(target.origin.y, NSMinY(visible), NSMaxY(visible) - target.size.height);
    [self animateTo:target];
  } else {
    _unmagnifiedFrame = current;
    _isSmartMagnified = YES;
    CGFloat scale = 1.75;
    double low, high;
    zen_pip_zoom::WidthLimits(aspect, {0, 0}, {0, 0},
                              {NSMinX(visible), NSMinY(visible), NSWidth(visible), NSHeight(visible)}, &low, &high);
    CGFloat newWidth = MIN(high, round(current.size.width * scale));
    CGFloat newHeight = round(newWidth / aspect);
    CGFloat targetX = (NSMidX(current) > NSMidX(visible)) ? (NSMaxX(current) - newWidth) : NSMinX(current);
    CGFloat targetY = (NSMidY(current) > NSMidY(visible)) ? (NSMaxY(current) - newHeight) : NSMinY(current);

    targetX = std::clamp(targetX, NSMinX(visible), NSMaxX(visible) - newWidth);
    targetY = std::clamp(targetY, NSMinY(visible), NSMaxY(visible) - newHeight);

    NSRect target = NSMakeRect(targetX, targetY, newWidth, newHeight);
    [self animateTo:target];
  }
}

- (BOOL)handleKeyDown:(NSEvent *)event {
  unsigned short code = event.keyCode;
  // Space (play/pause), Left (seek -5s), Right (seek +5s), Down (vol -), Up (vol +), M (mute)
  if (code == kKeySpace || code == kKeyLeftArrow || code == kKeyRightArrow ||
      code == kKeyDownArrow || code == kKeyUpArrow || code == kKeyM) {
    // The only path that needs app activation. Lift prevents-activation first so
    // the PiP can become key, then activate: AppKit raises the key window (the PiP),
    // not the browser window.
    const BOOL prevented = [_window _preventsActivation];
    if (prevented) [_window _setPreventsActivation:NO];
    [_window makeKeyWindow];
    if (!NSApp.isActive) {
      [NSRunningApplication.currentApplication activateWithOptions:0];
    }
    [_window sendEvent:event];
    if (prevented) [_window _setPreventsActivation:YES];
    return YES;
  }
  return NO;
}

- (NSDictionary *)throwInfo {
  return @{
    @"lastThrow" : _lastThrow ?: @{},
    @"lastSwipe" : _lastSwipe ?: @{},
    @"lastRelease" : _lastRelease ?: @{},
    @"lastScreenFit" : _lastScreenFit ?: @{},
    @"swiping" : @(_swiping),
    @"armed" : @(_armed),
    @"gestureMs" : @{
      @"eventToHandler" : @((_gestureEventAt > 0 ? (_gestureHandlerAt - _gestureEventAt) * 1000.0 : -1)),
      @"handlerToFirstMove" : @((_gestureFirstMoveAt > 0 ? (_gestureFirstMoveAt - _gestureHandlerAt) * 1000.0 : -1)),
    },
  };
}

@end

namespace zen_pip {

void InstallMonitors() {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskRightMouseDown
                                          handler:^NSEvent *(NSEvent *event) {
      ZenPiPController *controller = (event.window && [event.window isKindOfClass:[NSWindow class]]) ? [ZenPiPController forWindow:event.window] : nil;
      if (!controller) return event;
      [NSMenu popUpContextMenu:[controller menu] withEvent:event forView:controller.overlay];
      return nil;
    }];

    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp
                                          handler:^NSEvent *(NSEvent *event) {
      if (event.type == NSEventTypeLeftMouseDown) {
        NSWindow *window = event.window;
        ZenPiPController *controller = (window && [window isKindOfClass:[NSWindow class]]) ? [ZenPiPController forWindow:window] : nil;
        if (!controller) return event;
        [window orderFrontRegardless];
        gDragged = window;
        [ZenPiPController abandonSwipeOn:window];
        [controller stopMotion];
        NSPoint mouse = ScreenLocation(event);
        gLastMouse = mouse;
        gGrabLocal = NSMakePoint(mouse.x - NSMinX(window.frame), mouse.y - NSMinY(window.frame));
        gDragHome = [controller gestureHome];
        gDragSamples.clear();
        SampleDrag(event, mouse);
        return event;
      }
      NSWindow *window = gDragged;
      if (!window || ![window isKindOfClass:[NSWindow class]]) {
        gDragged = nil;
        gDragSamples.clear();
        return event;
      }
      if (event.type == NSEventTypeLeftMouseUp) {
        gDragged = nil;
        const NSPoint grabbed = NSMakePoint(NSMinX(window.frame) + gGrabLocal.x, NSMinY(window.frame) + gGrabLocal.y);
        const auto velocity = zen_pip_throw::ReleaseVelocity(gDragSamples.data(), (int)gDragSamples.size(), event.timestamp);
        gDragSamples.clear();
        [[ZenPiPController forWindow:window] dragReleasedAt:grabbed velocity:NSMakePoint(velocity.x, velocity.y)];
        return event;
      }
      NSPoint mouse = ScreenLocation(event);
      SampleDrag(event, mouse);
      const auto screens = ThrowScreens();
      const auto next = zen_pip_throw::DragStep(ThrowRect(window.frame), {mouse.x - gLastMouse.x, mouse.y - gLastMouse.y},
                                                screens.data(), (int)screens.size(), ScreenIndex(gDragHome));
      gLastMouse = mouse;
      [window setFrameOrigin:NSMakePoint(next.x, next.y)];
      return event;
    }];

    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel | NSEventMaskMagnify | NSEventMaskSmartMagnify
                                          handler:^NSEvent *(NSEvent *event) {
      if (event.type == NSEventTypeSmartMagnify) {
        NSWindow *window = event.window;
        if (!window || ![window isKindOfClass:[NSWindow class]]) {
          NSPoint p = [NSEvent mouseLocation];
          for (NSWindow *candidate in NSApp.orderedWindows) {
            if (candidate.visible && NSPointInRect(p, candidate.frame)) {
              window = candidate;
              break;
            }
          }
        }
        ZenPiPController *controller = (window && [window isKindOfClass:[NSWindow class]]) ? [ZenPiPController forWindow:window] : nil;
        if (controller) {
          [controller toggleSmartMagnify];
          return nil;
        }
        return event;
      }
      return [ZenPiPController handleSwipe:event] || [ZenPiPZoom handle:event] ? nil : event;
    }];

    // Scroll reaches an inactive app because it is routed by the window under the
    // pointer. Magnify is routed to the active app only, so while another app is
    // frontmost the local monitor never sees it and a pinch cannot front the PiP.
    // A global monitor sees events addressed to other apps; it cannot consume them,
    // so the other app may also get the first step. One step, then we are active.
    [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskMagnify
                                          handler:^(NSEvent *event) {
      if (NSApp.isActive) return;  // the local monitor owns the gesture then
      ZenPiPController *controller = [ZenPiPController controllerUnderPointer];
      if (!controller || ![ZenPiPZoom zooms:controller.window]) return;
      if (GestureTimingEnabled()) {
        NSLog(@"[pip-gesture] pinch (global) key=%d prevents=%d", controller.window.isKeyWindow,
              [controller.window _preventsActivation]);
      }
      [ZenPiPZoom handle:event];
    }];

    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                          handler:^NSEvent *(NSEvent *event) {
      NSPoint mouse = NSEvent.mouseLocation;
      for (NSWindow *candidate in NSApp.orderedWindows) {
        if (!candidate.visible) continue;
        ZenPiPController *controller = [ZenPiPController forWindow:candidate];
        if (controller && NSPointInRect(mouse, candidate.frame)) {
          if ([controller handleKeyDown:event]) {
            return nil;
          }
        }
      }
      return event;
    }];
  });
}

BOOL Attach(NSWindow *window) {
  return [ZenPiPController attachToWindow:window];
}

void Detach(NSWindow *window) {
  [ZenPiPController detachFromWindow:window];
}

}
