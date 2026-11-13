#import "ZenPictureInPictureInternal.h"
#import <QuartzCore/QuartzCore.h>

using namespace zen_pip;

@implementation ZenPiPControl {
  NSEvent *_down;
  NSTrackingArea *_tracking;
  void (^_onClick)(void);
}

- (void)dealloc {
  if (_tracking) {
    [self removeTrackingArea:_tracking];
    [_tracking release];
    _tracking = nil;
  }
  if (_down) {
    [_down release];
    _down = nil;
  }
  [_onClick release];
  _onClick = nil;
  [super dealloc];
}

- (void (^)(void))onClick {
  return _onClick;
}

- (void)setOnClick:(void (^)(void))onClick {
  if (_onClick != onClick) {
    [_onClick release];
    _onClick = [onClick copy];
  }
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_tracking) {
    [self removeTrackingArea:_tracking];
    [_tracking release];
    _tracking = nil;
  }
  _tracking = [[NSTrackingArea alloc]
      initWithRect:NSZeroRect
           options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect | NSTrackingCursorUpdate
             owner:self
          userInfo:nil];
  [self addTrackingArea:_tracking];
}

- (void)mouseEntered:(NSEvent *)event { self.hovered = YES; }
- (void)mouseExited:(NSEvent *)event { self.hovered = NO; }
- (void)cursorUpdate:(NSEvent *)event { [NSCursor.pointingHandCursor set]; }

- (void)mouseDown:(NSEvent *)event {
  if (_down != event) {
    [_down release];
    _down = [event retain];
  }
}

- (void)mouseDragged:(NSEvent *)event {
  if (!_down) return;
  NSPoint a = _down.locationInWindow, b = event.locationInWindow;
  if (hypot(b.x - a.x, b.y - a.y) < 3) return;
  NSEvent *down = [[_down retain] autorelease];
  [_down release];
  _down = nil;
  [self.window performWindowDragWithEvent:down];
}

- (void)mouseUp:(NSEvent *)event {
  if (!_down) return;
  [_down release];
  _down = nil;
  if (self.onClick) self.onClick();
}

@end
