# Bundled service and source settings

The native app starts the new `gateway` command with a host, port and path to a
small non-secret JSON file. The file is typed/validated; credentials are never
command-line arguments or JSON settings. The service does not edit Codex config.

| Setting/control | Behavior |
| --- | --- |
| Local only / LAN | Bind `127.0.0.1` / `0.0.0.0`; LAN remains keyless |
| Port | 1024–65535; an occupied listener is never taken over |
| Codex subscription | Independent browser/device OAuth via Pi and Keychain |
| GitHub Copilot | Existing Bridge credentials, model adapters and quota API |
| Unsloth Studio | One configured endpoint; discover loaded conversational models |
| Local API key | Stored over private control IPC, bound to the endpoint in Keychain |
| Copilot model override / Auto mode | Applies to Copilot only, not Codex or Local |
| Copilot request interval / waiting | Preserves the legacy rate-limit behavior |
| Debug logging | Bounded diagnostics; raw request tracing remains cleared |
| Use in Codex | Native journaled config transaction, not a gateway startup option |
| Authorize GitHub… | Existing one-shot `auth` command; stop shared-cache owners first |

Codex's official upstream is fixed by its adapter. Custom upstream/account type,
VS Code compatibility version and Copilot override apply to Copilot only. Cloud
HTTP(S) proxy settings are supported; the explicitly configured local hostname is
excluded from that cloud proxy. Caller auth/cookies/account identity do not travel
to Local or Copilot.

Private `/bridge/*` management routes require a fresh per-process secret and reject
browser origins. Model API browser-origin requests are also rejected. These guards
do not make keyless LAN inference authenticated: use trusted networks only.

The legacy `start` and `auth` commands remain for compatibility tests. The native
app no longer runs the old automatic Codex/Claude config writers or interactive
model picker. It accepts no arbitrary shell commands or extra CLI arguments.
