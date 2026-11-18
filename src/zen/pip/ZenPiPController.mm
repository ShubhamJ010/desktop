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
#import <ApplicationServices/ApplicationServices.h>
#import <os/log.h>
#import <os/signpost.h>

using namespace zen_pip;

namespace {

// The card whose window the pointer last entered. Hover is window-global rather
// than per controller: the pointer can cross from one PiP to another and only
// one of them may be in the hovered state at a time. Held unretained; the owning
// controller clears it in -detach, before the window can go away.
__unsafe_unretained NSWindow *sHoveredWindow = nil;
// Session-wide scroll tap (see PiPScrollTapCallback). NULL when the process is
// not trusted for Input Monitoring; every user of it checks first.
CFMachPortRef sEventTap = NULL;
CFRunLoopSourceRef sEventTapSource = NULL;

NSString *const kKeepOnTopDefault = @"ZenPictureInPictureKeepOnTop";
NSString *const kGestureTimingDefault = @"ZenPictureInPictureGestureTiming";
NSString *const kHoverFocusDefault = @"ZenPictureInPictureHoverFocus";
// A resize has to stay visible over whatever app is frontmost. Floating level
// beats another app's normal windows, but not its panels or sheets, so the card
// is lifted for the gesture only. Modal-panel level is still below the menu bar,
// which keeps the card from drawing over it.
constexpr NSInteger kGestureFrontLevel = NSModalPanelWindowLevel;
// How long the pointer has to rest over the card before hover focus may take
// the keyboard. Long enough that crossing the card on the way elsewhere never
// activates Zen, short enough to feel like a hover rather than a click.
constexpr NSTimeInterval kHoverFocusDelay = 0.25;
// Upper bound on waiting for an activation to settle. AppKit posts the
// activation notification within a loop turn or two; this only covers the case
// where it never arrives (activation refused, or already in progress).
constexpr NSTimeInterval kFocusSettleTimeout = 1.0;
const void *const kControllerKey = &kControllerKey;

os_log_t PiPGestureLog() {
  static os_log_t log;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    log = os_log_create("app.zen-browser.pip", "gesture");
  });
  return log;
}

// Opt-in, off by default: hover focus activates Zen, so it must never be a
// surprise. Read on every use instead of cached, because the context-menu
// toggle has to affect a request that is already in flight.
BOOL HoverFocusEnabled() {
  id value = [NSUserDefaults.standardUserDefaults objectForKey:kHoverFocusDefault];
  return value ? [value boolValue] : NO;
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
  // The pinch/scroll paths resize through AppKit's own live-resize machinery,
  // which only works on a resizable window. Page-created PiP windows may not
  // declare themselves resizable; the aspect ratio is locked either way, so the
  // only thing this allows is a resize the card was already taking.
  window.styleMask |= NSWindowStyleMaskResizable;
  // The card follows the user across Spaces, including another app's full-screen
  // space: a PiP that disappears when the frontmost app goes full screen cannot
  // be resized at all.
  window.collectionBehavior |= NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorFullScreenAuxiliary;
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
                                          usingBlock:^(NSNotification *) {
                                            // A resize gesture owns the frame for its whole
                                            // duration; rebuilding the corner radius and layer
                                            // state on every tick is pure per-frame cost and makes
                                            // the picture stutter. All of it is applied once when
                                            // the gesture ends, and the shadow is off for the
                                            // duration, so there is nothing to track here.
                                            if (weakSelf->_liveResizing || weakSelf->_isPinching) return;
                                            [weakSelf roundCorners];
                                          }]];
    [_observers addObject:[center addObserverForName:NSWindowDidChangeScreenNotification
                                              object:window
                                               queue:nil
                                          usingBlock:^(NSNotification *) { [weakSelf screenChanged]; }]];
    [_observers addObject:[center addObserverForName:NSApplicationDidChangeScreenParametersNotification
                                              object:NSApp
                                               queue:nil
                                          usingBlock:^(NSNotification *) { [weakSelf screenChanged]; }]];
    [_observers addObject:[center addObserverForName:NSApplicationDidBecomeActiveNotification
                                              object:NSApp
                                               queue:nil
                                          usingBlock:^(NSNotification *) { [weakSelf appBecameActive]; }]];
    [_observers addObject:[center addObserverForName:NSWindowWillStartLiveResizeNotification
                                              object:window
                                               queue:nil
                                          usingBlock:^(NSNotification *) {
                                            // A live resize this code started (pinch/scroll)
                                            // belongs to the pinch path: chrome, cursor and
                                            // elevation are already set from there.
                                            if (weakSelf->_ownLiveResize) return;
                                            [weakSelf frontForGesture];
                                            weakSelf->_awaitingMouseMoveToShowUI = NO;
                                            [weakSelf cancelMotion];
                                            [weakSelf showCursorIfNeeded];
                                            weakSelf->_carrying = NO;
                                            // Old `stopMotion` parity: a live resize must not inherit a
                                            // half-finished swipe, or the chrome pass at the end would be
                                            // skipped as "owned by the swipe".
                                            weakSelf->_swiping = NO;
                                            weakSelf->_liveResizing = YES;
                                            // Matching chrome for a mouse resize: no controls over
                                            // the picture, no soft shadow to rasterise per tick.
                                            // The cursor stays visible because the user is dragging
                                            // an edge with it.
                                            [weakSelf setPiPUIVisible:NO];
                                            [weakSelf hideShadowForResize];
                                          }]];
    [_observers addObject:[center addObserverForName:NSWindowDidEndLiveResizeNotification
                                              object:window
                                               queue:nil
                                          usingBlock:^(NSNotification *) { [weakSelf liveResizeEnded]; }]];
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
  if (sHoveredWindow == _window) {
    sHoveredWindow = nil;
  }
  _isMouseOver = NO;
  _focusingPiP = NO;
  [self endOwnedLiveResize];
  _liveResizing = NO;
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
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  CGPathRef p = CGPathCreateWithRoundedRect(CGRectMake(0, 0, size.width, size.height), radius, radius, NULL);
  layer.shadowPath = p;
  CGPathRelease(p);
  [CATransaction commit];
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

// The pointer is over the card again after a gesture hid the controls. Gecko
// waits for a DOM mousemove to show them, and mouse-moved events are not
// delivered to an inactive app - so while another app is frontmost it would
// never see the hover end. The tracking areas and the global mouse-moved
// monitor do fire in that state, so this is how Gecko learns it is hovered.
// Sent on every enter and move; Gecko early-outs when nothing is pending.
static void NotifyPiPGestureHover() {
#if __has_include("mozilla/Services.h")
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{
      NotifyPiPGestureHover();
    });
    return;
  }
  if (nsCOMPtr<nsIObserverService> obs = mozilla::services::GetObserverService()) {
    obs->NotifyObservers(nullptr, "zen-pip-gesture-hover", nullptr);
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

// A resize gesture must stay at 120 Hz. The drop shadow is a large blurred
// rounded rect whose path changes with every tick, and rasterising it per frame
// is the most expensive thing on this path; meanwhile the window server already
// scales the whole card - shadow included - during the live resize. So it is
// switched off for the gesture and rebuilt once from the final frame.
- (void)hideShadowForResize {
  if (!_window) return;
  CALayer *layer = _window.contentView.layer;
  if (!layer) return;
  _shadowSuppressedForResize = YES;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  layer.shadowOpacity = 0.0;
  layer.shadowPath = nil;
  [CATransaction commit];
}

- (void)restoreShadowForResizeEnd {
  if (!_shadowSuppressedForResize) return;
  _shadowSuppressedForResize = NO;
  if (!_window) return;
  CALayer *layer = _window.contentView.layer;
  if (!layer) return;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  layer.shadowColor = [NSColor blackColor].CGColor;
  layer.shadowOpacity = _isElevated ? 0.38 : 0.20;
  layer.shadowRadius = _isElevated ? 24.0 : 10.0;
  layer.shadowOffset = _isElevated ? CGSizeMake(0, -10) : CGSizeMake(0, -4);
  [CATransaction commit];
  [ZenPiPController updateShadowPathForWindow:_window radius:10];
}

- (void)beginOwnedLiveResize {
  if (_ownLiveResize || !_window || _window.inLiveResize) return;
  // Private, but present on every macOS that ships -inLiveResize; a system that
  // ever dropped it must degrade to a plain resize, not crash.
  if (![_window respondsToSelector:@selector(_startLiveResize)]) return;
  _ownLiveResize = YES;
  // AppKit now treats this exactly like the user dragging an edge with the
  // mouse: Gecko's live-resize notification suppresses the displayport, so the
  // last composited frame is stretched with the window instead of the picture
  // being laid out and resampled again on every tick. That per-tick re-layout
  // is what made the video lag and shimmer behind the card.
  [_window _startLiveResize];
}

- (void)endOwnedLiveResize {
  if (!_ownLiveResize) return;
  // Cleared first: AppKit posts the matching notification from inside
  // -endLiveResize, and it belongs to this session, not to a user drag.
  _ownLiveResize = NO;
  _ownLiveResizeForAnimation = NO;
  if (_window && [_window respondsToSelector:@selector(_endLiveResize)]) {
    [_window _endLiveResize];
  }
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
  // No hairline stroke. A 1 px translucent white border read as a light frame
  // around the picture - brightest against dark video and most obvious while the
  // card is being resized. The edge is defined by the rounded clip and the drop
  // shadow alone.
  rim.borderWidth = 0;
  rim.borderColor = NULL;
  [self fitCorners:NO];
  _window.opaque = NO;
  _window.backgroundColor = NSColor.clearColor;
  layer.backgroundColor = [NSColor blackColor].CGColor;

  layer.shadowColor = [NSColor blackColor].CGColor;
  layer.shadowOpacity = _shadowSuppressedForResize ? 0.0 : (_isElevated ? 0.38 : 0.20);
  layer.shadowRadius = _isElevated ? 24.0 : 10.0;
  layer.shadowOffset = _isElevated ? CGSizeMake(0, -10) : CGSizeMake(0, -4);
  [ZenPiPController updateShadowPathForWindow:_window radius:10];

  NSWindow *window = [_window retain];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (window.isVisible) {
      [window invalidateShadow];
    }
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
  NSWindow *window = [_window retain];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [CATransaction setCompletionBlock:^{
    if (window.isVisible) {
      [window invalidateShadow];
    }
    [window release];
  }];
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
  for (NSView *sub in _window.contentView.subviews) {
    if (sub != _overlay) {
      sub.wantsLayer = YES;
      sub.layer.cornerRadius = radius;
      sub.layer.cornerCurve = kCACornerCurveCircular;
      sub.layer.masksToBounds = YES;
      sub.layer.backgroundColor = [NSColor blackColor].CGColor;
    }
  }
  [CATransaction commit];
}

- (void)setKeepOnTop:(BOOL)keepOnTop {
  _keepOnTop = keepOnTop;
  _window.level = keepOnTop ? NSFloatingWindowLevel : NSNormalWindowLevel;
  // Remember what the card should go back to once a gesture ends.
  if (!_frontedForGesture) _restingLevel = _window.level;
}

// Window, not app. A gesture started over another app must show the card above
// that app, so it is ordered front and lifted to a level that beats the other
// app's own panels. Nothing here activates Zen or touches the browser window.
- (void)frontForGesture {
  if (!_window) return;
  if (!_frontedForGesture) {
    _frontedForGesture = YES;
    _restingLevel = _window.level;
  }
  // Re-asserted on every gesture tick: Gecko owns the window too, and a level it
  // writes back mid-resize would drop the card behind the frontmost app again.
  if (_window.level < kGestureFrontLevel) {
    _window.level = static_cast<NSWindowLevel>(kGestureFrontLevel);
  }
  [_window orderFrontRegardless];
}

- (void)standDownAfterGesture {
  if (!_frontedForGesture) return;
  _frontedForGesture = NO;
  if (!_window) return;
  _window.level = static_cast<NSWindowLevel>(_restingLevel);
  [_window orderFrontRegardless];
}

// ---------------------------------------------------------------------------
// Focus
//
// The card lives in Zen's process but, most of the time, another app is
// frontmost. Getting keyboard input into it (transport keys, click to drag,
// optional hover focus) therefore means activating Zen, and activation is the
// one thing a floating PiP must do as quietly as possible. Three rules:
//
//   1. Only the card comes forward. Activation raises the app's main window
//      too, so every other window is demoted again afterwards.
//   2. Only when asked. Hover focus is opt-in and delayed; key presses, clicks
//      and a completed swipe are explicit requests.
//   3. `preventsActivation` goes back up. That flag is what makes a plain click
//      on the card front the window instead of activating Zen; it has to be
//      lowered while the app activates, or AppKit keys the browser window
//      rather than the card.
// ---------------------------------------------------------------------------

- (void)focusPiP {
  if (!_window || !_window.isVisible) return;
  if (NSApp.isActive) {
    [self keyPiPWithoutActivating];
    return;
  }
  [self activateAppForPiPFocus];
}

// Zen is already frontmost: keying the card cannot disturb any other app, so
// `preventsActivation` is lifted and restored around the single call.
- (void)keyPiPWithoutActivating {
  if (!_window || _window.isKeyWindow) return;
  const BOOL prevented = [_window _preventsActivation];
  if (prevented) [_window _setPreventsActivation:NO];
  [_window makeKeyWindow];
  [_window orderFrontRegardless];
  if (prevented) [_window _setPreventsActivation:YES];
}

// Another app is frontmost. Activation is asynchronous and AppKit keys the
// app's main window on the way in, so the card is keyed once more when
// activation settles (-appBecameActive), and `preventsActivation` stays lowered
// until then.
- (void)activateAppForPiPFocus {
  _focusingPiP = YES;
  [_window _setPreventsActivation:NO];
  [_window makeKeyWindow];
  [_window orderFrontRegardless];
  [self sendOtherWindowsBack];
  [NSRunningApplication.currentApplication activateWithOptions:0];

  // Safety net for an activation that never reports back (refused, or already
  // in progress): the card must not stay focus-stealing. Retained explicitly
  // because the block holds a raw pointer in this (non-ARC) translation unit.
  [self retain];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFocusSettleTimeout * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   [self finishPiPFocus];
                   [self release];
                 });
}

// The focus session is over: hand the card its click-through behaviour back.
// Idempotent, so both the activation notification and the safety-net timer can
// call it.
- (void)finishPiPFocus {
  if (!_focusingPiP) return;
  _focusingPiP = NO;
  if (_window) [_window _setPreventsActivation:YES];
}

// A gesture that began while another app was frontmost keeps Zen's other
// windows out of the way for its whole duration, and only for that case: a
// gesture the user started inside already-active Zen needs no demotion.
- (BOOL)gestureStartedUnderOtherApp {
  return _startedUnderOtherApp && (_isPinching || _liveResizing || _swiping || _animating);
}

// AppKit can activate Zen as a side effect of a resize or a focus request. The
// notification arrives before the app's windows have finished being raised, so
// the demotion is applied twice: now, and once more on the next loop turn.
- (void)appBecameActive {
  if (!_window) return;
  if (!_focusingPiP && ![self gestureStartedUnderOtherApp]) return;
  [self sendOtherWindowsBack];
  [_window makeKeyWindow];
  [_window orderFrontRegardless];
  [self retain];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!_detached && _window && (_focusingPiP || [self gestureStartedUnderOtherApp])) {
      [self sendOtherWindowsBack];
      [_window makeKeyWindow];
      [_window orderFrontRegardless];
    }
    [self finishPiPFocus];
    [self release];
  });
}

- (void)sendOtherWindowsBack {
  if (!_window || !_window.isVisible) return;
  for (NSWindow *win in NSApp.windows) {
    if (win == _window || !win.isVisible) continue;
    // Other PiP cards are peers, not the browser window: demoting them would
    // reorder one card behind another every time either one is focused.
    if ([ZenPiPController forWindow:win]) continue;
    [win orderBack:nil];
  }
  [_window orderFrontRegardless];
}

- (void)toggleKeepOnTop:(id)sender {
  self.keepOnTop = !_keepOnTop;
  [NSUserDefaults.standardUserDefaults setBool:_keepOnTop forKey:kKeepOnTopDefault];
}

// Menu toggle. The preference is read when a request fires, so switching it off
// also has to cancel a request that is already pending.
- (void)toggleHoverFocus:(id)sender {
  const BOOL enabled = !HoverFocusEnabled();
  [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kHoverFocusDefault];
  if (!enabled) [self cancelHoverFocus];
}

- (NSMenu *)menu {
  NSMenu *menu = [[[NSMenu alloc] initWithTitle:@""] autorelease];
  NSMenuItem *back = [menu addItemWithTitle:@"Back to Tab" action:@selector(backToTabFromMenu:) keyEquivalent:@""];
  back.target = self;
  [menu addItem:NSMenuItem.separatorItem];
  NSMenuItem *top = [menu addItemWithTitle:@"Keep Window on Top" action:@selector(toggleKeepOnTop:) keyEquivalent:@""];
  top.target = self;
  top.state = _keepOnTop ? NSControlStateValueOn : NSControlStateValueOff;
  // Off by default: see kHoverFocusDelay for why the hover is delayed.
  NSMenuItem *hover = [menu addItemWithTitle:@"Focus on Hover" action:@selector(toggleHoverFocus:) keyEquivalent:@""];
  hover.target = self;
  hover.state = HoverFocusEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
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
  if (_animating || _swiping || _isPinching || _liveResizing) return;
  [self fitCorners:YES];
  [_lastScreenFit release];
  _lastScreenFit = [@{
    @"radius" : @([self cornerRadius]),
    @"frame" : NSStringFromRect(_window.frame),
    @"visibleFrame" : NSStringFromRect(screen.visibleFrame),
  } retain];
}

- (void)liveResizeEnded {
  // Programmatic resizes run their own ending: chrome, snap and the content
  // repaint all come from pinchEndedAtFrame:. Only a real edge drag lands here,
  // and it is the only one that ever set _liveResizing.
  if (!_liveResizing || _ownLiveResize) return;
  _liveResizing = NO;
  if (!_window) return;
  // One chrome pass for the whole gesture: controls, cursor, elevation, corner
  // radius and shadow are restored from the final frame, never per resize tick.
  [self endGestureChrome:NO];
  // A live resize that comes to rest next to a screen corner docks into it.
  NSScreen *screen = [self homeScreen];
  zen_pip_throw::Rect visible = ThrowRect(screen.visibleFrame);
  NSRect frame = _window.frame;
  const zen_pip_zoom::AnchorCorner corner = zen_pip_zoom::NearestDockCorner(
      {NSMinX(frame), NSMinY(frame), NSWidth(frame), NSHeight(frame)},
      {visible.x, visible.y, visible.w, visible.h}, zen_pip_zoom::kSnapTolerance);
  if (corner != zen_pip_zoom::kAnchorNone) {
    zen_pip_throw::Rect target = zen_pip_throw::CornerFrame(static_cast<zen_pip_throw::Corner>(corner), NSWidth(frame),
                                                           NSHeight(frame), visible);
    if (!NSEqualRects(NSMakeRect(target.x, target.y, target.w, target.h), frame)) {
      [self animateTo:NSMakeRect(target.x, target.y, target.w, target.h) restoreUI:NO];
      return;
    }
  }
  [self armUIRestoreOnMouseMove];
  [self rescueIfLost];
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
  if (_swiping || _animating || _isPinching || _liveResizing) return;
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
  if (_animateDisplayLink) {
    if (@available(macOS 14.0, *)) {
      [(CADisplayLink *)_animateDisplayLink invalidate];
    }
    [_animateDisplayLink release];
    _animateDisplayLink = nil;
  }
  _animating = NO;
  _throwActive = NO;
  // A snap animation that resized the card runs inside a live resize; leaving
  // the mode here repaints the picture at the final size. A pinch/scroll session
  // is untouched: it calls this on every wheel event and owns its live resize
  // for the whole gesture.
  if (_ownLiveResizeForAnimation) {
    [self endOwnedLiveResize];
  }
}

- (void)stopMotion {
  [self cancelMotion];
  _carrying = NO;
  _swiping = NO;
  // Safety net: a gesture that ended through some other path must not leave the
  // card lifted above the menu bar's neighbours forever.
  if (!_isPinching && !_liveResizing && !_animating) [self standDownAfterGesture];
  [self showCursorIfNeeded];
  // Safety net: a shadow suppressed for a gesture that was taken over by
  // something else (a swipe, a close) is restored here.
  [self restoreShadowForResizeEnd];
  if (!_awaitingMouseMoveToShowUI && !_isPinching && !_liveResizing) {
    [self setPiPUIVisible:YES];
  }
}

- (void)armUIRestoreOnMouseMove {
  _awaitingMouseMoveToShowUI = YES;
  [self setOverlayVisible:NO animated:NO];
  NotifyPiPGestureActive(true);
}

- (void)restoreUIOnMouseMove {
  if (!_awaitingMouseMoveToShowUI) {
    // The local and global mouse-moved monitors call this on every move over
    // the card, active app or not, so this is also how Gecko hears about plain
    // hovering while Zen is inactive.
    NotifyPiPGestureHover();
    return;
  }
  // A pinch can grow the card under a stationary pointer, which makes AppKit
  // post mouse-entered events; those must not end the deferred-UI state.
  if (_isPinching || _liveResizing || _animating) return;
  _awaitingMouseMoveToShowUI = NO;
  [self setPiPUIVisible:YES];
  [self showCursorIfNeeded];
  // setPiPUIVisible above re-armed Gecko's "wait for the mouse" state with the
  // end notification; this one says the pointer is right here, so the controls
  // come back immediately instead of waiting for a mousemove that may never
  // arrive (another app can be frontmost).
  NotifyPiPGestureHover();
}

- (void)animateTo:(NSRect)target {
  [self animateTo:target restoreUI:YES];
}

- (void)animateTo:(NSRect)target restoreUI:(BOOL)restoreUI {
  [self cancelMotion];
  [_window orderFrontRegardless];
  NSRect from = _window.frame;
  if (NSEqualRects(from, target)) {
    if (restoreUI) {
      [self setPiPUIVisible:YES];
    } else {
      [self armUIRestoreOnMouseMove];
    }
    [self showCursorIfNeeded];
    return;
  }
  _animating = YES;
  [self setElevated:YES animated:YES];
  [self bendCornersTo:zen_pip_throw::kFreeRadius animated:NO];
  [self setPiPUIVisible:NO];

  _animateFrom = from;
  _animateTarget = target;
  _animateRestoreUI = restoreUI;
  _animateStartAt = CACurrentMediaTime();
  _animateInitialDistX = NSMinX(from) - NSMinX(target);
  _animateInitialDistY = NSMinY(from) - NSMinY(target);
  const double initialDistW = NSWidth(from) - NSWidth(target);
  const double initialDistH = NSHeight(from) - NSHeight(target);
  _animateSizeChanges = (fabs(initialDistW) > 0.5 || fabs(initialDistH) > 0.5);
  if (_animateSizeChanges) {
    // The magnetic snap changes the size too. Freeze the picture and drop the
    // shadow for its ~250 ms, so it flies into the corner with the content
    // scaled by the window server instead of the video re-laying-out under it.
    // Both are restored when the animation lands (cancelMotion + the branch
    // below).
    [self hideShadowForResize];
    [self beginOwnedLiveResize];
    _ownLiveResizeForAnimation = _ownLiveResize;
  }

  _animatePinRight = fabs(NSMaxX(from) - NSMaxX(target)) < 5.0;
  _animatePinLeft = fabs(NSMinX(from) - NSMinX(target)) < 5.0;
  _animatePinTop = fabs(NSMaxY(from) - NSMaxY(target)) < 5.0;
  _animatePinBottom = fabs(NSMinY(from) - NSMinY(target)) < 5.0;
  _animateAspect = NSWidth(from) / MAX(NSHeight(from), 1.0);

  if (@available(macOS 14.0, *)) {
    CADisplayLink *link = [_window.contentView displayLinkWithTarget:self selector:@selector(animateTick:)];
    link.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    _animateDisplayLink = [link retain];
    return;
  }

  __unsafe_unretained ZenPiPController *weakSelf = self;
  _slide = [[NSTimer scheduledTimerWithTimeInterval:1.0 / 120 repeats:YES block:^(NSTimer *timer) {
    [weakSelf animateTick:timer];
  }] retain];
  [NSRunLoop.currentRunLoop addTimer:_slide forMode:NSRunLoopCommonModes];
}

- (void)animateTick:(id)sender {
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

  const double t = now - _animateStartAt;
  const NSRect from = _animateFrom;
  const NSRect target = _animateTarget;

  if (_animateSizeChanges) {
    const auto s = zen_pip_throw::SpringAt(1.0, 0, t, 0.38, 0.76);
    const BOOL done = (std::fabs(s.offset) < 0.005 && std::fabs(s.velocity) < 0.05) || t > 0.55;

    if (done) {
      [_window setFrame:target display:NO];
      [_window.contentView setNeedsDisplay:YES];
      [ZenPiPController updateShadowPathForWindow:_window size:target.size radius:10];
      const BOOL shouldRestore = _animateRestoreUI;
      [self cancelMotion];
      [self standDownAfterGesture];
      // The card is at its final size now: rebuild the resting shadow.
      [self restoreShadowForResizeEnd];
      _sawDrag = NO;
      [self fitCorners:YES];
      [self rescueIfLost];
      [self setElevated:NO animated:YES];
      if (shouldRestore) {
        [self setPiPUIVisible:YES];
      } else {
        [self armUIRestoreOnMouseMove];
      }
      [self showCursorIfNeeded];
      [self focusPiP];
      return;
    }

    const double progress = 1.0 - s.offset;
    const CGFloat curW = MAX(round(NSWidth(from) + (NSWidth(target) - NSWidth(from)) * progress), 100.0);
    const CGFloat curH = MAX(round(curW / _animateAspect), 60.0);

    CGFloat curX;
    if (_animatePinRight && !_animatePinLeft) {
      curX = NSMaxX(target) - curW;
    } else if (_animatePinLeft && !_animatePinRight) {
      curX = NSMinX(target);
    } else {
      curX = round(NSMinX(from) + (NSMinX(target) - NSMinX(from)) * progress);
    }

    CGFloat curY;
    if (_animatePinTop && !_animatePinBottom) {
      curY = NSMaxY(target) - curH;
    } else if (_animatePinBottom && !_animatePinTop) {
      curY = NSMinY(target);
    } else {
      curY = round(NSMinY(from) + (NSMinY(target) - NSMinY(from)) * progress);
    }

    NSRect current = NSMakeRect(curX, curY, curW, curH);
    [_window setFrame:current display:NO];
    [ZenPiPController updateShadowPathForWindow:_window size:current.size radius:10];
  } else {
    const auto sx = zen_pip_throw::SpringAt(_animateInitialDistX, 0, t, 0.38, 0.76);
    const auto sy = zen_pip_throw::SpringAt(_animateInitialDistY, 0, t, 0.38, 0.76);
    const BOOL done = zen_pip_throw::Resolved(sx, sy);

    if (done) {
      [_window setFrame:target display:NO];
      [_window.contentView setNeedsDisplay:YES];
      [ZenPiPController updateShadowPathForWindow:_window size:target.size radius:10];
      const BOOL shouldRestore = _animateRestoreUI;
      [self cancelMotion];
      [self standDownAfterGesture];
      // The card is at its final size now: rebuild the resting shadow.
      [self restoreShadowForResizeEnd];
      _sawDrag = NO;
      [self fitCorners:YES];
      [self rescueIfLost];
      [self setElevated:NO animated:YES];
      if (shouldRestore) {
        [self setPiPUIVisible:YES];
      } else {
        [self armUIRestoreOnMouseMove];
      }
      [self showCursorIfNeeded];
      [self focusPiP];
      return;
    }

    NSRect current = NSMakeRect(
        round(NSMinX(target) + sx.offset),
        round(NSMinY(target) + sy.offset),
        NSWidth(target),
        NSHeight(target));
    [_window setFrame:current display:NO];
  }
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
  _startedUnderOtherApp = !NSApp.isActive;
  // Any pinch still in flight loses: its idle timer would otherwise snap the window
  // in the middle of this flick. Safe here because endGestureChrome no-ops while
  // `_swiping` is set.
  [ZenPiPZoom abandonZoomOn:_window];
  _swipeStart = _window.frame;
  _swipeHome = (_armed && _armedHome) ? _armedHome : [self gestureHome];
  [self disarmSwipe];
  [self frontForGesture];
  [self focusPiP];

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

// The PiP card under the pointer, or nil. Uses the window server's stacking
// order rather than a frame test over Zen's own windows: the card routinely
// sits under the pointer while another app is frontmost, and possibly with one
// of that app's windows above it, in which case the pointer is not over the
// card at all.
+ (ZenPiPController *)controllerUnderPointer {
  return [self controllerUnderPointerAllowingOccluded:NO];
}

+ (ZenPiPController *)controllerUnderPointerAllowingOccluded:(BOOL)allowOccluded {
  const NSPoint mouse = NSEvent.mouseLocation;
  const NSInteger windowNumber = [NSWindow windowNumberAtPoint:mouse belowWindowWithWindowNumber:0];
  if (windowNumber > 0) {
    NSWindow *window = [NSApp windowWithWindowNumber:windowNumber];
    // A PiP card can own child panels; resolve up to the window that has a
    // controller.
    while (window && ![self forWindow:window] && window.parentWindow) {
      window = window.parentWindow;
    }
    ZenPiPController *controller = window ? [self forWindow:window] : nil;
    if (controller && controller.window.isVisible) return controller;
    if (!allowOccluded) return nil;
  }

  // No window under the pointer at all (a gap between windows, or the desktop),
  // or an occluded PiP card when explicitly allowed for user gestures.
  for (NSWindow *candidate in NSApp.windows) {
    if (!candidate.visible) continue;
    if (!NSPointInRect(mouse, candidate.frame)) continue;
    ZenPiPController *controller = [self forWindow:candidate];
    if (controller && controller.window.isVisible) return controller;
  }
  return nil;
}

// Enter/exit bookkeeping for the card under the pointer, driven by the mouse
// monitors. Both a local and a global monitor call it, because Zen's own
// monitors see nothing while another app is frontmost - which is the state the
// hover behaviour exists for. Idempotent per controller (see _isMouseOver), so
// the duplicate calls this causes are cheap.
+ (void)updateHoverState {
  ZenPiPController *current = [self controllerUnderPointer];
  NSWindow *currentWindow = (current && current.window.isVisible) ? current.window : nil;
  if (currentWindow == sHoveredWindow) {
    if (current) [current restoreUIOnMouseMove];
    return;
  }
  if (sHoveredWindow) {
    ZenPiPController *previous = [self forWindow:sHoveredWindow];
    sHoveredWindow = nil;
    [previous mouseExitedWindow];
  }
  if (currentWindow) {
    sHoveredWindow = currentWindow;
    [current mouseEnteredWindow];
  }
}

// Chrome for both gesture kinds: activate, front the window, hide the PiP UI, the
// cursor and raise the shadow. Always runs one main-loop turn after the first moved
// frame, and is dropped if that gesture is already over.
- (void)beginGestureChrome:(ZenPiPGesture)kind chained:(BOOL)chained {
  _awaitingMouseMoveToShowUI = NO;
  [self frontForGesture];
  [self focusPiP];
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
  // Window, not app: ordering the card front puts it above the other app without
  // dragging Zen's browser window forward.
  [self frontForGesture];
  [self focusPiP];
  [self setPiPUIVisible:NO];
  if (kind == ZenPiPGesturePinch) {
    // A resize is a sustained 120 Hz gesture: drop the big soft shadow for its
    // duration instead of re-rasterising it on every tick.
    [self hideShadowForResize];
  } else {
    [self setElevated:YES animated:YES];
  }
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
  _startedUnderOtherApp = NO;
  [self showCursorIfNeeded];
  if (restoreUI) [self setPiPUIVisible:YES];
  // Rebuild the resting shadow once, from the final frame.
  [self restoreShadowForResizeEnd];
  [self setElevated:NO animated:YES];
  if (!_animating) {
    [self standDownAfterGesture];
    [self fitCorners:YES];
    // The shadow path was deliberately left alone during the gesture; rebuild it
    // once for the final size so it never lags the resized picture.
    [ZenPiPController updateShadowPathForWindow:_window size:_window.contentView.bounds.size radius:[self cornerRadius]];
  }
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
    // A swipe that came to rest over the card leaves the pointer there with the
    // keyboard still in the app it was taken from. Hand it to the card: the user
    // just interacted with it, and the gesture suppressed the hover request that
    // would otherwise have done this.
    [self focusPiP];
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
  if (!_window || _isMouseOver) return;
  _isMouseOver = YES;
  // Scheduled before the gesture guards below: a pointer that comes to rest on
  // the card while it is being pinched, swiped or animated has still asked for
  // hover focus, and the request has to survive until the gesture is done.
  [self scheduleHoverFocus];
  // Freeze hover while the window is already moving.
  if (_swiping || _animating) return;
  // Growing the card during a resize makes AppKit post enters under a pointer
  // that never moved. Those are not a request to bring the controls back.
  if (_isPinching || _liveResizing) return;
  // Tracking areas fire even when Zen is inactive, so this is the only hover
  // signal that survives another app being frontmost. The awaiting path
  // reports it itself (after its end notification, see restoreUIOnMouseMove).
  if (_awaitingMouseMoveToShowUI) {
    [self restoreUIOnMouseMove];
  } else {
    NotifyPiPGestureHover();
  }
  [self armSwipe];
}

- (void)mouseExitedWindow {
  if (!_isMouseOver) return;
  _isMouseOver = NO;
  [self cancelHoverFocus];
  [self disarmSwipe];
}

// Hover focus is a delayed, cancellable request: the pointer has to rest over
// the card, and leaving cancels it, so a pointer merely crossing the card never
// takes the keyboard away from the frontmost app.
- (void)scheduleHoverFocus {
  [self cancelHoverFocus];
  if (!HoverFocusEnabled()) return;
  [self performSelector:@selector(hoverFocusFired) withObject:nil afterDelay:kHoverFocusDelay];
}

- (void)cancelHoverFocus {
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hoverFocusFired) object:nil];
}

// Everything can change while a hover request waits: the pointer may have left,
// the preference may have been switched off, a gesture may have started. All of
// it is re-checked here instead of being trusted from enter time.
- (void)hoverFocusFired {
  if (!HoverFocusEnabled() || !_isMouseOver) return;
  if (_swiping || _isPinching || _liveResizing || _animating) {
    // A gesture owns the card: neither stealing the keyboard mid-gesture nor
    // dropping the request is right, so it is deferred by one more delay. This
    // stops as soon as the pointer leaves (mouseExitedWindow cancels) or the
    // gesture ends, and a gesture cannot last forever.
    [self performSelector:@selector(hoverFocusFired) withObject:nil afterDelay:kHoverFocusDelay];
    return;
  }
  [self focusPiP];
}

- (void)pinchBegan {
  if (_swiping) [self abandonSwipe];
  _isPinching = YES;
  _startedUnderOtherApp = !NSApp.isActive;
  _awaitingMouseMoveToShowUI = NO;
  [self frontForGesture];
  [self focusPiP];
  // Announce the gesture now, not one main-loop turn later with the chrome: the
  // page freezes the remote video viewport from this notification, and it must
  // already be frozen when the first size change lands.
  NotifyPiPGestureActive(YES);
  _gestureEventAt = _gestureHandlerAt = CACurrentMediaTime();
  _gestureFirstMoveAt = 0;
  // Same lifecycle as a swipe: kill any spring, then let the resize land before the
  // chrome (activation, UI hide, cursor hide, elevation) is applied.
  [self cancelMotion];
  [self beginGestureChrome:ZenPiPGesturePinch chained:NO];
}

- (void)pinchEnded {
  [self pinchEndedAtFrame:NSZeroRect];
}

// A resize ends. With a `target` (a screen corner slot) the picture settles into
// it; with an empty rect it stays exactly where the cursor left it, pulled back
// on screen if the gesture overflowed an edge while following the pointer.
- (void)pinchEndedAtFrame:(NSRect)target {
  _isPinching = NO;
  _startedUnderOtherApp = NO;
  _isSmartMagnified = NO;  // Next double-tap scales from the new frame
  // The page holds the video's remote viewport frozen for the gesture; this is
  // its cue to let it settle. It waits for the window to stop changing size, so
  // a following snap animation is covered too. Sent on every ending, including
  // the cancel one, or the page would stay frozen forever.
  NotifyPiPGestureActive(NO);
  // A swipe that started meanwhile owns the window now; do not snap under it.
  if (_swiping) return;
  if (NSIsEmptyRect(target)) {
    [self clampToScreen];
    [self endGestureChrome:NO];
    [self armUIRestoreOnMouseMove];
    return;
  }
  [self endGestureChrome:NO];
  [self animateTo:target restoreUI:NO];
}

// Fit the window back inside its screen without changing its size. A resize
// follows the cursor in every direction, which can push an edge past the
// visible frame; this is the only place that gets undone.
- (void)clampToScreen {
  if (!_window) return;
  NSRect visible = [self homeScreen].visibleFrame;
  NSRect frame = _window.frame;
  NSRect fit = NSMakeRect(
      std::clamp(NSMinX(frame), NSMinX(visible), std::max(NSMinX(visible), NSMaxX(visible) - NSWidth(frame))),
      std::clamp(NSMinY(frame), NSMinY(visible), std::max(NSMinY(visible), NSMaxY(visible) - NSHeight(frame))),
      NSWidth(frame), NSHeight(frame));
  if (!NSEqualRects(fit, frame)) [_window setFrame:fit display:NO];
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

// Keyboard control while the pointer is over the card. Returns YES when the
// event was consumed and must not reach the browser.
- (BOOL)handleKeyDown:(NSEvent *)event {
  const unsigned short code = event.keyCode;
  // Close the card. This is also the only way out of a PiP that has the
  // keyboard while the pointer is parked over it.
  if (code == kKeyEscape || ((event.modifierFlags & NSEventModifierFlagCommand) && code == kKeyW)) {
    [_window performClose:nil];
    return YES;
  }
  // Everything else is the unmodified transport set below; a shortcut with
  // Command, Control or Option belongs to the browser or the system.
  const NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  if (mods & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) {
    return NO;
  }
  // Space (play/pause), Left (seek -5s), Right (seek +5s), Down (vol -), Up (vol +), M (mute)
  if (code == kKeySpace || code == kKeyLeftArrow || code == kKeyRightArrow ||
      code == kKeyDownArrow || code == kKeyUpArrow || code == kKeyM) {
    // The page only reacts to a key event if its window is key, so this is the
    // one shortcut path that activates the app.
    [self focusPiP];
    [_window sendEvent:event];
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

// Scroll is routed by the window under the pointer, so an inactive app still
// receives scrolls aimed at the card - where they would scroll the other app in
// the background instead of moving or resizing the card. A local monitor only
// sees Zen's own events, and a global one cannot consume them, so a session
// event tap is what lets the card take the scroll and swallow it for everyone
// else. Only the scroll wheel is tapped, and only while another app is
// frontmost: while Zen is active the local monitor already owns the event.
static CGEventRef PiPScrollTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef cgEvent,
                                       void *refcon) {
  // macOS disables a tap whose callback ran too long. Re-enable it, or the card
  // would silently stop receiving scrolls for the rest of the session.
  if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
    if (sEventTap) CGEventTapEnable(sEventTap, true);
    return cgEvent;
  }
  if (type != kCGEventScrollWheel) return cgEvent;
  if (NSApp.isActive) return cgEvent;

  NSEvent *event = [NSEvent eventWithCGEvent:cgEvent];
  if (!event || ![ZenPiPController controllerUnderPointer]) return cgEvent;
  // NULL swallows the event: it became a card gesture, not a page scroll.
  return ([ZenPiPController handleSwipe:event] || [ZenPiPZoom handle:event]) ? NULL : cgEvent;
}

// The tap needs the process to be trusted for Accessibility / Input Monitoring.
// Without it CGEventTapCreate returns NULL and the card simply behaves as it did
// before: gestures only work while Zen itself is frontmost.
static void InstallScrollTap() {
  sEventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                               CGEventMaskBit(kCGEventScrollWheel), PiPScrollTapCallback, NULL);
  if (!sEventTap) return;
  sEventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, sEventTap, 0);
  if (!sEventTapSource) return;
  CFRunLoopAddSource(CFRunLoopGetMain(), sEventTapSource, kCFRunLoopCommonModes);
  CGEventTapEnable(sEventTap, true);
}

void InstallMonitors() {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    InstallScrollTap();

    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskRightMouseDown
                                          handler:^NSEvent *(NSEvent *event) {
      NSWindow *window = event.window;
      ZenPiPController *controller = (window && [window isKindOfClass:[NSWindow class]]) ? [ZenPiPController forWindow:window] : nil;
      if (!controller) {
        controller = [ZenPiPController controllerUnderPointer];
      }
      if (!controller) return event;
      [controller focusPiP];
      [NSMenu popUpContextMenu:[controller menu] withEvent:event forView:controller.overlay];
      return nil;
    }];

    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp
                                          handler:^NSEvent *(NSEvent *event) {
      if (event.type == NSEventTypeLeftMouseDown) {
        NSWindow *window = event.window;
        ZenPiPController *controller = (window && [window isKindOfClass:[NSWindow class]]) ? [ZenPiPController forWindow:window] : nil;
        if (!controller) {
          controller = [ZenPiPController controllerUnderPointer];
          if (controller) window = controller.window;
        }
        if (!controller) return event;
        [controller focusPiP];
        gDragged = window;
        [ZenPiPController abandonSwipeOn:window];
        [ZenPiPZoom abandonZoomOn:window];
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
        ZenPiPController *controller = [ZenPiPController controllerUnderPointer];
        if (controller) {
          [controller toggleSmartMagnify];
          return nil;
        }
        return event;
      }
      return [ZenPiPController handleSwipe:event] || [ZenPiPZoom handle:event] ? nil : event;
    }];

    // Magnify is delivered to the active app only, so while another app is
    // frontmost the local monitor never sees the pinch and a pinch could not
    // front the card. A global monitor does see it, but cannot consume it, so
    // the other app may also get the first step; one step in, the card is keyed
    // and the local monitor owns the rest of the gesture.
    [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskMagnify
                                           handler:^(NSEvent *event) {
      if (NSApp.isActive) return;
      ZenPiPController *controller = [ZenPiPController controllerUnderPointerAllowingOccluded:YES];
      if (!controller || ![ZenPiPZoom zooms:controller.window]) return;
      [controller frontForGesture];
      [controller focusPiP];
      if (GestureTimingEnabled()) {
        NSLog(@"[pip-gesture] pinch (global) key=%d prevents=%d", controller.window.isKeyWindow,
              [controller.window _preventsActivation]);
      }
      [ZenPiPZoom handle:event];
    }];

    // Hover tracking. Both monitors are needed: the local one is the only one
    // that sees moves inside Zen, the global one the only one that sees moves
    // over the card while another app is frontmost. Drags are tracked as well so
    // hover state does not freeze when the pointer is held down.
    const NSEventMask mouseMask = NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged |
                                  NSEventMaskRightMouseDragged | NSEventMaskOtherMouseDragged;

    [NSEvent addLocalMonitorForEventsMatchingMask:mouseMask
                                          handler:^NSEvent *(NSEvent *event) {
      [ZenPiPController updateHoverState];
      return event;
    }];

    [NSEvent addGlobalMonitorForEventsMatchingMask:mouseMask
                                           handler:^(NSEvent *event) {
      [ZenPiPController updateHoverState];
    }];

    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                          handler:^NSEvent *(NSEvent *event) {
      ZenPiPController *controller = [ZenPiPController controllerUnderPointer];
      if (controller) {
        if ([controller handleKeyDown:event]) {
          return nil;
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
