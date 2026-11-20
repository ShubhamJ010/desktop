# Spec: Google Meet controls in PiP

Platform: macOS player window. Runs in the PiP player document and the content process that holds the meeting.

## Purpose

Keep a Meet call usable while its tab is in the background. The PiP card shows mute, camera and hangup buttons that act on the real meeting page.

## Files

| File | Role |
| --- | --- |
| `src/toolkit/actors/PictureInPictureChild-sys-mjs.patch` | Picks the Meet video, reads state, clicks page buttons, sends state |
| `src/toolkit/components/pictureinpicture/PictureInPicture-sys-mjs.patch` | Auto-PiP on tab switch, inter-workspace unpip, Meet state routing |
| `src/zen/media/ZenMediaController.sys.mjs` | Sidebar media card; reads `respect-disablePictureInPicture` for its PiP button |
| `src/zen/settings/panes/advanced.inc.xhtml` | Settings toggle for the auto-PiP pref |
| `src/toolkit/components/pictureinpicture/content/player-js.patch` | Builds the buttons, sends commands, renders state |
| `src/toolkit/components/pictureinpicture/content/player-xhtml.patch` | Container markup and stylesheet link |
| `src/toolkit/themes/shared/pictureinpicture/player-css.patch` | Button layout and glass treatment |

## Prefs

```yaml
# prefs/firefox/pip.yaml, upstream default
media.videocontrols.picture-in-picture.enable-when-switching-tabs.enabled: false
# Read by src/zen/media/ZenMediaController.sys.mjs, default true
media.videocontrols.picture-in-picture.respect-disablePictureInPicture: true
```

Auto-PiP is off by default. The "open PiP when switching tabs" toggle in Settings > Advanced writes `enable-when-switching-tabs.enabled`. Nothing in this fork forces `respect-disablePictureInPicture` off. The sidebar card reads it to decide whether to offer a PiP button, and the launcher still honors it.

## Detection

A document is a Meet call when its hostname ends with `meet.google.com`. All Meet work sits behind that check, so other sites are unchanged.

## Choosing the video

Meet streams are WebRTC `MediaStream` sources with two properties that break Firefox's picker:

- `duration` is `NaN`, so the "has a real duration" filter rejects them.
- Remote videos are muted to avoid local echo, so the "not muted" filter rejects them too.

The patch:

1. Collects playing videos at least 100 by 100 CSS pixels.
2. Sorts by width times height, largest first.
3. Returns the largest: the active speaker, a presentation, or a screen share, never the small self view.
4. Treats a muted video as playable on Meet, in both the auto-PiP path and the eligibility check.
5. Skips the duration check on Meet.

If no video passes the size and playing filter, the default picker runs. The auto-PiP path also skips a browser whose audio is muted, so a muted tab does not pop out a card.

## Reading meeting state

`getMeetButtons` resolves the three controls by attribute, trying several forms because Meet changes markup:

| Control | Selectors |
| --- | --- |
| Mic | `aria-label` contains "microphone" or " mic"; `data-is-muted` with a mic label; `data-tooltip` contains "microphone" or "mic" |
| Camera | `aria-label` or `data-is-muted` contains "camera"; `data-tooltip` contains "camera" or "video" |
| Leave | `aria-label` or `data-tooltip` contains "leave call" or "end call" |

`getMeetState` reads the mute flags. `data-is-muted` wins when present. Otherwise an `aria-label` that mentions turning the device on means the device is off. The state object carries a mic flag and a camera flag.

The child actor watches the document with a `MutationObserver` on attributes only (`data-is-muted`, `aria-label`, `class`, `style`) with `subtree` set; it does not observe child list changes. It sends state once immediately, then at 300ms, 800ms and 1500ms after setup, because Meet paints its toolbar progressively. Each change sends `PictureInPicture:MeetState`.

## Commands

The player sends one of three messages. For mic and camera the actor clicks the matching page button, waits 150ms, then sends fresh state, so the button follows the page, not the click. When the button is missing it dispatches Meet's shortcut instead (`Cmd+D` mic, `Cmd+E` camera). Leave only clicks; it sends no state back.

| Message | Effect |
| --- | --- |
| `PictureInPicture:MeetToggleMic` | Click the mic button |
| `PictureInPicture:MeetToggleCam` | Click the camera button |
| `PictureInPicture:MeetLeaveCall` | Click leave. No state is sent back |

An ended call has no leave button, so that message is a no-op. Mic and camera still report state after their 150ms wait, even when the shortcut fallback ran.

## Player UI

`setupMeetControls` adds `#meet-controls` inside `#controls-bottom`, after the window's own buttons. Each button has class `meet-btn control-item`, inheriting the show and hide rules: visible while the controls show, or while the pointer is over the button or the card is key.

- Icons are inline SVG paths, so no extra request is made and the icon follows the button color.
- The hangup button adds `meet-btn-hangup` and uses a red treatment.
- Buttons use the shared glass tokens from `zen-ardia-glass.css` for the backdrop.
- `setMeetState` swaps the mic and camera icons from the flags the page reported; it does not guess.

The player also listens for `zen-pip-gesture-begin`, `zen-pip-gesture-end` and `zen-pip-gesture-hover` from the native controller. Controls hide during a swipe or pinch and return when it ends.

## Edge cases

| Case | Behavior |
| --- | --- |
| Screen share plus speaker tiles | The largest playing video wins, normally the share |
| Audio-only call | No video passes the filter, so PiP does not open |
| Meet changes markup | Mic and camera fall back to `Cmd+D` and `Cmd+E`; unknown markup leaves the last known state on screen |
| Call ends in the tab | Observer disconnects on close. The card keeps its last icons until closed |
| Two Meet tabs | Each player window holds its own child actor and observer |
| Non-English UI | `data-is-muted` still works. Leave falls back to a `data-tooltip` match, which may miss |

## Known limits

- Auto-PiP is gated on a pref that ships off. Without it the Meet stream still opens on request, but switching tabs does nothing.
- Meet's DOM is not an API. A redesign can break the selectors. The state path degrades to no-ops, not wrong actions.
- The camera icon mirrors the page's mute flag, not the track state. A pending permission shows the last committed state.
- Auto-PiP, once enabled, applies to every site, not only Meet.

## Verification

1. Join a Meet call with a camera and a second participant. Turn on the auto-PiP toggle in Settings > Advanced if it is off.
2. Switch to another tab. The call opens in PiP showing the other participant.
3. Press the mic button in PiP. The tab's mic button changes and the PiP icon follows within about 300ms.
4. Repeat for the camera.
5. Press hangup. The call ends in the tab and the card closes. No state message follows the click.
6. Toggle mute in the tab. The PiP icon follows.
7. Start a screen share. The PiP card switches to the shared screen.
