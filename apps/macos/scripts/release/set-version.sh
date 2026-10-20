#!/usr/bin/env bash
# Sets MARKETING_VERSION in project.yml, commits it and pushes the current branch, ready for
# `release.sh --publish`. See docs/release.md.
#
#   scripts/release/set-version.sh v1.2.3   # or 1.2.3
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
spec="$root/project.yml"

[[ $# -eq 1 ]] || { echo "Usage: $(basename "$0") v<major>.<minor>.<patch>" >&2; exit 2; }
version="${1#v}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Not a version: $1 (expected e.g. v1.2.3)" >&2; exit 2; }

current="$(sed -nE 's/^    MARKETING_VERSION: "([^"]+)"$/\1/p' "$spec")"
[[ -n "$current" ]] || { echo "MARKETING_VERSION not found in $spec" >&2; exit 1; }
[[ "$version" != "$current" ]] || { echo "Already at $version" >&2; exit 1; }
# Sparkle only offers versions above the installed one.
[[ "$(printf '%s\n%s\n' "$current" "$version" | sort -V | tail -1)" == "$version" ]] \
  || { echo "$version is lower than the current $current" >&2; exit 2; }
git -C "$root" diff --quiet -- "$spec" || { echo "project.yml has uncommitted changes" >&2; exit 2; }

sed -i '' -E "s/^    MARKETING_VERSION: \"[^\"]+\"$/    MARKETING_VERSION: \"$version\"/" "$spec"
git -C "$root" commit --quiet -m "chore(release): v$version" -- "$spec"
# release.sh --publish tags this commit on GitHub, so it has to be pushed.
git -C "$root" push --quiet origin HEAD
echo "MARKETING_VERSION: $current -> $version (committed and pushed on $(git -C "$root" branch --show-current))"
echo "Next: mise run release:publish"
