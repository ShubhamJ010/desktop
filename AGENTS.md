# Zen PiP POC Guidelines for Agents

- **No Local Builds**: Never build Gecko locally on the host Mac. Always dispatch the GitHub Actions workflow (`.github/workflows/build-pip-poc.yml`) on your feature branch.
- **Upstream Hygiene**: Keep `dev` 100% clean and fast-forwarded to upstream `origin/dev`. Work strictly in feature branches (e.g. `feat/ardia-pip`).
- **Side-by-Side Safety**: Never touch `/Applications/Zen.app`. This POC installs as `/Applications/Zen (Custom).app` using `appId: zen-custom` to isolate browser profiles.
- **MRC Memory Model**: Gecko macOS code in `src/zen/pip/` compiles with `-fno-objc-arc`. Retain/release and lifecycle cleanup must be handled manually. Test syntax with `clang++ -fsyntax-only -fno-objc-arc -std=c++17 -Isrc/zen/pip`.
