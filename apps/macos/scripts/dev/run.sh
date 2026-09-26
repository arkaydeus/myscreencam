#!/usr/bin/env bash
# Launch this worktree's Debug build through LaunchServices so macOS attributes TCC permissions to the
# app itself (not the terminal). Each worktree gets its own recordings folder.
set -euo pipefail

# The macOS app root (apps/macos in the monorepo), not the git top level.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app="${MSA_DERIVED_DATA:-$root/build/DerivedData}/Build/Products/Debug/MyScreenArt Dev.app"
[[ -d "$app" ]] || { echo "No Debug build at $app. Run: mise run build" >&2; exit 1; }

# Keep the ID keyed to the git worktree root, as it was before the monorepo move.
worktree_root="$(git -C "$root" rev-parse --show-toplevel)"
worktree_id="$(printf '%s' "$worktree_root" | shasum -a 256 | cut -c1-12)"
recordings="$HOME/Movies/MyScreenArt Dev/$worktree_id"

# Replace an instance already launched from this worktree.
if pkill -f "$app/Contents/MacOS/"; then sleep 0.5; fi

echo "Worktree $worktree_id"
echo "Recordings: $recordings"
open -n --env "MYSCREENART_RECORDINGS_DIR=$recordings" "$app"
