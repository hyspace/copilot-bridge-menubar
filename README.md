# Copilot Bridge Menu Bar

<img src="docs/screenshots/app-icon.png" width="80" alt="Copilot Bridge app icon">

A native **Apple Silicon macOS menu-bar app** connecting **Codex App** to
**GitHub Copilot**, powered by [Copilot Bridge](https://github.com/hyspace/copilot-bridge).
Codex App is the only supported client. Manage its routing switch, the local
Bridge service, GitHub authorization, token activity and credit usage.
No Dock icon, ordinary application window, or separate Bun installation.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/overview-dark.png">
  <img src="docs/screenshots/overview.png" width="384" alt="Copilot Bridge overview with synthetic example data">
</picture>

## Install

Requires **macOS 14+ and Apple Silicon**.

```sh
brew tap hyspace/copilot-bridge-menubar https://github.com/hyspace/copilot-bridge-menubar
brew install --cask hyspace/copilot-bridge-menubar/copilot-bridge-menubar
```

Open **Copilot Bridge** from Applications. The app is installed at
`/Applications/Copilot Bridge.app`. Click its menu-bar icon, review Settings, then
choose **Start service**, enable **Use in Codex**, then
**restart Codex App**. The backend does not start automatically on first launch.
If another service already uses port 4142, choose a different port.
The app never takes over or terminates an existing CLI process.

If Homebrew asks you to trust this package before adding the tap, run
`brew trust --cask hyspace/copilot-bridge-menubar/copilot-bridge-menubar`, then retry.

You can also download `Copilot-Bridge-arm64.zip` from Releases and move the
extracted app to Applications. Public builds are ad-hoc signed, not Apple
Developer ID signed or notarized. If macOS blocks a downloaded copy, build from
source or review its origin before using the system's **Privacy & Security >
Open Anyway** flow. The project does not disable Gatekeeper or remove quarantine.

Quit the app before updating:

```sh
brew update
brew upgrade --cask hyspace/copilot-bridge-menubar/copilot-bridge-menubar
```

Optional startup behavior is controlled by **Open at login** and
**Start service when app opens** in Settings.

## Activity and credits

- The contribution-style grid shows **26 weeks** of recorded token activity,
  grouped by the local date of each upstream request attempt.
- Darker green means more reported **input + output tokens**. Cached tokens are
  already part of input and are not added twice.
- Hover, click or keyboard-focus a day to see its token totals and **credits used**.
  Hover coverage includes the gaps between tiles without changing their appearance.
- Request charges come directly from `usage.copilot_usage.total_nano_aiu`, divided
  by 1,000,000,000. They are **not estimated from token counts or balance changes**.
- Repeated stream snapshots are not added twice. Each real retry is recorded
  separately, and duplicate event IDs are ignored.
- An explicit zero is a known zero. Missing billing says **Credits unreported**;
  partial totals show how many requests included billing. Old token history is
  retained, but previously discarded billing fields cannot be recovered.
- A dashed tile border marks missing/partial token or billing data. The detail
  line reports **token coverage and credit coverage separately**.

**Account balance** remains a separate card, queried from GitHub's quota API.
It is account-wide, whereas the activity grid covers requests handled by this app.
The card shows **credits used on the left** and **remaining percentage on the right**.
Hover the percentage for the exact remaining credit amount.
The bar follows the same order: gray used quota, then green remaining quota.
Reported usage is preferred; when only a limit and remaining quota are available,
the calculated used amount is explicitly labeled **derived**. Unknown is not zero.
**Refresh usage** updates these account figures, not authorization.
Failed balance refreshes preserve the original observation timestamp. Legacy
premium-interaction quotas keep their own labels. See [activity data](docs/activity.md).

**Settings > GitHub account > Authorize GitHub…** starts a fresh device
authorization. Authorize again or select a different account on GitHub; approving
access replaces the shared CLI credential cache. This is not a sign-out action.
Stop the app's service and any standalone CLI service before changing authorization.
The app only reports whether cached credentials exist, not a verified account identity.

## Settings

- Local-only (`127.0.0.1`) or LAN (`0.0.0.0`) access, with a configurable port.
- Start, stop and restart only the app's own backend process.
- Explicit GitHub device authorization, sharing the CLI credential cache.
- Model override, Auto mode, request interval and rate-limit waiting.
- Account type, HTTP(S) proxy, proxy exclusions, custom upstream and compatibility version.
- Bounded diagnostic logs, automatic crash retries and optional login startup.
- A transactional Codex App routing switch with verified backups and safe restore.
- English interface, messages and help text.
- Full-area buttons and tabs with hover feedback, including Quit and disclosure headers.
- The app icon's original bridge mark in both the panel and menu bar, with
  template tinting that follows the actual menu-bar light/dark appearance.

Internal service options and intentional restrictions are documented in
[Service options](docs/service-options.md). These are implementation details,
not support for other coding clients.

The default service behavior is equivalent to:

```sh
env -u COPILOT_TOKEN -u COPILOT_BASE_URL copilot-bridge start \
  --host 127.0.0.1 --port 4142 \
  --no-codex-setup --no-claude-setup --no-prompt
```

The app uses its bundled standalone backend, not a user shell. Inherited
`COPILOT_TOKEN` and `COPILOT_BASE_URL` are cleared so the CLI can obtain and refresh
its own credentials. A custom upstream is set only when explicitly configured.

## Codex App configuration

Use **Use in Codex** in Overview, or **Use Copilot Bridge in Codex** in Settings. No configuration
copying or manual merging is required. **Restart Codex App after each switch**;
running tasks are not restarted or switched by this app.

- **On:** save a private, verified full backup, select an app-owned provider and
  point it to this Mac's Bridge service. OpenAI sign-in stays enabled.
- **Off:** restore the previous provider and remove only the app-owned block.
  Unrelated edits made while enabled, including model selection and project
  settings, are preserved. Changes to managed fields cause a conflict instead
  of being overwritten.
- **Existing manual Bridge configuration:** no pre-Bridge restore point can be
  assumed. The UI explicitly explains that turning off makes a full backup and
  selects Codex's default provider. Existing user-owned provider tables are kept.
  Overview's **Codex routing** button opens that explanation in Settings first.
- **Open backups** in Settings provides access to the retained restore points.

The switch edits `~/.codex/config.toml`, or the home selected by an absolute
`CODEX_HOME` when Bridge starts. It never reads or writes `auth.json`.
Model choice and reasoning preferences are not rewritten. To change the service
port, switch routing off, change/save the port, then switch routing on again.
The toggle always uses loopback, even when the server allows LAN access.

Routing persists when Bridge quits; it is never silently restored on quit,
launch or upgrade. Other Codex clients sharing this home can also read the same
user config, although only Codex App is supported. See
[Configuration switching and recovery](docs/configuration.md).

## Safety and local data

**LAN mode has no incoming API key and uses unencrypted HTTP. Use trusted
networks only. Do not expose it to the internet or configure port forwarding.**

Settings, daily/model token and billing totals, and quota snapshots are stored locally.
No prompt or response database is created. Aggregates are retained for 730 days,
deduplication IDs for two days, and logs for up to four files of approximately
2 MB each. Only the latest 200 log lines are held in the interface.

```text
~/Library/Application Support/CopilotBridgeMenuBar/
  settings.json       # App settings; no account credentials
  usage.sqlite        # Request tokens, billing totals and quota observations
  Logs/bridge*.log    # Rotating diagnostics
  CodexConfig/        # Private full-config backups and transaction recovery state
~/.local/share/copilot-bridge/github_token  # CLI-managed credentials, mode 0600
```

Configuration backups may contain credentials from existing settings. **Do not
upload backups or attach them to public issues.** Credentials are redacted in
service logs, but review debug logs before sharing them: upstream
errors may contain application-specific information. GitHub's internal quota
interface may change; missing values are shown as unknown, never invented.
Credit units are not converted into dollars.

## Development

```sh
git clone --recurse-submodules https://github.com/hyspace/copilot-bridge-menubar.git
cd copilot-bridge-menubar
cd vendor/copilot-bridge && bun install --frozen-lockfile && cd ../..
bun test backend
swift test --disable-sandbox
python3 scripts/test-cask.py
python3 scripts/test-english.py
python3 scripts/test-icon.py
python3 scripts/build-backend.py
python3 scripts/test-auth.py
python3 scripts/integration-test.py
bash scripts/build-app.sh
```

The original app icon is generated from vector geometry in
`scripts/generate-icon.swift`; the bundled `AppIcon.icns` includes standard and
Retina sizes. To regenerate it, run `swift scripts/generate-icon.swift build/icon`
and copy the resulting icon into `resources/AppIcon.icns`.

Build requirements: Apple Silicon Mac, Swift 6+, Python 3, and Bun 1.4.1.
The native targets have no remote package dependencies. The CLI is pinned by Git
submodule and its JavaScript dependencies by `bun.lock`. Builds copy the pinned
source without patching it or restarting an existing service.

Tests use temporary HOME directories, synthetic data and fake upstreams on
random non-4142 ports. They do not consume real model credits or read real
credentials. UI previews are rendered offscreen; the README example is synthetic.

[Architecture](docs/architecture.md) · [Activity data](docs/activity.md) ·
[Releases](docs/releasing.md) · [Verification](docs/verification.md) ·
[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

## License

MIT © 2026 hyspace. The pinned CLI is MIT © betaHi and contributors.
Bundled runtime/dependencies retain their own licenses; see
`THIRD_PARTY_NOTICES.md` and the license files packaged in the app.
