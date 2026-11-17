# ADR-002: Handle the back/forward swipe in two layers

## Status

Accepted

## Date

2026-11-17

## Context

Gecko already tracks swipe gestures in `browser-gestureSupport.js`. It owns the
swipe state, the confirmation threshold, the navigation commands and session
history. Replacing that tracker would mean reimplementing history navigation and
losing the existing cancel handling.

Two things the JS tracker cannot do:

- The compositor consumes the horizontal deltas before chrome sees them, so the
  chrome layer cannot draw an indicator from raw input.
- While the history sheet is open, the user moves the finger vertically. Those
  deltas must select a row, not scroll the page, and the page must not see them.

The existing Firefox indicator is a small arrow drawn by the theme. It has no
hold-to-pick behavior.

## Decision

Split the work.

- `src/zen/gesture/ZenSwipeController.mm` installs a scroll monitor on each
  browser window. It tracks horizontal travel, confirms the gesture, drives the
  capsule and plays one haptic.
- `browser-gestureSupport.js` keeps the swipe state, the navigation, the sheet
  contents and the row selection.
- The two layers share one integer pref, `zen.widget.macos.back-gesture-phase`.
  0 is idle, 1 is tracking, 2 is the sheet. JS writes it. The native monitor
  reads it.
- While phase is 2, the monitor consumes vertical deltas and forwards the
  cumulative travel as the `zen-swipe-vertical` observer notification. JS turns
  travel into a row.
- The monitor ignores the event when it is not precise scrolling, so a mouse
  wheel keeps native behavior.

The native side never changes history. JS never reads raw scroll deltas.

## Alternatives considered

### JS only

Rejected. Chrome cannot see the deltas the compositor uses, and a page scroll
would fight the row selection.

### APZ patch for gesture recognition

Rejected. It puts the logic in the deepest input layer, needs a rebuild for every
tweak, and duplicates what the JS tracker already models.

### Fully native swipe, including navigation

Rejected. Session history, container rules and error pages already have one
implementation in Gecko. A second one would drift.

### Native overlay with an XPC bridge to chrome

Rejected. A pref plus one observer topic is enough for two integers and a
cumulative delta. A message protocol would add lifetime and ordering problems
for no gain.

## Consequences

- The phase pref is a shared mutable value with no lock. A crash can leave it at
  2, so the monitor also requires a live gesture before forwarding travel.
- The feature only exists on macOS, where the monitor is built.
- The sheet depends on the monitor for vertical input. Without the monitor the
  sheet still opens but cannot move the selection.
- `zen.widget.macos.back-gesture-debug` exists to trace the handshake in the
  system log. It is off by default because it logs every event.
- The existing JS cancel logic had to be reworked twice to distinguish vertical
  browsing from a real pull-back. That logic lives in JS, next to the sheet it
  affects.

See [swipe/spec.md](../specs/swipe/spec.md).
