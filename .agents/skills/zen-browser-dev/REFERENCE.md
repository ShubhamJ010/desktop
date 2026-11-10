# Zen Browser Development Reference

## Repository Organization

```
zen-browser-desktop/
├── configs/branding/        # Branding configs (release, twilight, sj)
├── docs/                    # Zen architecture & contribution documentation
├── scripts/                 # Utility scripts (update_ff.py, run_tests.py, mar_sign.sh)
├── src/
│   ├── zen/                 # Core Zen Browser implementations
│   │   ├── components/      # Browser frontend components
│   │   ├── pip/             # Native macOS PiP controller & spring physics
│   │   ├── gesture/         # macOS gesture animations & capsule overlays
│   │   └── ui/              # Themes, layout modifications, chrome JS/CSS
│   └── **/*.patch           # Diffs applied directly onto Firefox source
├── surfer.json              # Version configurations, URLs, branding definitions
└── .github/workflows/       # CI workflows (build.yml, build-macos-sj.yml)
```

---

## Patching Engine Code

Zen patches Mozilla Firefox source code using git patches stored in `src/`.

### Testing a Patch Locally Against Mozilla Source
When updating or adding a patch without pulling the full engine:
```bash
# 1. Fetch upstream file matching version in surfer.json (e.g. 159.0.1)
curl -s -L "https://hg.mozilla.org/releases/mozilla-release/raw-file/FIREFOX_159_0_1_RELEASE/toolkit/actors/PictureInPictureChild.sys.mjs" > /tmp/target.mjs

# 2. Test if git apply recognizes the patch context
git apply --check --verbose src/toolkit/actors/PictureInPictureChild-sys-mjs.patch
```

### Exporting Patches After Modifying `engine/`
If you made modifications directly inside `engine/`:
```bash
npm run export
```
This inspects git changes within `engine/` and writes updated `.patch` files into `src/`.

---

## macOS Native Cocoa Code & MRC Rules

Cocoa source files in `src/zen/pip/` and `src/zen/gesture/` (such as `ZenPiPController.mm` and `ZenSwipeController.mm`) are compiled by Mozilla's build system with **Manual Reference Counting (MRC)**.

### Common Pitfalls
1. **ARC vs MRC**:
   - `__weak` is disallowed and triggers a compile error.
   - Using `__unsafe_unretained` does NOT retain objects in blocks. If the referenced object (e.g. `NSWindow`) is closed/released before the block or timer runs, accessing it causes a Use-After-Free crash.
2. **Safe Block Pattern**:
   ```objc
   NSWindow *window = [_window retain];
   [CATransaction begin];
   [CATransaction setCompletionBlock:^{
     if (window.isVisible) {
       [window invalidateShadow];
     }
     [window release];
   }];
   [CATransaction commit];
   ```
3. **Crash Diagnostics**:
   - `mozjemalloc` poisons deallocated heap memory with `0xe5`.
   - An exception address `0x0065e5e5e5e5e5f0` in `objc_msgSend` indicates the receiver's `isa` pointer was overwritten with `0xe5e5e5e5e5e5e5e5`.
   - Register `x1` in `objc_msgSend` contains the selector pointer. Query it with `sel_getName((SEL)x1)` to locate the faulting method.

---

## GitHub Actions & CI Triggering

### Custom macOS Workflow (`build-macos-sj.yml`)
To trigger a new build on a custom branch:
```bash
gh workflow run build-macos-sj.yml --ref <branch-name> --repo <owner>/desktop -f arch=aarch64
```

### Checking CI Status
```bash
gh run list --repo <owner>/desktop --workflow=build-macos-sj.yml
gh run view <run-id> --log-failed --repo <owner>/desktop
```

### Fast Artifact Downloading with `aria2c`
To download the generated DMG artifact at multi-connection speeds:
```bash
# Get redirect blob URL
TOKEN=$(gh auth token)
REDIRECT_URL=$(curl -sI -H "Authorization: Bearer $TOKEN" "https://api.github.com/repos/<owner>/desktop/actions/artifacts/<artifact-id>/zip" | grep -i "^location:" | awk '{print $2}' | tr -d '\r')

# Download with aria2c
aria2c -x 16 -s 16 -k 1M "$REDIRECT_URL" -o Zen-macOS-aarch64.zip
```
