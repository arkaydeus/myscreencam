# MyScreenArt

A native macOS screen recorder and editor built on ScreenCaptureKit, AVFoundation, VideoToolbox, Core Image and Metal. It aims for high quality recordings with a small CPU, memory and energy footprint.

> Status: all planned phases (0–6) are implemented and pass unit/integration tests. Live capture needs macOS permissions and is being validated with [the live test checklist](docs/live-test-checklist.md). See [the rewrite plan](docs/native-rewrite-plan.md) and [performance numbers](docs/perf-baseline.md).

## Requirements
- macOS 15 or later on Apple silicon
- Xcode 27 at `/Applications/Xcode.app`
- [mise](https://mise.jdx.dev)

## Getting started
```bash
mise install      # installs XcodeGen
mise run run      # generate the Xcode project, build, and launch "MyScreenArt Dev"
mise run test     # engine tests
```
On first use, grant **Screen & System Audio Recording**, **Input Monitoring**, **Camera** and **Microphone** to *MyScreenArt Dev* when macOS asks. `mise run doctor` prints the direct links to those settings panes.

## Docs
- [Live test checklist](docs/live-test-checklist.md): what needs real permissions to verify
- [Legacy inventory](docs/legacy-inventory.md): behaviour spec from the old app
- [Release](docs/release.md): signing, notarisation, Sparkle
- [Rewrite plan](docs/native-rewrite-plan.md): architecture, phases, decisions
- [Performance baseline](docs/perf-baseline.md): legacy numbers and native targets
- [Releasing](docs/release.md): Developer ID signing, notarisation, DMG, Sparkle updates
- [CLAUDE.md](CLAUDE.md): contributor and agent guide
