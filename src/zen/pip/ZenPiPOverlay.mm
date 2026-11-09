#import "ZenPictureInPictureInternal.h"
#import <QuartzCore/QuartzCore.h>

using namespace zen_pip;

@implementation ZenPiPOverlay {
  NSTrackingArea *_tracking;
}

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.wantsLayer = YES;
    self.layer.zPosition = 100;
    self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _handle = [[ZenPiPHandle alloc] initWithFrame:NSZeroRect];
    _handle.hidden = YES;
    _handle.alphaValue = 0;
    [self addSubview:_handle];
  }
  return self;
}

- (BOOL)isFlipped { return YES; }

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_tracking) {
    [self removeTrackingArea:_tracking];
    [_tracking release];
    _tracking = nil;
  }
  _tracking = [[NSTrackingArea alloc]
      initWithRect:NSZeroRect
           options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
             owner:self
          userInfo:nil];
  [self addTrackingArea:_tracking];
}

- (void)mouseEntered:(NSEvent *)event {
  NSWindow *win = self.window;
  if (win) {
    ZenPiPController *controller = [ZenPiPController forWindow:win];
    if (controller) [controller mouseEnteredWindow];
  }
}

- (void)mouseExited:(NSEvent *)event {
  NSWindow *win = self.window;
  if (win) {
    ZenPiPController *controller = [ZenPiPController forWindow:win];
    if (controller) [controller mouseExitedWindow];
  }
}

- (NSView *)hitTest:(NSPoint)point {
  NSPoint local = [self convertPoint:point fromView:self.superview];
  if (!_handle.hidden && NSPointInRect(local, _handle.frame)) return _handle;
  return nil;
}

- (void)layout {
  [super layout];
  NSSize size = self.bounds.size;
  _handle.frame = _handle.edge == ZenPiPEdgeLeft ? NSMakeRect(size.width - kPeek, 0, kPeek, size.height)
                                                 : NSMakeRect(0, 0, kPeek, size.height);
}

- (void)dealloc {
  if (_tracking) {
    [self removeTrackingArea:_tracking];
    [_tracking release];
    _tracking = nil;
  }
  [_handle release];
  _handle = nil;
  [super dealloc];
}

@end
