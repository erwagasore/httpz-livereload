# AGENTS — httpz-livereload

Operating rules for humans + AI.

## Workflow

- Never commit to `main`/`master`.
- Always start on a new branch.
- Only push after the user approves.
- Merge via PR.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/).

- fix → patch
- feat → minor
- feat! / BREAKING CHANGE → major
- chore, docs, refactor, test, ci, style, perf → no version change

## Releases

- Semantic versioning.
- Versions derived from Conventional Commits.
- Release performed locally via `/create-release` (no CI required).
- Manifest: `build.zig.zon` (source of truth for version).
- Tags: vX.Y.Z

## Repo map

- `src/root.zig` — the middleware (SSE endpoint, script injection, binary watcher, reload API)
- `example/main.zig` — minimal httpz server demonstrating the middleware
- `build.zig` — build script (library module, tests, example)
- `build.zig.zon` — package manifest and dependency on httpz
- `docs/` — documentation index

## Merge strategy

- Prefer squash merge.
- PR title must be a valid Conventional Commit.

## Definition of done

- Works locally.
- Tests updated if behaviour changed.
- CHANGELOG updated when user-facing.
- No secrets committed.

## Orientation

- **Entry point**: `src/root.zig` — single-file httpz middleware.
- **Domain**: dev-only browser reload middleware for the httpz web framework.
- **Stack**: Zig 0.15.2, httpz.
