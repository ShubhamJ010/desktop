# macOS enhancement specs

Specs for the native macOS work merged through [PR #5](https://github.com/ShubhamJ010/desktop/pull/5) on `zen-enh-main`.

Each folder holds one feature's behavior contract. The "why" lives in `docs/decisions/` as an ADR. The product summary lives in [PRD.md](../PRD.md).

## Index

| Spec | Feature | Code |
| --- | --- | --- |
| [pip/spec.md](pip/spec.md) | Floating PiP card. Corner snap, edge stash, fling, pinch zoom, keyboard focus | `src/zen/pip/` |
| [pip/spec-meet.md](pip/spec-meet.md) | Google Meet call controls inside the PiP window | `src/toolkit/components/pictureinpicture/`, `src/toolkit/actors/PictureInPictureChild-sys-mjs.patch`, `src/zen/media/ZenMediaController.sys.mjs` |
| [ctrl-tab/spec.md](ctrl-tab/spec.md) | Recent tabs card on Ctrl+Tab, scoped to the active space | `src/browser/components/tabbrowser/content/browser-ctrlTab-js.patch`, `src/browser/themes/shared/tabbrowser/ctrlTab-css.patch` |
| [swipe/spec.md](swipe/spec.md) | Back/forward trackpad swipe with capsule indicator and history sheet | `src/zen/gesture/`, `src/browser/base/content/browser-gestureSupport-js.patch`, `src/widget/cocoa/nsCocoaWindow-mm.patch` |
| [spaces/spec-extensions.md](spaces/spec-extensions.md) | Enable or disable extensions per space, including Gecko enforcement | `src/zen/urlbar/ZenSiteDataPanel.sys.mjs`, `src/browser/components/extensions/parent/*.patch`, `src/browser/modules/ExtensionContent-sys-mjs.patch` |
| [spaces/spec-swipe-haptics.md](spaces/spec-swipe-haptics.md) | Trackpad detent feedback while swiping between spaces | `src/zen/spaces/ZenSpacesSwipe.mjs`, `src/zen/spaces/ZenSpaceManager.mjs` |
| [glass/spec.md](glass/spec.md) | Shared frosted glass tokens for new chrome surfaces | `src/zen/common/styles/zen-ardia-glass.css` |

## How to read a spec

Each spec lists its prefs, its feel constants, its state machine, the failure modes the code handles, and the files that must change together. When a spec and the code disagree, the code is right and the spec needs a fix.
