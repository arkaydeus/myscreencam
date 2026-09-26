<!-- BEGIN:nextjs-agent-rules -->

# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` (resolved from this file's directory; in monorepos the `next` package may not be visible from the repo root) before writing any code. Heed deprecation notices.

This block is written and re-added by `next dev` — verify at `node_modules/next/dist/server/lib/generate-agent-files.js`. Removing it from a diff only re-creates the uncommitted change; committing it with your work keeps the tree clean.

<!-- END:nextjs-agent-rules -->

# MyScreenArt marketing site (`apps/web`)

A single-page marketing site for the MyScreenArt Mac app. It's statically rendered and ships no client JavaScript of its own; the hero demo is pure CSS.

## Stack

- Next.js App Router (`src/app`), React Server Components only.
- Tailwind CSS v4. Theme tokens and the hero keyframes live in `src/app/globals.css`; there is no `tailwind.config`.
- shadcn/ui (`components.json`, base-ui primitives) in `src/components/ui`. Add components with `bunx shadcn@latest add <name>`, and don't hand-edit them beyond small fixes.
- bun for packages and scripts. oxlint (`.oxlintrc.json`) and oxfmt (`.oxfmtrc.json`, sorts Tailwind classes) replace ESLint and Prettier.

## Layout

- `src/app/page.tsx` composes the sections in `src/components/site/`.
- `src/components/site/canvas-demo.tsx` is the hero. Its zoom blocks and click times must match the `msa-*` keyframes in `globals.css` (one 12 s loop).
- `src/lib/site.ts` holds the shared facts: download URL, requirements, description.

## Design

- Palette: gallery paper `#eceef2`, indigo ink `#1b1e45`, ultramarine `#2f46e8` for actions. Cadmium, rose and viridian appear only inside "canvases" (`canvas-paint`), the way the app frames recordings.
- Type: Hubot Sans at 125% width (`font-display`) for headings, Mona Sans for body text, and wide Mona Sans (`font-figures`) for large numbers.
- Motion is limited to the hero loop, and it respects `prefers-reduced-motion`.

## Content rules

Every claim about the app must be true of `apps/macos`: export presets (`ExportKit/ExportPreset.swift`), shortcuts, permissions and measured performance (`apps/macos/docs/perf-baseline.md`). Update the copy when those change. Don't invent pricing, testimonials or logos.

## Tasks

Run these from `apps/web` with `mise run <task>`, or from anywhere with `mise //apps/web:<task>`: `dev`, `build`, `start`, `lint`, `format`, `format:check`, `typecheck`, and `check` (all of them, then a production build).
