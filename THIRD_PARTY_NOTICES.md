# Third-party components

- **hyspace/copilot-bridge**, based on betaHi/copilot-bridge: MIT. The exact commit
  is pinned by `vendor/copilot-bridge` and recorded in each app bundle.
- **Bun 1.4.1**: MIT for Bun itself; bundled third-party runtime components retain
  their respective licenses. See the runtime license notices distributed in
  `Resources/Licenses` and https://github.com/oven-sh/bun.
- The CLI's production npm dependencies are locked in its `bun.lock`.
  Their available license files are copied into the app during packaging.
- Native UI: Apple AppKit, SwiftUI, SystemConfiguration and ServiceManagement frameworks.
  SQLite is provided by macOS; this app does not ship a separate SQLite library.

The project's MIT license does not replace licenses of bundled dependencies.
