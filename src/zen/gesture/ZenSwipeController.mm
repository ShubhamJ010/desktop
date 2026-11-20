/* -*- Mode: Objective-C++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#import "ZenSwipeController.h"
#import "ZenSwipeCapsuleView.h"
#import "ZenSwipeMath.h"
#import "ZenSwipeInternal.h"

#if __has_include("mozilla/Services.h")
#include "mozilla/Services.h"
#include "nsCOMPtr.h"
#include "nsIObserverService.h"
#include "nsString.h"
#endif

#if __has_include("mozilla/StaticPrefs_zen.h")
#include "mozilla/StaticPrefs_zen.h"
#endif

#if __has_include("mozilla/Preferences.h")
#include "mozilla/Preferences.h"
#endif

#import <objc/runtime.h>
#import <Foundation/Foundation.h>

using namespace zen_swipe;

namespace {

const void *const kZenSwipeControllerKey = &kZenSwipeControllerKey;

enum class GestureState {
  Idle,
  Pending,
  Tracking
};

// -----------------------------------------------------------------------------
// Vertical side channel for the history sheet
//
// Gecko's APZ owns the swipe and browser-gestureSupport.js draws the capsule from
// the horizontal delta, but nothing forwards the vertical component that picks an
// entry in the sheet. This controller runs a passive local scroll monitor and
// mirrors Ardia's accumulator: dy += scrollingDeltaY, reset when a gesture begins.
//
// chrome JS sets zen.widget.macos.back-gesture-phase:
//   0 = idle (no accumulation), 1 = tracking (accumulate only),
//   2 = sheet visible (accumulate and publish).
// native publishes topic "zen-swipe-vertical" with dy as a decimal string, which
// gHistorySwipeAnimation parses and snapshots as its baseline.
// The monitor never swallows an event: Gecko needs the end phase to finish.
// -----------------------------------------------------------------------------

// Mirrors `_zenSwipePhase()` in browser-gestureSupport.js.
const char* const kZenSwipePhasePref = "zen.widget.macos.back-gesture-phase";

// Observer topic consumed in `observe()` in browser-gestureSupport.js.
const char* const kZenSwipeVerticalTopic = "zen-swipe-vertical";

// Log every monitor event and notification to the system log when set.
const char* const kZenSwipeDebugPref = "zen.widget.macos.back-gesture-debug";

// Cumulative scrollingDeltaY of the in-flight gesture.
double gZenSwipeVertical = 0.0;

// Retained for the life of the app; one monitor per process, not per window.
id gZenSwipeScrollMonitor = nil;

/**
 * Read the gesture phase published by chrome JS. A missing pref means idle.
 */
int ZenSwipePhase() {
#if __has_include("mozilla/Preferences.h")
  return mozilla::Preferences::GetInt(kZenSwipePhasePref, 0);
#else
  return 0;
#endif
}

/**
 * Push cumulative vertical travel to chrome as a plain string, so chrome needs no
 * XPCOM interface to unpack it.
 */
void NotifySwipeVertical(double aDy) {
#if __has_include("mozilla/Services.h")
  nsCOMPtr<nsIObserverService> observerService =
      mozilla::services::GetObserverService();
  if (!observerService) {
    return;
  }
  nsAutoString payload;
  payload.AppendFloat(aDy);
  observerService->NotifyObservers(nullptr, kZenSwipeVerticalTopic,
                                   payload.get());
#endif
}

} // namespace

// Log monitor events and observer notifications to the system log when the debug
// pref is on. The pref is a bool: reading it as an int returns the default and
// silently disables this channel.
void ZenSwipeDebugLog(NSString *format, ...) {
#if __has_include("mozilla/Preferences.h")
  if (!mozilla::Preferences::GetBool(kZenSwipeDebugPref, false)) {
    return;
  }
#endif
  va_list ap;
  va_start(ap, format);
  NSString *msg = [[NSString alloc] initWithFormat:format arguments:ap];
  va_end(ap);
  NSLog(@"%@", msg);
  [msg release];
}

@implementation ZenSwipeController {
  NSWindow *_window;
  ZenSwipeCapsuleView *_capsuleView;
  GestureState _state;
  ZenSwipeDirection _direction;
  CGFloat _dx;
  CGFloat _dy;
  BOOL _wasConfirmed;
  BOOL _swallowingMomentum;
}

+ (void)ensureGlobalMonitor {
  // One passive monitor per process. It only reads the vertical travel of a swipe
  // chrome already announced; APZ still owns the gesture.
  if (gZenSwipeScrollMonitor) {
    return;
  }
  gZenSwipeScrollMonitor =
      [[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel | NSEventMaskSwipe
                                             handler:^NSEvent *(NSEvent *event) {
                                               return [ZenSwipeController
                                                   handleVerticalScroll:event];
                                             }] retain];
  ZenSwipeDebugLog(@"ZenSwipeMonitor installed (ScrollWheel|Swipe)");
}

/**
 * Passive wheel tap that measures the vertical component of a swipe.
 *
 * Phase 0 ignores the event after one pref read; phase 1 accumulates only; phase 2
 * accumulates and publishes. The event is always returned unchanged.
 *
 * The phase pref is the only gate. Requiring an attached controller threw every
 * sample away: a local monitor runs before AppKit dispatches to a window, so
 * [event window] is nil even when windowNumber is set.
 */
+ (NSEvent *)handleVerticalScroll:(NSEvent *)event {
  ZenSwipeDebugLog(@"ZenSwipeMonitorEntry: type=%u phase=%u momentumPhase=%u windowNumber=%ld scrollingDeltaY=%.3f deltaY=%.3f scrollingDeltaX=%.3f deltaX=%.3f",
                   (unsigned)event.type, (unsigned)event.phase, (unsigned)event.momentumPhase,
                   event.window ? (long)event.window.windowNumber : -1L,
                   event.scrollingDeltaY, event.deltaY,
                   event.scrollingDeltaX, event.deltaX);

  if (event.type != NSEventTypeScrollWheel && event.type != NSEventTypeSwipe) {
    return event;
  }

  // Both Ardia and the sheet measure travel from the start of the gesture.
  if (event.phase == NSEventPhaseBegan) {
    gZenSwipeVertical = 0.0;
    ZenSwipeDebugLog(@"-> reset dy=0 (phase began)");
  }

  const int phase = ZenSwipePhase();
  if (phase <= 0) {
    gZenSwipeVertical = 0.0;
    ZenSwipeDebugLog(@"-> idle (pref phase=%d): dropping", phase);
    return event;
  }

  // Momentum keeps arriving after the fingers leave and must never pick a row; the
  // end phase carries no travel.
  if (event.momentumPhase != NSEventPhaseNone ||
      event.phase == NSEventPhaseEnded) {
    ZenSwipeDebugLog(@"-> dropping (momentumPhase=%u phase=%u)",
                     (unsigned)event.momentumPhase, (unsigned)event.phase);
    return event;
  }

  // Only accumulate when vertical travel dominates, so horizontal swipes are not
  // disturbed by micro noise.
  if (fabs(event.scrollingDeltaY) > 0.01 &&
      fabs(event.scrollingDeltaY) >= fabs(event.scrollingDeltaX)) {
    gZenSwipeVertical += event.scrollingDeltaY;
    ZenSwipeDebugLog(@"-> accumulated dy=%.3f (pref phase=%d)", gZenSwipeVertical, phase);

    if (phase >= 2) {
      NotifySwipeVertical(gZenSwipeVertical);
      ZenSwipeDebugLog(@"-> notified zen-swipe-vertical dy=%.3f", gZenSwipeVertical);
    }
  }

  return event;
}

+ (BOOL)attachToWindow:(NSWindow *)window {
  if (!window) {
    return NO;
  }
  ZenSwipeController *existing = [self controllerForWindow:window];
  if (existing) {
    return YES;
  }

  ZenSwipeController *controller = [[ZenSwipeController alloc] initWithWindow:window];
  objc_setAssociatedObject(window, kZenSwipeControllerKey, controller,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [controller release];

  [self ensureGlobalMonitor];
  return YES;
}

+ (void)detachFromWindow:(NSWindow *)window {
  if (!window) {
    return;
  }
  ZenSwipeController *controller = [self controllerForWindow:window];
  if (controller) {
    [controller cancelGesture];
    objc_setAssociatedObject(window, kZenSwipeControllerKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
}

+ (ZenSwipeController *)controllerForWindow:(NSWindow *)window {
  if (!window) {
    return nil;
  }
  return (ZenSwipeController *)objc_getAssociatedObject(window, kZenSwipeControllerKey);
}

- (instancetype)initWithWindow:(NSWindow *)window {
  if ((self = [super init])) {
    _window = window;
    _capsuleView = nil;
    _state = GestureState::Idle;
    _direction = ZenSwipeDirectionBack;
    _dx = 0;
    _dy = 0;
    _wasConfirmed = NO;
    _swallowingMomentum = NO;
  }
  return self;
}

- (BOOL)isTracking {
  return _state == GestureState::Tracking;
}

- (void)cancelGesture {
  if (_capsuleView) {
    [_capsuleView dismissWithSuccess:NO completion:nil];
    [_capsuleView release];
    _capsuleView = nil;
  }
  _state = GestureState::Idle;
  _wasConfirmed = NO;
  _dx = 0;
  _dy = 0;
}

- (void)triggerNavigation:(ZenSwipeDirection)direction {
  const BOOL back = (direction == ZenSwipeDirectionBack);

  // Notify Gecko observers.
#if __has_include("mozilla/Services.h")
  if (nsCOMPtr<nsIObserverService> obs = mozilla::services::GetObserverService()) {
    obs->NotifyObservers(nullptr, back ? "zen-navigate-back" : "zen-navigate-forward", nullptr);
  }
#endif

  // Synthesize Command+[ (Back, keyCode 33) or Command+] (Forward, 30) to the window.
  const unsigned short keyCode = back ? 33 : 30;
  NSString *const characters = back ? @"[" : @"]";
  const NSTimeInterval timestamp = NSProcessInfo.processInfo.systemUptime;

  NSEvent *keyDown = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                      location:NSZeroPoint
                                 modifierFlags:NSEventModifierFlagCommand
                                     timestamp:timestamp
                                  windowNumber:_window.windowNumber
                                       context:nil
                                    characters:characters
                   charactersIgnoringModifiers:characters
                                     isARepeat:NO
                                       keyCode:keyCode];
  if (keyDown) {
    [_window sendEvent:keyDown];
  }

  NSEvent *keyUp = [NSEvent keyEventWithType:NSEventTypeKeyUp
                                    location:NSZeroPoint
                               modifierFlags:NSEventModifierFlagCommand
                                   timestamp:timestamp
                                windowNumber:_window.windowNumber
                                     context:nil
                                  characters:characters
                 charactersIgnoringModifiers:characters
                                   isARepeat:NO
                                     keyCode:keyCode];
  if (keyUp) {
    [_window sendEvent:keyUp];
  }
}

- (NSEvent *)handleScrollEvent:(NSEvent *)event {
  return event;
}

- (void)dealloc {
  [self cancelGesture];
  _window = nil;
  [super dealloc];
}

@end

namespace zen_swipe {

BOOL Attach(NSWindow *window) {
#if __has_include("mozilla/StaticPrefs_zen.h")
  if (!mozilla::StaticPrefs::zen_widget_macos_back_gesture_indicator()) {
    return NO;
  }
#endif
  ZenSwipeDebugLog(@"ZenSwipeAttach: window=%p windowNumber=%ld",
                   window, window ? (long)window.windowNumber : -1L);
  return [ZenSwipeController attachToWindow:window];
}

void Detach(NSWindow *window) {
  [ZenSwipeController detachFromWindow:window];
}

} // namespace zen_swipe
