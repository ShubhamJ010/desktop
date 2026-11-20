# Spec: floating PiP card

Platform: macOS (Cocoa). Applies to every Picture-in-Picture window Gecko opens.

## Purpose

Make the PiP window behave like a desktop window: move with a swipe, snap to corners, hide at a screen edge, resize around the cursor, and take keys while another app is frontmost.

## Files

| File | Role |
| --- | --- |
| `ZenPiPController.mm` | Window lifecycle, drag, snap, stash, chrome, focus |
| `ZenPiPController+Swipe.mm` | Scroll-swipe detection and momentum chaining |
| `ZenPiPZoom.mm` | Pinch and Command+scroll resize |
| `ZenPiPThrowMath.h` | Movement, corner picking, screen fitting, spring |
| `ZenPiPZoomMath.h` | Width limits, cursor anchoring, pixel rounding |
| `ZenPiPOverlay.mm`, `ZenPiPHandle.mm`, `ZenPiPControl.mm` | Stash handle and buttons |
| `src/toolkit/components/pictureinpicture/content/player-js.patch` | Reacts to gesture notifications, mirrors the card UI |

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

The card is attached to a visible window or detached. A detached controller drops its observers, timers and monitors, and answers gesture calls with a no-op.

## Geometry and feel

| Constant | Value | Meaning |
| --- | --- | --- |
| `kCornerInset` | 10 pt | Edge distance when snapped |
| `kBrowserCardInset` | 9 pt | The browser's own corner card inset |
| `kCornerTolerance` | π/4 | Half-angle of the corner cone |
| `kResponse`, `kDampingRatio` | 0.9, 0.9 | Spring for every snap and throw |
| `kResolve` | 0.2 | Offset and velocity counted as settled |
| `kDragFlingSpeed` | 350 pt/s | Release speed that flings |
| `kSwipeFlingDelta` | 6 pt | Last scroll delta counted as a fling |
| `kSwipeEventsPerSecond` | 90 | Assumed rate for delta to velocity |
| `kPeek` | 28 pt | Width visible when stashed |
| `kReturnMargin` | 16 pt | Gap from the edge after unstash |
| `kCornerBendDuration` | 0.2 s | Corner radius animation |
| `kFreeRadius`, `kSnappedRadius` | 6 pt, 9 pt | Radius free and docked |

The snapped radius matches Zen's browser cards: 9 points lines up with the 10 point inset and the 9 point card inset.

## Drag and throw

A drag records samples. On release the controller takes the last 100ms (`kVelocityWindow`); if the newest sample is older than 50ms (`kVelocityStale`), velocity is zero, so a pause drops the card where it is.

With velocity:

1. `PickCorner` picks the corner within 45 degrees of the release heading. None in range means no throw.
2. `throwTo` springs from the release frame to the corner frame.
3. Ticks come from a `CADisplayLink` (preferred 60 to 120 Hz on macOS 14) or a timer.
4. An unresolved throw is ended by `rescueIfLost` after the watchdog window, keeping the card on screen.

Without velocity the card stays put; `snapToNearestCorner` pulls it in when its center sits in a corner's quadrant.

## Stash

A release outside the visible frame, or past its edge, calls `stashAt:`. The card slides so `kPeek` points stay visible. The handle is a 28 point wide strip on the inner edge, card height, with a chevron, shown only while stashed. Clicking calls `unstash`, which returns the card `kReturnMargin` from the edge.

A stashed card remembers its screen. If the display disconnects, `rescueIfLost` moves it to the screen with the largest overlap.

## Zoom

Two inputs share one path.

| Input | Factor |
| --- | --- |
| Command+precise scroll | `exp(0.004 * deltaY)` per event |
| Command+line scroll | `exp(0.08 * deltaY)` per event |
| Magnify | `max(0.05, 1 + magnification)` per event, each step clamped to 0.90 to 1.10 in `ZenPiPZoom.mm` so trackpad spikes cannot jump the size |

Rules:

- Capture `baseFrame` and the grabbed fraction once. Every frame derives from that base, so rounding cannot accumulate.
- Width follows a dynamic range: the visible width, normalized for ultrawide displays, clamped to 260 to 360 points minimum and 540 to 960 maximum. Height stays under 75 percent of the screen; a portrait video under 90 percent of screen height.
- Frames snap to whole device pixels, so a 2x display moves one pixel per step.
- The gesture runs inside `_startLiveResize`. AppKit scales the last composited frame, so Gecko does not relayout the video every tick. `_endLiveResize` runs at gesture end or from the watchdog.
- `KeepOnScreen` clamps at the end. A card within 56 points of a corner slot on each axis is pulled in, keeping a docked card docked after a resize.
- Hitting the min or max width plays one alignment haptic per limit, latched. This path calls the performer directly and ignores `zen.haptic-feedback.enabled`.

## Focus

Focusing the card must not raise the browser.

- `focusPiP` keys the card in place when Zen is active.
- When another app is frontmost, it activates Zen, lowers `preventsActivation` until activation settles, then demotes every other Zen window.
- `preventsActivation` stays lowered until `finishPiPFocus`, which makes AppKit key the card instead of the main window.
- A click, a transport key, a finished swipe or an enabled hover calls `focusPiP`.

Hover focus is opt-in from the context menu, delayed 250ms, cancelled on pointer exit, skipped while a gesture owns the card. It uses the window server stacking order, so a card covered by another app is not hovered. A session scroll tap routes scrolls aimed at the card while another app is frontmost; it needs Input Monitoring. Without it the tap is absent and local events still work.

## Keyboard

A local key monitor routes keys to the card. Command+W is always consumed. Escape answers from the pointer and falls through to the page while the card is key. Letter shortcuts (A, M) apply only while the card has the keyboard, so they cannot eat browser typing.

| Key | Action |
| --- | --- |
| Escape | Back to the tab: card closes, video plays inline |
| Command+W | Pause, then close |
| A | Close and keep playing |
| Space | Play or pause |
| Left, Right | Seek back or forward |
| Up, Down | Volume |
| M | Mute or unmute |

Escape and Command+W match the close and back-to-tab buttons. While the card is key, Escape reaches the page first, so an open settings panel or fullscreen closes before the card.

The controller posts `zen-pip-command` and the player document performs it, because playback and the originating tab are reachable only there. The menu's Back to Tab and the player's key handler share that path. Other modified keys pass through.

## Context menu

| Item | Effect |
| --- | --- |
| Back to Tab | Close the card, select the originating tab |
| Keep Window on Top | Toggle `NSFloatingWindowLevel`. Stored in user defaults |
| Focus on Hover | Toggle delayed hover focus |

## Multi-screen

Movement never leaves the card unreachable.

- `Mover` limits each step; a step that would increase the shortfall is reduced.
- `Shortfall` measures the gap from 60 points of width, or 40 percent of height, inside a visible screen area.
- A card larger than the screen is boxed inside it.
- `Rescue` clamps a frame with no reachable position.

Displays touching an edge of the current display contribute their full frame, not their visible frame, so a card can cross the menu bar gap between screens.

## Notifications to the player

`Services.obs` carries `zen-pip-gesture-begin`, `zen-pip-gesture-end` and `zen-pip-gesture-hover`. The player hides controls during a gesture and scales the frozen child frame.

`zen-pip-command` carries one of `close-pause`, `close`, `unpip` or `mute`. The player decides what each means.

## Known limits

- Menu titles and haptic-free movement are not localized.
- The stash handle sits outside the card frame; a window-only screen recording misses it.
- Hover focus from another app needs the accessibility-backed mouse monitor. The menu item still works locally.
- If AppKit never delivers the phase end, the watchdog ends the live resize.

## Verification

1. Drag to each corner and release inside the cone. One spring, no overshoot past the menu bar.
2. Fling at a corner. It lands there and stays on screen.
3. Push past the right edge. It stashes with 28 points visible. Click the handle. It returns.
4. Pinch to grow and shrink. No tearing or stair-stepping. A docked card stays docked.
5. Put another app in front. Click the card. It becomes key; the Zen window stays behind.
6. Press Space, arrows, M. Playback follows.
7. Disconnect a display. The card moves to a screen that still exists.
