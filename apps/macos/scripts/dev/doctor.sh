#!/usr/bin/env bash
# Toolchain, signing and build diagnostics.
set -uo pipefail

# The macOS app root (apps/macos in the monorepo), not the git top level.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app="${MSA_DERIVED_DATA:-$root/build/DerivedData}/Build/Products/Debug/MyScreenArt Dev.app"

section() { printf '\n== %s ==\n' "$1"; }

section "Toolchain"
echo "DEVELOPER_DIR=${DEVELOPER_DIR:-<unset>}"
xcodebuild -version
swift --version 2>&1 | head -1
xcodegen --version
# The speech service builds MLX's Metal shaders (docs/speech-integration.md).
if xcrun metal --version >/dev/null 2>&1; then
  echo "Metal Toolchain: installed"
else
  echo "Metal Toolchain: MISSING — run: xcodebuild -downloadComponent MetalToolchain"
fi

section "Signing identities"
security find-identity -v -p codesigning | grep -E 'Apple Development|Developer ID Application' \
  || echo "No Apple Development / Developer ID identity found"

section "Debug build"
if [[ -d "$app" ]]; then
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist"
  codesign --verify --strict "$app" && echo "Signature: valid"
  codesign -dvv "$app" 2>&1 | grep -E '^(Authority|TeamIdentifier|Runtime Version)' | head -3
else
  echo "Not built: $app"
fi

section "Permissions"
echo "Grant Screen & System Audio Recording and Input Monitoring to 'MyScreenArt Dev' when prompted."
echo "Screen:  open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'"
echo "Input:   open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent'"
