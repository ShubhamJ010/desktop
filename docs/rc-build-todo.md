# RC build TODO

RC builds use pure Ubuntu Linux runners, codesign with `rcodesign`, and distribute via Homebrew Cask.
Updates are managed by Homebrew (`brew upgrade --cask zen-browser-sj`).

## Architecture

- **Build:** Cross-compiled on `ubuntu-24.04` (thin-LTO Gecko build).
- **Codesign:** `rcodesign` on `ubuntu-24.04` with fork self-signed P12 identity (`ZEN_CODESIGN_P12_BASE64`), always passing production entitlements (mic, camera, JIT) — hardened runtime without them makes macOS TCC silently deny mic/camera prompts.
- **Branches:** `fork/dev` is kept a 1:1 mirror of upstream dev (force-pushed by the `mirror` job on every run, build or not); `sync` merges `fork/dev` into `zen-enh-main` only when a build is needed.
- **Versions:** dispatch accepts fork-local suffixed versions (`1.24.3b.1`) — the upstream base tag is resolved by stripping trailing numeric dot-segments and must exist as an upstream git tag; changelog comes from that tag. Cron skips when any release for the same base tag (plain or suffixed) already exists; manual dispatches dedupe on exact version only (`force=true` rebuilds).
- **Distribution:** GitHub Releases (`zen-rc-macos-aarch64.zip`) + Homebrew Cask (`ShubhamJ010/homebrew-tap/Casks/zen-browser-sj.rb`).
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
brew install --cask zen-browser-sj

# Update
brew update
brew upgrade --cask zen-browser-sj
```

## Trigger Build

```bash
gh workflow run build-macos-rc.yml --repo ShubhamJ010/desktop --ref zen-enh-main
```

`workflow_dispatch` inputs: `version` (upstream tag, or a fork-local suffix like `1.24.3b.1`), `branch` (default `zen-enh-main`), `force` (rebuild an existing release).
