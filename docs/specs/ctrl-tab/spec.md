# Spec: recent tabs card on Ctrl+Tab

Platform: any. Chrome JS and CSS. Only macOS tested.

## Purpose

Ctrl+Tab lists the active space's tabs, most recently used first. A quick tap switches without drawing anything; holding opens the card to pick, close, or change space.

## Files

| File | Role |
| --- | --- |
| `src/browser/components/tabbrowser/content/browser-ctrlTab-js.patch` | Card, list building, keys, close and unload |
| `src/browser/themes/shared/tabbrowser/ctrlTab-css.patch` | Geometry, glass, row and exit animations |
| `prefs/zen/zen.yaml` | `zen.ctrlTab.max-previews`, `zen.ctrlTab.show-pending-tabs` |
| `src/zen/common/styles/zen-ardia-glass.css` | Blur token reused; the card redeclares fill, rim and shadow |

## Prefs

| Pref | Default | Meaning |
| --- | --- | --- |
| `zen.ctrlTab.max-previews` | 9 | Rows shown. Read once at startup by a lazy getter, clamped to 4 to 49 |
| `zen.ctrlTab.show-pending-tabs` | true | Include tabs of a restored, unloaded space |
| `zen.tabs.ctrl-tab.ignore-essential-tabs` | false | Existing pref, honored by the list builder |
| `zen.tabs.ctrl-tab.ignore-pending-tabs` | false | Existing pref, honored by the list builder |

Only an explicit `false` hides pending tabs.

## Geometry

Card and CSS share these numbers. Change one without the other and the card breaks.

| Part | Value |
| --- | --- |
| Card width | 400 px |
| Corner radius | 16 px |
| Padding | 8 px |
| Row height | 40 px |
| Row radius | 8 px |
| Icon to label gap | 10 px (rows sit back to back) |
| Favicon | 16 px |
| Card height | rows times 40 px, capped at 360 px |
| Backdrop filter | `blur(42px) saturate(180%)`, the shared token |
| Card fill | `light-dark(rgba(248,248,252,0.97), rgba(40,41,45,0.97))`, denser: a popup has no page behind it |
| Card rim and shadow | 0.5px rim, `0 12px 28px` shadow, declared by the card |
| Show delay | 140 ms (`SHOW_AFTER_MS`) |

The popup drops its native max width and height, so the panel reaches 400px by 360px. It enters with a 150ms scale and opacity animation.

## Lifecycle

1. Ctrl+Tab starts a session and a 140ms timer.
2. Ctrl released before the timer fires: no card, selection moves. This fast path keeps a quick tap from flashing.
3. Otherwise the card opens with the list painted and the first row selected.
4. The session ends on Enter, Escape, Ctrl release, or window blur.

On session end `gBrowser.warmupTab` warms the selected row, so the switch does not wait for a process.

## The list

`_buildList` collects the space's tabs in MRU order: its essential tabs, glance tabs, and pending tabs when allowed. `_fallbackList` runs when the filtered list is empty, so the card never shows nothing while a space loads.

A space switch started inside the card sets `_spaceOverride`. The card builds the target list before the switch lands, so no empty label flashes. Afterwards it compares the settled list with what it painted and repaints only when rows differ. `_sameTabs` compares rows within the cap.

## Keys

| Key | Action |
| --- | --- |
| Ctrl+Tab, Down | Next row |
| Ctrl+Shift+Tab, Up | Previous row |
| Enter | Select the row |
| Escape | Close the card |
| W | Close the row, or unload it when pinned or essential |
| Q | Close the space. Normal tabs close, pinned and essential unload |
| 1 to 9 | Switch to that space |

Digits accept `event.key` and `event.code`. `_transitionToken` invalidates an older switch.

## Pointer

The pointer starts stale; moving it recomputes the hovered row. Keyboard selection wins until the pointer moves, so a resting cursor cannot override Ctrl+Tab. Hover does not reorder the list, which is fixed at open time.

## Close and unload

`W` on a normal tab closes it. On a pinned or essential tab it unloads: the controller removes it from the card's used set, detaches it, and calls `_unloadTab`. The tab keeps its place in the space.

`Q` splits the list. Normal tabs go through `gBrowser.removeTabs` together; pinned and essential tabs unload. The card marks itself `closing`, plays the row exit (height and opacity), then closes.

Closing the last visible tab closes the card.

## Space switching inside the card

A digit switch runs five steps.

1. Build the target list and row count.
2. Take a transition token, clear the pending swap timer.
3. Set `_spaceOverride`, update the header with the target icon and label.
4. Paint the target rows with a directional slide, based on whether the target index is above or below the current one.
5. Call `gZenWorkspaces.changeWorkspace`; after it resolves, repaint only if the settled list differs.

A failed switch clears the override and logs the error.

## Edge cases

| Case | Behavior |
| --- | --- |
| One tab in the space | One row. The fallback list can still show other tabs |
| Space restored but unloaded | Pending tabs appear by default |
| Two spaces side by side | Digit switch paints the target before the switch, no empty flash |
| Rapid digits | Each switch bumps the token; older completions stop at the check |
| Tab closed elsewhere | The next list build drops it; the card repaints if a visible row changed |
| Reduced motion | Row animations are CSS transitions. The media query covers some, not all |

## Known limits

- Row count is capped twice: by `maxTabPreviews` and by the 360px card cap.
- No search. Firefox's find and select-all keys are removed.
- Essential tabs of another space can appear when the space rules allow it, but `Q` does not unload them there.
- The header shows the target icon only for a digit switch; otherwise the active space.

## Verification

1. Tap Ctrl+Tab, release under 140ms. Tab changes, no card.
2. Hold Ctrl+Tab. Card opens with the space's tabs, MRU first.
3. Down, Up, Enter, Escape behave.
4. W on a normal tab closes it, card stays. W on a pinned tab unloads it, it stays in the space.
5. Q closes normal tabs, unloads essentials, closes the card.
6. Press 2 while holding Ctrl. Space switches with a slide, card lists the new space.
7. Set `zen.ctrlTab.max-previews` to 4 and restart. Four rows. Values below 4 clamp to 4.
