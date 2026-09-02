# Project knowledge file

One file per project at `~/.vizier/projects/<name>.md`. The captain edits it
directly. The first mate proposes additions but writes them only once the
captain agrees.

```markdown
---
delivery: direct-PR
model_scout: claude-haiku-4-5-20251001
effort_scout: low
model_ship: claude-opus-5
effort_ship: high
---
How to build: `make build`
How to test: `make test`
PRs target `develop`, never `main`. Commits use Conventional Commits.
Known pitfall: the integration suite needs `docker compose up -d db` first.
```

`delivery` is the project's standard posture and the only required key. A
project with no file at all makes the first mate **ask the captain** for the
mode rather than assume one.

The `model_*` / `effort_*` hints are applied via `worker-start --model … --effort …`.
Orca accepts `--effort` only together with `--model`, and only for a new
terminal — never when reusing one via `--terminal`.

The body is copied verbatim into layer 2 of every brief for this project, so
write it as instructions to someone who has never seen the repo.
