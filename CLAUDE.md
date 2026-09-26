# MyScreenArt monorepo

MyScreenArt is a native macOS screen recorder and editor. This repo holds the app and its marketing site.

## Layout
```
apps/macos/     native Swift app, engine package, Quick Look extension, release scripts, docs
apps/web/       marketing site: Next.js (App Router), Tailwind CSS v4, shadcn/ui, bun, oxc
mise.toml       monorepo root: shared tools (bun, node) and cross-project tasks
package.json    bun workspace root (workspaces: apps/web)
```
Each project has its own `CLAUDE.md` with its stack, conventions and contracts. Read the one for the project you're working in: `apps/macos/CLAUDE.md` or `apps/web/CLAUDE.md`.

## Tasks
mise runs everything. The root is a mise monorepo (`monorepo_root = true`), and each project's `mise.toml` defines its own tasks.
```bash
mise run setup               # once: every project's tools (XcodeGen, bun, node) + bun install
mise tasks ls --all          # every task in every project
mise //apps/macos:run        # build and launch the Dev app
mise //apps/web:dev          # marketing site on http://localhost:3000
mise run check               # every project's local gate
```
Inside a project directory, `mise run <task>` runs that project's task (for example `cd apps/macos && mise run build`).

## Checks
There is no GitHub CI. Before pushing, run `mise run check`, or the `check` task of each project you changed.

## Conventions
- Never commit generated output: `MyScreenArt.xcodeproj`, `build/`, `.next/`, `node_modules/`.
- JavaScript dependencies are installed with bun from the repo root (`bun install`); `bun.lock` is committed.
- Facts the site states about the app (requirements, export presets, measured performance) come from `apps/macos`. Update `apps/web` when those change.
