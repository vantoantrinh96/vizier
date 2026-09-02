# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

## Working on this repo

- **Never run `bin/vizier install`, `vizier install`, or `vizier update` from a dev checkout.**
  They swap the skills of whatever first-mate session is live on this machine, mid-flight.
  Working from a checkout without installing is normal; the libraries and skills are read
  directly from it.
- **Never write to `~/.vizier`** — it is live first-mate state. Tests set `VIZIER_HOME` to a
  temp dir; `tests/helpers.sh` establishes that, and `tests/run-all.sh` snapshots the three real
  installed locations and fails loudly if any changed. Keep that property.
- Run the suite with `tests/run-all.sh`, one file with `bash tests/<name>.test.sh`.

## Shell lint

`shellcheck` is **not installed** on this machine, so `tests/run-all.sh` does not run it and a
static pass cannot be claimed without fetching it (the standalone release tarball works).
When you do run it: every file in `lib/` must be at **zero** findings. Test files carry three
tolerated classes only — `SC1091` (sourcing `helpers.sh`), `SC2016` (single-quoted anchors in
`tests/skills.test.sh`), and `SC2148` in `tests/helpers.sh`, which has no shebang by design.
Anything else in a file you touched is a regression.

## The one rule the libraries are built around

Every library **decides**; the skill **executes**. `lib/vizier-supervise-lib.sh` and
`lib/vizier-reconcile-lib.sh` take captured `orca` output as an argument and never call `orca`
themselves — that is what makes them testable, and their tests assert the zero-call property
against `fake_orca_calls`. `lib/vizier-mailbox-lib.sh` is the single owner of the response
envelope; nothing else may open one by hand.

## Fixtures come from the app, never from imagination

`tests/fixtures/README.md` is authoritative and explains the incident behind the rule: parsers
and test doubles were both written from an invented shape, 574 assertions stayed green, and the
feature was inert against the real app. Capture a new fixture from the real CLI rather than
editing one to make a test pass, and build only the cases the app cannot be made to produce —
via the builders in `tests/helpers.sh`, from a captured field set.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
