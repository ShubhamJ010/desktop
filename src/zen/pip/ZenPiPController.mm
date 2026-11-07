#import "ZenPictureInPictureInternal.h"
#import "ZenPiPThrowMath.h"

#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

using namespace zen_pip;

namespace {

NSString *const kKeepOnTopDefault = @"ZenPictureInPictureKeepOnTop";
const void *const kControllerKey = &kControllerKey;

BOOL KeepOnTop() {
  id value = [NSUserDefaults.standardUserDefaults objectForKey:kKeepOnTopDefault];
  return value ? [value boolValue] : YES;
}

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
  [self retain];
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
  [self detach];
  [super dealloc];
}

- (void)roundCorners {
  if (!_window) return;
  NSView *content = _window.contentView;
  content.wantsLayer = YES;
  CALayer *layer = content.layer;
  if (layer.cornerCurve != kCACornerCurveCircular || !layer.masksToBounds) {
    layer.cornerCurve = kCACornerCurveCircular;
    layer.masksToBounds = YES;
  }
  CALayer *rim = _overlay.layer;
  rim.cornerCurve = kCACornerCurveCircular;
  rim.borderWidth = 1;
  rim.borderColor = [NSColor colorWithWhite:1 alpha:kRimAlpha].CGColor;
  [self fitCorners:NO];
  _window.opaque = NO;
  _window.backgroundColor = NSColor.clearColor;
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
  NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
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
  NSScreen *screen = [self homeScreen];
  if (_animating) return;
  [self fitCorners:YES];
  _lastScreenFit = @{
    @"radius" : @([self cornerRadius]),
    @"frame" : NSStringFromRect(_window.frame),
    @"visibleFrame" : NSStringFromRect(screen.visibleFrame),
  };
}

- (void)windowMoved {
  [self homeScreen];
  if (!_animating) [self fitCorners:YES];
  if (_animating || (_swiping && NSProcessInfo.processInfo.systemUptime - _swipeLastAt < 1)) return;
  if (_swiping) [ZenPiPController abandonSwipeOn:_window];
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

- (void)stopMotion {
  if (_slide) {
    [_slide invalidate];
    [_slide release];
    _slide = nil;
  }
  _animating = NO;
}

- (void)animateTo:(NSRect)target {
  [self stopMotion];
  NSRect from = _window.frame;
  if (NSEqualRects(from, target)) return;
  _animating = YES;
  CFTimeInterval start = CACurrentMediaTime();
  __unsafe_unretained ZenPiPController *weakSelf = self;
  _slide = [[NSTimer scheduledTimerWithTimeInterval:1.0 / 120 repeats:YES block:^(NSTimer *timer) {
    ZenPiPController *strongSelf = weakSelf;
    if (!strongSelf || !strongSelf->_window || !strongSelf->_window.visible) {
      if (strongSelf) [strongSelf stopMotion];
      else [timer invalidate];
      return;
    }
    double t = MIN((CACurrentMediaTime() - start) / 0.25, 1);
    double eased = 1 - pow(1 - t, 3);
    NSRect frame = NSMakeRect(round(NSMinX(from) + (NSMinX(target) - NSMinX(from)) * eased),
                              round(NSMinY(from) + (NSMinY(target) - NSMinY(from)) * eased), NSWidth(target), NSHeight(target));
    [strongSelf.window setFrame:t < 1 ? frame : target display:YES];
    if (t < 1) return;
    [strongSelf stopMotion];
    strongSelf->_sawDrag = NO;
    [strongSelf fitCorners:YES];
    [strongSelf rescueIfLost];
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
  [self stopMotion];
  [self bendCornersTo:zen_pip_throw::kFreeRadius animated:NO];
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(settle) object:nil];
  _sawDrag = NO;
  if (_stashedEdge != ZenPiPEdgeNone) [self setStashedEdge:ZenPiPEdgeNone];
  const NSRect from = _window.frame;
  _animating = YES;
  const CFTimeInterval start = CACurrentMediaTime();
  __unsafe_unretained ZenPiPController *weakSelf = self;
  _slide = [[NSTimer scheduledTimerWithTimeInterval:1.0 / 120 repeats:YES block:^(NSTimer *timer) {
    ZenPiPController *strongSelf = weakSelf;
    if (!strongSelf || !strongSelf->_window || !strongSelf->_window.visible) {
      if (strongSelf) [strongSelf stopMotion];
      else [timer invalidate];
      return;
    }
    const double t = CACurrentMediaTime() - start;
    const auto x = zen_pip_throw::SpringAt(NSMinX(from) - NSMinX(target), velocity.x, t);
    const auto y = zen_pip_throw::SpringAt(NSMinY(from) - NSMinY(target), velocity.y, t);
    const BOOL done = zen_pip_throw::Resolved(x, y);
    const NSPoint origin = done ? target.origin : NSMakePoint(round(NSMinX(target) + x.offset), round(NSMinY(target) + y.offset));
    if (!NSEqualPoints(origin, strongSelf->_window.frame.origin)) {
      [strongSelf->_window setFrameOrigin:origin];
    }
    if (!done) return;
    [strongSelf stopMotion];
    [strongSelf fitCorners:YES];
    [strongSelf rescueIfLost];
  }] retain];
  [NSRunLoop.currentRunLoop addTimer:_slide forMode:NSRunLoopCommonModes];
}

- (void)dragReleasedAt:(NSPoint)pointer velocity:(NSPoint)velocity {
  const BOOL reduceMotion = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
  const BOOL flings = !reduceMotion && zen_pip_throw::DragFlings({velocity.x, velocity.y}) &&
                      [self edgeBeyond] == ZenPiPEdgeNone;
  const BOOL thrown = flings && [self throwFrom:pointer velocity:velocity];
  if (!thrown) [self rescueIfLost];
}

- (void)swipeBegan:(NSEvent *)event {
  [self stopMotion];
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(settle) object:nil];
  _swiping = YES;
  _swipeStart = _window.frame;
  _swipeHome = [self gestureHome];
  CGPoint point = CGEventGetLocation(event.CGEvent);
  NSPoint pointer = NSMakePoint(point.x, NSMaxY(NSScreen.screens.firstObject.frame) - point.y);
  _swipeGrab = NSMakePoint(MIN(MAX(pointer.x - NSMinX(_swipeStart), 0), NSWidth(_swipeStart)),
                           MIN(MAX(pointer.y - NSMinY(_swipeStart), 0), NSHeight(_swipeStart)));
  _swipePointer = NSEvent.mouseLocation;
  _swipeBeganAt = CACurrentMediaTime();
  _swipeLastDelta = NSZeroPoint;
  [NSCursor setHiddenUntilMouseMoves:YES];
  [self swipeMoved:event];
}

- (void)moveBy:(zen_pip_throw::Point)delta {
  if (delta.x == 0 && delta.y == 0) return;
  const auto screens = ThrowScreens();
  const auto next =
      zen_pip_throw::SwipeStep(ThrowRect(_window.frame), delta, screens.data(), (int)screens.size(), ScreenIndex(_swipeHome));
  const NSPoint origin = NSMakePoint(next.x, next.y);
  if (!NSEqualPoints(origin, _window.frame.origin)) [_window setFrameOrigin:origin];
}

- (void)abandonSwipe {
  if (!_swiping) return;
  _swiping = NO;
  [NSCursor setHiddenUntilMouseMoves:NO];
}

- (void)swipeMoved:(NSEvent *)event {
  const auto delta = zen_pip_throw::FingerDelta(event.scrollingDeltaX, event.scrollingDeltaY, event.isDirectionInvertedFromDevice);
  _swipeLastDelta = NSMakePoint(delta.x, delta.y);
  _swipeLastAt = NSProcessInfo.processInfo.systemUptime;
  [self moveBy:delta];
}

- (void)swipeEnded:(NSEvent *)event cancelled:(BOOL)cancelled {
  [self moveBy:zen_pip_throw::FingerDelta(event.scrollingDeltaX, event.scrollingDeltaY, event.isDirectionInvertedFromDevice)];
  _swiping = NO;
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
  [NSCursor setHiddenUntilMouseMoves:NO];
  [self rescueIfLost];
}

- (NSDictionary *)throwInfo {
  return @{@"lastThrow" : _lastThrow ?: @{}, @"lastSwipe" : _lastSwipe ?: @{}, @"lastRelease" : _lastRelease ?: @{}, @"lastScreenFit" : _lastScreenFit ?: @{}, @"swiping" : @(_swiping)};
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

    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel | NSEventMaskMagnify
                                          handler:^NSEvent *(NSEvent *event) {
      return [ZenPiPController handleSwipe:event] || [ZenPiPZoom handle:event] ? nil : event;
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
