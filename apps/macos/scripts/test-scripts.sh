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
chmod +x "$tmp/bin/pkill" "$tmp/bin/open" "$tmp/bin/lsregister"

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

# Unregisters missing bundles and idle build products (with their nested bundles); keeps installed copies.
built="$tmp/wt/build/DerivedData/Build/Products/Debug/MyScreenArt Dev.app"
installed="$tmp/Applications/MyScreenArt.app"
gone="$tmp/gone/build/DerivedData/Build/Products/Debug/MyScreenArt Dev.app"
mkdir -p "$built/Contents/PlugIns/MyScreenArtThumbnail.appex" "$installed/Contents/PlugIns/MyScreenArtThumbnail.appex"
cat > "$tmp/ls-dump" <<EOF
path:                       $built (0x1)
path:                       $built/Contents/PlugIns/MyScreenArtThumbnail.appex (0x2)
path:                       $installed (0x3)
path:                       $installed/Contents/PlugIns/MyScreenArtThumbnail.appex (0x4)
path:                       $gone/Contents/PlugIns/MyScreenArtThumbnail.appex (0x5)
path:                       /Applications/Safari.app (0x6)
EOF
MSA_LSREGISTER="$tmp/bin/lsregister" MSA_TEST_LS_DUMP="$tmp/ls-dump" MSA_TEST_LS_ARGS="$tmp/ls-clean-args" \
  "$root/scripts/dev/unregister-builds.sh" >/dev/null
[[ "$(cat "$tmp/ls-clean-args")" == "$(printf -- '-u %s\n' "$gone/Contents/PlugIns/MyScreenArtThumbnail.appex" \
  "$built" "$built/Contents/PlugIns/MyScreenArtThumbnail.appex")" ]]

release_output="$(MSA_VERSION=1.2.3 "$root/scripts/release/release.sh" --print-config)"
[[ "$release_output" == *"Root: $root"* ]]
[[ "$release_output" == *"DerivedData: $root/build/release/DerivedData"* ]]
[[ "$release_output" == *"Archive: $root/build/release/MyScreenArt.xcarchive"* ]]
[[ "$release_output" == *"App: $root/build/release/export/MyScreenArt.app"* ]]
[[ "$release_output" == *"DMG asset: $root/build/release/MyScreenArt.dmg"* ]]
[[ "$release_output" == *"Source tag: macos/v1.2.3"* ]]

echo 'Script checks passed.'
