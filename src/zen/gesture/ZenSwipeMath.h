/* -*- Mode: C++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#ifndef ZEN_GESTURE_ZENSWIPEMATH_H_
#define ZEN_GESTURE_ZENSWIPEMATH_H_

#include <algorithm>

/**
 * Mathematical models for trackpad swipe back/forward gestures.
 * Ported and adapted from Ardia's swipeMotion.ts and ArdiaSwipe.mm.
 */
namespace zen_swipe {

// Distance (in points) the user must swipe horizontally to reach full confirmation.
constexpr double kSwipeUnit = 75.0;

// Base diameter (in points) of the resting circular gesture pill.
constexpr double kCapsuleSize = 72.0;

// Expanded diameter (in points) of the capsule upon reaching the confirmation threshold.
constexpr double kCapsuleSizeConfirmed = 82.0;

// Inset distance (in points) from the window edge at the confirmation boundary.
constexpr double kCapsuleInset = 14.0;

// Standard logarithmic rubber-band resistance coefficient for over-travel.
constexpr double kRubberCoefficient = 0.15;

// Minimum horizontal travel (in points) required before initiating swipe tracking.
constexpr double kStartDistance = 4.0;

// Ratio of horizontal travel to vertical travel (dx / dy) required to begin tracking.
// Ensures that vertical page scrolling is not accidentally intercepted.
constexpr double kStartDominance = 1.5;

// Ratio of vertical travel to horizontal travel (dy / dx) that cancels an active swipe.
constexpr double kCancelDominance = 2.0;

/**
 * Standard iOS/macOS rubber-band resistance curve:
 * If value <= limit, returns value linearly.
 * When value > limit, resistance increases logarithmically towards (limit + dimension).
 *
 * @param value Current raw input distance.
 * @param limit Linear boundary before resistance begins.
 * @param dimension Dimension parameter scaling the curve asymptotic behavior.
 * @param c Resistance coefficient factor.
 * @return Damped rubber-band offset.
 */
inline double RubberBand(double value, double limit, double dimension, double c = kRubberCoefficient) {
  if (value <= limit) {
    return value;
  }
  return limit + (1.0 - 1.0 / (((value - limit) * c) / dimension + 1.0)) * dimension;
}

/**
 * Computes normalized progress for an input horizontal distance.
 * 0.0 = at rest (gesture starting).
 * 1.0 = threshold reached; navigation will trigger if released.
 * >1.0 = over-drag with rubber-band resistance.
 *
 * @param distance Absolute horizontal swipe travel in points.
 * @return Normalized progress value.
 */
inline double SwipeProgress(double distance) {
  return std::max(0.0, distance / kSwipeUnit);
}

/**
 * Calculates the visible offset of the gesture capsule from the window edge.
 * At progress 0.0, offset is -width, placing the capsule completely off-screen.
 * At progress 1.0, offset is kCapsuleInset, placing the capsule cleanly into the viewport.
 *
 * @param progress Normalized gesture progress from SwipeProgress().
 * @param width Current width of the capsule.
 * @return Offset in points from the active edge (left for Back, right for Forward).
 */
inline double CapsuleOffset(double progress, double width) {
  const double limit = width + kCapsuleInset;
  return RubberBand(progress * limit, limit, limit) - width;
}

} // namespace zen_swipe

#endif // ZEN_GESTURE_ZENSWIPEMATH_H_
