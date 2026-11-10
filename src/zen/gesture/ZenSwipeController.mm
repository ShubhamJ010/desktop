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
// Vertical side channel for the Ardia-style history sheet
// -----------------------------------------------------------------------------
//
// The swipe gesture itself stays where it already lives: Gecko's APZ tracks the
// pan, browser-gestureSupport.js receives the horizontal delta through
// MozSwipeGestureUpdate, draws the capsule from it and decides when a hold turns
// the capsule into the history sheet.
//
// The one piece Gecko never forwards to chrome is the vertical component of that
// same gesture. Swiping up/down while holding is what picks an entry in Ardia's
// sheet (`SwipeOverlay.tsx` `select()` over the `dy` of `ArdiaSwipe.mm`), and it
// cannot be reconstructed from the horizontal delta. So this controller runs a
// passive local scroll monitor that mirrors Ardia's accumulator:
//
//   dy += event.scrollingDeltaY   (ArdiaSwipe.mm: `gGesture.dy += ...`)
//   dy reset when a scroll gesture begins
//
// Protocol (all on the main thread, one swipe at a time because the trackpad
// gesture belongs to one window):
//
//   chrome JS  --pref-->  native
//     zen.widget.macos.back-gesture-phase
//       0 = idle, no swipe on this window           (nothing is accumulated)
//       1 = swipe tracked, sheet not up yet         (accumulate, do not push)
//       2 = history sheet visible                   (accumulate and push)
//
//   native  --observer-->  chrome JS
//     topic "zen-swipe-vertical", data = the cumulative scrollingDeltaY of the
//     current gesture rendered as a decimal string. gHistorySwipeAnimation
//     parses it with parseFloat and snapshots the first sample as its baseline.
//
// The monitor never swallows an event: Gecko has to keep seeing the scroll
// gesture, including its end phase, or the swipe would never finish and the
// capsule would be stuck on screen.

// Pref mirrored from browser-gestureSupport.js `_zenSwipePhase()`.
const char* const kZenSwipePhasePref = "zen.widget.macos.back-gesture-phase";

// Observer topic consumed in browser-gestureSupport.js `observe()`.
const char* const kZenSwipeVerticalTopic = "zen-swipe-vertical";

// When true, the native vertical monitor logs every event and every notification
// to the system log (visible in Console.app filtered on the Zen SJ process) so
// the Ardia-style sheet channel can be traced without a debugger.
const char* const kZenSwipeDebugPref = "zen.widget.macos.back-gesture-debug";

// Cumulative vertical travel (scrollingDeltaY) of the in-flight gesture.
double gZenSwipeVertical = 0.0;

// Retained so the monitor is never collected while the app runs; there is one
// monitor for the whole process, not one per window.
id gZenSwipeScrollMonitor = nil;

/**
 * Reads the gesture phase published by chrome JS.
 * A missing pref (older profile, non-macOS) means "idle".
 */
int ZenSwipePhase() {
#if __has_include("mozilla/Preferences.h")
  return mozilla::Preferences::GetInt(kZenSwipePhasePref, 0);
#else
  return 0;
#endif
}

/**
 * Pushes the cumulative vertical travel to chrome as an observer notification.
 * The payload is a plain string so the chrome side needs no XPCOM object and no
 * extra interface to unpack it.
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

// Debug logging for the native vertical side channel. When the debug pref is on,
// every monitor event and every observer notification is written to the system log
// (Console.app, filter on the Zen SJ process) so the channel can be traced without
// a debugger.
void ZenSwipeDebugLog(NSString *format, ...) {
#if __has_include("mozilla/Preferences.h")
  if (mozilla::Preferences::GetInt(kZenSwipeDebugPref, 0) == 0) {
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
  // One passive scroll monitor per process. It only reads the vertical travel of
  // a swipe that chrome already announced through the phase pref; Gecko's APZ
  // remains the owner of the gesture itself (see the protocol comment above).
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
 * Passive scroll-wheel tap used to measure the vertical component of a swipe.
 *
 * Phase 0 (idle): the event is ignored, so ordinary page scrolling costs one
 * pref read.
 * Phase 1 (tracking): travel is accumulated but not published; the sheet is not
 * up yet and the capsule does not need it.
 * Phase 2 (sheet visible): travel is accumulated and published, which is what
 * moves the selection in the sheet.
 *
 * The event is always returned unchanged.
 *
 * The phase pref is the only gate. An earlier version also required the event to
 * resolve to a window with an attached ZenSwipeController, which silently threw
 * every sample away: a local monitor runs inside `-[NSApplication sendEvent:]`,
 * i.e. *before* AppKit dispatches the event to a window, so `[event window]` is
 * nil for most scroll-wheel events even though `windowNumber` is set. No samples
 * meant no vertical travel, which looked exactly like the history sheet being
 * dead: it opened, and then nothing could ever be selected.
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

  // Momentum keeps arriving long after the fingers are gone; it must never pick
  // a row. The end phase itself carries no travel either.
  if (event.momentumPhase != NSEventPhaseNone ||
      event.phase == NSEventPhaseEnded) {
    ZenSwipeDebugLog(@"-> dropping (momentumPhase=%u phase=%u)",
                     (unsigned)event.momentumPhase, (unsigned)event.phase);
    return event;
  }

  gZenSwipeVertical += event.scrollingDeltaY;
  ZenSwipeDebugLog(@"-> accumulated dy=%.3f (pref phase=%d)", gZenSwipeVertical, phase);

  if (phase >= 2) {
    NotifySwipeVertical(gZenSwipeVertical);
    ZenSwipeDebugLog(@"-> notified zen-swipe-vertical dy=%.3f", gZenSwipeVertical);
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

  // 1. Notify Gecko observer service for any listener components
#if __has_include("mozilla/Services.h")
  if (nsCOMPtr<nsIObserverService> obs = mozilla::services::GetObserverService()) {
    obs->NotifyObservers(nullptr, back ? "zen-navigate-back" : "zen-navigate-forward", nullptr);
  }
#endif

  // 2. Synthesize Command+[ (Back) or Command+] (Forward) key event to the window.
  // Left Bracket: keyCode 33, Right Bracket: keyCode 30.
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
