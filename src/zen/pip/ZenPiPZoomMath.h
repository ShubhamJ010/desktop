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
// How close a finished resize must come to a screen corner to be pulled into it.
// Measured per axis, so a docked PiP shrunk towards its centre still counts.
constexpr double kSnapTolerance = 56.0;

// Baseline from a 14" MacBook Pro (1512pt), with FloatyMPV's 280-589pt limits.
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
  // Normalize ultrawide displays to a 16:9 height budget.
  const double effectiveWidth = std::min(visible.w, visible.h * (16.0 / 9.0) * 1.25);

  // Min width ~18.5% of the baseline, clamped to [260, 360].
  double dynamicMin = std::clamp(effectiveWidth * kMinRatio, 260.0, 360.0);

  // Max width ~39%, clamped to [540, 960].
  double dynamicMax = std::clamp(effectiveWidth * kMaxRatio, 540.0, 960.0);

  // Keep the max height under 75% of the screen.
  const double maxHeight = visible.h * 0.75;
  if (aspect > 0.01 && dynamicMax / aspect > maxHeight) {
    dynamicMax = maxHeight * aspect;
  }
  // Keep the min height under 90% for portrait video.
  if (aspect > 0.01 && dynamicMin / aspect > visible.h * 0.9) {
    dynamicMin = visible.h * 0.9 * aspect;
  }

  // Respect configured window content limits.
  if (minSize.w > 0) dynamicMin = std::max(dynamicMin, minSize.w);
  if (minSize.h > 0 && aspect > 0.01) dynamicMin = std::max(dynamicMin, minSize.h * aspect);

  if (maxSize.w > 0) dynamicMax = std::min(dynamicMax, maxSize.w);
  if (maxSize.h > 0 && aspect > 0.01) dynamicMax = std::min(dynamicMax, maxSize.h * aspect);

  // Stay inside the visible frame.
  dynamicMax = std::min({dynamicMax, visible.w, aspect > 0.01 ? visible.h * aspect : visible.w});

  if (dynamicMin > dynamicMax) dynamicMin = dynamicMax;

  *low = dynamicMin;
  *high = dynamicMax;
}

// Corner slot for a window, using the same inset as the throw/stash code so a zoom
// never lands half a pixel away from a docked PiP.
inline Rect CornerRect(AnchorCorner corner, double w, double h, Rect visible) {
  const Rect inner{visible.x + kCornerInset, visible.y + kCornerInset, visible.w - 2 * kCornerInset,
                   visible.h - 2 * kCornerInset};
  const bool left = corner == kAnchorTopLeft || corner == kAnchorBottomLeft;
  const bool top = corner == kAnchorTopLeft || corner == kAnchorTopRight;
  return {std::round(left ? inner.x : inner.maxX() - w), std::round(top ? inner.maxY() - h : inner.y), w, h};
}

// Closest corner slot within `tolerance`, measured per axis. Returns kAnchorNone in
// the middle of the screen, which keeps a free-floating resize from being dragged.
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

// Round to the nearest device pixel: whole-point frames move two pixels at a time
// on a 2x display, which reads as a stair-step on a slow zoom.
inline double SnapToPixel(double v, double quantum) {
  if (!(quantum > 0)) return std::round(v);
  return std::round(v / quantum) * quantum;
}

// Resize around the grabbed point from a fixed base frame, so rounding cannot
// accumulate into jitter. Edges that would leave the visible frame are pinned to it,
// which redirects a docked card's expansion towards the middle of the screen. The
// pin is continuous in `scale`, so it cannot jitter.
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

  // Keep the card on screen while it follows the cursor; pinned edges redirect a
  // docked card's expansion inwards.
  const double x = SnapToPixel(
      std::clamp(pointer.x - anchorX * rw, visible.x, std::max(visible.x, visible.maxX() - rw)), quantum);
  const double y = SnapToPixel(
      std::clamp(pointer.y - anchorY * rh, visible.y, std::max(visible.y, visible.maxY() - rh)), quantum);
  return {{x, y, rw, rh}, baseW * clampedScale};
}

// Pull a frame back inside `visible` without resizing it, once when a gesture ends.
inline Rect KeepOnScreen(Rect frame, Rect visible) {
  return {std::clamp(frame.x, visible.x, std::max(visible.x, visible.maxX() - frame.w)),
          std::clamp(frame.y, visible.y, std::max(visible.y, visible.maxY() - frame.h)), frame.w, frame.h};
}

}
