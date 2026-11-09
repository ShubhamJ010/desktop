/* -*- Mode: Objective-C++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#ifndef ZEN_GESTURE_ZENSWIPEINTERNAL_H_
#define ZEN_GESTURE_ZENSWIPEINTERNAL_H_

#import <Cocoa/Cocoa.h>

/**
 * Direction of horizontal edge swipe gesture.
 */
typedef NS_ENUM(NSInteger, ZenSwipeDirection) {
  ZenSwipeDirectionBack = 1,     // Swiping left-to-right (navigates back)
  ZenSwipeDirectionForward = -1  // Swiping right-to-left (navigates forward)
};

namespace zen_swipe {

/**
 * Attaches the back/forward trackpad swipe gesture monitor and overlay to a browser window.
 *
 * @param window The target NSWindow representing a top-level browser window.
 * @return YES if successfully attached, NO otherwise.
 */
BOOL Attach(NSWindow *window);

/**
 * Detaches the gesture monitor and removes overlays from a browser window.
 *
 * @param window The target NSWindow.
 */
void Detach(NSWindow *window);

} // namespace zen_swipe

#endif // ZEN_GESTURE_ZENSWIPEINTERNAL_H_
