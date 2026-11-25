# Spec: haptics on a space swipe

Platform: macOS with a Force Touch trackpad. The rest of the space swipe works everywhere.

## Purpose

Confirm a space switch at the moment the gesture is decided, not after the animation finishes.

## Files

| File | Role |
| --- | --- |
| `src/zen/spaces/ZenSpacesSwipe.mjs` | Computes progress, fires the detent once |
| `src/zen/spaces/ZenSpaceManager.mjs` | Switches the space, skips strip reordering for a scroll-driven switch |
| `src/zen/toolkit/common/cocoa/ZenHapticFeedback.mm` | Plays `NSHapticFeedbackPatternAlignment` |
| `src/zen/spaces/ZenSpaceAddSwipe.mjs` | Add-space swipe. Owns its own feedback, unaffected by this work |

## Prefs

`zen.haptic-feedback.enabled` is true by default and gates the native call. The swipe code does not read it; the shared helper does.

## Threshold model

| Value | Meaning |
| --- | --- |
| `SUCCESS_THRESHOLD` 0.25 | Normalized delta at which the swipe commits |
| Progress | `abs(event.delta) / SUCCESS_THRESHOLD` |
| Detent point | Progress `>= 0.6`, about 60 percent of the commit distance |
| `SUCCESS_VELOCITY_CONTRIBUTION` 0.5 | Weight of release velocity in the commit decision |

The detent fires before the commit, so the gesture feels like a key with a bump, not a reaction after the switch.

The native helper uses `NSHapticFeedbackPerformanceTimeDefault`, which syncs the bump to the next screen draw. `PerformanceTimeNow` plays synchronously on the calling thread and hitches the frames that animate the strip.

## Order of checks

`#handleDetentHaptic` runs on every swipe update, before the swipe is applied to the strip.

1. If the gesture has become an action (open library, add space), or the detent already resolved, stop. The action has its own feedback.
2. Compare progress with 0.6. Cheap math, so most frames stop here without touching the DOM or workspace cache.
3. Mark the detent resolved, then resolve direction. A right swipe means forward unless the document is RTL. `naturalScroll` flips the meaning.
4. Call `#canSwitchWorkspace(offset)`. It returns false at the first space moving back, at the last moving forward, and whenever wrap is off.
5. Fire only when a switch is possible.

The flag is forward-only and resets at gesture start. One gesture fires one detent however much the user wiggles at the threshold, and an edge swipe does no repeat work on later frames.

## Commit path

`changeWorkspace` receives `whileScrolling: true` from the swipe, which skips `_organizeWorkspaceStripLocations` so the strip is not re-laid out mid gesture. No second haptic fires here; the detent is the only feedback.

## Edge cases

| Case | Behavior |
| --- | --- |
| Swipe against the first or last space | No detent, no switch possible |
| Wrap enabled at the last space | Detent fires, a switch is possible |
| Gesture cancelled after the detent | The detent already fired. The space does not change |
| Add-space or library action | No detent from this path |
| No trackpad or no Force Touch | `performFeedbackPattern` is a no-op |
| macOS older than 10.14 | The call is compiled out by the availability check |
| Pref off | Helper returns without playing |

## Known limits

- The detent cannot be cancelled. A swipe that crosses 60 percent and returns leaves one bump.
- Only the alignment pattern is used. Strong and weak patterns exist, but one feel per commit.
- The helper does not check whether a window is key. Feedback plays even from a background window that receives the event.

## Verification

1. Swipe one space forward. One bump, then the switch.
2. Swipe slowly, stop at 50 percent. No bump, no switch.
3. Cross 60 percent and return. One bump, no switch.
4. Swipe at the first space with wrap off. No bump.
5. Turn `zen.haptic-feedback.enabled` off. No bump anywhere.
