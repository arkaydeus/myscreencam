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
chmod +x "$tmp/bin/pkill" "$tmp/bin/open"

bash -n "$root/scripts/dev/run.sh"
bash -n "$root/scripts/release/release.sh"
run_output="$(HOME="$tmp/home" MSA_DERIVED_DATA="$tmp/DerivedData" MSA_TEST_OPEN_ARGS="$tmp/open-args" PATH="$tmp/bin:$PATH" "$root/scripts/dev/run.sh")"
expected_recordings="$tmp/home/Movies/MyScreenArt Dev/$expected_id"
[[ "$run_output" == *"Worktree $expected_id"* ]]
[[ "$run_output" == *"Recordings: $expected_recordings"* ]]
[[ "$(sed -n '1p' "$tmp/open-args")" == '-n' ]]
[[ "$(sed -n '2p' "$tmp/open-args")" == "--env" ]]
[[ "$(sed -n '3p' "$tmp/open-args")" == "MYSCREENART_RECORDINGS_DIR=$expected_recordings" ]]
[[ "$(sed -n '4p' "$tmp/open-args")" == "$tmp/DerivedData/Build/Products/Debug/MyScreenArt Dev.app" ]]

release_output="$(MSA_VERSION=1.2.3 "$root/scripts/release/release.sh" --print-config)"
[[ "$release_output" == *"Root: $root"* ]]
[[ "$release_output" == *"DerivedData: $root/build/release/DerivedData"* ]]
[[ "$release_output" == *"Archive: $root/build/release/MyScreenArt.xcarchive"* ]]
[[ "$release_output" == *"App: $root/build/release/export/MyScreenArt.app"* ]]
[[ "$release_output" == *"DMG asset: $root/build/release/MyScreenArt.dmg"* ]]
[[ "$release_output" == *"Source tag: macos/v1.2.3"* ]]

echo 'Script checks passed.'
