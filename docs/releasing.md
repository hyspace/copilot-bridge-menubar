# Releases and Homebrew

This repository publishes a standalone macOS app and a Homebrew package.
Installation places the app in `/Applications/Copilot Bridge.app`.

1. Publish any new CLI fork commit first, then update this repository's submodule reference. Merge App changes into `main` after CI passes.
2. Choose a new semantic version; never overwrite a published tag or asset.
3. Tag and push:

   ```sh
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

4. `release.yml` checks out the pinned submodule, installs its frozen lockfile,
   tests Swift/TypeScript/auth/streaming/lifecycle on an arm64 macOS runner,
   packages and ad-hoc signs both executables, and verifies code signatures.
5. It publishes the ZIP and SHA256SUMS, calculates the actual archive checksum,
   updates `Casks/copilot-bridge-menubar.rb` on `main`, then installs the published
   app and verifies its version, arm64 binaries, bundle layout and signatures.
   The install test rejects a symlink in place of the actual app bundle.

The release workflow needs only the repository `GITHUB_TOKEN` with contents write
permission. If branch protection forbids its package update, retain protection and
submit the generated metadata through a PR instead; do not bypass user policies.
Third-party workflow actions are pinned to commit SHAs.

The packager checks that the CLI worktree is clean and matches the recorded
submodule pin. It does not rewind an initialized submodule as a side effect of a build.

For a local Developer ID build:

```sh
VERSION=0.1.0 SIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)" \
  bash scripts/build-app.sh
```

The project does not store signing certificates. Notarization requires the
maintainer's Apple account/certificate and is not silently simulated by ad-hoc signing.
If you add notarization, submit the artifact with `xcrun notarytool`, wait for
acceptance, staple the ticket, re-package, and only then calculate the release checksum.

Installation does not auto-start a service or rewrite Codex configuration.
Login startup is configured in the app. Uninstallation preserves personal settings
and usage history. Package scripts do not remove quarantine attributes or disable
macOS security checks.
