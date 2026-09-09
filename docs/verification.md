# Verification

## Runtime coverage

- Native build produces an arm64 `.app` and arm64 standalone backend.
- `codesign --verify --deep --strict` passes for the ad-hoc-signed local app.
- The executable version matches the release tag, and the bundle records the
  exact CLI submodule SHA.
- CLI fork suite: **356 tests passed**.
- App native suite: **61 tests passed** (configuration/accounting, real owned
  process lifecycle against a fake backend, and offscreen rendering of our own UI).
- App/CLI event contract test passes.
- Staged CLI stream regression suite: **34 tests passed**.
- Fake GitHub auth: pending → success, denial, private credential file, natural
  one-shot process exit.
- Compiled backend integration: **108 fake model requests**, keyless access,
  model catalog, billing-only/zero/missing charges, 413 and stream-interruption accounting, conflicting listener
  handling and parent-death cleanup.
- Usage regression tests include 700K-character completion payloads, bounded
  oversized-frame rejection, sibling usage fields, final Chat usage-only chunks,
  cancellation after a terminal event, exact counter arithmetic and inclusive
  native Anthropic cache accounting. No live account is used for these tests.
- Native lifecycle tests include repeated restarts and FD-count bounds, genuine
  occupied-port protection, TIME_WAIT reuse, SIGTERM-ignoring owned child cleanup,
  auth-init deadlines and final auth-event draining.
- Forged stdout lines without the per-launch channel token cannot alter auth state.
- Activity tests cover daylight-saving transitions, daily aggregation, cache
  accounting, old database migration, quota persistence and out-of-order snapshots.
- Failed quota refreshes preserve the original balance timestamp. Tooltip tests
  verify token counts and request credit costs independently of account balances.
- Pointer sweeps across every row and column cover tile gutters, boundaries and
  future-date exclusion without changing visual dimensions.
- Billing tests cover old events/databases, zero versus unknown, malformed fields,
  fractional units, duplicate IDs, retries and independent token/billing collection.
- Offscreen previews cover the English interface in light and dark appearance.
- Pointer click events verify empty button edges, selected/unselected tabs,
  disclosure headers, toggle labels and disabled actions in an offscreen window.
  No global mouse events or screen captures are used. Hover/pressed feedback
  state is tested independently; system hover transitions require a real pointer.
- Quota presentation tests cover reported/derived/unknown/zero/unlimited amounts
  and invalid percentages. Pixel checks verify gray-left/green-right bars in both
  appearances. Remaining-percentage tests preserve an exact-amount tooltip.
  Menu-bar icon tests enforce template rendering and the app mark's hollow nodes.
- All tests use temporary HOME / fake credentials and non-4142 ports. The existing
  real bridge is not taken over, stopped, restarted or sent model requests.

## Package checks

- `scripts/test-cask.py` checks Ruby syntax, package metadata, checksum immutability,
  rejected invalid inputs, atomic updates and downgrade prevention, entirely offline.
- `scripts/test-english.py` checks owned interface strings, help and documentation.
- `scripts/test-icon.py` validates the macOS icon container and all ten standard/
  Retina images. Build checks verify that the application declares and bundles it.
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
