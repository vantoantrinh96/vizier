---
name: brief
description: Turn one task from an open Request into a briefed, dispatched worker. Use for every task, including retries and review fixes.
---

# Brief and dispatch

`VIZIER_DIST` is not set by the harness — derive it from the home path
before the first `source`, the same way every other skill does:

```bash
VIZIER_DIST="${VIZIER_HOME:-$HOME/.vizier}/dist"
. "$VIZIER_DIST/lib/vizier-home.sh"
. "$VIZIER_DIST/lib/vizier-request-lib.sh"
. "$VIZIER_DIST/lib/vizier-brief-lib.sh"
```

## 0. Establish which request this task belongs to

`slug` is not already in scope either — nothing sets it before this point.
Never infer it from the working directory: the same rule applies here as
everywhere else in this project — the working directory is a suggestion,
never authority.

```bash
open=$(vizier_request_open_slugs)
n=$(printf '%s\n' "$open" | sed '/^$/d' | wc -l | tr -d ' ')
```

- **Exactly one** open request → that is the slug (`slug=$open`). State it in one line; with only one possible answer, this is not a question.
- **More than one** open → ask the captain which request this task belongs to, listing each slug from `vizier_request_open_slugs` with the first line of its body, so the choice is meaningful.
- **None** open → there is nothing to brief against. Say so, and route the captain to the request skill to open one — never create a Request from inside `brief`.

## 1. Read the request

`run_id` and `project` are not already in scope — this skill can run long
after `request` opened the Request, in a separate turn. Read both from the
request file the same way `host` is read later:

```bash
run_id=$(vizier_request_get "$slug" run_id)
project=$(vizier_request_get "$slug" project)
```

## 2. Settle the delivery mode — before writing anything

```bash
mode=$(vizier_project_mode "$project") || mode=""
```

- Empty → the project has no knowledge file. **Ask the captain** which mode.
  Never guess, and never default to `direct-PR` just because it is the default
  posture elsewhere.
- The captain named a different mode for *this* task → theirs wins, and you
  write a one-line reason into the request file:
  `vizier_request_note "$slug" "task N: mode=<mode> because <reason>"`.

Mode is locked in **per task, at creation time**. It never changes mid-task.

## 3. Assemble the brief

```bash
spec=$(vizier_brief_assemble "$project" "$mode" "<the concrete task and its definition of done>")
```

Never hand-write a spec. The four layers exist so that layer 1 (the
invariants) cannot be forgotten, and a hand-written spec forgets it first.

## 4. Create the task

```bash
task=$(orca orchestration task-create --spec "$spec" --task-title "<short title>" --run "$run_id" --json | jq -r '.result.task.id')
```

## 5. Start the worker

The host **inherits the request's host** — read it from the request file, never
re-ask, never substitute:

```bash
host=$(vizier_request_get "$slug" host)
```

Local host → omit `--on` entirely. Any other host → `--on "$host"` with the
host's *name*.

**`--repo` is required and must be exact** — Orca's own note on `worker-start`
is "Use exact `--repo` on the selected server; project/host convenience
routing remains on worktree create." Take it from the setup record for *this*
request's project on *this* request's host: the same record routing already
used to decide the host was eligible. Never the working directory, never a
guess.

```bash
# The host in the request file is the local host's ID ("local") or a remote
# host's NAME -- exactly the values `--on` takes. `project setups --host`
# takes the host ID, so map through `host list` for anything but local. This
# is the three-flags rule in lib/vizier-routing-lib.sh: health, setups and
# dispatch each name the same host differently.
if [ "$host" = "local" ]; then
  host_id=local
else
  host_id=$(orca host list --json | jq -r --arg n "$host" \
    '.result.hosts[] | select(.name == $n) | .id' | head -1)
fi
repo_path=$(orca project setups --project "$project" --host "$host_id" --json \
  | jq -r '.result.setups[0].path // empty')
```

An empty `repo_path` **stops the dispatch**. Report it to the captain: the
project has no ready setup on the host the request names, which is a routing
question, not something to work around by falling back to a different repo.

`worker-start` **needs a sender terminal**, and an ordinary editor session is
not one. Discover a live handle and pass `--from`:

```bash
from=$(orca terminal list --json | jq -r '.result.terminals[0].handle // empty')
```

An empty `from` **stops the dispatch** — say so to the captain rather than
retrying. Only `send` and `worker-start` need this; every read path, and
`run-use`, work without it (`docs/decisions/2026-09-02-sender-terminal.md`).

### Making the worktree is a SEPARATE COMMAND. It is two calls, not one.

`--worktree new-top-level` **does not work and never did.** Measured twice, the
second time with `--name` and a valid `--repo` both present:
`selector_not_found`, with `stage: null`, no `effects` and no recovery command.
`new-child` and `current` fail the same way. There is no `--worktree` value
that means "make me a new one" — `worker-start` only ever *selects* a worktree
that already exists.

```bash
wt=$(orca worktree create --name "<short-name>" --repo "path:$repo_path" \
       --setup run --json | jq -r '.result.worktree.path')
```

An empty `wt` **stops the dispatch**, same as an empty handle.

Then dispatch into it, with **no creation flags at all** — `--name`, `--repo`,
`--base-branch`, `--display-name`, `--comment` and `--setup` are all rejected
once the worktree exists, and they belong to the call above anyway:

```bash
receipt=$(orca orchestration worker-start \
  --task "$task" --run "$run_id" --from "$from" \
  --agent claude --worktree "path:$wt" \
  ${host:+--on "$host"} \
  --json)
```

A successful dispatch reads `state: ready` **and** `stage: input_accepted`.
Those are two different things: the agent launched, *and* it took the prompt.
Check for both.

### `agent_prompt_blocked` — the agent started but never got the task

```
worker-show -> status "failed", last_failure "agent_prompt_blocked"
```

The agent launched into a terminal that is sitting on a **first-run dialog** —
for Claude Code, "Is this a project you created or one you trust?" — so Orca's
prompt paste landed in the dialog instead of the agent, arriving as a literal
`^[[200~`.

**This latches, and no CLI call clears it.** `orca terminal send --text 1
--enter` against that terminal is itself refused with `agent_prompt_blocked`.
Do not retry the dispatch; it will fail identically.

Tell the captain exactly this: the worktree path needs to be trusted in the
agent once, in the Orca UI, and **trust is per exact path** — trusting the
repo root does *not* cover `~/orca/workspaces/<repo>/<name>`, which is where a
new worktree lives. Then re-dispatch.

`--terminal <handle>` is not a workaround: pointing `worker-start` at an
ordinary shell gives `agent_unconfigured`, "Terminal … is not running a
recognized agent."

### Reusing a worktree that already exists

A retry or a follow-on task in a checkout that is already there selects it and
passes **no creation flags at all**:

```bash
orca orchestration worker-start \
  --task "$task" --run "$run_id" \
  --agent claude --worktree "path:$existing_worktree_path" \
  ${host:+--on "$host"} \
  --json
```

Model hints from the project file (`model_scout`, `effort_scout`, …) are applied
as `--model <id> --effort <level>`. Orca **requires --model whenever
--effort is given**, and accepts neither when reusing a terminal via
`--terminal`.

The dispatch id is **`.result.dispatchId`** — camelCase, at the top of
`result`. There is no `.result.dispatch` object; reading one gets you an empty
id, and a note written with an empty id is not a note at all: the reader
requires both ids non-empty, so the whole line is dropped and the dispatch
becomes invisible to everything that reads these notes back.

Record it in the request file in **exactly** this shape —
`task <id> -> dispatch <id> (<mode>)` — because **two** readers join on that
line: `supervise`'s per-dispatch mode map, and activation's reconciliation of
the request against `orca orchestration worker-list` (`commands/vizier.md`
step 5). Both go through `vizier_request_dispatch_notes` in
`lib/vizier-request-lib.sh`, which owns the shape and is anchored to the start
of the line:

```bash
dispatch=$(printf '%s' "$receipt" | jq -r '.result.dispatchId')
vizier_request_note "$slug" "task $task -> dispatch $dispatch ($mode)"
```

A successful dispatch reads `state: ready` with `stage: input_accepted` — the
agent launched *and* took the prompt. Those are two different things: a
dispatch can launch and then fail with `last_failure: agent_prompt_blocked`
if the agent is sitting on a first-run dialog.

## 6. When worker-start fails

The receipt is the instruction. It carries `stage`/`failedStage`, `setup`,
`effects`, `residualResources`, and a recovery command.

**Read the receipt, do exactly the recovery it names, never retry blind.** On a
retry use `--retry-of <dispatch_id>` to chain the history — and repeat the
placement flags, because a retry does not inherit them. Leftover resources are
reported to the captain.

A wait-for-setup timeout that leaves setup `running` is **normal**, not
evidence of failure. Check again before concluding anything.
