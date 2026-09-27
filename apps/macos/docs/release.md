# Releasing MyScreenArt

Releases are built, signed, notarised and published **from this Mac**; GitHub CI doesn't build them.
- **Signing:** Developer ID Application (team `QWD87G9T3P`) with the Hardened Runtime.
- **Packaging:** the notarised, stapled app ships in a notarised, stapled DMG.
- **Updates:** installed apps update themselves with Sparkle 2 from an EdDSA-signed appcast.

The source repo is private, so the DMG and appcast are published to a separate **public** repo, `arkaydeustech/myscreenart-releases`, which only holds GitHub Releases.

| Piece | Where |
|---|---|
| Pipeline script | `scripts/release/release.sh`: `mise run release` (build only) / `mise run release:publish` (build + upload) / `mise run release:dmg` (unnotarised test DMG) |
| Export options | `scripts/release/ExportOptions.plist` (`developer-id`, manual signing) |
| Releases repo | `arkaydeustech/myscreenart-releases` (public; override with `MSA_RELEASES_REPO`) |
| Feed URL | `SUFeedURL` in `App/Info.plist`: `https://github.com/arkaydeustech/myscreenart-releases/releases/latest/download/appcast.xml` |
| Website download | `https://github.com/arkaydeustech/myscreenart-releases/releases/latest/download/MyScreenArt.dmg` (stable asset name uploaded with each release) |
| Public EdDSA key | `SPARKLE_PUBLIC_ED_KEY` build setting in `project.yml` → `SUPublicEDKey` |
| Private EdDSA key | your login Keychain; `generate_appcast` reads it directly, so it's never exported |
| Output | `build/release/`: `MyScreenArt-<version>.dmg`, `appcast.xml`, `export/MyScreenArt.app` |

## One-time setup

### 1. Sparkle EdDSA key (done)
`SPARKLE_PUBLIC_ED_KEY` in `project.yml` holds the public half of the key in your login Keychain. The tools are in `build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/` after any build.
- Print the public key again: `generate_keys -p`.
- **Back the private key up** (e.g. `generate_keys -x backup.txt`, then keep the file in a password manager and delete it). If it's lost, installed copies can't verify new updates.
- **Using a key only for MyScreenArt:**
  1. Run `generate_keys --account myscreenart`.
  2. Put its public key in `project.yml`.
  3. Export `MSA_SPARKLE_ACCOUNT=myscreenart` when releasing.

### 2. Notarisation credentials
Store an App Store Connect API key (preferred) or an app-specific password in the Keychain under the profile name the script uses (`myscreenart-notary`; override with `NOTARY_PROFILE`):
```bash
xcrun notarytool store-credentials myscreenart-notary \
  --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
# or: --apple-id you@example.com --team-id QWD87G9T3P --password <app-specific password>
```

### 3. Releases repo
`arkaydeustech/myscreenart-releases` must exist and be **public**, with no source code in it. `gh` must be logged in with access to push releases there (`gh auth status`).

## Cutting a release
1. Bump `MARKETING_VERSION` in `project.yml` and commit. The build number is the commit count on HEAD, so it always increases.
2. Optionally write release notes to a Markdown file.
3. Run:
   ```bash
   mise run release:publish            # or: scripts/release/release.sh --publish --notes notes.md
   ```
   The script:
   1. Archives the Release build and exports it with Developer ID.
   2. Notarises and staples the app.
   3. Builds the DMG, then signs, notarises and staples it.
   4. Downloads the current `appcast.xml` from the latest release, adds the new version to it, and signs the new version with your Keychain key.
   5. Creates release `v<version>` in the releases repo, with the versioned DMG, a `MyScreenArt.dmg` copy for the website, and the merged `appcast.xml` attached.
   6. Tags the source repo locally.
4. Push the source tag when you're happy: `git push origin macos/v<version>` (namespaced because the source repo is a monorepo).

Installed copies pick the new version up on their next check: every 6 h in Release builds, or via "Check for Updates…".

`--publish` refuses to run if:
- the working tree is dirty;
- the releases repo is missing or private;
- `v<version>` already exists there;
- notarisation, the DMG or the appcast is switched off.

### Other runs
- `mise run release`: the full build, notarisation and appcast, but no upload (output in `build/release/`).
- `mise run release:dmg`: a signed DMG without notarisation or an appcast, for local testing only. Gatekeeper rejects it on other Macs.
- `mise run install`: a Developer ID Release build (no notarisation, DMG or appcast) installed as `/Applications/MyScreenArt.app`, replacing and first quitting any copy there. Locally built apps aren't quarantined, so it opens without notarisation. `mise run install -- --open` also launches it; `--skip-build` reinstalls the last build.

Flags: `--publish`, `--notes FILE`, `--no-notarize`, `--no-appcast`, `--no-dmg` (needs `--no-appcast`), `--output DIR`.

Use `MSA_VERSION=1.2.3 scripts/release/release.sh --print-config` to inspect the resolved build paths, website DMG asset and source tag without building or publishing.

Environment: `MSA_VERSION`, `MSA_BUILD`, `NOTARY_PROFILE`, `MSA_RELEASES_REPO`, `MSA_SPARKLE_ACCOUNT`, `MSA_PREVIOUS_APPCAST` (path or URL).

## Verifying a release
```bash
spctl --assess --type execute --verbose=2 build/release/export/MyScreenArt.app   # "accepted, source=Notarized Developer ID"
xcrun stapler validate build/release/MyScreenArt-<version>.dmg
curl -fsSL https://github.com/arkaydeustech/myscreenart-releases/releases/latest/download/appcast.xml | head
curl -fIL https://github.com/arkaydeustech/myscreenart-releases/releases/latest/download/MyScreenArt.dmg
```
To test an update end to end:
1. Install the previous DMG.
2. Publish the new version.
3. Choose "Check for Updates…" in the installed app.

The updater postpones relaunching while a recording, export or unsaved edit is in progress.
