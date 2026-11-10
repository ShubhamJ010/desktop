---
name: zen-browser-dev
description: Guide for developing, patching, building, and debugging Zen Browser in the zen-browser-desktop repository. Use when working on Zen Browser features, creating or updating Firefox engine patches, running surfer commands, fixing macOS Cocoa/MRC bugs, or managing CI builds.
---

# Zen Browser Development

## Architecture

- **`src/zen/`**: Native Zen additions (UI, CSS, JS/MJS modules, Cocoa wrappers in `src/zen/pip/` and `src/zen/gesture/`, gladiator, themes).
- **`src/**/*.patch`**: Git diffs applied onto upstream Firefox Gecko (`engine/`).
- **`engine/`**: Local clone/checkout of Mozilla Firefox source (git/hg).
- **`surfer.json`**: Product config, target Firefox release version, branding profiles.

## Core Workflows

### 1. Patch Management (`surfer`)
- **Download engine**: `npm run download`
- **Apply patches to engine**: `npm run import` (`ffprefs` -> `import:dumps` -> `surfer import`)
- **Export changes from engine**: `npm run export`
- **Sync preferences**: `npm run ffprefs`

> [!IMPORTANT]
> When editing an existing `src/**/*.patch` manually, verify context lines against the exact Firefox version declared in `surfer.json` (`version.version`). Ensure line numbers and variable names (`v =>` vs `video =>`) match upstream exactly.

### 2. macOS Native & Cocoa Development
- **MRC (Manual Reference Counting)**: Gecko Cocoa code builds with MRC, not ARC.
  - Do NOT use `__weak` (compiler error).
  - Use `[_window retain]` before async dispatch or `CATransaction` completion blocks, and `[window release]` inside the block.
  - Always guard UI calls with `if (window.isVisible)` to avoid operating on deallocated windows.
  - Gecko's `mozjemalloc` poisons freed memory with `0xe5`. `EXC_BAD_ACCESS` on addresses like `0x0065e5e5...` indicates a Use-After-Free (UAF).

### 3. Local Installation & Profile Safety
- **Profile Location**: `~/Library/Application Support/zen/` (independent of `/Applications/Zen*.app`).
- **Safe App Update**:
  1. Gracefully close browser: `osascript -e 'tell application "Zen SJ" to quit'` (flushes session/tabs).
  2. Backup or replace `/Applications/Zen SJ.app`.
  3. Clear quarantine & sign: `xattr -cr "/Applications/Zen SJ.app" && codesign --force --deep -s - "/Applications/Zen SJ.app"`.

## Detailed References
See [REFERENCE.md](REFERENCE.md) for full commands, CI dispatch, and debugging workflows.
