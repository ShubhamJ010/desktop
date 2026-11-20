# Spec: per-space extension isolation

Platform: any. The enforcement hooks are in Gecko parent and content code, so the behavior is not macOS specific.

## Purpose

Let a user turn an extension on for one space and off for another, and make the choice real. Hiding a toolbar icon is not isolation. A disabled extension must not see the space's tabs, inject into them, take its shortcuts there, or appear in that space's menus.

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

Two JSON-string prefs.

| Pref | Shape | Reader |
| --- | --- | --- |
| `zen.workspaces.disabled-extensions` | `{ spaceId: [extensionId, ...] }` | Parent process, panel, Gecko hooks |
| `zen.workspaces.browser-disabled-extensions` | `{ browserId: [extensionId, ...] }` | Content process injection |

The second pref exists because a content process has no tab object and no workspace manager, only a `browsingContext` and a top `browserId`. `syncBrowserSpaces` walks every browser window's tabs, maps each tab's `zen-workspace-id` through the first pref, and writes the second.

Neither pref is in `prefs/zen/sync.yaml`, so the list stays on the device.

## Manager API

`ZenSpaceExtensionsManager` is the only writer.

| Member | Behavior |
| --- | --- |
| `getDisabled(spaceId)` | Copy of the space's list |
| `isDisabled(spaceId, extId)` | Boolean check |
| `setDisabled(spaceId, list)` | Replaces the list, deduplicates, deletes the entry when empty, writes JSON, notifies |
| `disable(spaceId, extId)` | Adds the id and notifies |
| `enable(spaceId, extId)` | Removes the id and notifies |
| `addChangeListener(fn)` | Registers a listener, returns an unsubscribe function |
| `updateAllWindows()` | Resyncs the browser map and toolbar visibility in every window |
| `syncBrowserSpaces()` | Rewrites the browserId map |
| `updateToolbarVisibility(win)` | Adds or removes `data-zen-space-hidden` |
| `getAllDisabled()` | Whole `{ spaceId: [extId] }` map, or `{}` on a parse failure |
| `getExtIdFromElement(el)` | Element to extension id, or null |

Every write catches a pref or JSON failure and logs it; the panel keeps rendering the previous list.

Changes fire `Services.obs` topic `zen-space-extensions-changed` and the window listeners. The same path reloads the changed space's tabs: the frontmost now, the rest on `TabSelect`. The panel listens to the topic.

## Toolbar hiding

`updateToolbarVisibility` scans `#nav-bar` children. Each button or item that resolves to an extension id gets `data-zen-space-hidden="true"` when the id is disabled in the active space; the attribute is removed otherwise.

`getExtIdFromElement` resolves in this order: `data-extensionid`, `extension-id`, `dataset.extensionid`, `WebExtensionPolicy.getByWidgetId` on the element id, then, for an id ending in `-browser-action`, the prefix against sanitized active policy ids and then against ids already in the disabled map.

Elements inside the site data panel are skipped, and stale hidden attributes there are removed. The panel shows all extensions regardless of space.

CSS sets `display: none` on `[data-zen-space-hidden="true"]` items in the nav bar, tabs toolbar and personal toolbar, so a hidden item leaves the layout instead of only turning transparent.

## Gecko enforcement

Each hook reads the pref at call time. No cache to invalidate.

### Tab access

`TabManager.canAccessTab` returns false when the tab's space (from `zen-workspace-id` or the active workspace) lists this extension. Background scripts can then neither query nor message that tab. The same patch hides `zen-empty-tab` from the tracker, so the placeholder never gets an id.

### Content injection

`ExtensionContent.sys.mjs` checks the top `browserId` before injection in two places: the initial content script probe and the user script and style runner. A hit returns before the extension context exists, so no sandbox, script or stylesheet.

### Shortcuts

`ext-commands.js` checks the active tab's space before granting an active tab permission or dispatching a command. A disabled extension's shortcut does nothing, and Firefox's default handling does not reach the extension.

### Menus

`ext-menus.js` gates the context menu build on the same space lookup. A disabled extension contributes no items to the page or tab menu in that space.

## Stack card and folder

The site data panel shows a stack card when the active space has disabled extensions. `ZenDisabledStackRenderer` always lays out three slots.

| Disabled count | Left | Center | Right |
| --- | --- | --- | --- |
| 1 | Placeholder | Icon | Placeholder |
| 2 | Icon | Icon | Placeholder |
| 3 or more | Icon | Icon, raised | Icon |

Placeholders use `chrome://mozapps/skin/extensions/extensionGeneric.svg`. Cards are 18px boxes with a 12px backdrop blur. Side cards rotate -13 and +13 degrees behind a center card raised 1.5px; hover widens the fan to 18 degrees and lifts the center. Three fixed cards keep the stack balanced.

Clicking the stack opens the folder view in place. The container gets `disabled-folder="true"`, the header shows the space icon and a "Disabled" label, and the add-on button becomes a back button with a danger red glow and a 45 degree rotated glyph.

Two details keep the panel alive. Click handling runs in the capture phase and suppresses the extension's own popup, and the container sets `closemenu="none"` so `PanelMultiView` does not dismiss the popup when the folder closes.

In the folder, clicking a disabled extension enables it for the active space and the tile leaves the folder. When the last one leaves, the panel returns to the main view. The normal view's right-click item is "Disable on this Space". The folder has no separate enable item; the click is the action.

## Why not unload the extension

Per-space disabling does not uninstall or disable the extension for the profile.

- Uninstalling per space would destroy data and settings.
- Toggling the profile-wide state restarts extensions on every space change and disturbs other windows.
- Blocking the surfaces an extension uses leaves its background page resident but unable to touch the space's tabs.

The last option ships. It is cheaper and reversible. The cost is memory and any network work the background page does on its own schedule.

## Edge cases

| Case | Behavior |
| --- | --- |
| Extension disabled in two spaces | Independent lists |
| Tabs open in the changed space | Frontmost reloads now; others on `TabSelect` |
| Space deleted | Its entry stays in the pref until the list is rewritten |
| Tab moved to another space | `syncBrowserSpaces` runs on change. Existing content scripts are not retroactively removed |
| New window | `updateToolbarVisibility` runs per window |
| Malformed pref | Read falls back to `{}`. Writes log and abort |
| Extension without a toolbar button | Enforced by the Gecko hooks, absent from the stack card |
| Private window or spaces off | The space lookup returns nothing, so nothing is blocked |

## Known limits

- Changing the list reloads the frontmost tab of that space. Other open tabs are marked and reload when selected, so there is no reload burst. Background pages are unaffected.
- Background pages stay loaded. They can still use storage, their own network requests, and APIs that skip tabs, menus and commands.
- The browser map is rewritten on every change across all windows and tabs. On many windows that is a visible pref write.
- Icon stacking order is list order, not most recent use.
- Hiding a toolbar item is instant; surrounding items reflow without animation.

## Verification

1. Disable extension A in space 1. Its icon disappears in space 1 and returns in space 2.
2. Open a page in space 1 with the extension's content script. Disable it in space 1: the frontmost page reloads and the script stops. Other tabs reload when selected. Re-enable: same path, script runs again.
3. Press the extension's shortcut in space 1. Nothing happens. In space 2 the command runs.
4. Right-click a page in space 1. The extension's menu items are absent.
5. Open the site data panel in space 1. The stack shows the disabled extension. Click it. The folder opens. Click the tile. The extension is enabled and the tile leaves the folder.
6. Restart the browser. The list survives.
7. Open a second window on space 1. The icon is hidden there too.
