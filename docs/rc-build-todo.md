# RC build TODO, 2026-11-16

Status when this was written: run `43753085405` on `fc738ed6`. Detect and Sync passed, PGO stage 1 in progress.
Keychain trust for `Zen Fork Signing` is done.

## Done already

- [x] Fork MAR key generated, cert committed, 3 secrets set.
- [x] Self-signed codesign cert, 2 secrets set.
- [x] Update host repo `ShubhamJ010/ShubhamJ010.github.io` created, Pages live.
- [x] Deploy key scoped write access, `UPDATE_HOST_SSH_KEY` set.
- [x] Workflow `build-macos-rc.yml` with PGO, codesign, MAR, release, update.xml.
- [x] Sync job merges upstream `dev`, patch check, push. Proven twice.
- [x] Credential leak fixed in `fc738ed6`, checkouts no longer persist token.
- [x] Keychain trust for the self-signed cert.

## Tomorrow, in order

1. [ ] Watch the current run.
   `gh run view 43753085405 --repo ShubhamJ010/desktop`
   First failure risk: `Collect signmar` in the `build` job.

2. [ ] Disable cron until the pipeline is proven.
   `gh workflow disable build-macos-rc.yml --repo ShubhamJ010/desktop`
   Re-enable after one publish and one successful app update.

3. [ ] If signmar is missing, add a fallback job that builds `tools/update-packaging` natively on Linux and uploads `signmar` plus its NSS libs. Current build fails hard when absent.

4. [ ] If `macos-26` never starts, switch `pgo-profile` and `package` to `macos-15`. Upstream uses `macos-26`, so confirm before changing.

5. [ ] If stage 3 and package pass, do the first publish run.
   `gh workflow run build-macos-rc.yml --repo ShubhamJ010/desktop --ref zen-enh-main -f version=1.24.2b -f publish_update=true -f force=true`

6. [ ] Verify the update host.
   `curl -s https://shubhamj010.github.io/updates/browser/Darwin_aarch64-gcc3/release/update.xml`
   Check `displayVersion="1.24.2b"`, `URL` points at `github.com/ShubhamJ010/desktop/releases/download/1.24.2b/macos.mar`, and `hashValue` matches the release asset.

7. [ ] Install the RC app once.
   Download the release zip, put `Zen.app` in `/Applications`, run `xattr -dr com.apple.quarantine /Applications/Zen.app`, open it.

8. [ ] Grant permissions once (screen recording, mic, notifications, Full Disk Access). Confirm they survive the next update.

9. [ ] Gate signing. Put `package` and `publish` behind a GitHub Environment with required reviewers, so unreviewed upstream code is not signed automatically.

10. [ ] Hardening, low urgency. Pin third-party actions to commit SHAs, pin GitHub SSH host keys instead of `ssh-keyscan`, add branch protection on `zen-enh-main`.

11. [ ] Off-machine backups: `~/Desktop/zen-mar-keys`, `~/Desktop/zen-signing`, including the deploy key. Losing the MAR key forces one reinstall. Losing the codesign key forces one permission reset.

12. [ ] Decide version scheme. Builds use the upstream release tag while code is merged `dev`, so rebuilding the same version cannot auto-update. Options: one build per upstream release, or a suffix scheme.

## Versioning for fork-only changes

Do not wait for an upstream release. App version is what the updater compares, and surfer writes `displayVersion` into `browser/config/version.txt`, so the build version and the update manifest always match.

- Upstream base: `1.24.2b`.
- First fork respin: `1.24.2b.1`.
- Later respins: `1.24.2b.2`, `1.24.2b.3`.
- Next upstream release `1.24.3b` is already greater, so it wins on its own.

Build with `-f version=1.24.2b.1`. The release tag, MAR URL and `appVersion` all use that string.

SemVer build metadata (`1.24.2b+1`) is ignored by the Mozilla version comparator. Debian style (`1.24.2b-1`) is not a Mozilla version format. Use the numeric fourth part.

If the installed app is already `1.24.3b`, base the respin on `1.24.3b`, not on `1.24.2b`, or the updater sees an older version.

## Future RC, repeatable, no new code

1. Put the changes on `zen-enh-main`. Sync merges upstream `dev` on its own.
2. Pick the version. Latest release `1.24.3b` plus your changes is `1.24.3b.1`. Another respin is `1.24.3b.2`. New upstream release needs no suffix.
3. Dispatch the existing workflow with that version. No script, no local build.
4. Wait for the release and `update.xml`. Installed RC updates itself through MAR.
5. Fresh machine only: download the release zip once, clear quarantine, open. Later versions arrive by update.

Use the same command every time:

```
gh workflow run build-macos-rc.yml --repo ShubhamJ010/desktop --ref zen-enh-main \
  -f version=1.24.3b.1 -f publish_update=true
```

Rules that keep this from becoming debt:

- Version is data passed to the workflow, never a code edit.
- Never add a per-release script. One workflow, one command.
- `updater.py` stays Twilight-only. It disables updates, RC needs them.
- If a step repeats three times, add a workflow input, not a local script.
- Fork values stay inline in the workflow, never committed to `surfer.json`.

## Limits to remember

- arm64 only.
- No notarization. Fresh downloads need one manual open or quarantine clear.
- Same upstream version rebuilt does not update installed apps.
- Sync conflicts fail the run and leave the branch untouched.
