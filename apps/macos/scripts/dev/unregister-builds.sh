#!/usr/bin/env bash
# Drop the LaunchServices registrations that builds leave behind. xcodebuild registers every app it builds (and
# its Quick Look extension) with no opt-out, so each worktree adds another "My Screen Cam Dev" entry to System
# Settings > Login Items & Extensions. This unregisters, across all worktrees, every My Screen Cam bundle that is
# either gone from disk or an idle build product (under build/ or an explicit --root). Installed copies such as
# /Applications/My Screen Cam.app are left alone. run.sh re-registers the app it launches.
#
#   scripts/dev/unregister-builds.sh [--dry-run] [--root BUILD_PRODUCT_DIR]...
set -euo pipefail

lsregister="${MSC_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
dry_run=0
roots=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --root)
      [[ $# -ge 2 && -n "$2" && "$2" != / ]] || { echo "--root requires a non-root directory" >&2; exit 2; }
      roots+=("${2%/}")
      shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# Check registered paths, including nested extensions and Sparkle's Updater.app, against their owning app.
paths="$("$lsregister" -dump | sed -nE 's/^path: +(.*) \(0x[0-9a-f]+\)$/\1/p' | sort -u)"

count=0
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  # Only our app bundles (or their nested registrations) are eligible, regardless of parent directory names.
  [[ "$path" =~ ^(.*/My\ Screen\ Cam(\ Dev)?\.app)(/.*)?$ ]] || continue
  owner="${BASH_REMATCH[1]}"
  if [[ -e "$owner" ]]; then
    canonical_owner="$(cd -P "$owner" && pwd)"
    eligible=0
    [[ "$canonical_owner" == */build/* ]] && eligible=1
    for root in "${roots[@]}"; do
      [[ "$owner" == "$root"/* || "$canonical_owner" == "$root"/* ]] && eligible=1
    done
    [[ $eligible -eq 1 ]] || continue
    if pgrep -f "$owner/Contents/MacOS/" >/dev/null; then continue; fi
    if [[ "$canonical_owner" != "$owner" ]] && pgrep -f "$canonical_owner/Contents/MacOS/" >/dev/null; then continue; fi
  fi
  if [[ $dry_run -eq 1 ]]; then
    echo "Would unregister $path"
  else
    echo "Unregistering $path"
  fi
  # Unregistering an app takes its extensions with it, so a later -u on one of those fails (-10814). Harmless.
  if [[ $dry_run -eq 0 ]]; then "$lsregister" -u "$path" 2>/dev/null || true; fi
  count=$((count + 1))
done <<< "$paths"

[[ $count -gt 0 ]] || echo "No stale My Screen Cam registrations."
[[ $dry_run -eq 0 ]] || echo "Dry run: no registrations were changed."
