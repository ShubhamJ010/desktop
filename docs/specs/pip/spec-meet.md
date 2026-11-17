# Spec: Google Meet controls in PiP

Platform: macOS player window. Runs in the PiP player document and the content
process that holds the meeting.

## Purpose

Keep a Meet call usable when the tab is in the background. The PiP card shows
mute, camera and hangup buttons that act on the real meeting page.

## Files

| File | Role |
| --- | --- |
| `src/toolkit/actors/PictureInPictureChild-sys-mjs.patch` | Picks the Meet video, reads meeting state, clicks page buttons, sends state |
| `src/toolkit/components/pictureinpicture/PictureInPicture-sys-mjs.patch` | Auto-PiP when switching tabs |
| `src/toolkit/components/pictureinpicture/content/player-js.patch` | Builds the buttons, sends commands, renders state |
| `src/toolkit/components/pictureinpicture/content/player-xhtml.patch` | Container markup and stylesheet link |
| `src/toolkit/themes/shared/pictureinpicture/player-css.patch` | Button layout and the glass treatment |

## Prefs

```yaml
media.videocontrols.picture-in-picture.enable-when-switching-tabs.enabled: true
media.videocontrols.picture-in-picture.respect-disablePictureInPicture: false
```

The second pref is off so a site that opts out of PiP still gets the automatic
transition on tab switch. That is deliberate for Meet, which does not opt in.

## Detection

A document is a Meet call when its hostname ends with `meet.google.com`. All
Meet-specific work is behind that check, so nothing changes on other sites.

## Choosing the video

Meet streams are WebRTC `MediaStream` sources. Two properties break Firefox's
default picker:

- `duration` is `NaN`, so the default "has a real duration" filter rejects them.
- The remote videos are muted to avoid local echo, so the default "not muted"
  filter rejects them too.

The patch:

1. Collects videos that are playing and at least 100 by 100 CSS pixels.
2. Sorts them by width times height, largest first.
3. Returns the largest. That is the active speaker, a presentation, or a screen
   share, never the small self view.
4. Treats a muted video as playable when the document is Meet.
5. Skips the duration check for Meet.

If no video passes the size and playing filter, the default picker runs.

## Reading meeting state

`getMeetButtons` resolves the three page controls by attribute, trying several
forms because Meet changes markup:

| Control | Selectors |
| --- | --- |
| Mic | `aria-label` contains "microphone" or " mic", `data-is-muted` with a mic label, `data-tooltip` contains "microphone" or "mic" |
| Camera | `aria-label` or `data-is-muted` containing "camera", `data-tooltip` containing "camera" |
| Leave | `aria-label` contains "leave call", `data-tooltip` contains "leave call" |

`getMeetState` reads the mute flags. `data-is-muted` wins when present.
Otherwise an `aria-label` that mentions turning the device on means the device is
currently off. The state object carries a mic flag and a camera flag.

The child actor watches the meeting document with a `MutationObserver` on
attributes and child nodes. It also sends state at 300ms, 800ms and 1500ms after
setup, because Meet paints its toolbar progressively. Each change sends
`PictureInPicture:MeetState`.

## Commands

The player sends one of three messages to the child actor. The actor clicks the
matching page button, waits 250ms, then sends fresh state. The button therefore
follows the page, not the click.

| Message | Effect |
| --- | --- |
| `PictureInPicture:MeetToggleMic` | Click the mic button |
| `PictureInPicture:MeetToggleCam` | Click the camera button |
| `PictureInPicture:MeetLeaveCall` | Click leave, then report final state |

If a button is missing, the actor sends the current state and does nothing. A
call that has already ended has no leave button, so the message is a no-op.

## Player UI

`setupMeetControls` adds `#meet-controls` inside `#controls-bottom`, after the
window's own buttons. Each button has class `meet-btn control-item`, so it
inherits the existing show and hide rules: visible while the controls are shown
or while the pointer is over the button or the card is key.

- Icons are inline SVG paths, so no extra request is made and the icon follows
  the button color.
- The hangup button adds `meet-btn-hangup` and uses a red treatment.
- The buttons use the shared glass tokens from `zen-ardia-glass.css` for the
  backdrop.
- `setMeetState` swaps the mic and camera icons. It does not guess. It renders
  the flags the page reported.

The player also listens for `zen-pip-gesture-begin`, `zen-pip-gesture-end` and
`zen-pip-gesture-hover` from the native controller. Controls are hidden during a
swipe or pinch, and restored when it ends.

## Edge cases

| Case | Behavior |
| --- | --- |
| Screen share plus speaker tiles | The largest playing video wins, which is normally the share |
| Audio-only call | No video passes the filter, so PiP does not open |
| Meet changes markup | Several selector forms are tried. Unknown markup shows the last known state and buttons become no-ops |
| Call ends in the tab | Observer clears the buttons' state source. The card keeps its last icons until closed |
| Two Meet tabs | Each player window holds its own child actor and its own observer |
| Non-English UI | `data-is-muted` still works. Leave falls back to a `data-tooltip` match, which may miss |

## Known limits

- Meet's DOM is not an API. A redesign can break the selectors. The state path
  degrades to no-ops rather than wrong actions.
- The camera icon mirrors the page's mute flag, not the actual track state. If
  Meet reports a pending permission, the icon shows the last committed state.
- The `respect-disablePictureInPicture` change applies to every site, not only
  Meet.

## Verification

1. Join a Meet call with a camera and a second participant.
2. Switch to another tab. The call opens in PiP showing the other participant.
3. Press the mic button in PiP. The tab's mic button changes and the PiP icon
   changes within about 300ms.
4. Repeat for the camera.
5. Press hangup. The call ends in the tab and the card closes.
6. Toggle mute in the tab. The PiP icon follows.
7. Start a screen share. The PiP card switches to the shared screen.
