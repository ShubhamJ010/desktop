# Zen macOS Guidelines for Agents

- **No Local Builds**: Never build Gecko locally on the host Mac. Always dispatch the GitHub Actions workflow (`.github/workflows/build-macos-sj.yml`) on your branch.
- **Branch Hygiene**: `zen-enh-main` is the main fork trunk / default branch. Keep `dev` clean and synced to `origin/dev`. Work in feature branches and fast-forward merge.
- **MRC Memory Model**: Gecko macOS code in `src/zen/pip/` compiles with `-fno-objc-arc`. Retain/release and lifecycle cleanup must be handled manually. Test syntax with `clang++ -fsyntax-only -fno-objc-arc -std=c++17 -Isrc/zen/pip`.
- **Artifacts**: Download and hot-install CI build artifacts via `.agents/skills/zen-artifact-updater/scripts/update_zen_artifact.py <run_url_or_id>`.


