# Verification record

This records implementation tests and the verified public **v0.1.1** release.
The release completed on **2026-09-09 UTC (2026-09-08 PDT)**. No Developer ID
signing or Apple notarization is claimed.

## Public release verified

- Public MIT repositories: `hyspace/copilot-bridge` and
  `hyspace/copilot-bridge-menubar`.
- Dependabot PRs [#1](https://github.com/hyspace/copilot-bridge-menubar/pull/1)
  and [#2](https://github.com/hyspace/copilot-bridge-menubar/pull/2) were reviewed
  and merged. They update only pinned GitHub Actions; no app/runtime behavior changes.
- Release tag `v0.1.1` points to App commit
  `08d101ad314785c447b4fbda15e90f85769c3e7a`.
- CLI submodule pin and fork main:
  `7561efce6a315cbd0cb688daf373dcf892b1bb68`, including the protocol compatibility merge.
- [Merged-main CI](https://github.com/hyspace/copilot-bridge-menubar/actions/runs/34305238660)
  passed all test, build, signature and artifact-upload steps.
- [Release workflow](https://github.com/hyspace/copilot-bridge-menubar/actions/runs/34305465129)
  passed tests, packaging, publication, formula update, installation from the public tap,
  `brew test`, executable version validation and `codesign --verify --deep --strict`.
- [Release assets](https://github.com/hyspace/copilot-bridge-menubar/releases/tag/v0.1.1):
  `Copilot-Bridge-arm64.zip` and `SHA256SUMS`.
- Archive SHA256, verified against the GitHub asset digest, downloaded checksum file
  and generated formula:
  `507b2c7015ca3872263f7f2735cd3901def11267fdc095ef556fae2278dec39d`.
- Formula publication commit: `761cba6f250b7efedcaf31b14160230dffea6971`.
  The public tap installs **0.1.1** without starting a service.
- The initial 0.1.0 release found a Homebrew archive-staging issue: copying staging
  metadata into the signed app root invalidated its seal. The formula now installs
  only `Contents` when Homebrew enters the archive's sole app directory. The
  signature check remains strict, and the complete 0.1.1 release passes.

## Verified locally

- Native build produces an arm64 `.app` and arm64 standalone backend.
- `codesign --verify --deep --strict` passes for the ad-hoc-signed local app.
- Default development builds report `0.1.0`; the published executable reports
  `0.1.1`. The bundle records the exact CLI submodule SHA.
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
- Formula generation is checked offline for Ruby syntax, real SHA shape, repository
  validation and downgrade prevention. This test does not install or publish.
- All tests use temporary HOME / fake credentials and non-4142 ports. The existing
  real bridge is not taken over, stopped, restarted or sent model requests.

## Requirement map

| Requirement | Verified evidence |
| --- | --- |
| Menu-bar only, arm64 | `LSUIElement`, accessory activation policy, `NSStatusItem`, transient popover; arm64 build/signature checks |
| Separate public MIT repo | Published independent repository, MIT, contribution/security docs and pinned fork; public release evidence above |
| Daemon/runtime best practices | Bundled pinned Bun runtime, owned process handles, no shell, bounded streams/logs, deadlines, retry circuit breaker and native lifecycle tests |
| Preserve existing command behavior | Exact default arguments and environment-cleaning tests; no user-config writes |
| Local/LAN and port | Typed scope/port settings, validated arguments, keyless backend health/catalog tests |
| CLI options | `docs/cli-options.md`; write-config / interactive-terminal / token-printing options are explicitly fixed for this GUI product |
| Codex reference only | Clipboard-only reference generation, valid WebSocket key, OpenAI auth choice preserved |
| Tokens and GitHub credits | API-reported metadata aggregation; actual quota schema recognized without assuming monetary conversion |
| Device authorization | Existing fork auth routines, structured events, success/denial/deadline tests |
| Keep current bridge alive | All testing is isolated; no global process killing or port-based takeover |
| Homebrew formula and CI release | Hosted CI and complete v0.1.1 release passed, including installation/test from the public tap |
| Commit CLI improvements in user's fork | Published CLI commit is referenced directly; no build-time source patches; merged protocol compatibility and supervisor fixes are on fork main |

## Publication order for future releases

1. Push the CLI support commit to the user's `hyspace/copilot-bridge` fork.
2. Create/push the public MIT App repository.
3. Verify hosted CI against the now-public submodule commit.
4. Tag a release, verify asset publication and generated formula commit.
5. Install/test the formula from the published tap, without auto-starting it.

Repeat all public release checks for each new version; do not infer installation
success from a successful build alone.

The CLI fork main includes `fix/codex-protocol-compatibility` via merge `7561efc`.
Keyless LAN access is intentional. Only the private parent/child diagnostic channel
uses an internal token; clients need no additional header.
