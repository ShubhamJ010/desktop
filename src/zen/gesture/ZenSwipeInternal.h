/* -*- Mode: Objective-C++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#ifndef ZEN_GESTURE_ZENSWIPEINTERNAL_H_
#define ZEN_GESTURE_ZENSWIPEINTERNAL_H_

#import <Cocoa/Cocoa.h>

/**
 * Direction of a horizontal edge swipe.
 */
typedef NS_ENUM(NSInteger, ZenSwipeDirection) {
  ZenSwipeDirectionBack = 1,     // Swiping left-to-right (navigates back)
  ZenSwipeDirectionForward = -1  // Swiping right-to-left (navigates forward)
};

namespace zen_swipe {

/**
 * Attach the swipe monitor and overlay to a browser window.
 */
BOOL Attach(NSWindow *window);

/**
 * Detach the monitor and remove the overlays.
 */
void Detach(NSWindow *window);

} // namespace zen_swipe

#endif // ZEN_GESTURE_ZENSWIPEINTERNAL_H_
