#ifndef ZEN_PIP_ZENPICTUREINPICTUREINTERNAL_H_
#define ZEN_PIP_ZENPICTUREINPICTUREINTERNAL_H_

#import <Cocoa/Cocoa.h>
#include <vector>

@class CADisplayLink;

namespace zen_pip_throw {
struct Point;
struct Rect;
struct Screen;
}

@interface NSWindow (ZenPreventsActivation)
- (void)_setPreventsActivation:(BOOL)prevents;
- (BOOL)_preventsActivation;
- (NSInteger)_resizeDirectionForMouseLocation:(NSPoint)location;
@end

namespace zen_pip {

constexpr CGFloat kPeek = 28;
constexpr CGFloat kReturnMargin = 16;
constexpr CGFloat kButtonMargin = 12, kButtonSize = 28;
constexpr CFTimeInterval kCornerBendDuration = 0.2;
constexpr CGFloat kRimAlpha = 0.17;

// Virtual key codes for keyboard control
constexpr unsigned short kKeySpace = 49;
constexpr unsigned short kKeyLeftArrow = 123;
constexpr unsigned short kKeyRightArrow = 124;
constexpr unsigned short kKeyDownArrow = 125;
constexpr unsigned short kKeyUpArrow = 126;
constexpr unsigned short kKeyM = 46;
constexpr unsigned short kKeyJ = 38;
constexpr unsigned short kKeyK = 40;
constexpr unsigned short kKeyL = 37;
constexpr unsigned short kKeyC = 8;
constexpr unsigned short kKeyZ = 6;
constexpr unsigned short kKeyX = 7;
constexpr unsigned short kKeyW = 13;
constexpr unsigned short kKeyQ = 12;
constexpr unsigned short kKeyEscape = 53;
constexpr unsigned short kKey0 = 29;
constexpr unsigned short kKey1 = 18;
constexpr unsigned short kKey2 = 19;
constexpr unsigned short kKey3 = 20;
constexpr unsigned short kKey4 = 21;
constexpr unsigned short kKey5 = 23;
constexpr unsigned short kKey6 = 22;
constexpr unsigned short kKey7 = 26;
constexpr unsigned short kKey8 = 28;
constexpr unsigned short kKey9 = 25;
constexpr unsigned short kKeyComma = 43;
constexpr unsigned short kKeyPeriod = 47;

}

typedef NS_ENUM(NSInteger, ZenPiPEdge) { ZenPiPEdgeNone = 0, ZenPiPEdgeLeft = -1, ZenPiPEdgeRight = 1 };

// Shared gesture lifecycle. Swipe and pinch differ only in what moves; the chrome
// (activation, window order, cursor, PiP UI, elevation, corner radius) is identical,
// so it lives in one place and is driven by this kind.
typedef NS_ENUM(NSInteger, ZenPiPGesture) { ZenPiPGestureSwipe = 1, ZenPiPGesturePinch = 2 };

@interface ZenPiPControl : NSView
@property (nonatomic, copy) void (^onClick)(void);
@property (nonatomic) BOOL hovered;
@end

@interface ZenPiPHandle : ZenPiPControl
@property (nonatomic) ZenPiPEdge edge;
@end

@interface ZenPiPOverlay : NSView
@property (nonatomic, readonly) ZenPiPHandle *handle;
@end

@interface ZenPiPController : NSObject
@property (nonatomic, readonly) NSWindow *window;
@property (nonatomic, copy) NSString *host;
@property (nonatomic, readonly) ZenPiPOverlay *overlay;
@property (nonatomic, readonly) ZenPiPEdge stashedEdge;
@property (nonatomic) BOOL keepOnTop;
+ (instancetype)forWindow:(NSWindow *)window;
+ (BOOL)attachToWindow:(NSWindow *)window;
+ (void)detachFromWindow:(NSWindow *)window;
+ (void)updateShadowPathForWindow:(NSWindow *)window radius:(CGFloat)radius;
+ (void)updateShadowPathForWindow:(NSWindow *)window size:(CGSize)size radius:(CGFloat)radius;
- (instancetype)initWithWindow:(NSWindow *)window;
- (void)roundCorners;
- (CGFloat)cornerRadius;
- (void)backToTab;
- (void)unstash;
- (NSMenu *)menu;
- (void)stopMotion;
- (void)abandonSwipe;
- (NSScreen *)gestureHome;
- (void)dragReleasedAt:(NSPoint)pointer velocity:(NSPoint)velocity;
- (NSDictionary *)throwInfo;
- (void)toggleSmartMagnify;
- (BOOL)handleKeyDown:(NSEvent *)event;
- (void)mouseEnteredWindow;
- (void)mouseExitedWindow;
- (void)pinchBegan;
- (void)pinchEnded;
- (void)pinchEndedAtAnchor:(int)anchorCorner;
- (void)snapToNearestCorner;
- (void)setElevated:(BOOL)elevated animated:(BOOL)animated;
- (void)setOverlayVisible:(BOOL)visible animated:(BOOL)animated;
- (void)setPiPUIVisible:(BOOL)visible;
@end

@interface ZenPiPController () {
  NSWindow *_window;
  NSString *_host;
  ZenPiPOverlay *_overlay;
  ZenPiPEdge _stashedEdge;
  BOOL _keepOnTop;
  NSMutableArray *_observers;
  NSTimer *_slide;
  id _displayLink;  // CADisplayLink on macOS 14+; `id` keeps the API-availability
                    // check out of the class layout (deployment target is 11.0).
  BOOL _animating;
  BOOL _sawDrag;
  BOOL _swiping;
  BOOL _cursorHidden;
  BOOL _isSmartMagnified;
  NSRect _unmagnifiedFrame;
  BOOL _isPinching;
  BOOL _isElevated;
  // Swipe pre-warm (armed while the pointer rests over the window).
  BOOL _armed;
  __unsafe_unretained NSScreen *_armedHome;
  // Momentum carried from a throw into a chained swipe.
  NSPoint _swipeCarry;
  BOOL _carrying;
  CFTimeInterval _carryStart;
  CFTimeInterval _carryLastAt;
  // Throw state, so a chained swipe can read the spring's velocity.
  BOOL _throwActive;
  NSRect _throwFrom;
  NSRect _throwTarget;
  NSPoint _throwVelocity;
  int _throwCorner;
  CFTimeInterval _throwStartAt;
  // Gesture latency probe (`zen.pip.debug.gesture-timing`).
  CFTimeInterval _gestureEventAt;
  CFTimeInterval _gestureHandlerAt;
  CFTimeInterval _gestureFirstMoveAt;
  uint64_t _gestureGeneration;
  NSPoint _swipeGrab;
  NSPoint _swipeLastDelta;
  NSPoint _swipePointer;
  CFTimeInterval _swipeBeganAt;
  NSTimeInterval _swipeLastAt;
  NSRect _swipeStart;
  NSDictionary *_lastRelease;
  NSDictionary *_lastSwipe;
  NSMutableDictionary *_lastThrow;
  NSDictionary *_lastScreenFit;
  __unsafe_unretained NSScreen *_lastScreen;
  __unsafe_unretained NSScreen *_swipeHome;
  __unsafe_unretained NSScreen *_stashScreen;
}
- (void)detach;
- (void)toggleKeepOnTop:(id)sender;
- (void)backToTabFromMenu:(id)sender;
- (void)windowMoved;
- (void)fitCorners:(BOOL)animated;
- (void)bendCornersTo:(CGFloat)radius animated:(BOOL)animated;
- (void)screenChanged;
- (NSScreen *)homeScreen;
- (ZenPiPEdge)edgeBeyond;
- (BOOL)throwFrom:(NSPoint)grab velocity:(NSPoint)velocity;
- (void)throwTo:(NSRect)target velocity:(NSPoint)velocity corner:(int)corner;
- (void)settle;
- (void)rescueIfLost;
- (NSRect)frameStashedAt:(ZenPiPEdge)edge;
- (void)stashAt:(ZenPiPEdge)edge;
- (void)animateTo:(NSRect)target;
- (void)cancelMotion;
- (void)armSwipe;
- (void)disarmSwipe;
+ (ZenPiPController *)controllerUnderPointer;
- (void)swipeBegan:(NSEvent *)event;
- (void)beginGestureChrome:(ZenPiPGesture)kind chained:(BOOL)chained;
- (void)applyGestureChrome:(ZenPiPGesture)kind chained:(BOOL)chained;
- (void)endGestureChrome:(BOOL)restoreUI;
- (void)throwTick:(id)sender;
- (NSPoint)throwVelocityAt:(CFTimeInterval)now;
- (void)moveBy:(zen_pip_throw::Point)delta;
- (void)swipeMoved:(NSEvent *)event;
- (void)swipeEnded:(NSEvent *)event cancelled:(BOOL)cancelled;
- (void)hideCursorIfNeeded;
- (void)showCursorIfNeeded;
@end

@interface ZenPiPController (Swipe)
+ (BOOL)handleSwipe:(NSEvent *)event;
+ (void)abandonSwipeOn:(NSWindow *)window;
@end

@interface ZenPiPZoom : NSObject
+ (BOOL)handle:(NSEvent *)event;
+ (BOOL)zooms:(NSWindow *)window;
+ (void)abandonZoomOn:(NSWindow *)window;
@end

namespace zen_pip {

NSScreen *ScreenFor(NSRect frame);
zen_pip_throw::Rect ThrowRect(NSRect r);
int ScreenIndex(NSScreen *screen);
std::vector<zen_pip_throw::Screen> ThrowScreens();
void InstallMonitors();
BOOL Attach(NSWindow *window);
void Detach(NSWindow *window);

}

#endif  // ZEN_PIP_ZENPICTUREINPICTUREINTERNAL_H_
