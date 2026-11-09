# ADR-001: Extended Media Keyboard Shortcuts and Free-Floating Pinch Settle in PiP

## Status
Accepted

## Date
2026-11-09

## Context
Users watching video in Zen Picture-in-Picture (PiP) on macOS frequently interact with the floating video while working in other desktop applications (code editors, terminals, documents). Two usability issues were identified:

1. **Limited Media Shortcuts & Window Focus Contention**:
   Zen PiP previously supported only a minimal set of keyboard shortcuts (`Space`, Left/Right arrows, Up/Down arrows, `M` for mute). Standard playback shortcuts familiar to users from YouTube, FloatyMPV, and standard media players (`J`/`K`/`L` for seek and pause, `0`–`9` for percentage scrubbing, `C` for closed captions, and `,`/`.` for frame/speed scrubbing) were ignored. Furthermore, shortcuts must work when the user clicks or hovers the PiP window without pulling the main browser window to the foreground over their active workspace.

2. **Unwanted Corner Snapping on Free-Floating Pinch**:
   `ZenPiPController.mm` previously invoked `[self snapToNearestCorner]` unconditionally at the end of any trackpad pinch gesture (`pinchEnded`). When a user resized a free-floating window in the center of their display, the window would forcefully snap to a display corner instead of staying in place.

## Decision

### 1. Extended Media Shortcuts Routing
- Expanded `handleKeyDown:` in [`src/zen/pip/ZenPiPController.mm`](file:///Users/sj/Desktop/ws/zen-browser-desktop/src/zen/pip/ZenPiPController.mm) and defined virtual hardware keycodes in [`src/zen/pip/ZenPictureInPictureInternal.h`](file:///Users/sj/Desktop/ws/zen-browser-desktop/src/zen/pip/ZenPictureInPictureInternal.h):
  - **Dismiss / Return to Tab**: `W` (13) / `Esc` (53) invokes `[self backToTab]` (`[_window performClose:nil]`), immediately closing the floating PiP window and docking video back into its originating browser tab.
  - **Pause & Close**: `Q` (12) dispatches a pause event (`Space`) and closes the window.
  - **Intro / Recap Skip**: `Shift+C` (8 with `NSEventModifierFlagShift`) synthesizes an 85-second forward skip (8x 10s seeks + 1x 5s seek), ideal for skipping anime/TV theme songs.
  - **Micro-Seeking**: `Z` (6) and `X` (7) for fine-grained ±3s seeking.
  - **Playback & Navigation**: `J` (38) / `K` (40) / `L` (37) for -10s seek / toggle pause / +10s seek.
  - **Captions**: `C` (8, without modifiers) for subtitles / closed captions toggle.
  - **Percentage Scrubbing**: `0`–`9` (29, 18–28) for jumping to 0% through 90% of playback.
  - **Frame / Speed Scrubbing**: `,` (43) / `.` (47).
  - **Preserved Core Keys**: `Space` (49), Arrows (123–126), `M` (46).
- **Modifier Isolation**: All shortcuts strictly check that `Command`, `Control`, and `Option` modifiers are not active, preventing accidental collisions with macOS system and browser hotkeys (`Cmd+C` copy, `Cmd+,` preferences, `Cmd+1..9` tab switching).
- When any media key is received, `ZenPiPController` lifts `_preventsActivation`, calls `[_window makeKeyWindow]`, activates only the PiP window via `[NSRunningApplication.currentApplication activateWithOptions:0]`, sends the event to the web player responder chain, and restores `_preventsActivation`. The main browser window is never raised forward.

### 2. Free-Floating Pinch Zoom Persistence & Precise Corner Settling
- Added `pinchEndedAtAnchor:(int)anchorCorner` to `ZenPiPController`.
- In `ZenPiPZoom.mm`, `_anchorCorner` detects whether the window was resting at a display corner when the pinch began.
- Extracted `finishPinch` helper to unify gesture-end teardown and timer completion.
- On pinch completion:
  - If `anchorCorner > 0`: Settle directly into the originating dock corner geometry (`zen_pip_throw::CornerFrame`) without flipping across display quadrants.
  - If `anchorCorner == 0` (free-floating): Calls `endGestureChrome:YES` leaving the window exactly where the user resized it in display space, without unwanted snap or edge displacement.

## Alternatives Considered

### Global `NSEvent` Key Monitor (`addGlobalMonitorForEventsMatchingMask:`)
- **Pros**: Would intercept keystrokes without needing key window focus.
- **Cons**: Requires macOS Accessibility permissions (which would prompt the user or fail silently). Moreover, global monitors cannot swallow events (`handler` returns `void`), meaning typing a key would simultaneously trigger PiP and type that character into the user's active application.
- **Rejected**: Clicking the PiP window once grants isolated key focus without raising the browser, avoiding permissions and keystroke leakage.

### Hover Auto-Focus via Tracking Area
- **Pros**: No click needed before typing.
- **Cons**: Automatically stealing key-window status on mouse hover causes unexpected focus loss in background apps (e.g. typing in a terminal and having focus stolen by hovering past PiP).
- **Rejected**: Hover shortcuts work when Zen is active; clicking once is the standard macOS pattern when Zen is in background.

## Consequences
- Full media deck keyboard navigation without mouse dragging or searching for UI buttons.
- External applications (e.g. code editors, IDEs) remain frontmost when clicking and controlling PiP.
- Free-floating PiP windows can be zoomed anywhere on the screen without being thrown into corners.
