# Spec: floating PiP card

Platform: macOS (Cocoa). Applies to every Picture-in-Picture window opened by
Gecko.

## Purpose

Turn the PiP window into a card that behaves like a desktop window. It moves
with a swipe, snaps to corners, hides at a screen edge, resizes around the
cursor, and takes keyboard input while another app is frontmost.

## Files

| File | Role |
| --- | --- |
| `ZenPiPController.mm` | Window lifecycle, drag, snap, stash, chrome, focus |
| `ZenPiPController+Swipe.mm` | Scroll-swipe detection and momentum chaining |
| `ZenPiPZoom.mm` | Pinch and Command+scroll resize |
| `ZenPiPThrowMath.h` | Movement, corner picking, screen fitting, spring |
| `ZenPiPZoomMath.h` | Width limits, cursor anchoring, pixel rounding |
| `ZenPiPOverlay.mm`, `ZenPiPHandle.mm`, `ZenPiPControl.mm` | Stash handle and buttons |
| `src/toolkit/components/pictureinpicture/content/player-js.patch` | Reacts to gesture notifications and mirrors the card UI |

## State

```
free ──drag and release inside a corner cone──▶ snapped
  ▲                                              │
  │                                          drag away
  └──────────────────────────────────────────────┘

snapped or free ──push past a screen edge──▶ stashed
stashed ──click handle──▶ restored at the edge
stashed ──drag──▶ free
```

The card is always either attached to a window that is visible, or detached. A
detached controller removes its observers, timers and monitors and answers all
gesture calls with a no-op.

## Geometry and feel

| Constant | Value | Meaning |
| --- | --- | --- |
| `kCornerInset` | 10 pt | Distance from the visible screen edge when snapped |
| `kBrowserCardInset` | 9 pt | Inset the browser window uses for its own corner cards |
| `kCornerTolerance` | π/4 | Half-angle of the cone that counts as aiming at a corner |
| `kResponse`, `kDampingRatio` | 0.9, 0.9 | Spring used for every snap and throw |
| `kResolve` | 0.2 | Offset and velocity below which the spring is considered settled |
| `kDragFlingSpeed` | 350 pt/s | Release speed that flings the card |
| `kSwipeFlingDelta` | 6 pt | Last scroll delta that counts as a fling |
| `kSwipeEventsPerSecond` | 90 | Assumed event rate when converting a scroll delta to velocity |
| `kPeek` | 28 pt | Width left visible when stashed |
| `kReturnMargin` | 16 pt | Gap between a restored card and the edge |
| `kCornerBendDuration` | 0.2 s | Corner radius animation time |
| `kFreeRadius`, `kSnappedRadius` | 6 pt, 9 pt | Corner radius when free and when docked |

The corner radius follows the same visual language as Zen's browser cards. A
snapped card uses 9 points so it lines up with the 10 point corner inset and the
9 point browser card inset.

## Drag and throw

A drag records samples. On release the controller takes the samples from the
last 100ms (`kVelocityWindow`). If the newest sample is older than 50ms
(`kVelocityStale`), velocity is zero, so a pause before release drops the card
where it is.

With velocity:

1. `PickCorner` computes the release heading and picks the corner within 45
   degrees of it. No corner in range means no throw.
2. `throwTo` runs the spring from the release frame to the corner frame.
3. Ticks come from a `CADisplayLink` with a preferred rate range of 60 to 120 Hz
   on macOS 14, or a timer otherwise.
4. A throw that has not resolved after the watchdog window is ended by
   `rescueIfLost`, which keeps the card on screen.

Without velocity the card stays where it was released, then `snapToNearestCorner`
pulls it into a corner when its center is in that corner's quadrant.

## Stash

A release outside the screen's visible frame, or past its edge, calls
`stashAt:`. The card slides so that `kPeek` points remain visible. The handle is
a 28 by 28 point view inset 12 points, shown only while stashed. Clicking it
calls `unstash`, which returns the card to `kReturnMargin` from the edge.

A stashed card still remembers its screen. If the display disconnects,
`rescueIfLost` moves the card to the screen with the largest overlap.

## Zoom

Two inputs share one path.

| Input | Factor |
| --- | --- |
| Precise scroll with Command | `exp(0.004 * deltaY)` per event |
| Line scroll with Command | `exp(0.08 * deltaY)` per event |
| Magnify | `max(0.05, 1 + magnification)` |

Rules:

- The gesture captures `baseFrame` and the grabbed fraction of the frame once.
  Every frame is computed from that base, so rounding cannot accumulate.
- Width stays within a dynamic range. The visible width of the screen is
  normalised for ultrawide displays, then clamped to 260 to 360 points minimum
  and 540 to 960 points maximum. Height cannot exceed 75 percent of the screen,
  and a portrait video cannot exceed 90 percent of screen height.
- Frames snap to whole device pixels. A 2x display then moves one pixel at a
  time instead of two.
- While the gesture runs, the controller calls `_startLiveResize` on the window.
  AppKit scales the last composited frame, so Gecko does not relayout the video
  on every tick. `_endLiveResize` runs when the gesture ends, or from the
  watchdog if it never reports an end.
- At the end, `KeepOnScreen` clamps the frame into the visible area. A card
  within 56 points of a corner slot on each axis is pulled into that slot, which
  keeps a docked card docked after a resize.

## Focus

The card belongs to Zen, so focusing it must not raise the browser window.

- `focusPiP` keys the card in place when Zen is already active.
- When another app is frontmost, it activates Zen, lowers
  `preventsActivation` until activation settles, then demotes every other Zen
  window.
- `preventsActivation` stays lowered until `finishPiPFocus`, which is what makes
  AppKit key the card instead of the main window.
- A click, a transport key, a finished swipe or an enabled hover all call
  `focusPiP`.

Hover focus is opt-in from the context menu, delayed by 250ms, cancelled when
the pointer leaves, and skipped while a gesture owns the card. The hover check
uses the window server stacking order, so a card covered by another app is not
treated as hovered. A session scroll tap routes scrolls aimed at the card while
another app is frontmost. That tap needs Input Monitoring permission. Without
it the tap is absent and local events still work.

## Keyboard

A local key monitor routes keys to the key card.

| Key | Action |
| --- | --- |
| Escape, Command+W | Close the card |
| Space | Play or pause |
| Left, Right | Seek back or forward |
| Up, Down | Volume |
| M | Mute |

Other modified keys pass through untouched.

## Context menu

| Item | Effect |
| --- | --- |
| Back to Tab | Close the card and select the originating tab |
| Keep Window on Top | Toggle `NSFloatingWindowLevel`. Stored in user defaults |
| Focus on Hover | Toggle delayed hover focus |

## Multi-screen

Movement never leaves the card unreachable.

- `Mover` limits each step. A step that would increase the shortfall is reduced
  until it does not.
- `Shortfall` measures how far the card is from having 60 points of width, or 40
  percent of its height, inside some visible screen area.
- A card larger than the screen is boxed inside that screen instead.
- `Rescue` clamps a frame that has no reachable position.

Displays that touch an edge of the current display contribute their full frame,
not their visible frame, so a card can cross the menu bar gap between screens.

## Notifications to the player

The controller posts `zen-pip-gesture-begin`, `zen-pip-gesture-end` and
`zen-pip-gesture-hover` through `Services.obs`. The PiP player uses them to hide
controls during a gesture and to scale the frozen child frame.

## Known limits

- Menu titles and haptic-free movement are not localized.
- The stash handle sits outside the card frame; a screen recorder that captures
  only the window will miss it.
- Hover focus from another app needs the accessibility-backed mouse monitor. The
  menu item still works locally without it.
- A live resize started by the controller is ended by the watchdog if AppKit
  never delivers the phase end.

## Verification

1. Drag the card to each corner and release inside the cone. It snaps with one
   spring and no overshoot past the menu bar.
2. Fling the card at a corner. It lands in that corner and stays on screen.
3. Push it past the right edge. It stashes with 28 points visible. Click the
   handle. It returns.
4. Pinch to grow and shrink. The picture does not tear or stair-step. The card
   that was docked stays docked.
5. Put another app in front. Click the card. The card becomes key and the Zen
   window stays behind.
6. Press Space, arrows and M. Playback follows.
7. Disconnect a display. The card moves to a screen that still exists.
