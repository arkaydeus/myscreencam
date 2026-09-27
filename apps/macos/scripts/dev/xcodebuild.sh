#!/usr/bin/env bash
# xcodebuild, then drop the LaunchServices registrations it leaves behind (see unregister-builds.sh), whether or not
# the build or tests pass.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
trap '"$root/scripts/dev/unregister-builds.sh" || true' EXIT
xcodebuild "$@"
