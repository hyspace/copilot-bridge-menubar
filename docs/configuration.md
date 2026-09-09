# Codex App configuration switching

## User workflow

1. Authorize GitHub and start the Bridge service.
2. Turn on **Use in Codex** in Overview, or **Use Copilot Bridge in Codex** in Settings.
3. Fully quit and reopen **Codex App** to apply the saved route; closing its window is not a restart.
4. To return to the previous provider, turn the switch off and restart Codex App.

The switch is a configuration operation, not a service restart or login/logout
action. It does not quit Codex App, restart running tasks, change authentication
files or stop an existing Bridge process. Routing persists when this app quits.
Switch routing off before uninstalling if Codex should stop using Bridge.

The product supports Codex App only. The underlying service may contain other
protocol adapters, but they are not supported client workflows for this app.

## Target and managed fields

The target is `config.toml` in the Codex home. The default is `~/.codex`;
an absolute `CODEX_HOME` inherited when Bridge launches is respected. An invalid
relative override disables switching rather than silently targeting a different
home. The resolved target path is displayed in Settings.

The app changes the root `model_provider` selector and adds its own
`model_providers.copilot_bridge_app` block. That block uses:

- the loopback Bridge endpoint on the selected port, including in LAN mode;
- Responses transport with `supports_websockets = false`;
- `requires_openai_auth = true`, preserving OpenAI sign-in.

Model selection, reasoning preferences, other providers, project settings and
authentication files are not rewritten. Select a model available to the active
provider in Codex App. No placeholder model is inserted.

Current [OpenAI configuration documentation](https://developers.openai.com/codex/config-reference/)
defines `openai` as the default provider and provider configuration as user-level
settings. [Configuration precedence](https://developers.openai.com/codex/config-basic/)
also includes explicit launch/profile overrides. This switch does not rewrite
profile files or attempt to override launch arguments. Recognized legacy
in-file profile provider overrides are refused before enabling.

Other Codex clients sharing the same home can read this config too; the file is
not an app-private preference. That does not expand this product's supported
client scope beyond Codex App.

## Backups and lossless restoration

Each configuration change gets an immutable transaction directory under:

```text
~/Library/Application Support/CopilotBridgeMenuBar/CodexConfig/<target-hash>/
  state.json
  lock
  <transaction-id>/
    manifest.json
    before.toml
    after.toml
```

The manifest records the canonical target path, timestamp, operation, file
existence, permissions, hashes and ownership information needed for restoration.
The journal also seals the complete manifest with SHA-256, so changed ownership
metadata is rejected even when the snapshot files themselves remain intact.
Files use mode `0600`, directories use `0700`. Backups can contain sensitive
settings: do not publish or share them. Backups are retained, not auto-pruned.

Before the first edit, full snapshots and the transaction manifest are written
and synced. Repeated enabling never overwrites the original restore point.
Turning off and on later establishes a fresh baseline, retaining older snapshots.

If the config is unchanged, restoration is byte-for-byte, including its original
permissions. An originally absent file is removed; an originally empty file is
kept. If unrelated settings changed while routing was enabled, the app restores
only its selector/block and retains the other edits. The TOML parser handles
quoted keys, multiline values, arrays, CRLF and table scope without reserializing
the entire file or losing comments.

Edits to the managed selector/block, removal of a previously defined provider,
invalid TOML, orphaned managed markers, or missing/corrupt recovery metadata
cause a visible conflict. The app does not guess, force restore, overwrite those
edits or take a new backup of the enabled configuration as if it were the
original. Use **Open backups**, review the conflict and recheck the configuration.

## Existing manual Bridge configurations

An existing root `model_provider = "bridge"` pointing at the matching loopback
Bridge endpoint is shown as a **manual** configuration.

There is no trustworthy pre-Bridge original to restore. The UI states this
before the user acts. Turning off:

- saves the complete manual configuration in a private transaction;
- removes its root selector so Codex uses its default provider;
- preserves the old user-owned Bridge table and all other settings.

The next enable establishes a normal managed restore point from that default
configuration. The app does not search for or guess from unrelated historical
backup files.

## Atomicity, conflicts and crash recovery

- An in-process lock and an OS file lock serialize switch operations. Process
  death releases the OS lock; no stale-PID lock deletion is needed.
- Backups are synced before publishing pending recovery metadata.
- A staging file beside the config is committed using macOS atomic swap or
  exclusive rename. The displaced file remains available until verified.
- Pre-commit changes are detected. A late concurrent edit is retained instead
  of being discarded by a blind overwrite. Conflicting versions are kept for
  review; non-conflicting post-swap edits can be reconciled without rewriting
  the live config.
- After a crash, status reconciles the journal with verified snapshots. It never
  rewrites `config.toml` just because the app was launched or status was checked.
- A crash can leave a `.copilot-bridge-<transaction-id>.tmp` recovery file beside
  the config. Unknown/conflicting recovery files are not automatically deleted.
- Read-only configs, symlinks, hard links, non-owned files and unsafe backup
  directories are refused. Configuration input is capped at 1 MiB. File systems
  that do not support the required atomic operations fail without a blind-write
  fallback.

The TOML helper is a pure planner inside the bundled service executable.
Configuration travels over bounded private pipes, not shell arguments or logs;
it does not start a model service or contact a provider. Native code owns all
filesystem mutation. Exact restoration from an intact, unchanged backup does not
require the planner, so a missing helper does not invalidate that recovery path.
