# ADR-004: Resize the PiP card inside a live resize it owns

## Status

Accepted

## Date

2026-11-17

## Context

A pinch gesture produces about 120 events per second. Setting a new window frame
for each event makes Gecko re-lay-out the video surface every tick. The result is
tearing and a picture that lags the window edge.

AppKit solves this for user edge drags. During a live resize the window server
scales the last composited frame, and Gecko asks for one relayout at the end.
A programmatic `setFrame:` does not enter that mode.

There is a second problem. A frame computed by adding deltas to the previous
frame accumulates rounding error. On a 2x display, a window laid out in whole
points moves two pixels per step, which looks like a stair.

## Decision

Run the whole pinch and Command+scroll session as a live resize started by the
PiP controller.

- Capture the base frame, aspect and the grabbed fraction of the frame once,
  when the gesture begins.
- Compute every frame from that base with `ResizeFromBase`. Never from the
  previous frame.
- Round each frame to the nearest device pixel with `SnapToPixel` using the
  window's backing scale factor.
- Call the private `_startLiveResize` at the start and `_endLiveResize` at the
  end. Both run the same view callbacks as a user drag, which is what freezes
  the picture.
- Track the live resize as owned. The controller ignores the notifications its
  own resize produces and applies chrome from the zoom path instead.
- Keep the card inside the visible frame while the gesture runs, and clamp once
  at the end with `KeepOnScreen`.
- A watchdog ends the mode if the gesture never reports an end.

Both calls are `NSWindow` methods declared in `ZenPictureInPictureInternal.h`.
They are private API, which is acceptable because the code already relies on
`_setPreventsActivation` and `_resizeDirectionForMouseLocation:`.

## Alternatives considered

### `setFrame:` per event

Rejected. That is the tearing path this ADR replaces.

### Scale the video layer instead of the window

Rejected. The window would keep its old frame while the picture grew inside it,
so snapping, stashing and the context menu would all use the wrong geometry.

### Animate in steps of 8 pixels

Rejected. It hides the stair but makes the card jump away from the cursor.

### Use a child window as the resize proxy

Rejected. It adds a second window to manage, and keyboard focus and the stash
handle would have to move to it.

## Consequences

- The picture stays sharp after the gesture instead of during it. One relayout
  happens at the end, which is the trade for no tearing.
- Every start must be paired with an end. `_ownLiveResizeForAnimation` and the
  watchdog exist because a missed end leaves the window frozen.
- A zoom animation that changes size, such as the snap after a pinch, also needs
  the mode, so the flag records whether the animation or the gesture owns it.
- Private AppKit methods can change between macOS releases. Both are guarded by
  availability and by the controller's own ownership flags.

See [pip/spec.md](../specs/pip/spec.md).
