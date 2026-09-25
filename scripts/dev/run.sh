#!/usr/bin/env bash
# Launch this worktree's Debug build through LaunchServices so macOS attributes TCC permissions to the
# app itself (not the terminal). Each worktree gets its own recordings folder.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
app="${MSA_DERIVED_DATA:-$root/build/DerivedData}/Build/Products/Debug/MyScreenArt Dev.app"
[[ -d "$app" ]] || { echo "No Debug build at $app. Run: mise run build" >&2; exit 1; }

worktree_id="$(printf '%s' "$root" | shasum -a 256 | cut -c1-12)"
recordings="$HOME/Movies/MyScreenArt Dev/$worktree_id"

# Replace an instance already launched from this worktree.
if pkill -f "$app/Contents/MacOS/"; then sleep 0.5; fi

echo "Worktree $worktree_id"
echo "Recordings: $recordings"
open -n --env "MYSCREENART_RECORDINGS_DIR=$recordings" "$app"
