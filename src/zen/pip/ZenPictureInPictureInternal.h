#import <Cocoa/Cocoa.h>
#include <vector>

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

}

typedef NS_ENUM(NSInteger, ZenPiPEdge) { ZenPiPEdgeNone = 0, ZenPiPEdgeLeft = -1, ZenPiPEdgeRight = 1 };

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
@end

@interface ZenPiPController () {
  NSWindow *_window;
  NSString *_host;
  ZenPiPOverlay *_overlay;
  ZenPiPEdge _stashedEdge;
  BOOL _keepOnTop;
  NSMutableArray *_observers;
  NSTimer *_slide;
  BOOL _animating;
  BOOL _sawDrag;
  BOOL _swiping;
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
- (void)swipeBegan:(NSEvent *)event;
- (void)moveBy:(zen_pip_throw::Point)delta;
- (void)swipeMoved:(NSEvent *)event;
- (void)swipeEnded:(NSEvent *)event cancelled:(BOOL)cancelled;
@end

@interface ZenPiPController (Swipe)
+ (BOOL)handleSwipe:(NSEvent *)event;
+ (void)abandonSwipeOn:(NSWindow *)window;
@end

@interface ZenPiPZoom : NSObject
+ (BOOL)handle:(NSEvent *)event;
@end

namespace zen_pip {

NSScreen *ScreenFor(NSRect frame);
zen_pip_throw::Rect ThrowRect(NSRect r);
int ScreenIndex(NSScreen *screen);
std::vector<zen_pip_throw::Screen> ThrowScreens();
void InstallMonitors();
BOOL Attach(NSWindow *window);

}
