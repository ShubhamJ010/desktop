# ADR-005: Focus the PiP card, not the browser window

## Status

Accepted

## Date

2026-11-17

## Context

The PiP card is an `NSWindow` owned by the Zen process. When another app is frontmost and the user clicks the card, AppKit activates Zen. Activation keys the main browser window, so the browser comes forward with the card, often covering the work the user wanted visible.

Clicking the card must make it key without reordering the browser window. Keyboard input then goes to the card: Space, arrows, M, Escape and Command+W.

Hover has the reverse problem. A card under the pointer in another app should be reachable, but it should not steal focus just because the pointer passes over it.

## Decision

Split focus into three steps and lower `preventsActivation` only while they run.

1. `keyPiPWithoutActivating` calls `makeKeyWindow` when Zen is already active.
2. When Zen is not active, `activateAppForPiPFocus` activates the app, keeps `preventsActivation` lowered until activation settles, then calls `finishPiPFocus`.
3. `finishPiPFocus` keys the card and sends every other Zen window back with `sendOtherWindowsBack`.

`preventsActivation` is an `NSWindow` property that keeps AppKit from keying the window during app activation. Keeping it lowered until activation settles makes AppKit key the card instead of the main window.

Hover focus is opt-in from the context menu, delayed by 250ms, cancelled when the pointer leaves, and skipped while a gesture owns the card. `_isMouseOver` guards against duplicate enter events from the local and global monitors.

Cross-app hover and cross-app scroll both need a monitor that sees events aimed at other applications. The hover path resolves the card through the window server stacking order, so a card covered by another app's window is not treated as hovered. The scroll path uses a session event tap, which needs Input Monitoring permission. Without the tap the feature still works inside Zen.

## Alternatives considered

### Accept the window raise

Rejected. It defeats a floating card. Users keep a call visible while working elsewhere.

### Non-activating panel

Rejected. A panel that never activates cannot become key, so keyboard control is lost.

### `orderFrontRegardless` without activation

Rejected. It brings the card forward but does not key it, so keys keep going to the other app.

### Focus on hover by default

Rejected. A pointer crossing the card would pull focus from the app the user is typing in. It is a menu option for that reason.

## Consequences

- Focus replacement depends on a private `_setPreventsActivation` method.
- Activation is asynchronous. `_focusingPiP` records an in-flight request so a second click does not start another activation.
- Without Input Monitoring, hover from another app does not work. Silent degradation is intended.
- The 250ms delay and cancel on exit keep hover focus from firing on a pass-over.

See [pip/spec.md](../specs/pip/spec.md).
