/* -*- Mode: Objective-C++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#ifndef ZEN_GESTURE_ZENSWIPECONTROLLER_H_
#define ZEN_GESTURE_ZENSWIPECONTROLLER_H_

#import <Cocoa/Cocoa.h>
#import "ZenSwipeInternal.h"

@class ZenSwipeCapsuleView;

/**
 * Controller managing trackpad swipe-to-navigate gestures and visual indicators.
 * Monitors local scroll wheel events on browser windows, filters for edge swipes,
 * controls the floating capsule indicator, delivers haptic feedback, and invokes navigation.
 */
@interface ZenSwipeController : NSObject

@property(nonatomic, readonly, assign) NSWindow *window;
@property(nonatomic, readonly) BOOL isTracking;

+ (BOOL)attachToWindow:(NSWindow *)window;
+ (void)detachFromWindow:(NSWindow *)window;
+ (ZenSwipeController *)controllerForWindow:(NSWindow *)window;

- (NSEvent *)handleScrollEvent:(NSEvent *)event;

@end

#endif // ZEN_GESTURE_ZENSWIPECONTROLLER_H_
