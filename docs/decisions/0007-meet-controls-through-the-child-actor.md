# ADR-007: Drive Meet controls through the child actor and the page

## Status

Accepted

## Date

2026-11-17

## Context

A Meet call in PiP shows video with no controls. The user has to find the meeting tab to mute or leave.

Meet has no control API. Two other routes exist, and neither is reliable:

- WebRTC tracks live in the page's JavaScript. The parent cannot reach them, and muting a track would not update Meet's own state. Meet would show the wrong icon and re-enable the device on its next sync.
- A content script could draw its own controls in the page. That duplicates Meet's UI and appears twice in the tab.

Meet also breaks Firefox's video picker. WebRTC streams report `NaN` duration, and remote participant videos are muted to avoid local echo, so the default filters reject every stream and pick the self view or nothing.

## Decision

Treat the page as the source of truth and let the child actor act on it.

- Detection is by hostname ending in `meet.google.com`. Nothing changes on other sites.
- `findVideoToPiP` gets a Meet branch that collects playing videos at least 100 by 100 CSS pixels, sorts by area, and returns the largest. The duration and muted filters are skipped for Meet, and a muted video counts as playable.
- `getMeetButtons` resolves mic, camera and leave by trying several attribute forms: `aria-label`, `data-is-muted` and `data-tooltip`.
- Toggles click the real page button, wait 150ms, then send fresh state. When the button is missing they dispatch Meet's own shortcut (`Cmd+D` mic, `Cmd+E` camera). Leave only clicks and sends no state. The PiP icon follows the page, not the click.
- A `MutationObserver` on the meeting document sends state on attribute changes, plus three timed sends at 300ms, 800ms and 1500ms because Meet paints its toolbar late.
- IPC messages are `PictureInPicture:MeetState` from the actor and `PictureInPicture:MeetToggleMic`, `MeetToggleCam`, `MeetLeaveCall` from the player.
- The player builds three buttons inside `#controls-bottom` with the existing `control-item` class, so show and hide behavior is inherited instead of reimplemented.

Auto-PiP is gated on `media.videocontrols.picture-in-picture.enable-when-switching-tabs.enabled`, which ships `false` (the upstream default) and is exposed as the auto-PiP toggle in Settings > Advanced. Nothing sets `media.videocontrols.picture-in-picture.respect-disablePictureInPicture` to false. `src/zen/media/ZenMediaController.sys.mjs` reads it, defaulting to `true`, to decide whether the sidebar card offers a PiP button.

## Alternatives considered

### Parent process controls the media tracks

Rejected. It needs a stream handle the parent does not have and would desynchronize from Meet's state.

### Injected floating controls in the meeting page

Rejected. It duplicates Meet's toolbar and competes with its layout.

### Keyboard simulation in the page

Rejected as the primary path. Shortcuts differ per locale and Meet version, and a synthetic key event can be ignored by the page's handlers. It remains a fallback for a missing button.

### Ship only the video picker fix

Rejected as incomplete. Selecting the right stream is necessary, but the user still cannot mute or leave from the card.

## Consequences

- Meet's DOM is not an API. Selectors can break with any Meet release. The failure mode is a no-op button, not a wrong action, because clicks target the resolved page button.
- Labels are matched in English. `data-is-muted` still drives state in other locales, but the leave button may not resolve.
- State can lag by up to 150ms after a click, plus Meet's paint time.
- Each PiP window holds its own observer. Two Meet calls mean two observers, which is correct and bounded.
- The automatic PiP pref applies to every site, not only Meet, and it ships off. Enabling it is a wider behavior change than the feature needs.

See [spec-meet.md](../specs/pip/spec-meet.md).
