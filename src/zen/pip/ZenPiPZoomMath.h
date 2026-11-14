#pragma once

#include <algorithm>
#include <cmath>

namespace zen_pip_zoom {

struct Rect {
  double x, y, w, h;
  double maxX() const { return x + w; }
  double maxY() const { return y + h; }
};
struct Size {
  double w, h;
};
struct Point {
  double x, y;
};

enum AnchorCorner : int {
  kAnchorNone = -1,
  kAnchorTopLeft = 0,
  kAnchorTopRight = 1,
  kAnchorBottomLeft = 2,
  kAnchorBottomRight = 3
};

constexpr double kPerPoint = 0.004, kPerLine = 0.08;
constexpr double kCornerInset = 10;
// How far a finished resize may come to rest from a screen corner and still be
// pulled into it. Measured per axis, so shrinking a docked PiP towards its
// centre (which backs the window off diagonally) still reads as "near the
// corner". Beyond this a window in the middle of the screen stays put.
constexpr double kSnapTolerance = 56.0;

// Base display reference (14" MacBook Pro visible width ~1512pt)
// Baseline constants from FloatyMPV: min 280pt, max 589pt
constexpr double kBaseDisplayWidth = 1512.0;
constexpr double kMinRatio = 280.0 / kBaseDisplayWidth;  // ~0.1852
constexpr double kMaxRatio = 589.0 / kBaseDisplayWidth;  // ~0.3895

inline double ScrollFactor(double deltaY, bool precise) {
  return std::exp((precise ? kPerPoint : kPerLine) * deltaY);
}

inline double MagnifyFactor(double magnification) {
  return std::max(0.05, 1 + magnification);
}

inline void WidthLimits(double aspect, Size minSize, Size maxSize, Rect visible, double *low, double *high) {
  // Normalize ultrawide displays by height budget equivalent
  const double effectiveWidth = std::min(visible.w, visible.h * (16.0 / 9.0) * 1.25);

  // Dynamic min based on floatyMPV ratio (~18.5%), clamped [260, 360]
  double dynamicMin = std::clamp(effectiveWidth * kMinRatio, 260.0, 360.0);

  // Dynamic max based on floatyMPV ratio (~39.0%), clamped [540, 960]
  double dynamicMax = std::clamp(effectiveWidth * kMaxRatio, 540.0, 960.0);

  // Guard max height <= 75% screen height
  const double maxHeight = visible.h * 0.75;
  if (aspect > 0.01 && dynamicMax / aspect > maxHeight) {
    dynamicMax = maxHeight * aspect;
  }
  // For tall/portrait videos, guard min height <= 90% screen height
  if (aspect > 0.01 && dynamicMin / aspect > visible.h * 0.9) {
    dynamicMin = visible.h * 0.9 * aspect;
  }

  // Factor in window content limits if explicitly configured
  if (minSize.w > 0) dynamicMin = std::max(dynamicMin, minSize.w);
  if (minSize.h > 0 && aspect > 0.01) dynamicMin = std::max(dynamicMin, minSize.h * aspect);

  if (maxSize.w > 0) dynamicMax = std::min(dynamicMax, maxSize.w);
  if (maxSize.h > 0 && aspect > 0.01) dynamicMax = std::min(dynamicMax, maxSize.h * aspect);

  // Visible bounds limit
  dynamicMax = std::min({dynamicMax, visible.w, aspect > 0.01 ? visible.h * aspect : visible.w});

  if (dynamicMin > dynamicMax) dynamicMin = dynamicMax;

  *low = dynamicMin;
  *high = dynamicMax;
}

// Screen-corner slot for a window of the given size, matching the inset used by
// the throw/stash code so a zoom never lands half a pixel away from a docked PiP.
inline Rect CornerRect(AnchorCorner corner, double w, double h, Rect visible) {
  const Rect inner{visible.x + kCornerInset, visible.y + kCornerInset, visible.w - 2 * kCornerInset,
                   visible.h - 2 * kCornerInset};
  const bool left = corner == kAnchorTopLeft || corner == kAnchorBottomLeft;
  const bool top = corner == kAnchorTopLeft || corner == kAnchorTopRight;
  return {std::round(left ? inner.x : inner.maxX() - w), std::round(top ? inner.maxY() - h : inner.y), w, h};
}

// Closest screen corner whose slot is within `tolerance` of the frame's current
// position for its own size. Per axis, so a docked window that was shrunk back
// towards its centre still counts as near its corner. Returns kAnchorNone in
// the middle of the screen, which is what keeps a free-floating resize from
// being dragged anywhere.
inline AnchorCorner NearestDockCorner(Rect frame, Rect visible, double tolerance) {
  AnchorCorner best = kAnchorNone;
  double closest = tolerance;
  for (AnchorCorner corner : {kAnchorTopLeft, kAnchorTopRight, kAnchorBottomLeft, kAnchorBottomRight}) {
    const Rect slot = CornerRect(corner, frame.w, frame.h, visible);
    const double distance = std::max(std::fabs(slot.x - frame.x), std::fabs(slot.y - frame.y));
    if (distance <= closest) {
      best = corner;
      closest = distance;
    }
  }
  return best;
}

struct Result {
  Rect frame;
  double width;
};

// Round to the nearest whole device pixel. The window server lays windows out in
// pixels, so a frame rounded to whole points moves two pixels at a time on a 2x
// display, which reads as a stair-step on a slow trackpad zoom.
inline double SnapToPixel(double v, double quantum) {
  if (!(quantum > 0)) return std::round(v);
  return std::round(v / quantum) * quantum;
}

// Resize a window around the point the gesture grabbed. `baseFrame` and the
// anchor fractions are captured once when the gesture begins; every frame is
// derived from that immutable reference, so integer rounding cannot accumulate
// into the jitter that an incremental resize produces.
//
// The grabbed fraction of the frame stays under the pointer, so the picture
// expands and shrinks away from the cursor in every direction at once - but
// never past the screen: an edge that would leave the visible frame is pinned
// to it. For a card docked in a screen corner that redirects the whole
// expansion toward the middle of the screen instead of letting it slide past
// the menu bar or off the side - the overflow was what made the resize stutter
// and tear, and the KeepOnScreen pullback at gesture end then jumped the card
// back. The pin is continuous in `scale`, so it cannot jitter, and a
// free-floating card still follows the cursor everywhere inside the screen.
inline Result ResizeFromBase(Rect baseFrame, double aspect, double scale, double anchorX, double anchorY,
                             Point pointer, Rect visible, Size minSize, Size maxSize, double quantum) {
  double low, high;
  WidthLimits(aspect, minSize, maxSize, visible, &low, &high);

  const double baseW = baseFrame.w;
  if (baseW <= 0) return {baseFrame, baseFrame.w};

  const double scaleFloor = low / baseW;
  const double scaleCeiling = high / baseW;
  const double clampedScale = std::clamp(scale, scaleFloor, scaleCeiling);

  const double safeAspect = (aspect > 0.01) ? aspect : (16.0 / 9.0);
  const double rw =
      SnapToPixel(std::clamp(baseW * clampedScale, std::ceil(low), std::max(std::ceil(low), std::floor(high))), quantum);
  const double rh = std::max(quantum, SnapToPixel(rw / safeAspect, quantum));

  // Keep the card inside the visible frame while it follows the cursor. For a
  // card docked in a screen corner this pins the edges that touch the screen
  // borders, so the expansion is redirected toward the middle of the screen
  // and nothing slides past the menu bar or the screen edge - overflow was
  // what broke the picture mid-gesture. The clamp is continuous in `scale`, so
  // it cannot jitter.
  const double x = SnapToPixel(
      std::clamp(pointer.x - anchorX * rw, visible.x, std::max(visible.x, visible.maxX() - rw)), quantum);
  const double y = SnapToPixel(
      std::clamp(pointer.y - anchorY * rh, visible.y, std::max(visible.y, visible.maxY() - rh)), quantum);
  return {{x, y, rw, rh}, baseW * clampedScale};
}

// Pull a frame fully back inside `visible` without changing its size. Used once
// when a gesture ends, so a picture that grew past the screen edge while it
// followed the cursor always comes to rest on screen.
inline Rect KeepOnScreen(Rect frame, Rect visible) {
  return {std::clamp(frame.x, visible.x, std::max(visible.x, visible.maxX() - frame.w)),
          std::clamp(frame.y, visible.y, std::max(visible.y, visible.maxY() - frame.h)), frame.w, frame.h};
}

}
