#!/usr/bin/env bash
# Builds the Developer ID signed Release app (no notarisation, DMG or appcast) and installs it as
# /Applications/MyScreenArt.app, replacing any copy already there. A running installed copy is quit first.
# Locally built apps carry no quarantine flag, so Gatekeeper opens them without notarisation.
#
#   scripts/release/install.sh [--skip-build] [--open] [--output DIR]
#
# Environment:
#   MSA_INSTALL_DIR   where to install (default: /Applications)
set -euo pipefail

build=1
launch=0
# The macOS app root (apps/macos in the monorepo), not the git top level.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="$root/build/release"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) build=0 ;;
    --open) launch=1 ;;
    --output) out="$2"; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

app="$out/export/MyScreenArt.app"
dest="${MSA_INSTALL_DIR:-/Applications}/MyScreenArt.app"
lsregister="${MSA_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"

if [[ $build -eq 1 ]]; then
  "$root/scripts/release/release.sh" --no-notarize --no-appcast --no-dmg --output "$out"
fi
[[ -d "$app" ]] || { echo "No Release build at $app. Run without --skip-build." >&2; exit 1; }

printf '\n==> Installing %s\n' "$dest"
# Quit the installed copy (and its helpers) so the bundle isn't replaced under a running process.
if pkill -f "$dest/Contents/"; then
  for _ in {1..50}; do pgrep -f "$dest/Contents/" >/dev/null || break; sleep 0.1; done
  if pgrep -f "$dest/Contents/" >/dev/null; then echo "MyScreenArt is still running from $dest; quit it and retry" >&2; exit 1; fi
fi

# Stage next to the destination, then swap, so a failed copy never leaves a half-installed app.
staging="$dest.installing"
rm -rf "$staging"
ditto "$app" "$staging"
rm -rf "$dest"
mv "$staging" "$dest"
"$lsregister" -f -R -trusted "$dest"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$dest/Contents/Info.plist" 2>/dev/null || echo '?')"
echo "Installed MyScreenArt $version at $dest"
[[ $launch -eq 0 ]] || open "$dest"
