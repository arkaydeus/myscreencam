# Agent instructions

Read `CLAUDE.md` first; it holds the project context, tasks and conventions. The rewrite plan and phase status are in `docs/native-rewrite-plan.md`, and the performance targets are in `docs/perf-baseline.md`.

Quick rules:
- Use `mise run <task>` for everything (build, run, test, lint, format).
- Edit `project.yml`, never the generated `MyScreenArt.xcodeproj`.
- Launch the app only with `mise run run`, so macOS permissions attach to the app.
- Run `mise run lint` and `mise run test` before finishing.
