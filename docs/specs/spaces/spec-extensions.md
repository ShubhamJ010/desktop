# Spec: per-space extension isolation

Platform: any. The enforcement hooks are in Gecko parent and content code, so the
behavior is not macOS specific.

## Purpose

Let a user turn an extension on for one space and off for another, and make the
choice real. Hiding a toolbar icon is not isolation. A disabled extension must
not see the space's tabs, inject into them, take its shortcuts there, or appear
in that space's menus.

## Files

| File | Role |
| --- | --- |
| `src/zen/urlbar/ZenSiteDataPanel.sys.mjs` | State manager, toolbar hiding, stack card, folder view |
| `src/zen/common/styles/zen-single-components.css` | Hidden toolbar items, stack geometry, folder chrome |
| `src/browser/base/content/zen-panels/site-data.inc` | Panel markup for the stack card and folder |
| `src/browser/components/extensions/parent/ext-menus-js.patch` | Drop context menu items from a disabled extension |
| `src/browser/components/extensions/parent/ext-browser-js.patch` | Refuse tab access and track stored tabs |
| `src/browser/components/extensions/parent/ext-commands-js.patch` | Ignore shortcuts of a disabled extension |
| `src/browser/modules/ExtensionContent-sys-mjs.patch` | Block content scripts, user scripts and styles |

## State

Two prefs hold the state. Both are JSON strings.

| Pref | Shape | Reader |
| --- | --- | --- |
| `zen.workspaces.disabled-extensions` | `{ spaceId: [extensionId, ...] }` | Parent process, panel, Gecko hooks |
| `zen.workspaces.browser-disabled-extensions` | `{ browserId: [extensionId, ...] }` | Content process injection |

The second pref exists because a content process has no tab object and no
workspace manager. It has a `browsingContext` and therefore a top `browserId`.
`syncBrowserSpaces` walks every browser window's tabs, maps each tab's
`zen-workspace-id` through the first pref, and writes the second one.

Neither pref is in `prefs/zen/sync.yaml`, so the list stays on the device.

## Manager API

`ZenSpaceExtensionsManager` is the only writer.

| Member | Behavior |
| --- | --- |
| `getDisabled(spaceId)` | Returns a copy of the space's list |
| `isDisabled(spaceId, extId)` | Boolean check |
| `setDisabled(spaceId, list)` | Replaces the list, deduplicates it, deletes the entry when the list is empty, writes JSON, notifies |
| `disable(spaceId, extId)` | Adds the id and notifies |
| `enable(spaceId, extId)` | Removes the id and notifies |
| `addChangeListener(fn)` | Registers a listener and returns an unsubscribe function |
| `updateAllWindows()` | Resyncs the browser map and toolbar visibility in every window |
| `syncBrowserSpaces()` | Rewrites the browserId map |
| `updateToolbarVisibility(win)` | Adds or removes `data-zen-space-hidden` |
| `getAllDisabled()` | Returns the whole `{ spaceId: [extId] }` map, or `{}` on a parse failure |
| `getExtIdFromElement(el)` | Resolves an element to an extension id, or null |

Every write catches a pref or JSON failure and logs it. Worse than throwing, the
panel keeps rendering from the previous list.

Changes fire `Services.obs` topic `zen-space-extensions-changed` and the
registered window listeners. The same path reloads the changed space's tabs: the
frontmost tab reloads immediately and the rest are marked for reload on
`TabSelect`. The panel listens to the topic.

## Toolbar hiding

`updateToolbarVisibility` scans `#nav-bar` children. For each button or item that
resolves to an extension id, it sets `data-zen-space-hidden="true"` when the id
is disabled in the active space, and removes the attribute otherwise.

`getExtIdFromElement` resolves an id in this order: `data-extensionid`,
`extension-id`, `dataset.extensionid`, `WebExtensionPolicy.getByWidgetId` on the
element id, then, for an element id ending in `-browser-action`, a comparison of
the prefix against the sanitized ids of active policies and then of the ids
already in the disabled map.

Elements inside the site data panel are skipped, and any stale hidden attribute
inside the panel is removed. The panel shows all extensions regardless of space.

CSS sets `display: none` on `[data-zen-space-hidden="true"]` items in the nav
bar, the tabs toolbar and the personal toolbar, so a hidden item leaves the
toolbar layout instead of only turning transparent.

## Gecko enforcement

Each hook reads the pref at call time. There is no cache to invalidate.

### Tab access

`TabManager.canAccessTab` returns false when the tab's space, taken from
`zen-workspace-id` or the active workspace, lists this extension. Background
scripts can then neither query nor message that tab. The same patch makes
`zen-empty-tab` invisible to the tracker, so the empty placeholder tab never
gets an id.

### Content injection

`ExtensionContent.sys.mjs` checks the top `browserId` before every injection in
two places: the initial content script probe and the user script and style
runner. A hit returns before the extension context exists, so no sandbox, no
script and no stylesheet.

### Shortcuts

`ext-commands.js` checks the active tab's space before it grants an active tab
permission or dispatches a command. A disabled extension's shortcut does
nothing, and Firefox's default shortcut handling does not reach the extension.

### Menus

`ext-menus.js` gates the context menu build on the same space lookup. A disabled
extension contributes no items to the page or tab menu in that space.

## Stack card and folder

The site data panel shows a stack card when the active space has disabled
extensions. `ZenDisabledStackRenderer` always lays out three slots.

| Disabled count | Left | Center | Right |
| --- | --- | --- | --- |
| 1 | Placeholder | Icon | Placeholder |
| 2 | Icon | Icon | Placeholder |
| 3 or more | Icon | Icon, raised | Icon |

Placeholders use `chrome://mozapps/skin/extensions/extensionGeneric.svg`. Cards
are 18px boxes with a 12px backdrop blur. Side cards rotate -13 and +13 degrees
behind a center card raised 1.5px, and hovering the stack widens the fan to 18
degrees and lifts the center. The geometry is fixed at three cards so the stack
never looks lopsided.

Clicking the stack opens the folder view in place. The container gets
`disabled-folder="true"`, the header shows the space icon and a "Disabled"
label, and the add-on button becomes a back button with a danger red glow and a
45 degree rotated glyph.

Two event details keep the panel alive. Click handling runs in the capture phase
and suppresses the extension's own popup, and the container sets
`closemenu="none"` so `PanelMultiView` does not dismiss the whole popup when the
folder closes.

In the folder, clicking a disabled extension enables it for the active space
and the tile leaves the folder. When the last one leaves, the panel returns to
the main view. The right-click item in the normal view is "Disable on this
Space". The folder has no separate enable item; the click is the action.

## Why not unload the extension

Disabling an extension for a space does not uninstall or disable it for the
profile. Options:

- Uninstalling per space would destroy data and settings.
- Toggling the profile-wide disabled state would restart extensions on every
  space change and disturb other windows.
- Blocking the surfaces an extension uses leaves its background page resident
  but unable to touch the space's tabs.

The last option is what ships. It is cheaper and reversible. The cost is memory
and any network work the background page does on its own schedule.

## Edge cases

| Case | Behavior |
| --- | --- |
| Extension disabled in two spaces | Each list is independent |
| Tabs open in the changed space | Frontmost reloads immediately; others reload on `TabSelect` |
| Space deleted | Its entry stays in the pref until the list is rewritten |
| Tab moved to another space | `syncBrowserSpaces` runs on change and rewrites the browser map. Existing content scripts are not retroactively removed |
| New window | `updateToolbarVisibility` runs per window |
| Malformed pref | Read falls back to `{}`. Writes log and abort |
| Extension without a toolbar button | Enforced by the Gecko hooks, absent from the stack card |
| Private window or spaces off | The space lookup returns nothing, so nothing is blocked |

## Known limits

- Content scripts already running when the disabled list changes are flushed by
  reloading the frontmost tab of that space. Other open tabs in the space are
  marked and reload when selected — no burst of reloads at change time.
  Background pages remain unaffected.
- Background pages remain loaded. A background page can still use APIs that do
  not go through tabs, menus or commands, such as storage or its own network
  requests.
- The browser map is rewritten on every change across all windows and tabs. On a
  profile with many windows this is a visible pref write.
- The stacking order of icons is by list order, not by most recently used.
- Hiding a toolbar item is instant; the surrounding items reflow with no
  animation.

## Verification

1. Disable extension A in space 1. Its toolbar icon disappears in space 1 and
   returns in space 2.
2. Open a page in space 1 with the extension's content script. Disable the
   extension in space 1: the frontmost page reloads and the script stops. Other
   tabs in the space reload when selected. Re-enable it: same path, script runs
   again.
3. Press the extension's shortcut in space 1. Nothing happens. Press it in space
   2 and the command runs.
4. Right-click a page in space 1. The extension's menu items are absent.
5. Open the site data panel in space 1. The stack shows the disabled extension.
   Click it. The folder opens. Click the tile. The extension is enabled and the
   tile leaves the folder.
6. Restart the browser. The list survives.
7. Open a second window on space 1. The icon is hidden there too.
