# Releasing My Screen Cam

Releases are built, signed, notarised and published **from this Mac**; GitHub CI doesn't build them.
- **Signing:** Developer ID Application (team `QWD87G9T3P`) with the Hardened Runtime.
- **Packaging:** the notarised, stapled app ships in a notarised, stapled DMG.
- **Updates:** installed apps update themselves with Sparkle 2 from an EdDSA-signed appcast.

The DMG and appcast are uploaded from this Mac as GitHub Releases of the public source repo, `arkaydeus/myscreencam`. GitHub only hosts the files; nothing runs in Actions.

| Piece | Where |
|---|---|
| Version bump | `scripts/release/set-version.sh`: `mise run release:version -- v1.2.3` |
| Pipeline script | `scripts/release/release.sh`: `mise run release` (build only) / `mise run release:publish` (build + upload) / `mise run release:dmg` (unnotarised test DMG) |
| Export options | `scripts/release/ExportOptions.plist` (`developer-id`, manual signing) |
| Releases repo | `arkaydeus/myscreencam`, the public source repo containing the build commit (override with `MSC_RELEASES_REPO`) |
| Feed URL | `SUFeedURL` in `App/Info.plist`: `https://github.com/arkaydeus/myscreencam/releases/latest/download/appcast.xml` |
| Website download | `https://github.com/arkaydeus/myscreencam/releases/latest/download/MyScreenCam.dmg` (stable asset name uploaded with each release) |
| Public EdDSA key | `SPARKLE_PUBLIC_ED_KEY` build setting in `project.yml` → `SUPublicEDKey` |
| Private EdDSA key | your login Keychain; `generate_appcast` reads it directly, so it's never exported |
| Output | `build/release/`: `MyScreenCam-<version>.dmg`, `appcast.xml`, `export/My Screen Cam.app` |

## One-time setup

### 1. Sparkle EdDSA key (done)
`SPARKLE_PUBLIC_ED_KEY` in `project.yml` holds the public half of the key in your login Keychain. The tools are in `build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/` after any build.
- Print the public key again: `generate_keys -p`.
- **Back the private key up** (e.g. `generate_keys -x backup.txt`, then keep the file in a password manager and delete it). If it's lost, installed copies can't verify new updates.
- **Using a key only for My Screen Cam:**
  1. Run `generate_keys --account myscreencam`.
  2. Put its public key in `project.yml`.
  3. Export `MSC_SPARKLE_ACCOUNT=myscreencam` when releasing.

### 2. Notarisation credentials
Store an App Store Connect API key (preferred) or an app-specific password in the Keychain under the profile name the script uses (`notary-arktech`; override with `NOTARY_PROFILE`):
```bash
xcrun notarytool store-credentials notary-arktech \
  --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
# or: --apple-id you@example.com --team-id QWD87G9T3P --password <app-specific password>
```

### 3. GitHub access
`arkaydeus/myscreencam` must stay **public** (Sparkle and the website download from it anonymously). `gh` must be logged in with access to create releases there (`gh auth status`).

`MSC_RELEASES_REPO` selects the public source repository for commit checks, release tags and assets. It must already contain the exact HEAD commit being built; a separate hosting-only repository is unsupported. When changing the default repository, also update `SUFeedURL` in `App/Info.plist`, the website's download and releases URLs, and the repository URLs in this guide so installed apps and the website find those releases.

## Cutting a release
From the repo root (or `apps/macos`):
1. Set the version:
   ```bash
   mise run release:version -- v1.2.3
   ```
   This sets `MARKETING_VERSION` in `project.yml`, commits it and pushes the current branch. Staged or unstaged changes to `project.yml` are rejected; unrelated changes stay out of the version commit. The release tag is created on that commit, so GitHub must have it. Use a higher numeric `major.minor.patch` version without leading zeros (optionally prefixed with `v`). The build number is the commit count on HEAD, so it always increases.
2. Optionally write release notes to a Markdown file.
3. Publish:
   ```bash
   mise run release:publish            # or, in apps/macos: scripts/release/release.sh --publish --notes notes.md
   ```
   The script:
   1. Archives the Release build and exports it with Developer ID.
   2. Notarises and staples the app.
   3. Builds the DMG, then signs, notarises and staples it.
   4. Downloads the current `appcast.xml` from the latest release, adds the new version to it, and signs the new version with your Keychain key.
   5. Creates release `v<version>` in the repo, with the versioned DMG, a `MyScreenCam.dmg` copy for the website, and the merged `appcast.xml` attached.
   6. GitHub creates the `v<version>` tag on the commit you built. Fetch it with `git fetch origin tag v<version>`.

Installed copies pick the new version up on their next check: every 6 h in Release builds, or via "Check for Updates…".

`--publish` refuses to run if:
- the working tree is dirty;
- the repo is missing or private;
- HEAD hasn't been pushed;
- `v<version>` already exists there;
- notarisation, the DMG or the appcast is switched off.

### Other runs
- `mise run release`: the full build, notarisation and appcast, but no upload (output in `build/release/`).
- `mise run release:dmg`: a signed DMG without notarisation or an appcast, for local testing only. Gatekeeper rejects it on other Macs.
- `mise run install`: a Developer ID Release build (no notarisation, DMG or appcast) installed as `/Applications/My Screen Cam.app`, replacing and first quitting any copy there. Locally built apps aren't quarantined, so it opens without notarisation. `mise run install -- --open` also launches it; `--skip-build` reinstalls the last build.

Flags: `--publish`, `--notes FILE`, `--no-notarize`, `--no-appcast`, `--no-dmg` (needs `--no-appcast`), `--output DIR`.

Use `MSC_VERSION=1.2.3 scripts/release/release.sh --print-config` to inspect the resolved build paths, website DMG asset and release tag without building or publishing.

Environment: `MSC_VERSION`, `MSC_BUILD`, `NOTARY_PROFILE`, `MSC_RELEASES_REPO`, `MSC_SPARKLE_ACCOUNT`, `MSC_PREVIOUS_APPCAST` (path or URL).

## Verifying a release
```bash
spctl --assess --type execute --verbose=2 build/release/export/My Screen Cam.app   # "accepted, source=Notarized Developer ID"
xcrun stapler validate build/release/MyScreenCam-<version>.dmg
curl -fsSL https://github.com/arkaydeus/myscreencam/releases/latest/download/appcast.xml | head
curl -fIL https://github.com/arkaydeus/myscreencam/releases/latest/download/MyScreenCam.dmg
```
To test an update end to end:
1. Install the previous DMG.
2. Publish the new version.
3. Choose "Check for Updates…" in the installed app.

The updater postpones relaunching while a recording, export or unsaved edit is in progress.
