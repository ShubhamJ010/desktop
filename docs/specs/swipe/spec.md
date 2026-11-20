# Spec: back/forward trackpad swipe

Platform: macOS. Two layers cooperate. Gecko's gesture tracker produces the
navigation and the sheet. A Cocoa monitor feeds it vertical travel and keeps the
system's own swipe from firing twice.

## Purpose

Replace the stock swipe indicator with a glass capsule that follows the finger,
and let the user pick a destination from recent history without leaving the
gesture.

## Files

| File | Role |
| --- | --- |
| `src/zen/gesture/ZenSwipeController.mm` | Scroll monitor, phase handling, vertical streaming, haptics |
| `src/zen/gesture/ZenSwipeCapsuleView.mm` | Capsule drawing and dismiss animations |
| `src/zen/gesture/ZenSwipeMath.h` | Rubber band, progress, offset |
| `src/browser/base/content/browser-gestureSupport-js.patch` | Swipe tracker, capsule markup, history sheet, phase pref |
| `src/widget/cocoa/nsCocoaWindow-mm.patch` | Routes Cocoa magnify and swipe events |
| `src/zen/common/styles/zen-browser-ui.css` | Capsule and history sheet styles |

## Prefs

| Pref | Default | Meaning |
| --- | --- | --- |
| `zen.widget.macos.override-system-swipe-gestures` | true | Take horizontal swipes from the system |
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

`CapsuleOffset` maps progress to an offset with the standard rubber band curve,
so the capsule decelerates instead of stopping at the edge. A confirmed swipe
runs a short pulse before removal. A cancelled one springs back into the edge.

The capsule sits in the browser stack, above page content and below panels. It
uses the shared glass tokens from `zen-ardia-glass.css`.

## Phase handshake

JS owns the phase. The native monitor reads it, because the sheet is a chrome
document and the monitor cannot ask it directly.

1. JS sets phase 1 when tracking starts.
2. If the sheet opens, JS sets phase 2.
3. The native monitor streams cumulative `scrollingDeltaY` as
   `zen-swipe-vertical` while phase is 2.
4. On end or cancel, JS sets phase 0.

If the pref is left at 2 by a crash, the monitor still requires a live gesture
window before forwarding travel. A stale phase cannot drive the sheet alone.

## History sheet

The sheet opens when the swipe stays past the confirmation threshold for 300ms
(`ZEN_SWIPE_LIST_HOLD_MS`). It lists entries from the selected browser's session
history in the swipe direction.

- Rows are 38 points high, the list is 200 points wide, with 8 point padding and
  a 16 point radius.
- The row count comes from `zen.widget.macos.back-gesture-history-count`, read on
  each presentation and clamped to at least 2 and at most the rows that fit the
  window and 15 (`ZEN_SWIPE_LIST_MAX`).
- Each row has a favicon, a tile with the host's first letter when no favicon
  exists, the page title, and a cleaned URL.
- `ZEN_SWIPE_UNIT` of travel moves the selection by one row. Overshoot past the
  first or last row is rubber banded with a nudge.
- An active row has a pill highlight that follows selection.

Vertical travel never scrolls the page while the sheet is up, because the native
monitor consumes it and JS cancels the wheel default.

## Cancellation

Cancellation has to survive two different mistakes:

- **Vertical drift while picking rows must not cancel.** When native vertical
  samples arrive (`zen-swipe-vertical`), the tracker records the vertical activity
  timestamp and marks vertical browsing as active for 250ms. Small horizontal trackpad
  jitter (delta step < 0.03) during this window is ignored so scrolling through
  history rows does not accidentally trigger cancellation.
- **A real pull-back after browsing must cancel.** A leaky reverse-travel bucket
  accumulates opposite horizontal travel over 600ms (`ZEN_SWIPE_CANCEL_LEAK_MS`).
  Moving forward again immediately drains accumulated travel. A deliberate pull-back
  of 18 percent of the unit (`ZEN_SWIPE_CANCEL_TRAVEL = 0.18`) triggers cancellation.
  On finger lift, 40 percent release progress (`ZEN_SWIPE_CANCEL_RELEASE = 0.40`)
  cancels the gesture instead of navigating.
- **Edge cancellation.** Returning fingers all the way back to the bezel/edge
  (`pos <= 0.04` in-flight or `<= 0.05` upon finger release, when vertical browsing
  is not active) triggers an instant cancel.

### Visual feedback on cancel

- **History sheet feedback:** As reverse travel accumulates towards cancellation,
  the sheet shifts back horizontally towards the screen edge by up to 28px
  (`translateX(±28px * progress)`) and subtly dims (`opacity: 1 - 0.35 * progress`),
  making it clear that the gesture is being reversed.
- **Capsule cancel exit:** When a partial or unconfirmed swipe is cancelled, the
  capsule slides back into the window edge (`translateX(±72px)`) with zero delay,
  avoiding mid-air shrinkage or flicker. Only when confirmed and navigating does
  the capsule fade and shrink in place after the 120ms dismiss beat.

`ZEN_SWIPE_CONFIRM_DELTA` is 0.25. Release above it navigates to the selected
row. Release below it returns to the page.

## Haptics

The native monitor fires one alignment feedback when the gesture crosses the
confirmation threshold, using the same haptic path as space switches. It fires
on the way in only, so wavering at the threshold does not buzz repeatedly.
`zen.haptic-feedback.enabled` gates it.

## Interaction with space swipes

A horizontal swipe has two consumers: page navigation and space switching. The
space tracker claims horizontal swipes on the toolbox when the pointer is not
over the urlbar, the spaces button or the download list. The back/forward
tracker sits below that, on the browser element. A swipe that starts over the
toolbox changes space. A swipe over content navigates history.

If both fire on one gesture, the page navigates and the space changes. The specs
do not define a priority beyond the event order above. Treat a double action as
a bug and capture the event at the earliest consumer that wants it.

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

- The history sheet reads session history, so entries the user has not visited in
  this session are absent.
- Titles and URLs come from history entries, not live tab titles.
- The native monitor only sees precise scrolling deltas. A mouse wheel with line
  deltas is ignored on purpose.
- Debug logging is per event and can flood the system log. Leave the pref off.

## Verification

1. Swipe right on a page with history. The capsule grows and a haptic fires at
   the threshold. Release. The page goes back.
2. Swipe right, hold. The sheet lists three destinations. Move up and down. The
   selection follows, and the sheet stays.
3. From a lower row, pull back left. The sheet fades out and the page stays.
4. Swipe right and reverse before the threshold. The capsule springs away.
5. Scroll vertically over the page. Nothing indicates a swipe.
6. Set the history count pref to 1. The sheet does not open. Set it to 9. Nine
   rows appear when the window is tall enough.
