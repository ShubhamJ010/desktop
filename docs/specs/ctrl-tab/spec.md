# Spec: recent tabs card on Ctrl+Tab

Platform: any. The card is chrome JS and CSS. Only macOS was tested.

## Purpose

Ctrl+Tab shows the tabs of the current space, most recently used first, in a
small card. A quick tap switches without drawing anything. Holding opens the
card for picking, closing and space switching.

## Files

| File | Role |
| --- | --- |
| `src/browser/components/tabbrowser/content/browser-ctrlTab-js.patch` | Card, list building, keys, close and unload |
| `src/browser/themes/shared/tabbrowser/ctrlTab-css.patch` | Geometry, glass, row and exit animations |
| `prefs/zen/zen.yaml` | `zen.ctrlTab.max-previews`, `zen.ctrlTab.show-pending-tabs` |
| `src/zen/common/styles/zen-ardia-glass.css` | Blur token reused by the card; the card redeclares the fill and defines its own rim and shadow |

## Prefs

| Pref | Default | Meaning |
| --- | --- | --- |
| `zen.ctrlTab.max-previews` | 9 | Rows shown. Read once at startup through a lazy preference getter, clamped to 4 to 49 |
| `zen.ctrlTab.show-pending-tabs` | true | Include tabs of a space that is restored but not loaded |
| `zen.tabs.ctrl-tab.ignore-essential-tabs` | false | Existing pref, still honored by the list builder |
| `zen.tabs.ctrl-tab.ignore-pending-tabs` | false | Existing pref, still honored by the list builder |

A user who never touched `show-pending-tabs` sees pending tabs. Only an explicit
`false` hides them.

## Geometry

Card and CSS share these numbers. Changing one without the other breaks the card.

| Part | Value |
| --- | --- |
| Card width | 400 px |
| Corner radius | 16 px |
| Padding | 8 px |
| Row height | 40 px |
| Row radius | 8 px |
| Icon to label gap | 10 px (rows sit back to back, with no gap between them) |
| Favicon | 16 px |
| Card height | rows times 40 px, capped at 360 px |
| Backdrop filter | `blur(42px) saturate(180%)`, the shared token |
| Card fill | `light-dark(rgba(248,248,252,0.97), rgba(40,41,45,0.97))`, denser than the shared glass fill because a popup has no page behind it |
| Card rim and shadow | A 0.5px rim and a `0 12px 28px` shadow, declared by the card rather than taken from the glass tokens |
| Show delay | 140 ms (`SHOW_AFTER_MS`) |

The card is a popup with its native max width and max height removed, so the
frosted panel can reach 400px and 360px. It enters with a 150ms scale and
opacity animation.

## Lifecycle

1. Ctrl+Tab starts a session and sets a 140ms timer.
2. If Ctrl is released before the timer fires, the card never exists and the
   selection moves immediately. This is the fast path, and it is why there is no
   flash on a quick tap.
3. Otherwise the card opens with the list painted and the first row selected.
4. The session ends on Enter, Escape, Ctrl release, or window blur.

The selected row is warmed with `gBrowser.warmupTab` when the session ends, so
the switch does not wait for a process.

## The list

`_buildList` collects tabs of the active space, ordered by most recent use. It
keeps essential tabs that belong to the space, glance tabs, and pending tabs
when allowed. `_fallbackList` runs when the filtered list is empty, so the card
never shows nothing while a space is loading.

A space switch started from inside the card sets `_spaceOverride`. The card then
builds the target space's list before the switch lands, which prevents an empty
label from flashing. After the switch, it compares the settled list with what it
painted and repaints only when the rows differ. `_sameTabs` compares only the
rows within the cap.

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

Digit handling accepts both `event.key` and `event.code` forms. A newer switch
invalidates an older one through `_transitionToken`.

## Pointer

The pointer is stale when the card opens. Moving it recomputes the hovered row.
Keyboard selection wins until the pointer moves, so a resting cursor over the
card cannot override Ctrl+Tab. Hover changes do not reorder the list, which is
fixed at open time.

## Close and unload

`W` on a normal tab closes it. On a pinned or essential tab it unloads the tab:
the controller removes it from the card's used set, detaches it, and calls
`_unloadTab`. The tab keeps its place in the space.

`Q` splits the list. Normal tabs are removed together through
`gBrowser.removeTabs`. Pinned and essential tabs are unloaded. The card marks
itself `closing` and plays the row exit, which is a height and opacity
transition, then closes.

Closing the last visible tab closes the card.

## Space switching inside the card

A digit switch does five things in order.

1. Builds the target list and the row count.
2. Takes a transition token and clears the pending swap timer.
3. Sets `_spaceOverride` to the target space and updates the header with the
   target space icon and label.
4. Paints the target rows with a directional slide, based on whether the target
   index is above or below the current one.
5. Calls `gZenWorkspaces.changeWorkspace` and, after it resolves, repaints only
   if the settled list differs.

A failed switch clears the override and logs the error.

## Edge cases

| Case | Behavior |
| --- | --- |
| One tab in the space | Card opens with one row. The fallback list can still show other tabs |
| Space restored but unloaded | Pending tabs appear by default |
| Two spaces side by side | Digit switch paints the target before the switch, no empty flash |
| Rapid digits | Each switch bumps the token. Older completions stop at the token check |
| Tab closed from another window | The next list build drops it. The card repaints if a visible row changed |
| Reduced motion | Row animations are CSS transitions. The platform setting is respected where the sheet defines a media query, not everywhere |

## Known limits

- Row count is capped twice, by `maxTabPreviews` and by the 360px card cap.
- The card does not search. Firefox's find and select-all keys are removed.
- Essential tabs from another space can appear when the space rules say they
  should, but they are not unloaded by `Q` in a space they do not belong to.
- The header shows the target space icon only for a digit switch. Otherwise it
  shows the active space.

## Verification

1. Tap Ctrl+Tab and release in under 140ms. The tab changes and no card appears.
2. Hold Ctrl+Tab. The card opens with the active space's tabs, MRU first.
3. Press Down, Up, Enter, then Escape. Selection and cancel behave.
4. Press W on a normal tab. It closes and the card stays. Press W on a pinned
   tab. It unloads and stays visible in the space.
5. Press Q. Normal tabs close, essentials unload, the card closes.
6. Press 2 while holding Ctrl. The space switches with a slide, and the card
   lists the new space's tabs.
7. Set `zen.ctrlTab.max-previews` to 4 and restart. Four rows appear. Values
   below 4 clamp to 4.
