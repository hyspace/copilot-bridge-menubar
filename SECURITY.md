# Security policy

Supported security fixes target the latest release.

Do not disclose tokens or personal logs in public issues. For a vulnerability,
use the repository's **Security → Report a vulnerability** flow where available;
otherwise contact the maintainer privately via their GitHub profile.

LAN mode is not an Internet-facing gateway. It uses a Keychain-backed access key,
but plain HTTP does not protect against network eavesdropping. Use trusted networks
and do not expose the listener with router port forwarding.

The menu app never asks for your GitHub password or OpenAI token. Device login
must happen at `https://github.com/login/device`. Reference configuration can
contain a LAN access key; keep it private.

Release artifacts are checksummed. Default CI builds are ad-hoc signed, not Apple
notarized; verify the Release and build from source if your deployment requires
a trusted Developer ID. Do not disable macOS security protections globally.
