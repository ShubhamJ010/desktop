/* -*- Mode: Objective-C++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#ifndef ZEN_GESTURE_ZENSWIPECAPSULEVIEW_H_
#define ZEN_GESTURE_ZENSWIPECAPSULEVIEW_H_

#import <Cocoa/Cocoa.h>
#import "ZenSwipeInternal.h"

/**
 * Frosted glass pill shown during a back/forward swipe (Ardia's SwipeOverlay).
 */
@interface ZenSwipeCapsuleView : NSView

@property(nonatomic, readonly) ZenSwipeDirection direction;
@property(nonatomic, readonly) BOOL confirmed;

- (instancetype)initWithDirection:(ZenSwipeDirection)direction;

/**
 * Update position, size and appearance from swipe progress (0.0 to >1.0).
 */
- (void)updateWithProgress:(CGFloat)progress
                 confirmed:(BOOL)confirmed
            inWindowBounds:(NSRect)bounds;

/**
 * Remove the view. Success plays a confirmation pulse; otherwise it springs back
 * into the window edge.
 */
- (void)dismissWithSuccess:(BOOL)success
                completion:(void (^)(void))completion;

@end

#endif // ZEN_GESTURE_ZENSWIPECAPSULEVIEW_H_
