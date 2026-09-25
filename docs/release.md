# Releasing MyScreenArt

Release builds are signed with **Developer ID Application** (team `QWD87G9T3P`) and the Hardened Runtime, notarised, stapled and shipped as a DMG. Sparkle 2 updates the installed app from an EdDSA-signed appcast attached to the latest GitHub release.

| Piece | Where |
|---|---|
| Pipeline script | `scripts/release/release.sh` (`mise run release`, `mise run release:dmg`) |
| Export options | `scripts/release/ExportOptions.plist` (`developer-id`, manual signing) |
| CI workflow | `.github/workflows/release.yml` (tag `v*` or manual) |
| Feed URL | `SUFeedURL` in `App/Info.plist`: `https://github.com/arkaydeus/myscreenart-native/releases/latest/download/appcast.xml` |
| Public EdDSA key | `SPARKLE_PUBLIC_ED_KEY` build setting in `project.yml` → `SUPublicEDKey` |
| Output | `build/release/` (`MyScreenArt-<version>.dmg`, `appcast.xml`, `export/MyScreenArt.app`) |

## One-time setup

### 1. Sparkle EdDSA keys
The app only starts its updater once `SPARKLE_PUBLIC_ED_KEY` holds a real key. Until then, "Check for Updates…" is disabled and Settings > Updates says updates are unavailable.

1. Build once (`mise run build`) so SwiftPM downloads Sparkle. Its tools are in `build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/`.
2. Generate the key pair. This stores the private key in your **login Keychain** (item "Private key for signing Sparkle updates"):
   ```bash
   build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
   ```
   It prints the public key (base64, 44 characters).
3. Replace `SPARKLE_PUBLIC_ED_KEY_NOT_SET` in `project.yml` with that public key and commit it.
4. For CI, export the private key and store the file's contents as the `SPARKLE_PRIVATE_KEY` secret. Delete the file afterwards:
   ```bash
   build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt
   ```
   Back the key up somewhere safe. If it's lost, installed copies can't verify new updates.

### 2. Notarisation credentials (local)
Store an App Store Connect API key (preferred) or an app-specific password under the profile name the script uses (`myscreenart-notary`; override with `NOTARY_PROFILE`):
```bash
xcrun notarytool store-credentials myscreenart-notary \
  --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
# or: --apple-id you@example.com --team-id QWD87G9T3P --password <app-specific password>
```

### 3. GitHub secrets (CI)
| Secret | Value |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | `base64 -i DeveloperID.p12` (certificate + private key, exported from Keychain Access) |
| `DEVELOPER_ID_P12_PASSWORD` | the .p12 password |
| `KEYCHAIN_PASSWORD` | any random string |
| `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | App Store Connect API key ID and issuer ID |
| `NOTARY_KEY_P8_BASE64` | `base64 -i AuthKey_<id>.p8` |
| `SPARKLE_PRIVATE_KEY` | contents of the `generate_keys -x` file |

Sparkle and the feed URL need the GitHub releases to be publicly downloadable.

## Cutting a release

### From CI (normal path)
1. Bump `MARKETING_VERSION` in `project.yml` (or rely on the tag), commit.
2. `git tag v0.2.0 && git push origin v0.2.0`.
3. The **Release** workflow archives, notarises, builds and notarises the DMG, then merges the previous `appcast.xml` (downloaded from the latest release) with the new entry. It creates the `v0.2.0` release and attaches `MyScreenArt-0.2.0.dmg` and `appcast.xml`.

A manual run (Actions > Release > Run workflow) builds the same artifacts and uploads them to the run. It only creates a release if you tick **publish**.

### Locally
```bash
mise run release:dmg     # Developer ID build + signed DMG. No notarisation, no appcast (safe to try)
mise run release         # full pipeline: needs the notary profile and the Sparkle key in the Keychain
```
Flags for `scripts/release/release.sh`: `--no-notarize`, `--no-appcast`, `--output DIR`. Environment: `MSA_VERSION`, `MSA_BUILD`, `NOTARY_PROFILE`, `SPARKLE_ED_KEY_FILE` / `SPARKLE_PRIVATE_KEY`, `MSA_PREVIOUS_APPCAST` (path or URL), `MSA_DOWNLOAD_URL_PREFIX`. After a local full run, upload the DMG and `appcast.xml` to a GitHub release tagged `v<version>`.

### What the script does
1. `xcodegen generate`, then `xcodebuild archive` (Release, arm64, Developer ID, Hardened Runtime). `CFBundleVersion` is the commit count (`MSA_BUILD` overrides it). Sparkle compares this number, so it must increase with every release.
2. `xcodebuild -exportArchive` with `ExportOptions.plist`. This re-signs the app, the Quick Look extension and Sparkle's XPC services with secure timestamps.
3. `codesign --verify --deep --strict`.
4. Zip the app, run `notarytool submit --wait`, then `stapler staple` and `spctl --assess` (skipped with `--no-notarize`).
5. `hdiutil` UDZO DMG containing the app and an `Applications` symlink. The DMG is signed with Developer ID and a timestamp, then notarised and stapled.
6. `generate_appcast` (from Sparkle's SwiftPM artifact) signs the DMG with the EdDSA key and writes `appcast.xml`, keeping earlier entries when `MSA_PREVIOUS_APPCAST` is given.

## App-side behaviour
- Debug builds don't check automatically (`SUEnableAutomaticChecks` = `NO` via `MSA_SPARKLE_AUTOMATIC_CHECKS`). Release builds check every 6 hours (`SUScheduledCheckInterval` 21600).
- While `AppModel.isBusy` (recording, exporting or an unsaved edit), a downloaded update doesn't relaunch the app. `UpdateController` implements `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)` and installs once the model goes idle (it observes the model; there's no timer).
- The Quick Look thumbnail extension (`QuickLookThumbnail/`, bundle ID `<app id>.thumbnail`) is embedded in `Contents/PlugIns` and signed like the app.

## Verifying a build
```bash
codesign --verify --deep --strict --verbose=2 build/release/export/MyScreenArt.app
spctl --assess --type execute --verbose=2 build/release/export/MyScreenArt.app      # notarised builds only
xcrun stapler validate build/release/MyScreenArt-<version>.dmg                      # notarised builds only
```
