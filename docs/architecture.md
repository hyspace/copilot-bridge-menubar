# Architecture and failure boundaries

```text
NSStatusItem + transient NSPopover (SwiftUI, LSUIElement)
  └─ BridgeController (MainActor)
       ├─ owned Process, no shell, bundled arm64 executable
       ├─ bounded nonblocking pipe readers → sanitised rotating logs
       ├─ usage JSONL → daily/model token and billing aggregates
       ├─ loopback health check with per-launch instance identifier
       └─ loopback /usage → daily account-balance snapshots + quota UI

Compiled Bun backend
  ├─ pinned hyspace/copilot-bridge CLI (Git submodule)
  ├─ same start/auth routines and credential refresh
  ├─ byte-transparent upstream usage observer (no tee/read-ahead)
  ├─ parent-PID watchdog
  └─ pinned CLI health identity and usage events
```

Swift targets keep pure configuration/accounting (`BridgeCore`), process ownership
and OS integrations (`BridgeRuntime`), reusable menu content (`BridgeUI`), and the
application entry point (`BridgeMenuBar`) separate. The runtime's backend/home
injection is internal to the module for tests; release users cannot select an
arbitrary executable through an environment variable.

## Lifecycle

The menu-bar app owns one foreground service. It is not a double-forked daemon:
ownership and exit state remain observable. Login startup uses Apple's
`SMAppService.mainApp`, controlled by the app's login-item setting.

Stop sends SIGTERM to the exact owned `Process`. After five seconds it may send
SIGKILL only if that same `Process` is still running. No name matching, port-based
killing, global signals or takeover of an already-running CLI.

If the UI crashes or is SIGKILLed, the backend checks its parent every two seconds
and exits when the parent changes. Unexpected exits have exponential backoff and
a circuit breaker (five retries per ten minutes). Port conflicts are not retried
by killing somebody else's listener.

Health checks are bounded and verify a per-launch identity. A timeout alone does
not prove death and does not kill a busy model request. Starting and device-auth
states have deadlines; the user can explicitly cancel.
Receiving auth success clears the device prompt without treating it as expiry.
The startup clock resets after a human finishes device authorization. Even the
initial auth request (before any device code arrives) has a bounded deadline.
Port preflight uses `SO_REUSEADDR` to distinguish recent TIME_WAIT connections
from a live listener; actual occupied ports remain protected.

## Resource bounds

- One in-flight health request and one quota request; timeouts and cancellation.
- Two nonblocking serial pipe readers; no Task per token, EOF cancellation,
  cancellation-safe FD closing, final output draining before exit publication.
- Last 200 diagnostic lines only, 64 KiB line framing, redaction and 8 KiB log truncation.
- Rotating logs (about 2 MiB active plus three historical files).
- SQLite WAL with checkpoints; UTC event timestamps aggregate by local date.
  Hourly maintenance retains two days of dedup IDs and 730 days of daily totals.
- A 26-week native activity grid displays token totals and server-reported request
  credits. Remaining account quota is a separate card; see `activity.md`.
- Retry-response observation is capped at one second and 4 MiB. Repeated stream
  snapshots replace counters rather than being counted as additional charges.
- SSE observation uses a 256 KiB event cap; JSON observation uses a 4 MiB cap.
  Oversized bodies are still forwarded unchanged but usage may be unavailable.
- No response clone/tee branch for model streaming. Downstream cancellation
  cancels the observer's upstream reader. The pinned CLI normalizer is also pull-driven and cancellation-aware; malformed unterminated
  SSE frames are rejected above 8 MiB instead of buffering forever.

## Upstream ownership and packaging

General bridge improvements are committed in the `hyspace/copilot-bridge` fork:

1. Health instance identity, with keyless local/LAN access.
2. Optional authenticated JSONL usage/auth events; no model content is retained.
3. Content header correction after SSE normalization, backpressure and cancellation.
4. Deterministic listener-error exit and one-shot auth with non-overlapping refresh.
5. Valid Codex WebSocket configuration and preservation of explicit OpenAI auth.

`scripts/build-backend.py` copies the pinned source unchanged into a disposable
build directory. It defines the CLI's supported compile-time version constant,
then bundles the CLI and the small parent-watchdog entry point with Bun.
There are no build-time source replacements. End users do not need Bun or a checkout.

## Security and accounting

OpenAI authentication remains owned by Codex; the adapter never forwards those
credentials to Copilot. LAN requests have no additional key or incoming authentication requirement.
LAN HTTP must stay on a trusted network; it is neither authenticated nor TLS.

GitHub login uses the existing CLI device flow and 0600 credential cache.
The CLI auth command exits after success rather than leaving its refresh timer
alive forever. Expired and denied authorization have explicit UI states.

The parent creates a fresh private event-channel token per launch. Only matching
JSONL records can change auth/accounting state; untrusted error text cannot spoof
a supervisor event merely by using the same line prefix.

Telemetry records a request UUID, timestamp, model identifier, numeric token usage and raw nano-AIU billing,
HTTP status and completion category. It never stores a prompt or model output.
Missing usage is not treated as measured zero. Counts include actual retries and
bridge-internal model calls, not just user turns.

## Limits

GitHub's internal quota API may change. Credits are shown in returned units,
without guessing USD conversions. Quota failures do not stop the model service.
No historical CLI token reconstruction, no WebSocket support, no silent config
rewrites, and no claim of a formal memory-leak proof.
