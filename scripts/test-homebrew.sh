#!/bin/bash
# Install the published app on a clean test host. Never launch its UI/backend.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPOSITORY="${GITHUB_REPOSITORY:-hyspace/copilot-bridge-menubar}"
PACKAGE="hyspace/copilot-bridge-menubar/copilot-bridge-menubar"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
BEFORE="$(lsof -nP -t -iTCP:4142 -sTCP:LISTEN || true)"
test "$(uname -m)" = arm64

# Newer Homebrew versions require a package-specific trust grant before tapping.
if brew help trust >/dev/null 2>&1; then
  brew trust --cask "$PACKAGE"
fi
brew tap hyspace/copilot-bridge-menubar "https://github.com/$REPOSITORY"
brew install --cask "$PACKAGE"
EXPECTED_VERSION="${1:-$(brew info --cask --json=v2 "$PACKAGE" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["casks"][0]["version"])')}"
python3 "$ROOT/scripts/verify-app.py" \
  --app "/Applications/Copilot Bridge.app" --version "$EXPECTED_VERSION"
test "$BEFORE" = "$(lsof -nP -t -iTCP:4142 -sTCP:LISTEN || true)"
echo "PASS: installed app in /Applications; existing listener unchanged."
