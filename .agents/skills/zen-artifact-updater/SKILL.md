---
name: zen-artifact-updater
description: Download GitHub Actions build artifacts at maximum speed using aria2c from ANY workflow run (URL or ID) across any repository and safely install/upgrade over an existing running Zen Browser instance on macOS with zero data loss. Use when downloading CI artifacts with aria2, upgrading Zen Browser or Zen SJ from CI builds, or installing new builds without losing tabs, cookies, or profile data.
---

# Zen Artifact Updater

Download macOS CI build artifacts via `aria2c` multi-connection chunks from **any** GitHub Actions run URL or run ID, gracefully stop the running Zen browser instance to save tabs/session, replace the `.app` bundle, ad-hoc sign, and relaunch.

## Quick Start (Accepts ANY Action Run)

```bash
# Pass ANY GitHub Actions run URL directly:
python3 .agents/skills/zen-artifact-updater/scripts/update_zen_artifact.py https://github.com/ShubhamJ010/desktop/actions/runs/42798527985

# Or pass just the run ID:
python3 .agents/skills/zen-artifact-updater/scripts/update_zen_artifact.py 42798527985

# Or pass a different repository + run ID:
python3 .agents/skills/zen-artifact-updater/scripts/update_zen_artifact.py https://github.com/zen-browser/desktop/actions/runs/123456789

# Or auto-detect the latest successful run on a specific branch:
python3 .agents/skills/zen-artifact-updater/scripts/update_zen_artifact.py --repo ShubhamJ010/desktop --branch feat/meet-auto-pip
```

## How It Works

1. **Flexible Run Parsing**: Accepts a full GitHub Actions URL (`https://github.com/<owner>/<repo>/actions/runs/<id>`), a raw run ID, or auto-detects the latest successful run.
2. **Artifact Detection**: Inspects the workflow run's artifacts via GitHub API and automatically picks the appropriate macOS DMG/app bundle (e.g. `Zen-SJ-macOS-aarch64`, `zen-macos-aarch64`).
3. **High-Speed Download with `aria2c`**: Follows GitHub's 302 redirect to Azure Blob storage with user auth, then opens 16 parallel connections with `aria2c` for maximum download speed.
4. **Session-Safe Shutdown (Zero Data Loss)**: Issues `tell application "Zen SJ" to quit` via AppleScript so Gecko flushes session and tab state to `~/Library/Application Support/zen/` before the binary is touched.
5. **In-Place Replacement & Signing**: Mounts the DMG, replaces `/Applications/Zen SJ.app`, strips quarantine (`xattr -cr`), signs with `codesign --force --deep -s -`, and relaunches.
