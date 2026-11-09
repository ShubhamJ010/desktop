# Zen PiP POC Guidelines for Agents

- **No Local Builds**: Never build Gecko locally on the host Mac. Always dispatch the GitHub Actions workflow (`.github/workflows/build-pip-poc.yml`) on your feature branch.
- **Branch Hygiene**: Keep `dev` 100% clean and fast-forwarded to `origin/dev`. `zen-enh-main` is the main fork trunk. `feat/ardia-pip` is base POC (do not touch). Work strictly in feature branches.
- **MRC Memory Model**: Gecko macOS code in `src/zen/pip/` compiles with `-fno-objc-arc`. Retain/release and lifecycle cleanup must be handled manually. Test syntax with `clang++ -fsyntax-only -fno-objc-arc -std=c++17 -Isrc/zen/pip`.


