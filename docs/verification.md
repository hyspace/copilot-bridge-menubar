# Verification and acceptance boundaries

The local build's `build/acceptance.md` is the run-specific evidence record: source
revisions, test counts, artifact paths/checksums and known limitations. Do not infer
live-account support from a mock or from an upstream HTTP 200.

## Four separate evidence levels

1. **Unit/contract fixtures:** routing, auth lifecycle, metadata, event framing,
   search evidence rules, namespace restoration, source usage, migrations and config
   recovery. These establish implementation behavior, not a subscription entitlement.
2. **Live local API:** opt-in scripts in the core send synthetic text/functions,
   red/blue test images, a synthetic tool-result screenshot and a freeform patch.
   They check lifecycle/usage/IDs and client disconnect. No user screenshot or real
   workspace content is sent. No file patch is executed by that direct API suite.
3. **Real Codex engine:** an opt-in harness uses an isolated temporary `CODEX_HOME`
   and synthetic read-only workspace. It proves a supplied file tool executes and
   its result returns through the gateway, including Codex's default tool list.
   This is test infrastructure, not the production inference architecture.
4. **Full desktop/account acceptance:** real Codex subscription, browser/device
   login through the packaged app, account quotas, long tasks/compaction, and desktop
   Computer Use must be tested explicitly. The first three levels are not a claim
   that every Codex App feature or model has the same quality as the official stack.

## Current local findings

The synthetic local checks and isolated Codex file-tool task passed. The service
reported a runtime context that changed while its model ID stayed the same, validating
why discovery uses a capability fingerprint rather than a hardcoded model table.

Studio-native search did **not** return paired executed-tool evidence on the tested
endpoint, even with its documented search-only selection/event header. Plain text,
URLs and XML-like tool markup were rejected as evidence. The guarded adapter keeps
ordinary coding usable and reports an explicit error when an unavailable search is
invoked. Codex's default cached-only search cannot be silently turned into live
Studio search. A usable local native-search path is still an acceptance limitation.

**Not verified:** a live subscribed Codex account, full desktop Computer Use, immediate
server/GPU cancellation, every auxiliary desktop endpoint, long-running cross-provider
history/compaction, or parity of model quality. Opaque history is deliberately
rejected when the selected provider cannot read it.

## Repeatable local checks

```sh
(cd vendor/copilot-bridge && bun test && bun run typecheck)
bun test backend
swift test --disable-sandbox
python3 scripts/test-english.py
python3 scripts/test-icon.py
python3 scripts/build-backend.py
python3 scripts/test-auth.py
python3 scripts/integration-test.py
```

After packaging, run `verify-app.py` and the config suite with
`CBM_CONFIG_TEST_BINARY` pointing at the packaged helper. These checks use temporary
homes/fake credentials and ephemeral ports, not the user's live service. UI tests
render only this app's own hidden/offscreen views; they do not capture the desktop.

The existing regression suite retains Copilot retry accounting, zero/missing billing,
large final usage frames, sibling counters, Chat usage tails, cancellation, 413
responses and source-owned authentication. Native tests retain exact/missing/empty
config restoration, concurrent writes, corrupt snapshots/manifests, OS locking,
crash recovery, safe model-selection restore, process ownership, button edges,
gutter hover coverage and icon template behavior.

## Local package only

The artifact must contain arm64 native/backend executables, the app icon, license
notices and exact recorded source revisions. Ad-hoc signature verification does not
mean Apple notarization. Do not run the historical release or Homebrew-installation
scripts for this acceptance build. No public artifact, cask or existing installation
is changed by verification.
