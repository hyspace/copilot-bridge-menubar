#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ "$(uname -m)" != arm64 ]]; then echo "Apple Silicon build host required." >&2; exit 1; fi
BUN="${BUN:-$(command -v bun || true)}"
BUN="${BUN:-$HOME/.bun/bin/bun}"
if [[ ! -x "$BUN" ]]; then echo "Build-only dependency missing: Bun. End users do not need Bun." >&2; exit 1; fi
export BUN
if [[ ! -e vendor/copilot-bridge/.git ]]; then
  git submodule update --init --recursive
fi
EXPECTED_REV="$(git ls-files --stage vendor/copilot-bridge | awk '{print $2}')"
ACTUAL_REV="$(git -C vendor/copilot-bridge rev-parse HEAD)"
if [[ -z "$EXPECTED_REV" || "$EXPECTED_REV" != "$ACTUAL_REV" ]]; then
  echo "Submodule HEAD differs from the recorded pin. Stage/commit the intended update; builds never rewind it." >&2
  exit 1
fi
if [[ -n "$(git -C vendor/copilot-bridge status --porcelain)" ]]; then
  echo "Commit CLI fork changes before packaging. Refusing an unrecorded dirty submodule." >&2
  exit 1
fi
if [[ ! -d vendor/copilot-bridge/node_modules ]]; then
  (cd vendor/copilot-bridge && "$BUN" install --frozen-lockfile --ignore-scripts)
fi
mkdir -p .build/module-cache build
python3 scripts/build-backend.py
CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/module-cache" \
swift build -c release --arch arm64 --disable-sandbox
APP="$ROOT/build/Codex Bridge.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/arm64-apple-macosx/release/CopilotBridgeMenuBar "$APP/Contents/MacOS/"
cp build/copilot-bridge-service "$APP/Contents/Resources/"
cp resources/Info.plist "$APP/Contents/Info.plist"
cp resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
VERSION="${VERSION:-0.5.0}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "VERSION must be x.y.z" >&2; exit 1; fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
python3 scripts/package-licenses.py "$APP/Contents/Resources/Licenses"
cp vendor/copilot-bridge/LICENSE "$APP/Contents/Resources/Bridge-LICENSE"
git -C vendor/copilot-bridge rev-parse HEAD > "$APP/Contents/Resources/bridge-revision.txt"
git rev-parse HEAD > "$APP/Contents/Resources/app-revision.txt"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then TIMESTAMP=--timestamp=none; else TIMESTAMP=--timestamp; fi
codesign --force --sign "$SIGN_IDENTITY" "$TIMESTAMP" --options runtime \
  --entitlements resources/backend.entitlements.plist "$APP/Contents/Resources/copilot-bridge-service"
codesign --force --sign "$SIGN_IDENTITY" "$TIMESTAMP" --options runtime "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ROOT/build/Codex-Bridge-arm64.zip"
(cd build && shasum -a 256 Codex-Bridge-arm64.zip > SHA256SUMS)
echo "Built: $APP"
echo "No CLI service was started/stopped. No user config or login data was changed."
echo "Local review build only. Nothing was installed, uploaded, or published."
