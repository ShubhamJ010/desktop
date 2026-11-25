# Spec: back/forward trackpad swipe

Platform: macOS. Two layers cooperate. Gecko's gesture tracker produces the navigation and the sheet. A Cocoa monitor feeds it vertical travel and keeps the system's own swipe from firing twice.

## Purpose

Replace the stock swipe indicator with a glass capsule that follows the finger, and let the user pick a destination from recent history without leaving the gesture.

## Files

| File | Role |
| --- | --- |
| `src/zen/gesture/ZenSwipeController.mm` | Scroll monitor, phase handling, vertical streaming |
| `src/zen/gesture/ZenSwipeCapsuleView.mm` | Capsule drawing and dismiss animations |
| `src/zen/gesture/ZenSwipeMath.h` | Rubber band, progress, offset |
| `src/browser/base/content/browser-gestureSupport-js.patch` | Swipe tracker, capsule markup, history sheet, phase pref |
| `src/widget/cocoa/nsCocoaWindow-mm.patch` | Routes Cocoa magnify and swipe events |
| `src/widget/cocoa/nsCocoaUtils-mm.patch` | Reads `zen.widget.macos.override-system-swipe-gestures` |
| `src/zen/common/styles/zen-browser-ui.css` | Capsule and history sheet styles |

## Prefs

| Pref | Default | Meaning |
| --- | --- | --- |
| `zen.widget.macos.override-system-swipe-gestures` | true | Let Cocoa claim horizontal swipes from the system |
| `zen.widget.macos.back-gesture-indicator` | true | Draw the capsule |
| `zen.widget.macos.back-gesture-phase` | 0 | Published by JS. 0 idle, 1 tracking, 2 sheet visible |
| `zen.widget.macos.back-gesture-history-count` | 3 | Rows in the history sheet |
| `zen.widget.macos.back-gesture-debug` | false | Log every monitor event to the system log |

## Capsule

| Constant | Value | Meaning |
| --- | --- | --- |
| `kSwipeUnit` | 75 pt | Travel that means full progress |
| `kCapsuleSize` | 72 pt | Resting diameter |
| `kCapsuleSizeConfirmed` | 82 pt | Diameter after the threshold |
| `kCapsuleInset` | 14 pt | Offset from the window edge at full progress |
| `kRubberCoefficient` | 0.15 | Resistance past the limit |
| `kStartDistance` | 4 pt | Travel before tracking starts |
| `kStartDominance` | 1.5 | Horizontal to vertical ratio needed to start |
| `kCancelDominance` | 2.0 | Vertical to horizontal ratio that cancels |

`CapsuleOffset` maps progress to an offset with the standard rubber band curve, so the capsule decelerates instead of stopping at the edge. A confirmed swipe fades out in place over 160ms. A cancelled one animates off into the edge over 200ms.

The capsule sits in the browser stack, above page content and below panels. It uses the shared glass tokens from `zen-ardia-glass.css`.

## Phase handshake

JS owns the phase. The native monitor reads it: the sheet is a chrome document, and the monitor cannot ask it directly.

1. JS sets phase 1 when tracking starts.
2. If the sheet opens, JS sets phase 2.
3. While phase is 2, the monitor streams cumulative `scrollingDeltaY` as `zen-swipe-vertical`.
4. On end or cancel, JS sets phase 0.

If a crash leaves the pref at 2, the monitor still requires a live gesture window before forwarding travel. A stale phase cannot drive the sheet alone.

## History sheet

The sheet opens when the swipe stays past the confirmation threshold for 300ms (`ZEN_SWIPE_LIST_HOLD_MS`). It lists entries from the selected browser's session history in the swipe direction.

- Rows are 38 points high; the list is 200 points wide, with 8 point padding and a 16 point radius.
- Row count comes from `zen.widget.macos.back-gesture-history-count`, read on each presentation and clamped to at least 2 and at most the rows that fit the window and 15 (`ZEN_SWIPE_LIST_MAX`).
- Each row has a favicon, a host-initial tile when no favicon exists, the title, and a cleaned URL.
- `ZEN_SWIPE_UNIT` of travel moves the selection one row. Overshoot past the first or last row is rubber banded with a nudge.
- The active row has a pill highlight that follows selection.

Vertical travel never scrolls the page while the sheet is up: the native monitor consumes it and JS cancels the wheel default.

## Cancellation

Cancellation must survive two different mistakes.

- Vertical drift while picking rows must not cancel. Native vertical samples (`zen-swipe-vertical`) record the vertical activity timestamp and mark vertical browsing active for 250ms. During that window horizontal jitter (delta step < 0.03) is ignored, so scrolling rows does not cancel.
- A real pull-back after browsing must cancel. A leaky reverse-travel bucket accumulates opposite travel over 600ms (`ZEN_SWIPE_CANCEL_LEAK_MS`); moving forward drains it. A deliberate pull-back of 18 percent of the unit (`ZEN_SWIPE_CANCEL_TRAVEL = 0.18`) cancels. On finger lift, 40 percent release progress (`ZEN_SWIPE_CANCEL_RELEASE = 0.40`) cancels instead of navigating.
- Edge cancellation. Fingers back at the bezel (`pos <= 0.04` in flight, or `<= 0.05` on release, with vertical browsing inactive) cancel instantly.

### Visual feedback on cancel

- History sheet: reverse travel shifts the sheet toward the screen edge by up to 28px (`translateX(±28px * progress)`) and dims it (`opacity: 1 - 0.35 * progress`).
- Capsule cancel exit: a partial or unconfirmed swipe slides back into the edge (`translateX(±72px)`) with zero delay, avoiding mid-air shrinkage or flicker. Only a confirmed, navigating swipe fades and shrinks in place, after the 120ms dismiss beat.

`ZEN_SWIPE_CONFIRM_DELTA` is 0.25. Release above it navigates to the selected row; below it returns to the page.

## Haptics

The back/forward swipe plays no haptic. Confirmation is visual: the capsule grows 72 to 82 points and its chevron thickens and brightens. Space swipes have their own detent ([spec-swipe-haptics.md](../spaces/spec-swipe-haptics.md)); it is a separate path and does not fire for history navigation.

## Interaction with space swipes

Two consumers claim horizontal swipes: navigation and space switching. The space tracker claims swipes on the toolbox when the pointer is not over the urlbar, the spaces button or the download list. The back/forward tracker sits below it, on the browser element. A swipe over the toolbox changes space; a swipe over content navigates history.

If both fire on one gesture, the page navigates and the space changes. Nothing in the specs sets a priority beyond that event order. Treat a double action as a bug and capture the event at the earliest consumer that wants it.

## Edge cases

| Case | Behavior |
| --- | --- |
| Swipe at the first or last history entry | No capsule, system handles the event |
| Sheet would show one row | Sheet does not open. One destination is not a choice |
| Window too short for the pref count | Row count shrinks to what fits |
| Vertical page scroll | Cancel dominance 2.0 ends tracking, page scrolls |
| Pointer leaves the window mid-gesture | Gesture ends through the normal end path |
| Two windows | Each window has its own controller and capsule |

## Known limits

- The sheet reads session history, so entries not visited this session are absent.
- Titles and URLs come from history entries, not live tab titles.
- The monitor only sees precise scrolling deltas. A mouse wheel with line deltas is ignored on purpose.
- Debug logging is per event and can flood the system log. Leave the pref off.

## Verification

1. Swipe right on a page with history. The capsule grows and its chevron brightens. Release. The page goes back.
2. Swipe right, hold. The sheet lists three destinations. Move up and down. Selection follows and the sheet stays.
3. From a lower row, pull back left. The sheet fades out and the page stays.
4. Swipe right and reverse before the threshold. The capsule springs away.
5. Scroll vertically over the page. Nothing indicates a swipe.
6. Set the history count to 1. The sheet does not open. Set it to 9. Nine rows appear when the window is tall enough.
