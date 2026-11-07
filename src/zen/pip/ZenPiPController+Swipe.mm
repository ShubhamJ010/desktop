#import "ZenPictureInPictureInternal.h"
#import "ZenPiPThrowMath.h"

#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

using namespace zen_pip;

@implementation ZenPiPController (Swipe)

static __unsafe_unretained NSWindow *gSwipeWindow = nil;
static __unsafe_unretained NSWindow *gSwipeMomentum = nil;

+ (void)abandonSwipeOn:(NSWindow *)window {
  if (!window) return;
  if (gSwipeWindow == window) gSwipeWindow = nil;
  [[self forWindow:window] abandonSwipe];
}

+ (ZenPiPController *)swipeTargetFor:(NSEvent *)event {
  NSWindow *window = event.window;
  if (!window) {
    CGPoint point = CGEventGetLocation(event.CGEvent);
    NSPoint p = NSMakePoint(point.x, NSMaxY(NSScreen.screens.firstObject.frame) - point.y);
    for (NSWindow *candidate in NSApp.orderedWindows)
      if (candidate.visible && NSPointInRect(p, candidate.frame)) {
        window = candidate;
        break;
      }
  }
  ZenPiPController *controller = window ? [self forWindow:window] : nil;
  return controller && window.visible ? controller : nil;
}

+ (BOOL)handleSwipe:(NSEvent *)event {
  if (event.type != NSEventTypeScrollWheel) return NO;
  const NSEventPhase phase = event.phase, momentum = event.momentumPhase;
  if (momentum != NSEventPhaseNone) {
    const BOOL ours = gSwipeMomentum != nil;
    if (momentum & (NSEventPhaseEnded | NSEventPhaseCancelled)) gSwipeMomentum = nil;
    return ours;
  }
  if (phase == NSEventPhaseNone) return NO;
  if (phase & (NSEventPhaseBegan | NSEventPhaseMayBegin)) {
    gSwipeMomentum = nil;
    [self abandonSwipeOn:gSwipeWindow];
    if (phase != NSEventPhaseBegan || !event.hasPreciseScrollingDeltas ||
        (event.modifierFlags & NSEventModifierFlagCommand))
      return NO;
    ZenPiPController *controller = [self swipeTargetFor:event];
    if (!controller) return NO;
    gSwipeWindow = controller.window;
    [controller swipeBegan:event];
    return YES;
  }
  NSWindow *window = gSwipeWindow;
  ZenPiPController *controller = window ? [self forWindow:window] : nil;
  if (!controller) return NO;
  if (phase & (NSEventPhaseEnded | NSEventPhaseCancelled)) {
    gSwipeWindow = nil;
    gSwipeMomentum = window;
    [controller swipeEnded:event cancelled:(phase & NSEventPhaseCancelled) != 0];
  } else {
    [controller swipeMoved:event];
  }
  return YES;
}

@end
