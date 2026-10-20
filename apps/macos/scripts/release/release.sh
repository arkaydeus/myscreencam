#!/usr/bin/env bash
# Builds a Developer ID signed, notarised My Screen Cam.app, wraps it in a signed + notarised DMG, refreshes the
# Sparkle appcast and (with --publish) uploads both as a GitHub Release of the public source repo. Runs entirely on
# this Mac; see docs/release.md.
#
#   scripts/release/release.sh [--publish] [--notes FILE] [--no-notarize] [--no-appcast] [--no-dmg] [--output DIR]
#   MSC_VERSION=1.2.3 scripts/release/release.sh --print-config  # inspect paths and release tag
#
# Environment:
#   NOTARY_PROFILE        notarytool keychain profile (default: myscreencam-notary)
#   MSC_VERSION           CFBundleShortVersionString override (default: MARKETING_VERSION in project.yml)
#   MSC_BUILD             CFBundleVersion override (default: commits on HEAD; must increase per release)
#   MSC_RELEASES_REPO     public GitHub repo that hosts DMGs + appcast (default: arkaydeus/myscreencam)
#   MSC_SPARKLE_ACCOUNT   Keychain account of the Sparkle private key (default: Sparkle's default, "ed25519")
#   MSC_PREVIOUS_APPCAST  path or URL of the current appcast.xml, merged so older versions stay listed
#                         (default: the latest release's appcast.xml in MSC_RELEASES_REPO)
set -euo pipefail

notarize=1
appcast=1
dmg_enabled=1
publish=0
print_config=0
notes=""
# The macOS app root (apps/macos in the monorepo), not the git top level.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="$root/build/release"
releases_repo="${MSC_RELEASES_REPO:-arkaydeus/myscreencam}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-notarize) notarize=0 ;;
    --no-appcast) appcast=0 ;;
    --no-dmg) dmg_enabled=0 ;;
    --publish) publish=1 ;;
    --print-config) print_config=1 ;;
    --notes) notes="$2"; shift ;;
    --output) out="$2"; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# The script builds from $root; make custom output paths absolute for the cleanup trap and LaunchServices paths.
# The system Python, so a mise python3 shim can't intercept it.
out="$(/usr/bin/python3 -c 'import os, sys; print(os.path.realpath(os.path.join(sys.argv[1], sys.argv[2])))' "$root" "$out")"

team="QWD87G9T3P"
identity="Developer ID Application"
notary_profile="${NOTARY_PROFILE:-myscreencam-notary}"
derived="$out/DerivedData"
archive="$out/MyScreenCam.xcarchive"
export_dir="$out/export"
app="$export_dir/My Screen Cam.app"
stable_dmg="$out/MyScreenCam.dmg"

release_tag_for_version() { printf 'v%s' "$1"; }

if [[ $print_config -eq 1 ]]; then
  [[ -n "${MSC_VERSION:-}" ]] || { echo "--print-config needs MSC_VERSION" >&2; exit 2; }
  printf 'Root: %s\nDerivedData: %s\nArchive: %s\nApp: %s\nDMG asset: %s\nRelease tag: %s\n' \
    "$root" "$derived" "$archive" "$app" "$stable_dmg" "$(release_tag_for_version "$MSC_VERSION")"
  exit 0
fi

step() { printf '\n==> %s\n' "$*"; }

# The appcast is generated from the DMG.
[[ $dmg_enabled -eq 1 || $appcast -eq 0 ]] || { echo "--no-dmg needs --no-appcast" >&2; exit 2; }

if [[ $publish -eq 1 ]]; then
  [[ $notarize -eq 1 && $appcast -eq 1 && $dmg_enabled -eq 1 ]] \
    || { echo "--publish needs notarisation, the DMG and the appcast" >&2; exit 2; }
  [[ -z "$notes" || -f "$notes" ]] || { echo "Release notes file not found: $notes" >&2; exit 2; }
  gh repo view "$releases_repo" --json visibility --jq .visibility | grep -qx PUBLIC \
    || { echo "$releases_repo must exist and be public (Sparkle downloads from it)" >&2; exit 2; }
  [[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes before publishing" >&2; exit 2; }
  # The release tag is created on the commit being built, so GitHub must already have that commit.
  head_sha="$(git rev-parse HEAD)"
  gh api "repos/$releases_repo/commits/$head_sha" --silent 2>/dev/null \
    || { echo "Push $head_sha to $releases_repo before publishing" >&2; exit 2; }
fi

notarize_file() {
  local file="$1"
  step "Notarising $(basename "$file") (profile: $notary_profile)"
  xcrun notarytool submit "$file" --keychain-profile "$notary_profile" --wait
}

cd "$root"
# Archiving and exporting register their apps with LaunchServices; drop those registrations however the run ends.
trap '"$root/scripts/dev/unregister-builds.sh" --root "$derived" --root "$archive" --root "$export_dir" --root "$out/dmg-staging" || true' EXIT
rm -rf "$archive" "$export_dir" "$out/dmg-staging"
mkdir -p "$out"

build_number="${MSC_BUILD:-$(git rev-list --count HEAD)}"
version_args=(CURRENT_PROJECT_VERSION="$build_number")
[[ -n "${MSC_VERSION:-}" ]] && version_args+=(MARKETING_VERSION="$MSC_VERSION")

step "Generating the Xcode project"
xcodegen generate --quiet

step "Archiving (Release, $identity, build $build_number)"
xcodebuild archive \
  -project MyScreenCam.xcodeproj -scheme MyScreenCam -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived" -archivePath "$archive" \
  DEVELOPMENT_TEAM="$team" "${version_args[@]}" \
  -skipPackagePluginValidation -skipMacroValidation \
  -quiet

step "Exporting (developer-id)"
xcodebuild -exportArchive \
  -archivePath "$archive" -exportPath "$export_dir" \
  -exportOptionsPlist "$root/scripts/release/ExportOptions.plist" \
  -quiet

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
dmg="$out/MyScreenCam-$version.dmg"

step "Verifying the app signature"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -dvv "$app" 2>&1 | grep -E '^(Authority=Developer ID|TeamIdentifier|Runtime Version|Timestamp)'

if [[ $notarize -eq 1 ]]; then
  zip="$out/MyScreenCam-$version-notarize.zip"
  ditto -c -k --keepParent "$app" "$zip"
  notarize_file "$zip"
  rm -f "$zip"
  xcrun stapler staple "$app"
  spctl --assess --type execute --verbose=2 "$app"
else
  echo "Skipping notarisation (--no-notarize): Gatekeeper will reject this build on other Macs."
fi

if [[ $dmg_enabled -eq 1 ]]; then
  step "Building $(basename "$dmg")"
  staging="$out/dmg-staging"
  mkdir -p "$staging"
  ditto "$app" "$staging/My Screen Cam.app"
  ln -s /Applications "$staging/Applications"
  rm -f "$dmg"
  hdiutil create -volname "My Screen Cam $version" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg" -quiet
  rm -rf "$staging"
  codesign --sign "$identity" --timestamp "$dmg"
  codesign --verify --verbose=2 "$dmg"

  if [[ $notarize -eq 1 ]]; then
    notarize_file "$dmg"
    xcrun stapler staple "$dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
  fi
else
  echo "Skipping the DMG (--no-dmg)."
fi

if [[ $appcast -eq 1 ]]; then
  generate_appcast="$(find "$derived/SourcePackages/artifacts" -path '*/Sparkle/bin/generate_appcast' -type f | head -1)"
  [[ -x "$generate_appcast" ]] || { echo "generate_appcast not found under $derived/SourcePackages/artifacts" >&2; exit 1; }
  prefix="https://github.com/$releases_repo/releases/download/$(release_tag_for_version "$version")/"
  previous="${MSC_PREVIOUS_APPCAST:-https://github.com/$releases_repo/releases/latest/download/appcast.xml}"
  updates="$out/updates"
  rm -rf "$updates"
  mkdir -p "$updates"
  cp "$dmg" "$updates/"
  step "Merging the previous appcast ($previous)"
  if [[ "$previous" == http* ]]; then
    curl -fsSL "$previous" -o "$updates/appcast.xml" || { rm -f "$updates/appcast.xml"; echo "No previous appcast; starting a new one."; }
  else
    cp "$previous" "$updates/appcast.xml"
  fi
  step "Generating the Sparkle appcast (download prefix $prefix)"
  # The private key is read from the login Keychain (it never leaves this Mac).
  appcast_args=(--download-url-prefix "$prefix" -o "$updates/appcast.xml")
  [[ -n "${MSC_SPARKLE_ACCOUNT:-}" ]] && appcast_args+=(--account "$MSC_SPARKLE_ACCOUNT")
  "$generate_appcast" "${appcast_args[@]}" "$updates"
  cp "$updates/appcast.xml" "$out/appcast.xml"
else
  echo "Skipping the appcast (--no-appcast)."
fi

if [[ $publish -eq 1 ]]; then
  tag="$(release_tag_for_version "$version")"
  if gh api "repos/$releases_repo/git/ref/tags/$tag" --silent 2>/dev/null; then
    echo "$releases_repo already has a $tag tag; bump MARKETING_VERSION (or MSC_VERSION) first" >&2
    exit 1
  fi
  step "Publishing $tag to $releases_repo"
  notes_args=(--notes "My Screen Cam $version (build $build)")
  [[ -n "$notes" ]] && notes_args=(--notes-file "$notes")
  # The site links to this stable asset name; retain the versioned DMG for Sparkle's appcast.
  cp "$dmg" "$stable_dmg"
  # GitHub creates the tag on the commit that was built.
  gh release create "$tag" --repo "$releases_repo" --target "$head_sha" --title "My Screen Cam $version" \
    "${notes_args[@]}" "$dmg" "$stable_dmg" "$out/appcast.xml"
  echo "Published: https://github.com/$releases_repo/releases/tag/$tag"
  echo "Fetch the tag locally with: git fetch origin tag $tag"
fi

step "Done: My Screen Cam $version ($build)"
echo "App: $app"
[[ $dmg_enabled -eq 1 ]] && echo "DMG: $dmg"
[[ $appcast -eq 1 ]] && echo "Appcast: $out/appcast.xml"
exit 0
