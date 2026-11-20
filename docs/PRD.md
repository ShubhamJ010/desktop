# PRD: native macOS enhancements

| Field | Value |
| --- | --- |
| Status | Draft |
| Owner | Shubham Jha |
| Date | 2026-11-17 |
| Source | [PR #5](https://github.com/ShubhamJ010/desktop/pull/5), branch `zen-enh-main` |
| Platform | macOS. Cocoa paths need macOS 14 for the display link, with a timer fallback |

## Summary

This fork adds native macOS input and window behavior to Zen: a glass back/forward swipe with a history picker, a floating PiP card with Meet controls, a per-space Ctrl+Tab card, per-space extension isolation, and a trackpad detent on space swipes.

## Problem

Zen inherits Firefox's macOS gesture handling.

- The back/forward indicator is a small arrow. It cannot jump further back in history mid-gesture and gives no haptic.
- The PiP window stays where it opened. No dock, no hide, no resize without dragging an edge.
- Meet in PiP shows video only. Muting or leaving needs the meeting tab. Meet also breaks Firefox's video picker: WebRTC reports `NaN` duration, and Meet mutes remote videos to avoid echo.
- Ctrl+Tab shows a thumbnail grid. In a vertical tab browser the thumbnails are large, not scoped to the space, and not MRU ordered.
- An extension is on for the whole profile or off. No per-space choice.
- A space swipe gives no tactile confirmation, so overshoot is easy.

## Goals

1. Back/forward navigation feels native: capsule, rubber band, destination picker on hold.
2. The PiP card behaves like a desktop window: snap, stash, fling, zoom, keys from any app.
3. A Meet call stays usable while its tab is in the background.
4. Ctrl+Tab picks a tab in two keystrokes, scoped to the space.
5. Extension availability is per space and enforced beyond hiding toolbar buttons.
6. A space swipe gives one detent per commit.

## Non-goals

- Windows, Linux, or Android parity.
- New telemetry. Success is judged by use, not counters.
- Syncing the per-space extension list across devices.
- Changing upstream Zen defaults outside the prefs listed in the specs.
- Reworking CI, signing, or releases. Those are separate chores in the same PR.

## Users

A macOS trackpad user on Zen with vertical tabs and more than one space, who keeps a Meet call open while working elsewhere. The audience is small, so the specs favor direct behavior over configurability.

## Requirements

Each ID maps to a detailed spec.

### Gesture navigation

| ID | Requirement |
| --- | --- |
| FR-SWIPE-01 | A horizontal two-finger sweep draws a capsule that follows the finger with rubber band resistance. |
| FR-SWIPE-02 | Crossing the confirmation threshold grows the capsule and brightens its chevron. Release past it navigates. |
| FR-SWIPE-03 | Holding past the threshold for 300ms opens a sheet of recent session history. Vertical movement picks a row. |
| FR-SWIPE-04 | Pulling back after browsing cancels sheet and navigation. Vertical drift never cancels. |
| FR-SWIPE-05 | Vertical page scrolling is not intercepted. |

Details: [specs/swipe/spec.md](specs/swipe/spec.md).

### Picture in Picture

| ID | Requirement |
| --- | --- |
| FR-PIP-01 | Releasing a dragged card inside a corner's 45 degree cone snaps it there, inset 10 points. |
| FR-PIP-02 | A release faster than 350 points per second flings the card to the nearest corner in the travel direction. |
| FR-PIP-03 | Pushing the card past a screen edge stashes it with 28 points visible. The handle restores it. |
| FR-PIP-04 | Pinch or Command+scroll resizes around the cursor without tearing the picture. |
| FR-PIP-05 | The card takes keyboard focus while another app is frontmost, without raising the browser. |
| FR-PIP-06 | The card stays reachable: 60 points of width, or 40 percent of its height, on a visible screen area. |

Details: [specs/pip/spec.md](specs/pip/spec.md).

### Meet in PiP

| ID | Requirement |
| --- | --- |
| FR-MEET-01 | With auto-PiP enabled, switching away from a Meet tab opens the call in PiP. The toggle ships off. |
| FR-MEET-02 | The PiP window shows the largest playing participant or presentation stream, not the self view. |
| FR-MEET-03 | Mic, camera and hangup buttons mirror meeting state within 300ms of a DOM change. |
| FR-MEET-04 | Each button acts on the real meeting controls and refreshes its icon from the result. |

Details: [specs/pip/spec-meet.md](specs/pip/spec-meet.md).

### Tab switching

| ID | Requirement |
| --- | --- |
| FR-CT-01 | Releasing Ctrl within 140ms of Ctrl+Tab switches tab without drawing the card. |
| FR-CT-02 | The card lists up to `zen.ctrlTab.max-previews` tabs of the active space (9 by default), most recently used first. |
| FR-CT-03 | W closes the selected tab; pinned and essential tabs unload. Q empties the space. |
| FR-CT-04 | 1 to 9 switch space while the card is open. |

Details: [specs/ctrl-tab/spec.md](specs/ctrl-tab/spec.md).

### Per-space extensions

| ID | Requirement |
| --- | --- |
| FR-EXT-01 | A disabled extension stays disabled for that space across restarts. |
| FR-EXT-02 | Its toolbar buttons hide in that space only. |
| FR-EXT-03 | Its content scripts, user scripts and styles do not run in that space's tabs. |
| FR-EXT-04 | Its context menus, shortcuts and background tab access are blocked in that space. |
| FR-EXT-05 | The site data panel shows a stack card for hidden extensions; one click re-enables one. |

Details: [specs/spaces/spec-extensions.md](specs/spaces/spec-extensions.md).

### Space haptics

| ID | Requirement |
| --- | --- |
| FR-HAP-01 | A space swipe fires one detent when it passes 60 percent of the success threshold. |
| FR-HAP-02 | No detent at a space boundary, or when wrap is off. |
| FR-HAP-03 | Switching space does not fire a second feedback when the gesture ends. |

Details: [specs/spaces/spec-swipe-haptics.md](specs/spaces/spec-swipe-haptics.md).

## Constraints

- Native code compiles inside Gecko's `libxul` under its manual retain/release model. No ARC.
- Upstream files change through patches under `src/`. A patch that no longer applies blocks every build.
- No new runtime dependency. Gesture math is plain C++ headers.
- Native menu strings are English only.
- The PiP controller works when macOS reports no display link.

## Success signals

- Vertical scrolling never opens the swipe sheet.
- A stashed or thrown card is always recoverable with the mouse.
- No new console or system log errors during normal navigation.
- Meet controls stay in sync after the user clicks the same button in the tab.

No counters are added. Reviewers check these by hand on Twilight builds.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Upstream Gecko breaks a patch | No target builds | Patches regenerate against a pristine engine base, not the patched tree |
| JS and Cocoa disagree on phase | Swipe sticks, or the sheet opens twice | One `zen.widget.macos.back-gesture-phase` pref, owned by JS |
| Extension background pages stay loaded | Memory and network use continue | Tabs, menus, shortcuts and injection are blocked; unloading is out of scope |
| Meet selectors change | Controls stop toggling | Several aria-label and data-attribute forms, plus a repaint from the page |
| Manual memory management | Leaks or use-after-free | Controllers detach on close; observers and timers go with them |

## Rollout

The work ships in the Twilight dev build and in the release channel built on `zen-enh-main`. Chrome-side changes can be patched into a built app for a quick check; native changes need a CI build. Every feature has a pref in its spec, so a bad behavior can be turned off without a new build.

## Open questions

- Should the disabled extension list sync with the account, like `zen.ctrlTab.show-pending-tabs` does?
- Should a zoom keep the card anchored to its corner when the display changes mid-gesture?
- Meet selectors rely on English labels. Non-English sessions fall back to `data-is-muted`, which covers mute state but not the leave button.
