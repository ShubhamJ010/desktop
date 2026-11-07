#import "ZenPictureInPictureInternal.h"
#import "ZenPiPZoomMath.h"

#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

using namespace zen_pip;

namespace zen_pip {
const void *const kZoomKey = &kZoomKey;
}

@implementation ZenPiPZoom {
  __weak NSWindow *_window;
  NSRect _last;
  double _width;
  double _aspect;
  double _target;
  NSPoint _pointer;
  NSTimer *_ease;
}

+ (BOOL)zooms:(NSWindow *)window {
  if (!window.visible || !(window.styleMask & NSWindowStyleMaskResizable)) return NO;
  ZenPiPController *controller = [ZenPiPController forWindow:window];
  if (controller) return controller.stashedEdge == ZenPiPEdgeNone;
  return NO;
}

+ (instancetype)forWindow:(NSWindow *)window {
  ZenPiPZoom *zoom = objc_getAssociatedObject(window, kZoomKey);
  if (!zoom) {
    zoom = [[ZenPiPZoom alloc] init];
    zoom->_window = window;
    objc_setAssociatedObject(window, kZoomKey, zoom, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return zoom;
}

static __weak NSWindow *gZoomGesture;

+ (BOOL)handle:(NSEvent *)event {
  return [self route:event];
}

+ (NSWindow *)windowFor:(NSEvent *)event {
  if (event.window) return event.window;
  NSPoint point = event.locationInWindow;
  for (NSWindow *window in NSApp.orderedWindows)
    if (NSPointInRect(point, window.frame) && [self zooms:window]) return window;
  return nil;
}

+ (BOOL)route:(NSEvent *)event {
  NSWindow *window = [self windowFor:event];
  BOOL command = (event.modifierFlags & NSEventModifierFlagCommand) != 0;
  BOOL scroll = event.type == NSEventTypeScrollWheel;
  if (scroll) {
    NSEventPhase phase = event.phase, momentum = event.momentumPhase;
    BOOL wheel = phase == NSEventPhaseNone && momentum == NSEventPhaseNone;
    if (wheel || (phase & (NSEventPhaseBegan | NSEventPhaseMayBegin))) gZoomGesture = nil;
    if (gZoomGesture) window = gZoomGesture;
    if (!window || (!command && gZoomGesture != window)) return NO;
    if (![self zooms:window]) return NO;
    if (!wheel) gZoomGesture = window;
    if (momentum & (NSEventPhaseEnded | NSEventPhaseCancelled)) gZoomGesture = nil;
    double dy = event.scrollingDeltaY;
    if (dy == 0) return YES;
    [[self forWindow:window] zoomBy:zen_pip_zoom::ScrollFactor(dy, event.hasPreciseScrollingDeltas)
                                 at:[self screenPoint:event]
                               ease:!event.hasPreciseScrollingDeltas];
    return YES;
  }
  if (!window || ![self zooms:window]) return NO;
  [[self forWindow:window] zoomBy:zen_pip_zoom::MagnifyFactor(event.magnification)
                               at:[self screenPoint:event]
                             ease:NO];
  return YES;
}

+ (NSPoint)screenPoint:(NSEvent *)event {
  return event.window ? [event.window convertPointToScreen:event.locationInWindow] : event.locationInWindow;
}

- (void)zoomBy:(double)factor at:(NSPoint)pointer ease:(BOOL)ease {
  NSWindow *window = _window;
  [[ZenPiPController forWindow:window] stopMotion];
  NSRect frame = window.frame;
  if (!NSEqualRects(frame, _last) || _width <= 0) {
    double aspect = NSWidth(frame) / MAX(NSHeight(frame), 1);
    if (!(_aspect > 0 && fabs(NSWidth(frame) / _aspect - NSHeight(frame)) <= 1)) _aspect = aspect;
    _width = NSWidth(frame), _target = 0;
    [_ease invalidate], _ease = nil;
  }
  _pointer = pointer;
  if (!ease) {
    [_ease invalidate], _ease = nil, _target = 0;
    return [self step:factor];
  }
  double low, high;
  zen_pip_zoom::WidthLimits(_aspect, [self minSize], [self maxSize], [self visible], &low, &high);
  _target = MIN(MAX((_target > 0 ? _target : _width) * factor, low), high);
  if (_ease) return;
  __weak ZenPiPZoom *weakSelf = self;
  _ease = [NSTimer timerWithTimeInterval:1.0 / 120 repeats:YES block:^(NSTimer *timer) {
    ZenPiPZoom *strongSelf = weakSelf;
    if (!strongSelf || !strongSelf->_window.visible || !NSEqualRects(strongSelf->_window.frame, strongSelf->_last)) {
      if (strongSelf) strongSelf->_ease = nil, strongSelf->_target = 0;
      return [timer invalidate];
    }
    double width = strongSelf->_width, target = strongSelf->_target;
    BOOL done = fabs(target - width) < 0.25;
    [strongSelf step:(done ? target : width + (target - width) * 0.25) / width];
    if (!done) return;
    strongSelf->_ease = nil, strongSelf->_target = 0;
    [timer invalidate];
  }];
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
  zen_pip_zoom::Result result = zen_pip_zoom::Zoom(
      {NSMinX(frame), NSMinY(frame), NSWidth(frame), NSHeight(frame)}, _width, _aspect, factor, {_pointer.x, _pointer.y},
      [self visible], [self minSize], [self maxSize]);
  _width = result.width;
  NSRect next = NSMakeRect(result.frame.x, result.frame.y, result.frame.w, result.frame.h);
  if (!NSEqualRects(next, frame)) [window setFrame:next display:YES];
  _last = window.frame;
}

@end
