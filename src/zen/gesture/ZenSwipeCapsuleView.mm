/* -*- Mode: Objective-C++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#import "ZenSwipeCapsuleView.h"
#import "ZenSwipeMath.h"
#import <QuartzCore/QuartzCore.h>

using namespace zen_swipe;

@implementation ZenSwipeCapsuleView {
  NSView *_pillView;
  NSVisualEffectView *_blurView;
  NSView *_washView;
  NSImageView *_iconView;
  CGFloat _currentDiameter;
  BOOL _dismissing;
}

static NSImage *CreateCircleMaskImage(CGFloat size) {
  NSImage *mask = [[[NSImage alloc] initWithSize:NSMakeSize(size, size)] autorelease];
  [mask lockFocus];
  [[NSColor blackColor] setFill];
  [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(0, 0, size, size)] fill];
  [mask unlockFocus];
  return mask;
}

static NSImage *CreateChevronFallbackImage(ZenSwipeDirection direction, CGFloat size, BOOL confirmed) {
  NSImage *image = [[[NSImage alloc] initWithSize:NSMakeSize(size, size)] autorelease];
  [image lockFocus];

  NSBezierPath *path = [NSBezierPath bezierPath];
  path.lineWidth = confirmed ? 4.0 : 3.5;
  path.lineCapStyle = NSLineCapStyleRound;
  path.lineJoinStyle = NSLineJoinStyleRound;

  const CGFloat midY = size / 2.0;
  const CGFloat spanY = size * 0.28;
  const CGFloat spanX = size * 0.16;

  if (direction == ZenSwipeDirectionBack) {
    const CGFloat tipX = (size / 2.0) - (spanX / 2.0);
    const CGFloat baseX = tipX + spanX;
    [path moveToPoint:NSMakePoint(baseX, midY + spanY)];
    [path lineToPoint:NSMakePoint(tipX, midY)];
    [path lineToPoint:NSMakePoint(baseX, midY - spanY)];
  } else {
    const CGFloat tipX = (size / 2.0) + (spanX / 2.0);
    const CGFloat baseX = tipX - spanX;
    [path moveToPoint:NSMakePoint(baseX, midY + spanY)];
    [path lineToPoint:NSMakePoint(tipX, midY)];
    [path lineToPoint:NSMakePoint(baseX, midY - spanY)];
  }

  [[NSColor colorWithCalibratedWhite:1.0 alpha:0.90] setStroke];
  [path stroke];

  [image unlockFocus];
  return image;
}

static NSImage *GetChevronImage(ZenSwipeDirection direction, BOOL confirmed) {
  const BOOL back = (direction == ZenSwipeDirectionBack);
  NSString *symbolName = back ? @"chevron.left" : @"chevron.right";
  const CGFloat pointSize = confirmed ? 34.0 : 28.0;

  if (@available(macOS 11.0, *)) {
    NSImage *symbol = [NSImage imageWithSystemSymbolName:symbolName
                                accessibilityDescription:nil];
    if (symbol) {
      NSImageSymbolConfiguration *config =
          [NSImageSymbolConfiguration configurationWithPointSize:pointSize
                                                          weight:NSFontWeightBold];
      NSImage *configured = [symbol imageWithSymbolConfiguration:config];
      if (configured) {
        return configured;
      }
      return symbol;
    }
  }

  return CreateChevronFallbackImage(direction, 40.0, confirmed);
}

- (instancetype)initWithDirection:(ZenSwipeDirection)direction {
  _currentDiameter = kCapsuleSize;
  NSRect initialFrame = NSMakeRect(0, 0, _currentDiameter, _currentDiameter);

  if ((self = [super initWithFrame:initialFrame])) {
    _direction = direction;
    _confirmed = NO;
    _dismissing = NO;

    // Outer view hosts drop shadow without clipping
    self.wantsLayer = YES;
    self.layer.masksToBounds = NO;

    // Ardia SHADOWS.swipe: { color: black, opacity: 0.25, radius: 8, offset: [0, 2] }
    self.layer.shadowColor = [NSColor blackColor].CGColor;
    self.layer.shadowOpacity = 0.25;
    self.layer.shadowRadius = 8.0;
    self.layer.shadowOffset = CGSizeMake(0, -2.0);

    CGPathRef shadowPath = CGPathCreateWithEllipseInRect(initialFrame, NULL);
    self.layer.shadowPath = shadowPath;
    CGPathRelease(shadowPath);

    // Inner pill container strictly clips all content into a circle
    _pillView = [[NSView alloc] initWithFrame:initialFrame];
    _pillView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _pillView.wantsLayer = YES;
    _pillView.layer.masksToBounds = YES;
    _pillView.layer.cornerRadius = _currentDiameter / 2.0;
    if (@available(macOS 10.15, *)) {
      _pillView.layer.cornerCurve = kCACornerCurveContinuous;
    }
    // Subtle white rim matching Ardia swipeRim: rgba(255,255,255,0.15)
    _pillView.layer.borderWidth = 1.0;
    _pillView.layer.borderColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.18].CGColor;
    [self addSubview:_pillView];

    // Translucent frosted glass matching Ardia: VisualEffect material="popover" blendingMode="withinWindow"
    _blurView = [[NSVisualEffectView alloc] initWithFrame:_pillView.bounds];
    _blurView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _blurView.material = NSVisualEffectMaterialPopover;
    _blurView.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    _blurView.state = NSVisualEffectStateActive;
    _blurView.wantsLayer = YES;
    _blurView.layer.masksToBounds = YES;
    _blurView.layer.cornerRadius = _currentDiameter / 2.0;
    if (@available(macOS 10.15, *)) {
      _blurView.layer.cornerCurve = kCACornerCurveContinuous;
    }
    _blurView.maskImage = CreateCircleMaskImage(_currentDiameter);
    [_pillView addSubview:_blurView];

    // Confirmed wash matching Ardia: SWIPE_CONFIRMED_WASH rgba(255,255,255,0.4)
    _washView = [[NSView alloc] initWithFrame:_pillView.bounds];
    _washView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _washView.wantsLayer = YES;
    _washView.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.35].CGColor;
    _washView.alphaValue = 0.0;
    [_pillView addSubview:_washView];

    // Centered chevron icon matching Ardia: Symbol chevron, opacity 0.50 idle, 1.0 confirmed
    _iconView = [[NSImageView alloc] initWithFrame:_pillView.bounds];
    _iconView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _iconView.imageScaling = NSImageScaleProportionallyDown;
    _iconView.image = GetChevronImage(direction, NO);
    _iconView.contentTintColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.90];
    _iconView.alphaValue = 0.50;
    [_pillView addSubview:_iconView];
  }
  return self;
}

- (void)updateWithProgress:(CGFloat)progress
                 confirmed:(BOOL)confirmed
            inWindowBounds:(NSRect)bounds {
  if (_dismissing) {
    return;
  }

  if (_confirmed != confirmed) {
    _confirmed = confirmed;
    _currentDiameter = confirmed ? kCapsuleSizeConfirmed : kCapsuleSize;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
      context.duration = 0.15;
      context.timingFunction =
          [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];

      const CGFloat r = self->_currentDiameter / 2.0;
      self->_pillView.layer.cornerRadius = r;
      self->_blurView.layer.cornerRadius = r;
      self->_blurView.maskImage = CreateCircleMaskImage(self->_currentDiameter);

      self->_pillView.layer.borderColor = confirmed
          ? [NSColor colorWithCalibratedWhite:1.0 alpha:0.38].CGColor
          : [NSColor colorWithCalibratedWhite:1.0 alpha:0.18].CGColor;

      self->_washView.animator.alphaValue = confirmed ? 1.0 : 0.0;
      self->_iconView.image = GetChevronImage(self->_direction, confirmed);
      self->_iconView.animator.alphaValue = confirmed ? 1.0 : 0.50;

      CGPathRef shadowPath = CGPathCreateWithEllipseInRect(
          NSMakeRect(0, 0, self->_currentDiameter, self->_currentDiameter), NULL);
      self.layer.shadowPath = shadowPath;
      CGPathRelease(shadowPath);
    } completionHandler:nil];
  }

  const CGFloat offset = CapsuleOffset(progress, _currentDiameter);
  const CGFloat centerY = bounds.size.height / 2.0;
  const CGFloat originY = centerY - (_currentDiameter / 2.0);

  CGFloat originX = 0;
  if (_direction == ZenSwipeDirectionBack) {
    originX = offset;
  } else {
    originX = bounds.size.width - _currentDiameter - offset;
  }

  self.frame = NSMakeRect(originX, originY, _currentDiameter, _currentDiameter);
}

- (void)dismissWithSuccess:(BOOL)success
                completion:(void (^)(void))completion {
  if (_dismissing) {
    return;
  }
  _dismissing = YES;

  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
    if (success) {
      context.duration = 0.16;
      context.timingFunction =
          [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
      self.animator.alphaValue = 0.0;
    } else {
      context.duration = 0.20;
      context.timingFunction =
          [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];

      NSRect targetFrame = self.frame;
      if (self->_direction == ZenSwipeDirectionBack) {
        targetFrame.origin.x = -self->_currentDiameter;
      } else {
        targetFrame.origin.x = self.superview.bounds.size.width;
      }
      self.animator.frame = targetFrame;
      self.animator.alphaValue = 0.0;
    }
  } completionHandler:^{
    [self removeFromSuperview];
    if (completion) {
      completion();
    }
  }];
}

- (void)dealloc {
  [_iconView release];
  _iconView = nil;
  [_washView release];
  _washView = nil;
  [_blurView release];
  _blurView = nil;
  [_pillView release];
  _pillView = nil;
  [super dealloc];
}

@end
