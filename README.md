# MyScreenArt

A native macOS screen recorder and editor built on ScreenCaptureKit, AVFoundation, VideoToolbox, Core Image and Metal. It aims for high quality recordings with a small CPU, memory and energy footprint.

This monorepo contains:

| Project | What it is | Guide |
|---|---|---|
| [`apps/macos`](apps/macos) | The Mac app (Swift 6, SwiftUI/AppKit) | [README](apps/macos/README.md) |
| [`apps/web`](apps/web) | The marketing site (Next.js, Tailwind CSS, shadcn/ui, bun, oxc) | [README](apps/web/README.md) |

## Requirements
- [mise](https://mise.jdx.dev), which installs everything else (XcodeGen, bun, node)
- For the Mac app: macOS 15 or later on Apple silicon, and Xcode 27 at `/Applications/Xcode.app`

## Getting started
```bash
mise run setup               # install every project's tools and JS dependencies
mise //apps/macos:run        # build and launch "MyScreenArt Dev"
mise //apps/web:dev          # run the site at http://localhost:3000
mise run check               # lint, test and build everything before pushing
```
`mise tasks ls --all` lists every task. See [CLAUDE.md](CLAUDE.md) for the contributor and agent guide.
