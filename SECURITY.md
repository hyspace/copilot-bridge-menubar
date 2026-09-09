# Security policy

Supported security fixes target the latest release.

Do not disclose tokens or personal logs in public issues. For a vulnerability,
use the repository's **Security → Report a vulnerability** flow where available;
otherwise contact the maintainer privately via their GitHub profile.

LAN mode intentionally has no access-key requirement or inbound authentication.
Use trusted networks only: plain HTTP does not prevent eavesdropping or usage by
other devices on that network. Do not expose it with Internet port forwarding.

The menu app never asks for your GitHub password or OpenAI token. Device login
must happen at `https://github.com/login/device`. Reference configuration does not add a LAN access key.

Release artifacts are checksummed. Default CI builds are ad-hoc signed, not Apple
notarized; verify the Release and build from source if your deployment requires
a trusted Developer ID. Do not disable macOS security protections globally.
