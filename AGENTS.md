# Zen PiP POC Guidelines for Agents

- **No Local Builds**: Never build Gecko locally on the host Mac. Always dispatch the GitHub Actions workflow (`.github/workflows/build-pip-poc.yml`) on your feature branch.
- **Upstream Hygiene**: Keep `dev` 100% clean and fast-forwarded to upstream `origin/dev`. Work strictly in feature branches (e.g. `feat/ardia-pip`).
- **Side-by-Side Safety & Installation Rules**:
  - **NEVER touch, modify, replace, or launch `/Applications/Zen.app`**. That is the user's primary daily-driver browser installed via Homebrew.
  - **Always install CI build artifacts exclusively to `/Applications/Zen (Custom).app`**:
    ```bash
    hdiutil attach build-artifacts/Zen-macOS-aarch64.dmg -nobrowse -readonly
    rm -rf "/Applications/Zen (Custom).app"
    ditto "/Volumes/Zen/Zen.app" "/Applications/Zen (Custom).app"
    xattr -cr "/Applications/Zen (Custom).app"
    # Prevent Mozilla background auto-updater loop from breaking renamed bundle:
    sed -i '' 's|URL=https://updates.zen-browser.app/.*|URL=http://127.0.0.1/no-update|g' "/Applications/Zen (Custom).app/Contents/Resources/application.ini"
    rm -rf "/Users/sj/Library/Caches/Mozilla/updates/Applications/Zen (Custom)"
    # Re-sign ad-hoc after modifying bundle and bundle rename:
    codesign --force --deep --sign - "/Applications/Zen (Custom).app"
    hdiutil detach "/Volumes/Zen"
    ```
  - When testing or launching dev builds, **ONLY launch `/Applications/Zen (Custom).app`**:
    ```bash
    open -n "/Applications/Zen (Custom).app"
    ```
- **MRC Memory Model**: Gecko macOS code in `src/zen/pip/` compiles with `-fno-objc-arc`. Retain/release and lifecycle cleanup must be handled manually. Test syntax with `clang++ -fsyntax-only -fno-objc-arc -std=c++17 -Isrc/zen/pip`.

