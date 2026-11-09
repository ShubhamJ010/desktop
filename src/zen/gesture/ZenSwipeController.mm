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
#endif

#if __has_include("mozilla/StaticPrefs_zen.h")
#include "mozilla/StaticPrefs_zen.h"
#endif

#import <objc/runtime.h>

using namespace zen_swipe;

namespace {

const void *const kZenSwipeControllerKey = &kZenSwipeControllerKey;

enum class GestureState {
  Idle,
  Pending,
  Tracking
};

} // namespace

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
  // Global scroll monitoring disabled: Gecko APZ manages overscroll swipe tracking
  // and routes swipe events directly to browser-gestureSupport.js and ZenSpacesSwipe.mjs.
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
  return [ZenSwipeController attachToWindow:window];
}

void Detach(NSWindow *window) {
  [ZenSwipeController detachFromWindow:window];
}

} // namespace zen_swipe
