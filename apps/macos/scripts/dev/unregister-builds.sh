#!/usr/bin/env bash
# Drop the LaunchServices registrations that builds leave behind. xcodebuild registers every app it builds (and
# its Quick Look extension) with no opt-out, so each worktree adds another "MyScreenArt Dev" entry to System
# Settings > Login Items & Extensions. This unregisters, across all worktrees, every MyScreenArt bundle that is
# either gone from disk or a build product (under a build/ directory) that isn't running. Installed copies such
# as /Applications/MyScreenArt.app are left alone. run.sh re-registers the app it launches.
#
#   scripts/dev/unregister-builds.sh [--dry-run]
set -euo pipefail

lsregister="${MSA_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
dry_run=0
[[ "${1:-}" == "--dry-run" ]] && dry_run=1

# Every registered path under a MyScreenArt bundle, including nested extensions and Sparkle's Updater.app.
paths="$("$lsregister" -dump | sed -nE 's/^path: +(.*MyScreenArt.*) \(0x[0-9a-f]+\)$/\1/p' | sort -u)"

count=0
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  # Judge nested bundles by the MyScreenArt app that contains them.
  owner="$(printf '%s' "$path" | sed -E 's#^(.*/MyScreenArt[^/]*\.app)/.*#\1#')"
  if [[ -e "$owner" ]]; then
    [[ "$owner" == */build/* ]] || continue
    pgrep -f "$owner/Contents/MacOS/" >/dev/null && continue
  fi
  echo "Unregistering $path"
  # Unregistering an app takes its extensions with it, so a later -u on one of those fails (-10814). Harmless.
  [[ $dry_run -eq 1 ]] || "$lsregister" -u "$path" 2>/dev/null || true
  count=$((count + 1))
done <<< "$paths"

[[ $count -gt 0 ]] || echo "No stale MyScreenArt registrations."
