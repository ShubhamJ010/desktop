# ADR-004: Resize the PiP card inside a live resize it owns

## Status

Accepted

## Date

2026-11-17

## Context

A pinch produces about 120 events per second. Setting a new window frame for each event makes Gecko relayout the video surface every tick, which tears the picture and lags the window edge.

AppKit handles this for user edge drags. During a live resize the window server scales the last composited frame, and Gecko relayouts once at the end. A programmatic `setFrame:` does not enter that mode.

A second problem: adding deltas to the previous frame accumulates rounding error. On a 2x display a window laid out in whole points moves two pixels per step, which stair-steps.

## Decision

Run the whole pinch and Command+scroll session as a live resize the PiP controller starts.

- Capture the base frame, aspect and grabbed fraction once, when the gesture begins.
- Compute every frame from that base with `ResizeFromBase`. Never from the previous frame.
- Round each frame to the nearest device pixel with `SnapToPixel` using the window's backing scale factor.
- Call the private `_startLiveResize` at the start and `_endLiveResize` at the end. Both run the same view callbacks as a user drag, which freezes the picture.
- Track the live resize as owned. The controller ignores the notifications its own resize produces and applies chrome from the zoom path instead.
- Keep the card inside the visible frame during the gesture and clamp once at the end with `KeepOnScreen`.
- A watchdog ends the mode if the gesture never reports an end.

Both calls are `NSWindow` methods declared in `ZenPictureInPictureInternal.h`. They are private API. The code already relies on `_setPreventsActivation` and `_resizeDirectionForMouseLocation:`.

## Alternatives considered

### `setFrame:` per event

Rejected. That is the tearing path this ADR replaces.

### Scale the video layer instead of the window

Rejected. The window keeps its old frame while the picture grows inside it, so snapping, stashing and the context menu use wrong geometry.

### Animate in 8 pixel steps

Rejected. It hides the stair but makes the card jump away from the cursor.

### Child window as the resize proxy

Rejected. It adds a second window, and focus and the stash handle would have to move to it.

## Consequences

- The picture stays sharp after the gesture, not during it. One relayout at the end is the trade for no tearing.
- Every start must pair with an end. `_ownLiveResizeForAnimation` and the watchdog exist because a missed end leaves the window frozen.
- A zoom animation that changes size, such as the snap after a pinch, also needs the mode, so the flag records whether the animation or the gesture owns it.
- Private AppKit methods can change between macOS releases. Availability checks and the controller's ownership flags guard both.

See [pip/spec.md](../specs/pip/spec.md).
