# Codex Bridge architecture

```text
Codex App (task, history, context, permissions and workstation tools)
  └─ one local Responses endpoint and source-qualified model catalog
       ├─ Codex subscription → independent Pi OAuth → native official Responses
       ├─ Copilot → existing model-specific compatibility/search pipeline
       └─ Local → loaded-model discovery → Unsloth Responses
                    ├─ namespace/replay adaptation
                    └─ guarded Studio-native hosted-search seam

Native menu app
  ├─ owned Bun child, parent-death watchdog and instance health identity
  ├─ private /bridge/* management channel, source status and quota polling
  ├─ dedicated stdio Keychain broker (separate from UI/log/event pipes)
  ├─ authenticated usage events → provider/day/model SQLite totals
  ├─ one total-token heatmap + compact source rows
  └─ explicit Codex config toggle → locked, journaled, verified atomic edits
```

The product supports Codex App only. There is no inner Codex CLI/agent for inference.
The installed engine is used only by an opt-in isolated verification harness.
Legacy CLI adapters remain in the core to preserve Copilot regressions, not to
expand the native app's supported-client scope.

## What is shared and what is not

Shared code provides bounded HTTP/JSON/SSE framing, cancellation, source routing,
namespace identity restoration, usage observation and source-qualified catalogs.
Copilot's ID corrections, fallback conversions, reasoning handling and search
configuration remain inside its adapter. Official Responses preserve unknown
fields, encrypted reasoning, server tools and event bytes; they are not run
through Copilot's protocol repairs.

Local Responses keep native text/function/image behavior. A namespace adapter
flattens model-facing names and restores Codex-facing names/call IDs. Only the
supported custom `apply_patch` grammar is accepted. Unknown tools/files/history
are rejected rather than silently discarded. Readable reasoning and prior search
metadata are explicitly represented in replayable history.

The local hosted-search seam translates only a declared hosted search tool into
an internal function. It intercepts that function, asks the **same Studio endpoint**
to execute its own allowlisted search, and merges one Responses lifecycle. It never
executes a workstation function or silently uses a cloud search account. Ordinary
output remains pull-driven. Actual search results require paired native tool events;
plain model text is not execution evidence. Cached-only search, unsupported filters,
extra tool requests and pending approvals fail explicitly. Mixed client/search calls
retain the result in visible history while waiting for Codex to execute client tools.

## Discovery and routing

`/v1/models?client_version=...` returns Codex metadata; plain `/v1/models` returns
the OpenAI-style list. Model IDs are qualified with `codex/`, `copilot/`, `local/`.
Provider failures are isolated. Catalog reads have bounded upstream waits, and a
forced refresh arriving during another refresh is queued rather than lost.

Local discovery does not request model loads. It filters loaded conversational
models and uses reported runtime context, not the model's theoretical maximum.
The fingerprint includes context, quantization/build and declared capabilities.
Before local inference, discovery is checked again. There is no atomic residency
lease in this API: an upstream operator changing models concurrently remains a
race that must be considered during acceptance.

A task's established source can route unqualified background names. Without such
a binding, old bare names are accepted only for a Copilot-only catalog. Missing
routes fail; they are never redirected to another billing source. The in-memory
binding is bounded/expiring and is not a replacement for Codex task persistence.

## Independent authentication

Codex OAuth uses `@earendil-works/pi-ai` 0.85.1 authentication methods only. Browser
and device-code interaction is initiated in the app. The backend neither imports
Codex App's credentials nor reads/writes its `auth.json`. A private native stdio
broker stores this account in Keychain and holds a lifetime OS lock. Refresh,
login commit and logout are serialized; cancellation cannot resurrect a login.
Tokens must persist before a refreshed credential is returned. The final Keychain
login commit is briefly non-cancellable: Cancel is disabled, and a stale cancellation
request receives an explicit conflict rather than falsely reporting success.
Disconnect queues removal after any in-flight commit. A 401 retry may
refresh once but cannot switch accounts mid-request.

Caller authentication, cookies and account IDs are never copied to a different
upstream. Official headers are source-owned. Local keys are keyed to the normalized
endpoint; changing the host/port/path cannot leak a previous key. A missing required
key disables Local discovery without preventing other sources from starting.

GitHub retains the shared Bridge credential-cache/device flow. Reauthorization
requires stopping competing owners of that GitHub cache. The independently managed
Codex Keychain account is not that shared cache.

## Native lifecycle and resource boundaries

- One owned service Process, no shell. No port/name-based kill or takeover.
- SIGTERM, then bounded SIGKILL only for that same owned Process; parent-death
  watchdog; bounded crash retries; health failures do not terminate a busy task.
- Private control requests are serialized; health, status and per-source quotas
  have independent bounded/cancellable tasks.
- Keychain IPC is bounded (including pending commands) and has no credential logs.
- Two bounded pipe readers, authenticated event channel, last 200 UI log lines,
  four rotating files of approximately 2 MiB each.
- SSE/JSON parsing and observations are bounded. The legacy byte observer does not
  tee/read ahead. Hosted loops record each actual upstream attempt once.
- Source status and cached account quotas are separate. Old observations are never
  stamped with a new refresh time when a network request fails.
- SQLite transaction/backup details are documented in [activity](activity.md).

## Configuration and packaging

The transactional toggle is the only native action that writes Codex config.
Start, quit, installation and status polling do not rewrite it. Existing backup
ownership identifiers stay unchanged despite the product rename. See
[configuration](configuration.md) for source-qualified model restoration.

The app vendors an exact core commit. Packaging copies that source unchanged,
bundles the standalone Bun runtime, includes dependency licenses and records source
provenance. It refuses dirty/unrecorded vendor contents. This branch produces a
local review artifact only; it does not install or publish it.

## Explicit acceptance limits

Server declarations are not a model-quality or Computer Use certification. A
subscription login is not proof that every model/tool is entitled. Full desktop
Computer Use, a live subscribed Codex account, and server/GPU-side cancellation
must be verified separately from synthetic API and fixture tests. Internal upstream
interfaces can change independently of this app.
