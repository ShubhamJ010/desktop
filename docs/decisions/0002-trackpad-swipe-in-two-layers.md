# ADR-002: Handle the back/forward swipe in two layers

## Status

Accepted

## Date

2026-11-17

## Context

Gecko already tracks swipe gestures in `browser-gestureSupport.js`. It owns the swipe state, the confirmation threshold, the navigation commands and session history. Replacing that tracker would mean reimplementing history navigation and losing the existing cancel handling.

Two things the JS tracker cannot do:

- The compositor consumes horizontal deltas before chrome sees them, so chrome cannot draw an indicator from raw input.
- While the history sheet is open, vertical finger movement must select a row, not scroll the page, and the page must not see the deltas.

The stock Firefox indicator is a small theme-drawn arrow with no hold-to-pick behavior.

## Decision

Split the work.

- `src/zen/gesture/ZenSwipeController.mm` installs a scroll monitor on each browser window. It tracks horizontal travel, confirms the gesture and drives the capsule.
- `browser-gestureSupport.js` keeps the swipe state, navigation, sheet contents and row selection.
- The layers share one integer pref, `zen.widget.macos.back-gesture-phase`. 0 idle, 1 tracking, 2 sheet. JS writes it, the native monitor reads it.
- While phase is 2, the monitor consumes vertical deltas and forwards cumulative travel as the `zen-swipe-vertical` observer notification. JS turns travel into a row.
- The monitor ignores non-precise scrolling, so a mouse wheel keeps native behavior.

The native side never changes history. JS never reads raw scroll deltas.

## Alternatives considered

### JS only

Rejected. Chrome cannot see the deltas the compositor uses, and a page scroll would fight row selection.

### APZ patch for gesture recognition

Rejected. It puts logic in the deepest input layer, needs a rebuild for every tweak, and duplicates the JS tracker's model.

### Fully native swipe, including navigation

Rejected. Session history, container rules and error pages already have one implementation in Gecko. A second would drift.

### Native overlay with an XPC bridge to chrome

Rejected. A pref plus one observer topic carries two integers and a cumulative delta. A message protocol adds lifetime and ordering problems for no gain.

## Consequences

- The phase pref is shared mutable state with no lock. A crash can leave it at 2, so the monitor also requires a live gesture before forwarding travel.
- The feature exists only on macOS, where the monitor builds.
- Without the monitor the sheet still opens but cannot move the selection.
- `zen.widget.macos.back-gesture-debug` traces the handshake in the system log. It is off by default because it logs every event.
- The JS cancel logic was reworked twice to separate vertical browsing from a real pull-back. It lives in JS, next to the sheet it affects.

See [swipe/spec.md](../specs/swipe/spec.md).
