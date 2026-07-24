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

- `SPEC.md` — implementation contract and subsystem boundaries
- `src/root.zig` — the httpz middleware contract (version endpoint, script injection, reload API)
- `src/supervisor.zig` — minimal development supervisor (persistent Zig builder, restart child)
- `example/main.zig` — minimal httpz server demonstrating the middleware
- `build.zig` — build script (library module, tests, example)
- `build.zig.zon` — package manifest and dependency on httpz
- `docs/` — documentation index

## Document precedence

- `SPEC.md` is the implementation contract.
- `AGENTS.md` is the operating contract.
- `README.md` is the user-facing overview and must remain consistent with both.

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
- **Stack**: Zig 0.16.x, httpz.
