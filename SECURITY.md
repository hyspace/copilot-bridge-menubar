# Security policy

Supported security fixes target the latest release.

Do not disclose tokens or personal logs in public issues. For a vulnerability,
use the repository's **Security → Report a vulnerability** flow where available;
otherwise contact the maintainer privately via their GitHub profile.

LAN mode intentionally has no access-key requirement or inbound authentication.
Use trusted networks only: plain HTTP does not prevent eavesdropping or usage by
other devices on that network. Do not expose it with Internet port forwarding.

The menu app never asks for your GitHub password or OpenAI token. GitHub device login
happens at `https://github.com/login/device`. Independent Codex authorization uses
OpenAI's HTTPS authorization pages via Pi OAuth. Tokens are stored in the app's own
Keychain service and transported to the backend only over private stdio. Local API
keys are endpoint-bound and must be re-entered for a changed endpoint. The Codex App routing switch
keeps OpenAI sign-in enabled and does not read or write `auth.json`.
It does not add a LAN access key.

Config switching requires an explicit user action and uses verified private
backups, OS locking and atomic replacement. Conflicts are not force-overwritten.
Configuration backups can contain existing credentials; never upload them to
public issues. See [configuration recovery](docs/configuration.md).

Release artifacts are checksummed. Default CI builds are ad-hoc signed, not Apple
notarized; verify the Release and build from source if your deployment requires
a trusted Developer ID. Do not disable macOS security protections globally.
