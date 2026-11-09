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

inline double Anchor(double origin, double size, double next, double pointer) {
  double fraction = (size > 0) ? std::clamp((pointer - origin) / size, 0.0, 1.0) : 0.5;
  return pointer - fraction * next;
}

struct Result {
  Rect frame;
  double width;
};

inline Result Zoom(Rect frame, double width, double aspect, double factor, Point pointer, Rect visible, Size minSize,
                   Size maxSize, AnchorCorner corner = kAnchorNone) {
  double low, high;
  WidthLimits(aspect, minSize, maxSize, visible, &low, &high);
  double w = std::clamp(width * factor, low, high);
  const double safeAspect = (aspect > 0.01) ? aspect : (16.0 / 9.0);
  double rw = std::clamp(std::round(w), std::ceil(low), std::max(std::ceil(low), std::floor(high)));
  double rh = std::round(rw / safeAspect);

  double x, y;
  switch (corner) {
    case kAnchorTopLeft:
      x = frame.x;
      y = frame.maxY() - rh;
      break;
    case kAnchorTopRight:
      x = frame.maxX() - rw;
      y = frame.maxY() - rh;
      break;
    case kAnchorBottomLeft:
      x = frame.x;
      y = frame.y;
      break;
    case kAnchorBottomRight:
      x = frame.maxX() - rw;
      y = frame.y;
      break;
    case kAnchorNone:
    default:
      x = Anchor(frame.x, frame.w, rw, pointer.x);
      y = Anchor(frame.y, frame.h, rh, pointer.y);
      break;
  }

  x = std::clamp(x, visible.x, std::max(visible.x, visible.maxX() - rw));
  y = std::clamp(y, visible.y, std::max(visible.y, visible.maxY() - rh));
  return {{std::round(x), std::round(y), rw, rh}, w};
}

// Fixed-baseline zoom for trackpad pinch gestures (FloatyMPV pattern).
// Scaling against an invariant base frame prevents compounded integer rounding drift,
// ensuring corner-pinned edges never jitter by ±1px during continuous pinch gestures.
inline Result ZoomFromBase(Rect baseFrame, Point baseCenter, double aspect, double scale, Rect visible, Size minSize,
                           Size maxSize, AnchorCorner corner = kAnchorNone) {
  double low, high;
  WidthLimits(aspect, minSize, maxSize, visible, &low, &high);

  const double baseW = baseFrame.w;
  if (baseW <= 0) return {{baseFrame.x, baseFrame.y, baseFrame.w, baseFrame.h}, baseFrame.w};

  const double scaleFloor = low / baseW;
  const double scaleCeiling = high / baseW;
  const double clampedScale = std::clamp(scale, scaleFloor, scaleCeiling);

  const double safeAspect = (aspect > 0.01) ? aspect : (16.0 / 9.0);
  const double rw = std::clamp(std::round(baseW * clampedScale), std::ceil(low), std::max(std::ceil(low), std::floor(high)));
  const double rh = std::round(rw / safeAspect);

  double x, y;
  switch (corner) {
    case kAnchorTopLeft:
      x = baseFrame.x;
      y = baseFrame.maxY() - rh;
      break;
    case kAnchorTopRight:
      x = baseFrame.maxX() - rw;
      y = baseFrame.maxY() - rh;
      break;
    case kAnchorBottomLeft:
      x = baseFrame.x;
      y = baseFrame.y;
      break;
    case kAnchorBottomRight:
      x = baseFrame.maxX() - rw;
      y = baseFrame.y;
      break;
    case kAnchorNone:
    default:
      // Invariant center anchor prevents cursor drift from jumping the zoom origin
      x = baseCenter.x - (rw / 2.0);
      y = baseCenter.y - (rh / 2.0);
      break;
  }

  x = std::clamp(x, visible.x, std::max(visible.x, visible.maxX() - rw));
  y = std::clamp(y, visible.y, std::max(visible.y, visible.maxY() - rh));
  return {{std::round(x), std::round(y), rw, rh}, baseW * clampedScale};
}

}

