# CLI options

| CLI option | App behavior |
| --- | --- |
| `start --host` | Local only / LAN |
| `start --port` | Port field, 1024–65535 |
| `--model` | Model override; leave blank to preserve the client's model choice |
| `--debug` | Debug logging |
| `--rate-limit` | Request interval; zero omits this option |
| `--wait` | Wait when rate-limited |
| `--auto` | Auto mode |
| `--codex-setup` | Disabled; the app never rewrites Codex configuration |
| `--claude-setup` | Disabled; the app never rewrites Claude configuration |
| `--prompt` | Disabled; choose a model in Settings or your client instead |
| `--show-token` | Disabled; credentials must not be printed into service logs |
| `auth` | Sign in / authorize with GitHub |
| `auth --host/--port` | Uses loopback and the configured port for CLI initialization; no additional authorization listener |
| `auth --show-token` | Disabled |

Settings also cover `COPILOT_ACCOUNT_TYPE`, an optional `COPILOT_BASE_URL`,
`COPILOT_VSCODE_VERSION`, HTTP(S) proxies and `NO_PROXY`.
Inherited `COPILOT_TOKEN`, runtime loaders and raw-request trace destinations
are intentionally cleared.

The app is not a shell-command runner and does not accept arbitrary extra CLI arguments.
