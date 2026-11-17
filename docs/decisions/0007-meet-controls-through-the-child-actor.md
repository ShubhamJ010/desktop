# ADR-007: Drive Meet controls through the child actor and the page

## Status

Accepted

## Date

2026-11-17

## Context

A Meet call in PiP shows video with no controls. The user has to find the meeting
tab to mute or leave.

Meet has no control API. Two other routes exist, and neither is reliable:

- WebRTC tracks live in the page's JavaScript. The parent cannot reach them, and
  even with a stream handle, muting a track would not update Meet's own state.
  Meet would show the wrong icon and re-enable the device on its next sync.
- A content script could draw its own controls inside the page. That duplicates
  Meet's UI and would appear twice in the tab.

Meet also breaks Firefox's video picker. WebRTC streams report `NaN` duration,
and remote participant videos are muted to avoid local echo, so the default
filters reject every stream and pick the self view or nothing.

## Decision

Treat the page as the source of truth and let the child actor act on it.

- Detection is by hostname ending in `meet.google.com`. Nothing changes on other
  sites.
- `findVideoToPiP` gets a Meet branch that collects playing videos at least 100
  by 100 CSS pixels, sorts by area, and returns the largest. The duration and
  muted filters are skipped for Meet, and a muted video counts as playable.
- `getMeetButtons` resolves mic, camera and leave by trying several attribute
  forms: `aria-label`, `data-is-muted` and `data-tooltip`.
- Toggles click the real page button, wait 250ms, then send fresh state. The PiP
  icon follows the page, not the click.
- A `MutationObserver` on the meeting document sends state on change, plus three
  timed sends at 300ms, 800ms and 1500ms because Meet paints its toolbar late.
- IPC messages are `PictureInPicture:MeetState` from the actor and
  `PictureInPicture:MeetToggleMic`, `MeetToggleCam`, `MeetLeaveCall` from the
  player.
- The player builds three buttons inside `#controls-bottom` with the existing
  `control-item` class, so show and hide behavior is inherited instead of
  reimplemented.

The two prefs that make a call open in PiP are
`media.videocontrols.picture-in-picture.enable-when-switching-tabs.enabled` and
`media.videocontrols.picture-in-picture.respect-disablePictureInPicture` set to
false.

## Alternatives considered

### Parent process controls the media tracks

Rejected. It needs a stream handle the parent does not have, and it would
desynchronize from Meet's state.

### Injected floating controls in the meeting page

Rejected. It duplicates Meet's own toolbar and competes with its layout.

### Keyboard simulation in the page

Rejected. Shortcuts differ per locale and per Meet version, and a synthetic key
event can be ignored by the page's own handlers.

### Ship only the video picker fix

Rejected as incomplete. Selecting the right stream is necessary but the user
still cannot mute or leave from the card.

## Consequences

- Meet's DOM is not an API. Selectors can break with any Meet release. The failure
  mode is a no-op button, not a wrong action, because clicks target the resolved
  page button.
- Labels are matched in English. `data-is-muted` still drives state in other
  locales, but the leave button may not resolve.
- State can lag by up to 250ms after a click, plus Meet's own paint time.
- Each PiP window holds its own observer. Two Meet calls mean two observers, which
  is correct and bounded.
- The automatic PiP pref applies to every site, not only Meet. That is a wider
  behavior change than the feature needs, and it is listed as a known trade.

See [spec-meet.md](../specs/pip/spec-meet.md).
