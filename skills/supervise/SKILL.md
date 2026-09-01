---
name: supervise
description: Process the mailbox after the wake hook fires. Use whenever a wake message says a Run has traffic.
---

# Supervise

The wake hook has already told you a Run has traffic. It **never acks** —
acking is yours, and only after processing.

`VIZIER_DIST` is not set by the harness — derive it from the home path
before the first `source`, the same way every other skill does:

```bash
VIZIER_DIST="${VIZIER_HOME:-$HOME/.vizier}/dist"
. "$VIZIER_DIST/lib/vizier-home.sh"
. "$VIZIER_DIST/lib/vizier-request-lib.sh"
. "$VIZIER_DIST/lib/vizier-supervise-lib.sh"
. "$VIZIER_DIST/lib/vizier-brief-lib.sh"
```

`brief-lib` is here for `vizier_project_mode` in §2 — it is not only `brief`'s
library. Without it that call is a `command not found` swallowed by `||
default_mode=""`, which silently holds every healthy `direct-PR` worker.

## 0. Read run_id off the wake message itself

This skill starts cold, from an independent wake event — nothing has run
beforehand in this session, so `run_id` is not already in scope. The wake
line is exactly `vizier: <type> run=<run_id> <detail>`; take `run_id` from
it before doing anything else. Translate it to the request's slug — needed
for the mode map below, and for `host` later — with the shared library
lookup, since a wake event never carries the slug itself:

```bash
slug=$(vizier_request_slug_for_run "$run_id")
```

## 1. Read the batch

```bash
batch=$(orca orchestration check --run "$run_id" --peek --json)
```

## 2. Plan every message before acting on any

Build a per-dispatch mode map from the request file's own dispatch notes.
`brief` writes one line per dispatch, `task <id> -> dispatch <id> (<mode>)` —
keyed by dispatch id. The per-task override note is **not** a usable join
key here: it's keyed by task number, and the batch you're resolving only
carries `dispatch_id`. Pull dispatch id and mode out of the dispatch note —
**anchored to the start of the line**, never a bare `.*` search across the
whole file: the request body holds the captain's own words verbatim, and a
captain who pastes a previous run's notes into a new request can reproduce
`-> dispatch <id> (<mode>)`-shaped prose by accident, with no need for
anyone to exploit anything. Only a line that actually starts with `task `
and has the real note's shape counts:

```bash
f=$(vizier_request_path "$slug")
map=$(mktemp)
sed -n 's/^task [^[:space:]]* -> dispatch \([^[:space:]]*\) (\(.*\))$/\1\t\2/p' "$f" > "$map"
```

The fallback for a dispatch the map doesn't name is the project's own
default mode — never a guess, and if even that is unavailable, the strict
check applies (see below):

```bash
default_mode=$(vizier_project_mode "$(vizier_request_get "$slug" project)") || default_mode=""
plan=$(printf '%s\n' "$batch" | vizier_supervise_plan "$default_mode" "$map")
printf '%s\n' "$plan"
```

Keep the plan in `$plan`: §4 acks off it, one `--ack` per `ACK` line.

This is **one call over the whole batch**, never one call per message —
`vizier_supervise_plan` resolves the mode per dispatch internally from the
map you gave it. Splitting it into per-message calls breaks the ACK
invariant below: "did anything fail to classify" has to be computed over
the one true peeked batch, not recomputed separately per message.
`vizier_supervise_plan` treats anything other than the exact string
`direct-PR` — including an empty or unrecognised mode, from the map or from
`default_mode` — as `no-mistakes` and requires the outcome line.

Each `PLAN <delivery_id> <disposition> <reason>` line is a decision:

- **`release`** — the work is over. A *failed* `worker_done` releases too.
- **`hold`** — a task whose body has no terminal `axi_outcome:` line, under
  the strict (default) check. **Do not release.** A pipeline run may still
  own the branch. `orca orchestration worker-read --dispatch <id>` to
  diagnose, then report to the captain.
- **`none`** — not a terminal event. Never release on a timeout, TUI idle,
  heartbeat, status, question, escalation, or a stale `worker_done`.

If the plan prints no `ACK` line, something in the batch did not classify.
**Do not ack anything.** Orca replays an unacked batch, so nothing is lost;
acking now would lose a message permanently.

## 3. Act on each `release`

Decide where the terminal goes **before** acking.

A follow-on task exists for the same agent → transfer, don't release:

```bash
handle=$(orca orchestration worker-show --dispatch "<id>" --json | jq -r '.result.worker.agent_terminal_handle')
orca orchestration worker-start --task "<next_task>" --terminal "$handle" --run "$run_id" --json
```

Otherwise release:

```bash
orca orchestration worker-release --dispatch "<id>" --json
```

A receipt of `release_pending` or `release_unknown` → follow the receipt's own
recovery action. **Substituting `terminal close` is forbidden.** Repeating
`worker-release` after a replayed delivery is safe.

The captain asked to keep a terminal (`worker-retain`) → keep it.

## 4. Ack last — one `--ack` per `ACK` line

The plan prints **one `ACK <delivery_id>` line per message in the batch**, in
batch order. Issue one `--ack` for each of them. An ack removes exactly the
delivery it names, so a single `--ack` for a multi-message batch leaves the
rest queued — the next wake replays them, re-plans a release, re-runs
`worker-release` on a dispatch already released, and re-reports the same PR to
the captain.

```bash
printf '%s\n' "$plan" | sed -n 's/^ACK //p' | while IFS= read -r ack_id; do
  orca orchestration check --run "$run_id" --ack "$ack_id" --json
done
```

Acking an id twice is harmless; leaving one unacked is not.

## 5. Report once

**One** consolidated message, containing only what is worth saying: outcomes,
PR URLs, and decisions the captain must make.

- `escalation` / `question` → turn into a question with full context. The
  captain's answer goes back with `orca orchestration reply --id <msg> --body`.
- A `question` carrying a **no-mistakes ask-user finding** does not go straight
  to the captain: run it through the `delivery` skill's policy first.
- A worker gone unusually quiet → `orca orchestration worker-read --dispatch <id>`
  to diagnose. Report what you found; do not guess.
