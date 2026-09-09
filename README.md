# Copilot Bridge Menu Bar

A native **Apple Silicon macOS menu-bar app** for [Copilot Bridge](https://github.com/hyspace/copilot-bridge).
Manage your local service, GitHub sign-in, token activity and remaining credits.
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
choose **Start service**. The backend does not start automatically on first launch.
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
  grouped by local calendar date.
- Darker green means more reported **input + output tokens** relative to the
  busiest visible day. Cached tokens are already part of input and are not added twice.
- Hover, click, or keyboard-focus a day to see its recorded tokens and its
  last-observed **account-wide credit balance**. The tooltip also includes
  input/output/cache counts, requests, errors and the snapshot time.
- Credit figures come from GitHub's quota API. They are **not estimated from tokens**.
  A historical balance is a snapshot, not a daily cost or a live balance.
- Days without saved quota data say **Credits: not recorded**. Existing token
  history is preserved, but credit history cannot be reconstructed retroactively.
- Missing token usage is reported explicitly; a dashed tile border marks days
  containing requests with incomplete usage data.
- Legacy premium-interaction quotas keep their own labels; they are not shown as credits.

Token totals cover only requests handled by this app. Credit balances are
account-wide and can include usage by other clients. The current balance is
refreshed while the owned service is running; failed queries do not make an old
balance appear freshly updated. See [activity data](docs/activity.md) for details.

## Settings

- Local-only (`127.0.0.1`) or LAN (`0.0.0.0`) access, with a configurable port.
- Start, stop and restart only the app's own backend process.
- GitHub device authorization, using the existing CLI credential cache.
- Model override, Auto mode, request interval and rate-limit waiting.
- Account type, HTTP(S) proxy, proxy exclusions, custom upstream and compatibility version.
- Bounded diagnostic logs, automatic crash retries and optional login startup.
- English interface, messages, help text and reference configuration.

All CLI options and intentional restrictions are documented in
[CLI options](docs/cli-options.md).

The default service behavior is equivalent to:

```sh
env -u COPILOT_TOKEN -u COPILOT_BASE_URL copilot-bridge start \
  --host 127.0.0.1 --port 4142 \
  --no-codex-setup --no-claude-setup --no-prompt
```

The app uses its bundled standalone backend, not a user shell. Inherited
`COPILOT_TOKEN` and `COPILOT_BASE_URL` are cleared so the CLI can obtain and refresh
its own credentials. A custom upstream is set only when explicitly configured.

## Codex configuration

Choose **Codex config** to copy a reference. Merge it into your existing
`~/.codex/config.toml`; do not replace the entire file. The app never writes
Codex or Claude configuration.

```toml
[model_providers.bridge]
name = "Copilot Bridge"
base_url = "http://127.0.0.1:4142/v1"
wire_api = "responses"
supports_websockets = false
requires_openai_auth = true
```

The reference preserves OpenAI sign-in by default. If Model override is blank,
replace the explicit model placeholder with a model available to your account.

## Safety and local data

**LAN mode has no incoming API key and uses unencrypted HTTP. Use trusted
networks only. Do not expose it to the internet or configure port forwarding.**

Settings, daily/model usage totals, and daily quota snapshots are stored locally.
No prompt or response database is created. Aggregates are retained for 730 days,
deduplication IDs for two days, and logs for up to four files of approximately
2 MB each. Only the latest 200 log lines are held in the interface.

```text
~/Library/Application Support/CopilotBridgeMenuBar/
  settings.json       # App settings; no account credentials
  usage.sqlite        # Token aggregates and last daily quota observations
  Logs/bridge*.log    # Rotating diagnostics
~/.local/share/copilot-bridge/github_token  # CLI-managed credentials, mode 0600
```

Credentials are redacted, but review debug logs before sharing them: upstream
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
python3 scripts/build-backend.py
python3 scripts/test-auth.py
python3 scripts/integration-test.py
bash scripts/build-app.sh
```

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
