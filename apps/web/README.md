# My Screen Cam website

The marketing site for My Screen Cam, in `apps/web` of the monorepo. It's built with Next.js (App Router), Tailwind CSS v4, shadcn/ui, bun and oxc (oxlint + oxfmt).

```bash
mise run dev            # http://localhost:3000
mise run check          # oxfmt --check, oxlint, tsc, next build
mise run format         # oxfmt in place
```

From outside this directory, use `mise //apps/web:<task>`. See [AGENTS.md](AGENTS.md) for structure, design tokens and content rules.

The **Download for Mac** buttons link to the latest release of `arkaydeus/myscreencam` (set in `src/lib/site.ts`).
