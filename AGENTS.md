# Agent instructions

Read `CLAUDE.md` first. It describes the monorepo, and each project has its own guide: `apps/macos/CLAUDE.md` (native app) and `apps/web/CLAUDE.md` (marketing site).

Quick rules:
- Use mise for everything: `mise //apps/<project>:<task>` from anywhere, or `mise run <task>` inside a project.
- macOS app: edit `apps/macos/project.yml`, never the generated Xcode project. Launch the app only with `mise //apps/macos:run`, so macOS permissions attach to the app.
- Web: bun for packages, oxlint and oxfmt for lint and formatting (not ESLint or Prettier).
- Run the `check` task of every project you changed before finishing; there is no GitHub CI.
