# PRD: native macOS enhancements

| Field | Value |
| --- | --- |
| Status | Draft |
| Owner | Shubham Jha |
| Date | 2026-11-17 |
| Source | [PR #5](https://github.com/ShubhamJ010/desktop/pull/5), branch `zen-enh-main` |
| Platform | macOS. Cocoa paths require macOS 14 for the display link, with a timer fallback |

## Summary

This fork adds native macOS input and window behavior to Zen. Trackpad
back/forward swipes draw a glass capsule and offer a history picker. The
Picture-in-Picture window becomes a floating card that snaps to screen corners,
hides at an edge and resizes under the cursor. Google Meet gains mic, camera and
hangup buttons inside that card. Ctrl+Tab opens a card listing the tabs of the
active space. Extensions can be limited to one space. Swiping between spaces
fires a trackpad detent.

## Problem

Zen inherits Firefox's gesture handling on macOS.

- The back/forward indicator is a small arrow. There is no way to jump to a
  destination further back in history during the gesture, and no haptic.
- The PiP window sits wherever it was opened. It cannot dock, does not hide, and
  cannot be resized without dragging an edge.
- A Meet call in PiP shows video only. Muting or leaving needs the meeting tab.
  Meet participant streams also confuse Firefox's video picker because WebRTC
  streams report `NaN` duration, and Meet mutes them to avoid echo.
- Ctrl+Tab shows a grid of page thumbnails. In a vertical tab browser the
  thumbnails are large, not scoped to the space, and not ordered by recent use.
- An extension is either on for the whole profile or off. A user cannot keep a
  developer tool in one space and out of another.
- Switching spaces by swipe gives no tactile confirmation, which makes it easy
  to overshoot.

## Goals

1. Back/forward navigation feels native. Capsule, rubber band, and a destination
   picker on hold.
2. The PiP card behaves like a desktop window. Snap, stash, fling, zoom, and
   keyboard control from any app.
3. A Meet call is usable while the tab is in the background.
4. Ctrl+Tab selects a tab in two keystrokes, scoped to the current space.
5. Extension availability is per space, and the choice is enforced beyond
   hiding toolbar buttons.
6. Space swipes give one detent per commit.

## Non-goals

- Windows, Linux, or Android parity for any of this work.
- New telemetry. Success is judged by use, not by counters.
- Syncing the per-space extension list across devices.
- Changing upstream Zen defaults outside the prefs listed in the specs.
- Reworking the CI, signing, or release pipeline. Those are separate chores in
  the same PR.

## Users

A macOS user on a trackpad who runs Zen with vertical tabs and more than one
space, and who keeps a Meet call open while working in other tabs. The fork has
a small audience, so the specs favour direct behavior over configurability.

## Requirements

Identifiers map to the detailed spec in the same row.

### Gesture navigation

| ID | Requirement |
| --- | --- |
| FR-SWIPE-01 | A horizontal two-finger sweep draws a capsule that follows the finger with rubber band resistance. |
| FR-SWIPE-02 | Crossing the confirmation threshold grows the capsule and brightens its chevron. Releasing past the threshold navigates. |
| FR-SWIPE-03 | Holding past the threshold for 300ms opens a sheet listing recent session history destinations. Moving vertically selects a row. |
| FR-SWIPE-04 | Pulling back after browsing cancels the sheet and the navigation. Vertical drift never cancels it. |
| FR-SWIPE-05 | Vertical page scrolling is not intercepted. |

Details: [swipe/spec.md](specs/swipe/spec.md).

### Picture in Picture

| ID | Requirement |
| --- | --- |
| FR-PIP-01 | Dragging the card and releasing inside a corner's 45 degree cone snaps it to that corner, inset 10 points. |
| FR-PIP-02 | A release faster than 350 points per second flings the card toward the nearest corner in the direction of travel. |
| FR-PIP-03 | Pushing the card past a screen edge stashes it, leaving 28 points visible. Clicking the handle restores it. |
| FR-PIP-04 | Pinch or Command+scroll resizes the card around the cursor without tearing the picture. |
| FR-PIP-05 | The card accepts keyboard focus while another app is frontmost, without bringing the browser window forward. |
| FR-PIP-06 | The card always stays reachable. At least 60 points of width, or 40 percent of its height, remains on a visible screen area. |

Details: [pip/spec.md](specs/pip/spec.md).

### Meet in PiP

| ID | Requirement |
| --- | --- |
| FR-MEET-01 | With auto-PiP enabled, switching away from a Meet tab opens the call in PiP. The toggle ships off. |
| FR-MEET-02 | The PiP window shows the largest playing participant or presentation stream, not the self view. |
| FR-MEET-03 | The card shows mic, camera and hangup buttons that mirror the meeting state within 300ms of a DOM change. |
| FR-MEET-04 | Each button acts on the real meeting controls in the page and refreshes its icon from the result. |

Details: [pip/spec-meet.md](specs/pip/spec-meet.md).

### Tab switching

| ID | Requirement |
| --- | --- |
| FR-CT-01 | Releasing Ctrl within 140ms of Ctrl+Tab switches to the next tab without drawing the card. |
| FR-CT-02 | The card lists up to `zen.ctrlTab.max-previews` tabs of the active space (9 by default), most recently used first. |
| FR-CT-03 | W closes the selected tab. Pinned and essential tabs unload instead of closing. Q empties the space. |
| FR-CT-04 | 1 to 9 switch to that space while the card is open. |

Details: [ctrl-tab/spec.md](specs/ctrl-tab/spec.md).

### Per-space extensions

| ID | Requirement |
| --- | --- |
| FR-EXT-01 | A disabled extension stays disabled for that space across restarts. |
| FR-EXT-02 | Toolbar buttons for disabled extensions are hidden in that space only. |
| FR-EXT-03 | Content scripts, user scripts and styles from a disabled extension do not run in tabs of that space. |
| FR-EXT-04 | Context menus, keyboard shortcuts and background tab access are blocked for that space. |
| FR-EXT-05 | The site data panel shows a stack card for hidden extensions, and one click enables one again. |

Details: [spaces/spec-extensions.md](specs/spaces/spec-extensions.md).

### Space haptics

| ID | Requirement |
| --- | --- |
| FR-HAP-01 | A space swipe fires one detent when it passes 60 percent of the success threshold. |
| FR-HAP-02 | No detent fires at a space boundary, or when wrap is off. |
| FR-HAP-03 | Switching space does not fire a second feedback when the gesture ends. |

Details: [spaces/spec-swipe-haptics.md](specs/spaces/spec-swipe-haptics.md).

## Constraints

- The native code compiles inside Gecko's `libxul` and follows its manual
  retain/release memory model. No ARC.
- Upstream files are modified through patch files under `src/`. A patch that no
  longer applies blocks every build.
- No new runtime dependency. The gesture math is plain C++ headers.
- All strings shown in native menus are English only.
- The PiP controller must keep working when macOS reports no display link.

## Success signals

- Vertical scrolling never opens the swipe sheet.
- A stashed or thrown card is always recoverable with the mouse.
- No new console or system log errors during normal navigation.
- Meet controls stay in sync after the user clicks the same button in the tab.

No counters are added. These are reviewed by hand on Twilight builds.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Upstream Gecko changes break a patch | Build fails for every target | Patches are regenerated against a pristine engine base, not against the patched tree |
| JS gesture layer and Cocoa monitor disagree on phase | Swipe sticks or sheet opens twice | Single `zen.widget.macos.back-gesture-phase` pref, owned by JS |
| Extension background pages still load | Disabled extension still uses memory and network | Access to tabs, menus, shortcuts and injection is blocked; unloading is out of scope |
| Meet DOM selectors change | Controls stop toggling | Selectors match several aria-label and data-attribute forms, and the state observer repaints from the page |
| Manual memory management | Leaks or use-after-free in the card | Controllers detach on window close; observers and timers are removed on detach |

## Rollout

The work ships in the Twilight dev build and in the release channel built on
`zen-enh-main`. Chrome-side changes can be patched into a built app for a quick
check. Native changes need a CI build. Every feature has a pref, listed in its spec, so
a bad behavior can be turned off without a new build.

## Open questions

- Should the disabled extension list sync with the account, like
  `zen.ctrlTab.show-pending-tabs` does?
- Should a zoom keep the card anchored to its corner when the display changes
  mid-gesture?
- Meet button selectors rely on English labels. Non-English sessions fall back
  to `data-is-muted`, which covers mute state but not the leave button.
