# Verification

## Runtime coverage

- Native build produces an arm64 `.app` and arm64 standalone backend.
- `codesign --verify --deep --strict` passes for the ad-hoc-signed local app.
- The executable version matches the release tag, and the bundle records the
  exact CLI submodule SHA.
- CLI fork suite: **334 tests passed**.
- App native suite: **25 tests passed** (configuration/accounting, real owned
  process lifecycle against a fake backend, and offscreen rendering of our own UI).
- App/CLI event contract test passes.
- Staged CLI stream regression suite: **34 tests passed**.
- Fake GitHub auth: pending → success, denial, private credential file, natural
  one-shot process exit.
- Compiled backend integration: **103 fake model requests**, keyless access,
  model catalog, 413 and stream-interruption accounting, conflicting listener
  handling and parent-death cleanup.
- Native lifecycle tests include repeated restarts and FD-count bounds, genuine
  occupied-port protection, TIME_WAIT reuse, SIGTERM-ignoring owned child cleanup,
  auth-init deadlines and final auth-event draining.
- Forged stdout lines without the per-launch channel token cannot alter auth state.
- All tests use temporary HOME / fake credentials and non-4142 ports. The existing
  real bridge is not taken over, stopped, restarted or sent model requests.

## Package checks

- `scripts/test-cask.py` checks Ruby syntax, package metadata, checksum immutability,
  rejected invalid inputs, atomic updates and downgrade prevention, entirely offline.
- `scripts/verify-app.py` checks a real app bundle, version, arm64 executables,
  code signatures and recorded backend revision. It runs only `--version`, never
  the UI or model service.
- `scripts/test-homebrew.sh` installs from the public tap on a clean macOS host.
  It verifies `/Applications/Copilot Bridge.app` is the actual application rather
  than a symlink, and that an existing listener on port 4142 is unchanged.
- Installation does not modify settings, register a login service, strip quarantine
  attributes or disable macOS security checks.

## CI and release evidence

The [CI workflow](https://github.com/hyspace/copilot-bridge-menubar/actions/workflows/ci.yml)
runs runtime tests and packages the app.
The [installation workflow](https://github.com/hyspace/copilot-bridge-menubar/actions/workflows/homebrew.yml)
checks the published app independently.
The [release workflow](https://github.com/hyspace/copilot-bridge-menubar/actions/workflows/release.yml)
tests, packages, publishes checksums, updates Homebrew metadata and verifies
installation. See the matching workflow run and checksum file for each
[published release](https://github.com/hyspace/copilot-bridge-menubar/releases).
