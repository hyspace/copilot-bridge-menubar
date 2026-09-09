# Verification record

This is an implementation/test checklist, **not** a claim that public publication
has completed.

## Verified locally

- Native build produces an arm64 `.app` and arm64 standalone backend.
- `codesign --verify --deep --strict` passes for the ad-hoc-signed local app.
- Main executable reports `0.1.0`; bundle records the exact CLI submodule SHA.
- CLI fork suite: **280 tests passed**.
- App native suite: **25 tests passed** (configuration/accounting, real owned
  process lifecycle against a fake backend, and offscreen rendering of our own UI).
- App/CLI event contract test passes.
- Staged CLI stream regression suite: **34 tests passed**.
- Fake GitHub auth: pending → success, denial, private credential file, natural
  one-shot process exit.
- Compiled backend integration: **103 fake model requests**, authentication,
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

| Requirement | Evidence / remaining work |
| --- | --- |
| Menu-bar only, arm64 | `LSUIElement`, accessory activation policy, `NSStatusItem`, transient popover; arm64 build/signature checks |
| Separate public MIT repo | Independent local Git repository, MIT, contribution/security docs and pinned fork; **public repository creation pending permission** |
| Daemon/runtime best practices | Bundled pinned Bun runtime, owned process handles, no shell, bounded streams/logs, deadlines, retry circuit breaker and native lifecycle tests |
| Preserve existing command behavior | Exact default arguments and environment-cleaning tests; no user-config writes |
| Local/LAN and port | Typed scope/port settings, validated arguments, Keychain-backed LAN key and backend route-auth tests |
| CLI options | `docs/cli-options.md`; write-config / interactive-terminal / token-printing options are explicitly fixed for this GUI product |
| Codex reference only | Clipboard-only reference generation, valid WebSocket key, OpenAI auth choice preserved |
| Tokens and GitHub credits | API-reported metadata aggregation; actual quota schema recognized without assuming monetary conversion |
| Device authorization | Existing fork auth routines, structured events, success/denial/deadline tests |
| Keep current bridge alive | All testing is isolated; no global process killing or port-based takeover |
| Homebrew formula and CI release | Workflows and formula generator ready; **hosted CI, public Release and installation from the public tap remain pending permission** |
| Commit CLI improvements in user's fork | Local CLI commit is referenced directly; no build-time source patches; **push to the public fork remains pending permission** |

## Publication order after explicit authorization

1. Push the CLI support commit to the user's `hyspace/copilot-bridge` fork.
2. Create/push the public MIT App repository.
3. Verify hosted CI against the now-public submodule commit.
4. Tag a release, verify asset publication and generated formula commit.
5. Install/test the formula from the published tap, without auto-starting it.

Do not mark the overall project complete until the pending public steps are
actually performed and checked. No Developer ID signing or notarization is claimed.
