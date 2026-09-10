# Local review now; publication later

This multi-provider branch is **not approved for publication**. Deliver the local
`Codex Bridge.app`, ZIP, checksum and acceptance report first. Do not push a release
tag, upload assets, update Homebrew, or replace a user's installed app during this
work. Existing public casks/releases still describe the Copilot-only product.

## Review build

```sh
VERSION=0.5.0 bash scripts/build-app.sh
python3 scripts/verify-app.py --app 'build/Codex Bridge.app' --version 0.5.0
```

The exact clean core commit must match the recorded submodule pin. Local commits
can provide reproducible provenance without publishing them. Builds never rewind
an initialized vendor checkout. The build script does not launch either app or
modify user settings, accounts, login items or live services.

By default, both binaries are ad-hoc signed. This provides integrity checking,
not a trusted Apple Developer ID or notarization ticket. For an explicitly
requested Developer ID build, set `SIGN_IDENTITY` to the maintainer's certificate.
The repository does not store certificates or Apple credentials. Notarization
requires the maintainer's account, successful notary submission, stapling and
repackaging before calculating the final checksum. Do not remove quarantine or
disable macOS security protections as a substitute.

## Before any future release

After user acceptance, separately review and approve:

1. Live Codex account sign-in/model/quota behavior and desktop Computer Use limits.
2. Model/source switching, long histories/compaction and Local search limitations.
3. Migration rollback instructions and the retained bundle/data identifiers.
4. Publication of the core commit to the maintainer's fork and the matching app pin.
5. Product-name, ZIP/application path, version, cask and release-workflow changes.
6. Immutable tags/assets, signatures, checksum and clean-host installation tests.

The historical `release.yml`, cask updater and Homebrew tests have **not** been
used to publish this branch. They must be reviewed for the renamed product before
release. Keeping them in the repository is not publication approval.
