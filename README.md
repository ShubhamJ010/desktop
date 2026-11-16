<!--
   - This Source Code Form is subject to the terms of the Mozilla Public
   - License, v. 2.0. If a copy of the MPL was not distributed with this
   - file, You can obtain one at http://mozilla.org/MPL/2.0/.
   -->
<!-- TODO: Get a job -->
<img src="./docs/assets/zen-dark.svg" width="100px" align="left">

### `Zen Browser`

[![Downloads](https://img.shields.io/github/downloads/zen-browser/desktop/total.svg)](https://github.com/zen-browser/desktop/releases)
[![Crowdin](https://badges.crowdin.net/zen-browser/localized.svg)](https://crowdin.com/project/zen-browser)
[![Zen Release builds](https://github.com/zen-browser/desktop/actions/workflows/build.yml/badge.svg?branch=stable)](https://github.com/zen-browser/desktop/actions/workflows/build.yml)

Zen is a firefox-based browser with the aim of pushing your productivity to a new level!

<div flex="true">
  <a href="https://zen-browser.app/download">
    Download
  </a>
  •
  <a href="https://zen-browser.app">
    Website
  </a>
  •
  <a href="https://docs.zen-browser.app">
    Documentation
  </a>
  •
  <a href="https://zen-browser.app/release-notes/latest">
    Release Notes
  </a>
</div>

### Fork features

This fork adds native macOS gestures, tab switching, and workspace isolation on top of Zen Browser:

- Trackpad swipe navigation: rubber-band swipe indicator, hold to browse session history, reverse-swipe cancellation, and haptic detents for navigation and workspace switching.
- Picture-in-picture window management: harmonic spring corner snapping, fling to edge-stash, 120 Hz pinch-to-zoom with freeze-frame scaling, floating window keyboard focus, and Google Meet controls for mic, camera, and hang up.
- Per-workspace extension isolation: disable extensions per workspace, hide their toolbar icons, block background tab access and shortcut keys, and prevent content script injection. Includes a 3-card stack indicator in the site data panel to manage disabled extensions.
- Vertical tab switcher: replaces the default Ctrl+Tab grid with a centered frosted glass list filtered to the current workspace, instant switching on release, space switching with number keys 1 to 9, and single-key actions to close or unload tabs.

### Installation (macOS arm64)

Install this fork via Homebrew Cask:

```bash
# Add tap
brew tap ShubhamJ010/tap

# Trust tap (if Homebrew tap trust is enforced)
brew trust ShubhamJ010/tap

# Install Zen Browser
brew install --cask zen-browser-sj
```

To update to future releases:

```bash
brew upgrade --cask zen-browser-sj
```

### Contributing

If you'd like to report a bug, please do so on our [GitHub Issues page](https://github.com/zen-browser/desktop/issues/) and for feature requests, you can use [GitHub Discussions](https://github.com/zen-browser/desktop/discussions).

Zen is an open-source project, and we welcome contributions from the community! Please take a look at the [contribution guidelines](./docs/contribute.md) before getting started!

#### Partners

Thanks to all the [sponsors](https://zen-browser.app/#sponsors) of Zen for their support and contributions, including:

<a href="https://blacksmith.sh">
  <img src="./docs/assets/blacksmith-yellow.png" width="350px"/>
</a>
