#!/usr/bin/env bash
# Builds a Developer ID signed, notarised MyScreenArt.app, wraps it in a signed + notarised DMG and
# refreshes the Sparkle appcast. See docs/release.md.
#
#   scripts/release/release.sh [--no-notarize] [--no-appcast] [--output DIR]
#
# Environment:
#   NOTARY_PROFILE       notarytool keychain profile (default: myscreenart-notary)
#   MSA_VERSION          CFBundleShortVersionString override (default: MARKETING_VERSION in project.yml)
#   MSA_BUILD            CFBundleVersion override (default: number of commits on HEAD; must increase per release)
#   SPARKLE_ED_KEY_FILE  private EdDSA key file for generate_appcast (default: the login Keychain)
#   SPARKLE_PRIVATE_KEY  private EdDSA key itself (CI); piped to generate_appcast on stdin
#   MSA_PREVIOUS_APPCAST path or URL of the current appcast.xml, merged so older versions stay listed
#   MSA_DOWNLOAD_URL_PREFIX  where the DMG will be downloadable
#                        (default: https://github.com/arkaydeus/myscreenart-native/releases/download/v<version>/)
set -euo pipefail

notarize=1
appcast=1
root="$(git rev-parse --show-toplevel)"
out="$root/build/release"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-notarize) notarize=0 ;;
    --no-appcast) appcast=0 ;;
    --output) out="$2"; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

team="QWD87G9T3P"
identity="Developer ID Application"
notary_profile="${NOTARY_PROFILE:-myscreenart-notary}"
derived="$out/DerivedData"
archive="$out/MyScreenArt.xcarchive"
export_dir="$out/export"
app="$export_dir/MyScreenArt.app"

step() { printf '\n==> %s\n' "$*"; }

notarize_file() {
  local file="$1"
  step "Notarising $(basename "$file") (profile: $notary_profile)"
  xcrun notarytool submit "$file" --keychain-profile "$notary_profile" --wait
}

cd "$root"
rm -rf "$archive" "$export_dir" "$out/dmg-staging"
mkdir -p "$out"

build_number="${MSA_BUILD:-$(git rev-list --count HEAD)}"
version_args=(CURRENT_PROJECT_VERSION="$build_number")
[[ -n "${MSA_VERSION:-}" ]] && version_args+=(MARKETING_VERSION="$MSA_VERSION")

step "Generating the Xcode project"
xcodegen generate --quiet

step "Archiving (Release, $identity, build $build_number)"
xcodebuild archive \
  -project MyScreenArt.xcodeproj -scheme MyScreenArt -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived" -archivePath "$archive" \
  DEVELOPMENT_TEAM="$team" "${version_args[@]}" \
  -quiet

step "Exporting (developer-id)"
xcodebuild -exportArchive \
  -archivePath "$archive" -exportPath "$export_dir" \
  -exportOptionsPlist "$root/scripts/release/ExportOptions.plist" \
  -quiet

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
dmg="$out/MyScreenArt-$version.dmg"

step "Verifying the app signature"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -dvv "$app" 2>&1 | grep -E '^(Authority=Developer ID|TeamIdentifier|Runtime Version|Timestamp)'

if [[ $notarize -eq 1 ]]; then
  zip="$out/MyScreenArt-$version-notarize.zip"
  ditto -c -k --keepParent "$app" "$zip"
  notarize_file "$zip"
  rm -f "$zip"
  xcrun stapler staple "$app"
  spctl --assess --type execute --verbose=2 "$app"
else
  echo "Skipping notarisation (--no-notarize): Gatekeeper will reject this build on other Macs."
fi

step "Building $(basename "$dmg")"
staging="$out/dmg-staging"
mkdir -p "$staging"
ditto "$app" "$staging/MyScreenArt.app"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -volname "MyScreenArt $version" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg" -quiet
rm -rf "$staging"
codesign --sign "$identity" --timestamp "$dmg"
codesign --verify --verbose=2 "$dmg"

if [[ $notarize -eq 1 ]]; then
  notarize_file "$dmg"
  xcrun stapler staple "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi

if [[ $appcast -eq 1 ]]; then
  generate_appcast="$(find "$derived/SourcePackages/artifacts" -path '*/Sparkle/bin/generate_appcast' -type f | head -1)"
  [[ -x "$generate_appcast" ]] || { echo "generate_appcast not found under $derived/SourcePackages/artifacts" >&2; exit 1; }
  prefix="${MSA_DOWNLOAD_URL_PREFIX:-https://github.com/arkaydeus/myscreenart-native/releases/download/v$version/}"
  updates="$out/updates"
  rm -rf "$updates"
  mkdir -p "$updates"
  cp "$dmg" "$updates/"
  if [[ -n "${MSA_PREVIOUS_APPCAST:-}" ]]; then
    step "Merging the previous appcast ($MSA_PREVIOUS_APPCAST)"
    if [[ "$MSA_PREVIOUS_APPCAST" == http* ]]; then
      curl -fsSL "$MSA_PREVIOUS_APPCAST" -o "$updates/appcast.xml" || echo "No previous appcast; starting a new one."
    else
      cp "$MSA_PREVIOUS_APPCAST" "$updates/appcast.xml"
    fi
  fi
  step "Generating the Sparkle appcast (download prefix $prefix)"
  appcast_args=(--download-url-prefix "$prefix" -o "$updates/appcast.xml")
  if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$generate_appcast" --ed-key-file - "${appcast_args[@]}" "$updates"
  elif [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
    "$generate_appcast" --ed-key-file "$SPARKLE_ED_KEY_FILE" "${appcast_args[@]}" "$updates"
  else
    "$generate_appcast" "${appcast_args[@]}" "$updates"
  fi
  cp "$updates/appcast.xml" "$out/appcast.xml"
else
  echo "Skipping the appcast (--no-appcast)."
fi

step "Done: MyScreenArt $version ($build)"
echo "App: $app"
echo "DMG: $dmg"
[[ $appcast -eq 1 ]] && echo "Appcast: $out/appcast.xml"
exit 0
