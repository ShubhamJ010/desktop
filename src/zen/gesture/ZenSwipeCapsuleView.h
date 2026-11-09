/* -*- Mode: Objective-C++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#ifndef ZEN_GESTURE_ZENSWIPECAPSULEVIEW_H_
#define ZEN_GESTURE_ZENSWIPECAPSULEVIEW_H_

#import <Cocoa/Cocoa.h>
#import "ZenSwipeInternal.h"

/**
 * Floating circular frosted glass pill indicating a back/forward swipe gesture.
 * Directly replicates Ardia's SwipeOverlay design and physics.
 */
@interface ZenSwipeCapsuleView : NSView

@property(nonatomic, readonly) ZenSwipeDirection direction;
@property(nonatomic, readonly) BOOL confirmed;

- (instancetype)initWithDirection:(ZenSwipeDirection)direction;

/**
 * Updates the capsule position, size, and appearance according to swipe progress.
 *
 * @param progress Normalized gesture progress (0.0 to >1.0).
 * @param confirmed Whether the gesture has exceeded the threshold to navigate.
 * @param bounds Bounds of the containing browser window content view.
 */
- (void)updateWithProgress:(CGFloat)progress
                 confirmed:(BOOL)confirmed
            inWindowBounds:(NSRect)bounds;

/**
 * Dismisses the capsule view.
 *
 * @param success If YES, animates a confirmation pulse/fade before removal.
 *                If NO, springs/slides back into the window edge before removal.
 * @param completion Block invoked once animation completes and view is removed.
 */
- (void)dismissWithSuccess:(BOOL)success
                completion:(void (^)(void))completion;

@end

#endif // ZEN_GESTURE_ZENSWIPECAPSULEVIEW_H_
