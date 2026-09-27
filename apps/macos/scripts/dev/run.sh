#!/usr/bin/env bash
# Launch this worktree's Debug build through LaunchServices so macOS attributes TCC permissions to the
# app itself (not the terminal). Each worktree gets its own recordings folder.
set -euo pipefail

# The macOS app root (apps/macos in the monorepo), not the git top level.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app="${MSC_DERIVED_DATA:-$root/build/DerivedData}/Build/Products/Debug/My Screen Cam Dev.app"
[[ -d "$app" ]] || { echo "No Debug build at $app. Run: mise run build" >&2; exit 1; }

# Keep the ID keyed to the git worktree root, as it was before the monorepo move.
worktree_root="$(git -C "$root" rev-parse --show-toplevel)"
worktree_id="$(printf '%s' "$worktree_root" | shasum -a 256 | cut -c1-12)"
recordings="$HOME/Movies/My Screen Cam Dev/$worktree_id"

# Builds unregister themselves (scripts/dev/xcodebuild.sh), so register this one and its Quick Look extension.
lsregister="${MSC_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
"$lsregister" -f -R -trusted "$app"

# Replace an instance already launched from this worktree.
if pkill -f "$app/Contents/MacOS/"; then sleep 0.5; fi

echo "Worktree $worktree_id"
echo "Recordings: $recordings"
open -n --env "MYSCREENCAM_RECORDINGS_DIR=$recordings" "$app"
