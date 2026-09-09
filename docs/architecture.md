# Architecture and failure boundaries

```text
NSStatusItem + transient NSPopover (SwiftUI, LSUIElement)
  └─ BridgeController (MainActor)
       ├─ owned Process, no shell, bundled arm64 executable
       ├─ bounded nonblocking pipe readers → sanitised rotating logs
       ├─ usage JSONL → daily/model SQLite aggregates
       ├─ loopback health check with per-launch instance identifier
       └─ loopback /usage → GitHub quota UI

Compiled Bun backend
  ├─ pinned hyspace/copilot-bridge CLI (Git submodule)
  ├─ same start/auth routines and credential refresh
  ├─ byte-transparent upstream usage observer (no tee/read-ahead)
  ├─ parent-PID watchdog
  └─ build-stage-only middleware: LAN key + health identity
```

## Lifecycle

The menu-bar app owns one foreground service. It is not a double-forked daemon:
ownership and exit state remain observable. Login startup uses Apple's
`SMAppService.mainApp`; Homebrew users may alternatively use a user launch agent
through `brew services`. Never enable both.

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

## Resource bounds

- One in-flight health request and one quota request; timeouts and cancellation.
- Two nonblocking serial pipe readers; no Task per token, EOF cancellation,
  cancellation-safe FD closing, final output draining before exit publication.
- Last 200 diagnostic lines only, 64 KiB line framing, redaction and 8 KiB log truncation.
- Rotating logs (about 2 MiB active plus three historical files).
- SQLite WAL with checkpoints; UTC event timestamps aggregate by local date.
  Hourly maintenance retains two days of dedup IDs and 730 days of daily totals.
- SSE observation uses a 256 KiB event cap; JSON observation uses a 4 MiB cap.
  Oversized bodies are still forwarded unchanged but usage may be unavailable.
- No response clone/tee branch for model streaming. Downstream cancellation
  cancels the observer's upstream reader. A build-stage overlay also makes the
  CLI's normalizer pull-driven and cancellation-aware; malformed unterminated
  SSE frames are rejected above 8 MiB instead of buffering forever.

## Build overlays

`scripts/build-backend.py` copies the pinned CLI to a disposable staging tree and
applies anchored, fail-closed transformations:

1. Require a constant-time checked LAN access header when `CBM_LAN_KEY` is set.
2. Add a process-identity health endpoint.
3. Remove `Content-Length` and `Content-Encoding` from SSE bodies transformed by
   the CLI normalizer. Reusing upstream length after JSON reserialization corrupts
   the downstream HTTP body contract.
4. Exit on listener errors, and make the SSE normalizer propagate backpressure,
   cancellation and reader cleanup rather than draining in an eager start loop.

An upstream ref update that changes an expected anchor fails the build rather
than silently dropping the protection. The release executable embeds the staging
source and Bun runtime; there is no source checkout dependency on the end-user Mac.

## Security and accounting

OpenAI authentication remains owned by Codex; the adapter never forwards those
credentials to Copilot. The LAN key is stored in Keychain, passed through child
environment (not process argv), and removed from upstream requests by the CLI's
header allowlist. LAN HTTP still needs a trusted network; it is not TLS.

GitHub login uses the existing CLI device flow and 0600 credential cache.
The auth-only wrapper exits after success rather than leaving its refresh timer
alive forever. Expired and denied authorization have explicit UI states.

Telemetry records a request UUID, timestamp, model identifier, numeric usage,
HTTP status and completion category. It never stores a prompt or model output.
Missing usage is not treated as measured zero. Counts include actual retries and
bridge-internal model calls, not just user turns.

## Limits

GitHub's internal quota API may change. Credits are shown in returned units,
without guessing USD conversions. Quota failures do not stop the model service.
No historical CLI token reconstruction, no WebSocket support, no silent config
rewrites, and no claim of a formal memory-leak proof.
