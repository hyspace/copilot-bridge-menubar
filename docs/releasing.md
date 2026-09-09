# Releases and Homebrew

This public repository doubles as a custom Homebrew tap. It distributes a
**formula**, not a cask. It does not claim eligibility for `homebrew/core`, whose
policy excludes app bundles as their main formula product.

1. Publish any new CLI fork commit first, then update this repository's submodule reference. Merge App changes into `main` after CI passes.
2. Choose a new semantic version; never overwrite a published tag or asset.
3. Tag and push:

   ```sh
   git tag v0.1.0
   git push origin v0.1.0
   ```

4. `release.yml` checks out the pinned submodule, installs its frozen lockfile,
   tests Swift/TypeScript/auth/streaming/lifecycle on an arm64 macOS runner,
   packages and ad-hoc signs both executables, and verifies code signatures.
5. It publishes the ZIP and SHA256SUMS, calculates the actual archive checksum,
   updates `Formula/copilot-bridge-menubar.rb` on `main`, then installs and tests
   the published formula.

The release workflow needs only the repository `GITHUB_TOKEN` with contents write
permission. If branch protection forbids its formula update, retain protection and
submit the generated formula through a PR instead; do not bypass user policies.
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

Homebrew installation does not auto-start a daemon or rewrite Codex configuration.
`brew services` is optional and user-initiated. On removal, personal settings,
Keychain keys and usage history are intentionally preserved.
