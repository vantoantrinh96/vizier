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

## 0. Read the request

`run_id` and `project` are not already in scope — this skill can run long
after `request` opened the Request, in a separate turn. Read both from the
request file the same way `host` is read later:

```bash
run_id=$(vizier_request_get "$slug" run_id)
project=$(vizier_request_get "$slug" project)
```

## 1. Settle the delivery mode — before writing anything

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

## 2. Assemble the brief

```bash
spec=$(vizier_brief_assemble "$project" "$mode" "<the concrete task and its definition of done>")
```

Never hand-write a spec. The four layers exist so that layer 1 (the
invariants) cannot be forgotten, and a hand-written spec forgets it first.

## 3. Create the task

```bash
task=$(orca orchestration task-create --spec "$spec" --task-title "<short title>" --run "$run_id" --json | jq -r '.result.task.id')
```

## 4. Start the worker

The host **inherits the request's host** — read it from the request file, never
re-ask, never substitute:

```bash
host=$(vizier_request_get "$slug" host)
```

Local host → omit `--on` entirely. Any other host → `--on "$host"` with the
host's *name*.

```bash
orca orchestration worker-start \
  --task "$task" --run "$run_id" \
  --agent claude --worktree new-top-level --setup run \
  --name "<short-name>" \
  ${host:+--on "$host"} \
  --json
```

Model hints from the project file (`model_scout`, `effort_scout`, …) are applied
as `--model <id> --effort <level>`. Orca **requires --model whenever
--effort is given**, and accepts neither when reusing a terminal via
`--terminal`.

Record the dispatch in the request file:
`vizier_request_note "$slug" "task <id> -> dispatch <id> (<mode>)"`.

## 5. When worker-start fails

The receipt is the instruction. It carries `stage`/`failedStage`, `setup`,
`effects`, `residualResources`, and a recovery command.

**Read the receipt, do exactly the recovery it names, never retry blind.** On a
retry use `--retry-of <dispatch_id>` to chain the history — and repeat the
placement flags, because a retry does not inherit them. Leftover resources are
reported to the captain.

A wait-for-setup timeout that leaves setup `running` is **normal**, not
evidence of failure. Check again before concluding anything.
