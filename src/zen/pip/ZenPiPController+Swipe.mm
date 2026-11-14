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
  if (gSwipeMomentum == window) gSwipeMomentum = nil;
  [[self forWindow:window] abandonSwipe];
}

+ (ZenPiPController *)swipeTargetFor:(NSEvent *)event {
  return [self controllerUnderPointer];
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
  if (phase & NSEventPhaseMayBegin) {
    if (!event.hasPreciseScrollingDeltas || (event.modifierFlags & NSEventModifierFlagCommand)) {
      ZenPiPController *controller = [self swipeTargetFor:event];
      if (controller) [controller disarmSwipe];
      return NO;
    }
    ZenPiPController *controller = [self swipeTargetFor:event];
    return controller != nil;
  }
  if (phase & NSEventPhaseBegan) {
    gSwipeMomentum = nil;
    if (!event.hasPreciseScrollingDeltas || (event.modifierFlags & NSEventModifierFlagCommand)) {
      ZenPiPController *controller = [self swipeTargetFor:event];
      if (controller) [controller disarmSwipe];
      return NO;
    }
    ZenPiPController *controller = [self swipeTargetFor:event];
    if (!controller) return NO;
    if (gSwipeWindow != controller.window) {
      [self abandonSwipeOn:gSwipeWindow];
    }
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
