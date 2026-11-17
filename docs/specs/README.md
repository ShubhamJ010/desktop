# macOS enhancement specs

Specs for the native macOS work merged through
[PR #5](https://github.com/ShubhamJ010/desktop/pull/5) on `zen-enh-main`.

Each folder holds the behavior contract for one feature. The "why" lives in
`docs/decisions/` as an ADR. The product summary lives in [PRD.md](PRD.md).

New ADRs: [0002](../decisions/0002-trackpad-swipe-in-two-layers.md),
[0003](../decisions/0003-pip-motion-math-in-headers.md),
[0004](../decisions/0004-pip-zoom-through-owned-live-resize.md),
[0005](../decisions/0005-pip-focus-without-raising-the-browser.md),
[0006](../decisions/0006-ctrl-tab-per-space-mru-card.md),
[0007](../decisions/0007-meet-controls-through-the-child-actor.md),
[0008](../decisions/0008-single-glass-token-sheet.md). Extension isolation keeps
its original [ADR-001](../decisions/0001-per-space-extension-isolation-and-stack-ui.md).

## Index

| Spec | Feature | Code |
| --- | --- | --- |
| [pip/spec.md](pip/spec.md) | Floating PiP card. Corner snap, edge stash, fling, pinch zoom, keyboard focus | `src/zen/pip/` |
| [pip/spec-meet.md](pip/spec-meet.md) | Google Meet call controls inside the PiP window | `src/toolkit/components/pictureinpicture/`, `src/toolkit/actors/PictureInPictureChild-sys-mjs.patch` |
| [ctrl-tab/spec.md](ctrl-tab/spec.md) | Recent tabs card on Ctrl+Tab, scoped to the active space | `src/browser/components/tabbrowser/content/browser-ctrlTab-js.patch`, `src/browser/themes/shared/tabbrowser/ctrlTab-css.patch` |
| [swipe/spec.md](swipe/spec.md) | Back/forward trackpad swipe with capsule indicator and history sheet | `src/zen/gesture/`, `src/browser/base/content/browser-gestureSupport-js.patch`, `src/widget/cocoa/nsCocoaWindow-mm.patch` |
| [spaces/spec-extensions.md](spaces/spec-extensions.md) | Enable or disable extensions per space, including Gecko enforcement | `src/zen/urlbar/ZenSiteDataPanel.sys.mjs`, `src/browser/components/extensions/parent/*.patch`, `src/browser/modules/ExtensionContent-sys-mjs.patch` |
| [spaces/spec-swipe-haptics.md](spaces/spec-swipe-haptics.md) | Trackpad detent feedback while swiping between spaces | `src/zen/spaces/ZenSpacesSwipe.mjs`, `src/zen/spaces/ZenSpaceManager.mjs` |
| [glass/spec.md](glass/spec.md) | Shared frosted glass tokens for new chrome surfaces | `src/zen/common/styles/zen-ardia-glass.css` |

## Not covered here

CI workflows, MAR signing, release naming and other repository chores from the
same PR are build plumbing. They live in `.github/workflows/` and
`docs/rc-build-todo.md`, and this spec set does not restate them.

## Status and platform

All specs are draft, matching the branch state at the time of writing.

The PiP, swipe and haptics work is Cocoa only. Ctrl+Tab, extension isolation and
the glass sheet are platform neutral, though only macOS was exercised.

## How to read a spec

Each spec lists the prefs it reads, the constants that define its feel, the
state machine, the failure modes the code already handles, and the places that
must change together. When a spec and the code disagree, the code is right and
the spec needs a fix.

## Verification

Files under `src/` with a `.patch` suffix are applied to the vendored Gecko tree
during the build. Changes to those files need a CI build. Chrome JS, XHTML and
CSS can be hotpatched into the local Twilight app; see `.agents/skills/zen-dev-loop/SKILL.md`.
