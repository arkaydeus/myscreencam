<!-- BEGIN:nextjs-agent-rules -->

# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` (resolved from this file's directory; in monorepos the `next` package may not be visible from the repo root) before writing any code. Heed deprecation notices.

This block is written and re-added by `next dev` — verify at `node_modules/next/dist/server/lib/generate-agent-files.js`. Removing it from a diff only re-creates the uncommitted change; committing it with your work keeps the tree clean.

<!-- END:nextjs-agent-rules -->

# My Screen Cam marketing site (`apps/web`)

A single-page marketing site for the My Screen Cam Mac app. It's statically rendered. Client JavaScript of its own is limited to the hero editor's animation loop (`editor-demo.tsx`) and the highlights gallery's paddle buttons (`highlights-gallery.tsx`); both render fully on the server, and the gallery still scrolls natively without its script.

## Stack

- Next.js App Router (`src/app`), React Server Components apart from the `"use client"` hero editor and gallery.
- Tailwind CSS v4. Theme tokens (including the app's own `ui-*` colours) and the `ui-units` scaling utilities live in `src/app/globals.css`; there is no `tailwind.config`.
- shadcn/ui (`components.json`, base-ui primitives) in `src/components/ui`. Add components with `bunx shadcn@latest add <name>`, and don't hand-edit them beyond small fixes.
- bun for packages and scripts. oxlint (`.oxlintrc.json`) and oxfmt (`.oxfmtrc.json`, sorts Tailwind classes) replace ESLint and Prettier.

## Layout

- `src/app/page.tsx` composes the sections in `src/components/site/`.
- `src/components/site/editor-demo.tsx` is the hero: the app's editor window drawn in HTML at its real 1280 × 800 pt layout, playing a recording (`demo-recording.tsx`) while a pointer works the inspector. One 24 s clock drives it; the zooms, clicks, cursor path and the pointer's script live in `editor-demo-script.ts`, which `tests/site-contract.test.mjs` checks.
- App mocks are drawn in the app's points, not CSS pixels: inside `AppFrame` (`app-ui.tsx`) Tailwind's spacing step is one point, so copy sizes straight from the SwiftUI sources (`apps/macos/App/Sources/Theme/AppTheme.swift`, the editor panels). `app-ui.tsx` holds the themed controls, `app-windows.tsx` the Recorder, Export sheet and timeline stills in "How it works". When the app's UI changes, update the mocks to match.
- `src/lib/site.ts` holds the shared facts: download URL, requirements, description.
- The app icon is `src/assets/app-icon.png` (drawn by `LogoMark`, and in the OG image). `src/app/icon.png` and `apple-icon.png` are copies made from the same artwork as `apps/macos/App/Resources/AppIcon.icon`.
- Measured figures carry a footnote marker (`FootnoteRef`) that links to the numbered note in `SiteFooter`.

## Design

- Modelled on apple.com/mac: a translucent sticky product bar, big centred headlines, sections alternating white, light grey (`paper` `#f5f5f7`) and black, rounded tiles (28 px) and pill buttons.
- Palette: text `ink` `#1d1d1f`, secondary text `graphite` `#6e6e73`, rules `#d2d2d7`, ultramarine `#2f46e8` for actions and links. Cadmium, rose and viridian appear only inside "canvases" (`canvas-paint`), the way the app frames recordings, plus cadmium for zoom blocks, click rings and the Performance eyebrow. App mocks use the app's own dark theme (`ui-*` tokens) instead.
- Type: the system font stack (SF Pro on a Mac), semibold for headings. No web fonts are loaded.
- Layout: `page-width` is the 1160 px content column, `page-width-narrow` the 980 px reading column, and `gallery-inset` lines a full-bleed scroller up with them. Section headings use `sectionTitle` from `brand.tsx`.
- Motion is limited to the hero loop. It pauses off screen and in hidden tabs, and with `prefers-reduced-motion` it shows one still frame.

## Content rules

Every claim about the app must be true of `apps/macos`: export presets (`ExportKit/ExportPreset.swift`), shortcuts, permissions and measured performance (`apps/macos/docs/perf-baseline.md`). Update the copy when those change. The app is free, with no checkout or licence keys. Don't invent testimonials or logos.

## Tasks

Run these from `apps/web` with `mise run <task>`, or from anywhere with `mise //apps/web:<task>`: `dev`, `build`, `start`, `lint`, `format`, `format:check`, `typecheck`, and `check` (all of them, then a production build).
