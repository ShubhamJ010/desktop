/* -*- Mode: C++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#ifndef ZEN_GESTURE_ZENSWIPEMATH_H_
#define ZEN_GESTURE_ZENSWIPEMATH_H_

#include <algorithm>

/**
 * Swipe back/forward motion models, adapted from Ardia's swipeMotion.ts and
 * ArdiaSwipe.mm.
 */
namespace zen_swipe {

// Horizontal travel (points) for full confirmation.
constexpr double kSwipeUnit = 75.0;

// Resting pill diameter (points).
constexpr double kCapsuleSize = 72.0;

// Pill diameter (points) once confirmed.
constexpr double kCapsuleSizeConfirmed = 82.0;

// Inset (points) from the window edge at confirmation.
constexpr double kCapsuleInset = 14.0;

// Rubber-band resistance coefficient for over-travel.
constexpr double kRubberCoefficient = 0.15;

// Travel (points) before tracking starts.
constexpr double kStartDistance = 4.0;

// dx/dy ratio needed to start tracking, so vertical scrolling is not intercepted.
constexpr double kStartDominance = 1.5;

// dy/dx ratio that cancels an active swipe.
constexpr double kCancelDominance = 2.0;

/**
 * iOS-style rubber band: linear up to `limit`, then asymptotically towards
 * limit + dimension.
 */
inline double RubberBand(double value, double limit, double dimension, double c = kRubberCoefficient) {
  if (value <= limit) {
    return value;
  }
  return limit + (1.0 - 1.0 / (((value - limit) * c) / dimension + 1.0)) * dimension;
}

/**
 * Normalized progress: 0 at rest, 1 at the navigation threshold, above 1 overdrag.
 */
inline double SwipeProgress(double distance) {
  return std::max(0.0, distance / kSwipeUnit);
}

/**
 * Capsule offset from the edge: -width (off-screen) at 0, kCapsuleInset at 1.
 */
inline double CapsuleOffset(double progress, double width) {
  const double limit = width + kCapsuleInset;
  return RubberBand(progress * limit, limit, limit) - width;
}

} // namespace zen_swipe

#endif // ZEN_GESTURE_ZENSWIPEMATH_H_
