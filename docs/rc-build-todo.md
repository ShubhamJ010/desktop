# RC build TODO

RC builds use pure Ubuntu Linux runners, codesign with `rcodesign`, and distribute via Homebrew Cask.
Updates are managed by Homebrew (`brew upgrade --cask zen-browser-rc`).

## Architecture

- **Build:** Cross-compiled on `ubuntu-24.04` (thin-LTO Gecko build).
- **Codesign:** `rcodesign` on `ubuntu-24.04` with fork self-signed P12 identity (`ZEN_CODESIGN_P12_BASE64`).
- **Distribution:** GitHub Releases (`zen-rc-macos-aarch64.zip`) + Homebrew Cask (`ShubhamJ010/homebrew-tap/Casks/zen-browser-rc.rb`).
- **In-app Updater:** Disabled via `distribution/policies.json` inside the app bundle.

## Secrets

In repository `ShubhamJ010/desktop`:
- `ZEN_CODESIGN_P12_BASE64`: Base64 encoded self-signed code-signing certificate (P12).
- `ZEN_CODESIGN_P12_PASSWORD`: Password for the P12 certificate.
- `TAP_GITHUB_TOKEN` (optional): GitHub PAT with write access to `ShubhamJ010/homebrew-tap` for auto-bumping Cask version and sha256 on release.

## Install & Update

```bash
# Add tap and install
brew tap ShubhamJ010/tap
brew install --cask zen-browser-rc

# Update
brew update
brew upgrade --cask zen-browser-rc
```

## Trigger Build

```bash
gh workflow run build-macos-rc.yml --repo ShubhamJ010/desktop --ref zen-enh-main
```
