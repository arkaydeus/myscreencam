#!/usr/bin/env bash
# Exercise script paths without launching the app or publishing a release.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
worktree_root="$(git -C "$root" rev-parse --show-toplevel)"
expected_id="$(printf '%s' "$worktree_root" | shasum -a 256 | cut -c1-12)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/home" "$tmp/DerivedData/Build/Products/Debug/MyScreenArt Dev.app"
cat > "$tmp/bin/pkill" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$tmp/bin/open" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MSA_TEST_OPEN_ARGS"
EOF
# Fake lsregister: -dump prints $MSA_TEST_LS_DUMP; anything else is appended to $MSA_TEST_LS_ARGS.
cat > "$tmp/bin/lsregister" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == -dump ]]; then cat "$MSA_TEST_LS_DUMP"; else printf '%s\n' "$*" >> "$MSA_TEST_LS_ARGS"; fi
EOF
cat > "$tmp/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
[[ -n "${MSA_TEST_RUNNING_PREFIX:-}" && "$2" == "$MSA_TEST_RUNNING_PREFIX"* ]]
EOF
cat > "$tmp/bin/xcodegen" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$tmp/bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MSA_TEST_XCODE_ARGS"
previous=""
for arg in "$@"; do
  case "$previous" in
    -derivedDataPath) mkdir -p "$arg/Build/Products/Release/MyScreenArt.app/Contents/PlugIns/MyScreenArtThumbnail.appex" ;;
    -archivePath) mkdir -p "$arg/Products/Applications/MyScreenArt.app/Contents/PlugIns/MyScreenArtThumbnail.appex" ;;
    -exportPath) mkdir -p "$arg/MyScreenArt.app/Contents/PlugIns/MyScreenArtThumbnail.appex" ;;
  esac
  previous="$arg"
done
if [[ "${1:-}" == -exportArchive ]]; then exit "${MSA_TEST_EXPORT_STATUS:-0}"; fi
exit "${MSA_TEST_XCODE_STATUS:-0}"
EOF
chmod +x "$tmp/bin/pkill" "$tmp/bin/open" "$tmp/bin/lsregister" "$tmp/bin/pgrep" "$tmp/bin/xcodegen" "$tmp/bin/xcodebuild"

bash -n "$root/scripts/dev/run.sh"
bash -n "$root/scripts/dev/unregister-builds.sh"
bash -n "$root/scripts/dev/xcodebuild.sh"
bash -n "$root/scripts/release/release.sh"
run_output="$(HOME="$tmp/home" MSA_DERIVED_DATA="$tmp/DerivedData" MSA_TEST_OPEN_ARGS="$tmp/open-args" \
  MSA_LSREGISTER="$tmp/bin/lsregister" MSA_TEST_LS_ARGS="$tmp/ls-run-args" PATH="$tmp/bin:$PATH" "$root/scripts/dev/run.sh")"
[[ "$(cat "$tmp/ls-run-args")" == "-f -R -trusted $tmp/DerivedData/Build/Products/Debug/MyScreenArt Dev.app" ]]
expected_recordings="$tmp/home/Movies/MyScreenArt Dev/$expected_id"
[[ "$run_output" == *"Worktree $expected_id"* ]]
[[ "$run_output" == *"Recordings: $expected_recordings"* ]]
[[ "$(sed -n '1p' "$tmp/open-args")" == '-n' ]]
[[ "$(sed -n '2p' "$tmp/open-args")" == "--env" ]]
[[ "$(sed -n '3p' "$tmp/open-args")" == "MYSCREENART_RECORDINGS_DIR=$expected_recordings" ]]
[[ "$(sed -n '4p' "$tmp/open-args")" == "$tmp/DerivedData/Build/Products/Debug/MyScreenArt Dev.app" ]]

# Unregisters missing bundles and idle build products (with their nested bundles); keeps installed copies and running builds.
built="$tmp/wt/build/DerivedData/Build/Products/Debug/MyScreenArt Dev.app"
installed="$tmp/Applications/MyScreenArt.app"
gone="$tmp/gone/build/DerivedData/Build/Products/Debug/MyScreenArt Dev.app"
running="$tmp/running/build/DerivedData/Build/Products/Debug/MyScreenArt Dev.app"
linked_running="$tmp/running-alias/build/DerivedData/Build/Products/Debug/MyScreenArt Dev.app"
unrelated="$tmp/MyScreenArt/build/Other.app"
mkdir -p "$built/Contents/PlugIns/MyScreenArtThumbnail.appex" "$installed/Contents/PlugIns/MyScreenArtThumbnail.appex" \
  "$running/Contents/PlugIns/MyScreenArtThumbnail.appex" "$unrelated"
ln -s "$tmp/running" "$tmp/running-alias"
running_canonical="$(cd -P "$running" && pwd)"
cat > "$tmp/ls-dump" <<EOF
path:                       $built (0x1)
path:                       $built/Contents/PlugIns/MyScreenArtThumbnail.appex (0x2)
path:                       $installed (0x3)
path:                       $installed/Contents/PlugIns/MyScreenArtThumbnail.appex (0x4)
path:                       $gone/Contents/PlugIns/MyScreenArtThumbnail.appex (0x5)
path:                       /Applications/Safari.app (0x6)
path:                       $linked_running (0x7)
path:                       $linked_running/Contents/PlugIns/MyScreenArtThumbnail.appex (0x8)
path:                       $unrelated (0x9)
path:                       $running_canonical (0xa)
path:                       $running_canonical/Contents/PlugIns/MyScreenArtThumbnail.appex (0xb)
EOF
MSA_LSREGISTER="$tmp/bin/lsregister" MSA_TEST_LS_DUMP="$tmp/ls-dump" MSA_TEST_LS_ARGS="$tmp/ls-clean-args" \
  MSA_TEST_RUNNING_PREFIX="$running_canonical/Contents/MacOS/" PATH="$tmp/bin:$PATH" \
  "$root/scripts/dev/unregister-builds.sh" >/dev/null
[[ "$(cat "$tmp/ls-clean-args")" == "$(printf -- '-u %s\n' "$gone/Contents/PlugIns/MyScreenArtThumbnail.appex" \
  "$built" "$built/Contents/PlugIns/MyScreenArtThumbnail.appex")" ]]

# A dry run names the proposed removals and never calls lsregister -u.
dry_output="$(MSA_LSREGISTER="$tmp/bin/lsregister" MSA_TEST_LS_DUMP="$tmp/ls-dump" \
  MSA_TEST_LS_ARGS="$tmp/ls-dry-args" MSA_TEST_RUNNING_PREFIX="$running_canonical/Contents/MacOS/" \
  PATH="$tmp/bin:$PATH" "$root/scripts/dev/unregister-builds.sh" --dry-run)"
[[ ! -e "$tmp/ls-dry-args" ]]
[[ "$dry_output" == *"Would unregister $built"* ]]
[[ "$dry_output" == *"Dry run: no registrations were changed."* ]]
[[ "$dry_output" != *"Unregistering "* ]]

# The wrapper forwards arguments, cleans up on either exit path, and preserves xcodebuild's status.
for expected_status in 0 23; do
  rm -f "$tmp/ls-wrapper-args"
  set +e
  MSA_LSREGISTER="$tmp/bin/lsregister" MSA_TEST_LS_DUMP="$tmp/ls-dump" \
    MSA_TEST_LS_ARGS="$tmp/ls-wrapper-args" MSA_TEST_RUNNING_PREFIX="$running_canonical/Contents/MacOS/" \
    MSA_TEST_XCODE_ARGS="$tmp/xcode-args" MSA_TEST_XCODE_STATUS="$expected_status" PATH="$tmp/bin:$PATH" \
    "$root/scripts/dev/xcodebuild.sh" -scheme 'MyScreenArt Dev' build >"$tmp/wrapper-output"
  actual_status=$?
  set -e
  [[ $actual_status -eq $expected_status ]]
  [[ "$(cat "$tmp/xcode-args")" == "$(printf '%s\n' -scheme 'MyScreenArt Dev' build)" ]]
  [[ "$(cat "$tmp/ls-wrapper-args")" == "$(cat "$tmp/ls-clean-args")" ]]
done

release_output="$(MSA_VERSION=1.2.3 "$root/scripts/release/release.sh" --print-config)"
[[ "$release_output" == *"Root: $root"* ]]
[[ "$release_output" == *"DerivedData: $root/build/release/DerivedData"* ]]
[[ "$release_output" == *"Archive: $root/build/release/MyScreenArt.xcarchive"* ]]
[[ "$release_output" == *"App: $root/build/release/export/MyScreenArt.app"* ]]
[[ "$release_output" == *"DMG asset: $root/build/release/MyScreenArt.dmg"* ]]
[[ "$release_output" == *"Source tag: macos/v1.2.3"* ]]
relative_output="$(MSA_VERSION=1.2.3 "$root/scripts/release/release.sh" --print-config --output relative-release)"
[[ "$relative_output" == *"App: $root/relative-release/export/MyScreenArt.app"* ]]

# The release exit trap also cleans products when --output is outside build/ and export fails.
release_dir="$tmp/custom-release"
release_actual="$(cd -P "$tmp" && pwd)/custom-release"
release_derived="$release_actual/DerivedData/Build/Products/Release/MyScreenArt.app"
release_archive="$release_actual/MyScreenArt.xcarchive/Products/Applications/MyScreenArt.app"
release_app="$release_actual/export/MyScreenArt.app"
cat > "$tmp/release-ls-dump" <<EOF
path:                       $release_derived (0x9)
path:                       $release_derived/Contents/PlugIns/MyScreenArtThumbnail.appex (0x10)
path:                       $release_archive (0xa)
path:                       $release_archive/Contents/PlugIns/MyScreenArtThumbnail.appex (0xb)
path:                       $release_app (0xc)
path:                       $release_app/Contents/PlugIns/MyScreenArtThumbnail.appex (0xd)
EOF
set +e
MSA_BUILD=7 MSA_LSREGISTER="$tmp/bin/lsregister" MSA_TEST_LS_DUMP="$tmp/release-ls-dump" \
  MSA_TEST_LS_ARGS="$tmp/ls-release-args" MSA_TEST_XCODE_ARGS="$tmp/release-xcode-args" \
  MSA_TEST_EXPORT_STATUS=17 PATH="$tmp/bin:$PATH" \
  "$root/scripts/release/release.sh" --no-notarize --no-appcast --output "$release_dir" >"$tmp/release-output" 2>&1
release_status=$?
set -e
[[ $release_status -eq 17 ]]
[[ "$(cat "$tmp/ls-release-args")" == "$(printf -- '-u %s\n' "$release_derived" \
  "$release_derived/Contents/PlugIns/MyScreenArtThumbnail.appex" "$release_archive" \
  "$release_archive/Contents/PlugIns/MyScreenArtThumbnail.appex" "$release_app" \
  "$release_app/Contents/PlugIns/MyScreenArtThumbnail.appex")" ]]

echo 'Script checks passed.'
