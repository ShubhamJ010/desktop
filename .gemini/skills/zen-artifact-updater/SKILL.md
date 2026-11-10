---
name: zen-artifact-updater
description: Download GitHub Actions build artifacts at maximum speed using aria2c and safely install/upgrade over an existing running Zen Browser instance on macOS with zero data loss. Use when downloading CI artifacts with aria2, upgrading Zen Browser or Zen SJ from CI builds, or installing new builds without losing tabs, cookies, or profile data.
---

# Zen Artifact Updater

Download macOS CI build artifacts via `aria2c` multi-connection chunks, gracefully stop the running Zen browser instance to save tabs/session, replace the `.app` bundle, ad-hoc sign, and relaunch.

## Quick Start (Automated Script)

Run the bundled updater script:

```bash
# Auto-detect latest successful run on ShubhamJ010/desktop, download via aria2c, and install over /Applications/Zen SJ.app
python3 .agents/skills/zen-artifact-updater/scripts/update_zen_artifact.py

# Or specify an exact run ID
python3 .agents/skills/zen-artifact-updater/scripts/update_zen_artifact.py --run-id 42798527985
```

## Step-by-Step Manual Workflow

### 1. Resolve Artifact Direct URL
GitHub Actions artifact endpoints return a 302 redirect to Azure Blob storage. Resolve the final redirect location:

```bash
TOKEN=$(gh auth token)
# Get artifact metadata
gh api repos/ShubhamJ010/desktop/actions/runs/<RUN_ID>/artifacts

# Resolve redirect URL
REDIRECT_URL=$(python3 -c '
import urllib.request, subprocess
token = subprocess.check_output(["gh", "auth", "token"]).decode().strip()
req = urllib.request.Request("https://api.github.com/repos/ShubhamJ010/desktop/actions/artifacts/<ARTIFACT_ID>/zip",
                             headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"})
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl): return None
opener = urllib.request.build_opener(NoRedirect)
try: opener.open(req)
except urllib.error.HTTPError as e: print(e.headers["Location"])
')
```

### 2. High-Speed Download with `aria2c`
```bash
echo "$REDIRECT_URL" > /tmp/zen_artifact_url.txt
aria2c -x 16 -s 16 -k 1M -i /tmp/zen_artifact_url.txt -d /tmp -o zen_artifact.zip
```

### 3. Graceful Shutdown (Zero Data Loss)
Firefox/Zen profiles reside in `~/Library/Application Support/zen/`. To avoid session loss, flush and save tab states cleanly using AppleScript instead of `kill -9`:

```bash
osascript -e 'tell application "Zen SJ" to quit'
# Wait until process exits cleanly
while pgrep -f "Zen SJ.app/Contents/MacOS" >/dev/null; do sleep 1; done
```

### 4. Mount DMG, Replace App, Strip Quarantine & Ad-Hoc Sign
```bash
unzip -o /tmp/zen_artifact.zip -d /tmp/zen_dmg
hdiutil attach /tmp/zen_dmg/*.dmg -mountpoint /tmp/zen_mnt -nobrowse -readonly

# Replace installed app
rm -rf "/Applications/Zen SJ.app"
cp -R "/tmp/zen_mnt/Zen SJ.app" "/Applications/Zen SJ.app"

# Strip quarantine attribute & ad-hoc sign to avoid Gatekeeper block
xattr -cr "/Applications/Zen SJ.app"
codesign --force --deep -s - "/Applications/Zen SJ.app"

# Cleanup
diskutil eject /tmp/zen_mnt
rm -rf /tmp/zen_dmg /tmp/zen_artifact.zip /tmp/zen_artifact_url.txt
```

### 5. Relaunch
```bash
open -a "/Applications/Zen SJ.app"
```
