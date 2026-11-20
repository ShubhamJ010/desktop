# ADR-006: Replace the Ctrl+Tab thumbnail grid with a per-space MRU card

## Status

Accepted

## Date

2026-11-17

## Context

Firefox's Ctrl+Tab panel shows page thumbnails in a grid. In Zen:

- Tabs live in a vertical strip and are grouped by space. The grid shows tabs
  from every space unless it is filtered, and it has no space header.
- Thumbnails for a vertical tab layout are large and slow to read. The user
  already knows the page by its title and icon.
- The grid is a stopping point, not a picker. Closing tabs and switching spaces
  from inside it is not possible.

The goal is a switcher where two keystrokes pick a tab, and holding Ctrl opens a
small card for closing tabs or changing space.

## Decision

Replace the panel contents in place, keeping Firefox's shortcut plumbing.

- The card is 400px wide with 16px radius and 40px rows. Nine rows by default,
  read from `zen.ctrlTab.max-previews`, which the lazy getter clamps to 4 to 49.
- The list is the active space's tabs in most recent use order. Pending tabs are
  included unless the user explicitly set
  `zen.ctrlTab.show-pending-tabs` to false, because a restored tab is still a
  tab of that space.
- If Ctrl is released before `SHOW_AFTER_MS` (140ms), the card never opens and
  the selection moves. No frame is painted for a quick tap.
- Holding opens the card. Keys: Ctrl+Tab and Down move forward, Ctrl+Shift+Tab
  and Up move back, Enter picks, Escape cancels, W closes or unloads, Q empties
  the space, 1 to 9 switch space.
- W on a pinned or essential tab unloads it instead of removing it. Q removes
  normal tabs and unloads pinned and essential ones.
- A digit switch paints the target space's list before the switch lands, using
  `_spaceOverride`, then repaints only if the settled list differs.
- The pointer is ignored until it moves, so a resting cursor cannot override
  keyboard selection.

## Alternatives considered

### Keep the grid and filter it by space

Rejected. It keeps the thumbnail cost and still needs close and unload actions
added. The grid's visual language does not match the rest of Zen chrome.

### A subview inside the tab strip

Rejected. It would compete with the strip for space and cannot overlay content.

### A search field like a command palette

Rejected for now. Typing adds a mode and a text field. MRU order plus digits
covers the common case with fewer keys.

### Reuse Firefox's `tabPreviews` module

Rejected. The card needs titles, icons and URLs, not images. Removing the
thumbnail path also removes a cache and a thumbnail service from the hot path.

## Consequences

- The card is a patch against `browser-ctrlTab.js`, which upstream still changes.
  Patch drift is the main maintenance cost.
- The find and select-all keys from Firefox are gone. They were thumbnail grid
  features and do not fit the card.
- Digits are claimed while the card is open. A user who expects them to type into
  something else will notice, but Ctrl is held, so typing into a page was not
  possible anyway.
- `warmupTab` on the selected row makes the switch feel instant at the cost of
  starting a process for a tab the user may not pick.
- `zen.ctrlTab.max-previews` is read once at startup. Changing it needs a restart.

See [ctrl-tab/spec.md](../specs/ctrl-tab/spec.md).
