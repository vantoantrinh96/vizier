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
```

## 0. Read run_id off the wake message itself

This skill starts cold, from an independent wake event — nothing has run
beforehand in this session, so `run_id` is not already in scope. The wake
line is exactly `vizier: <type> run=<run_id> <detail>`; take `run_id` from
it before doing anything else. To find the request this Run belongs to (for
the mode lookup in step 2, or the host later), match it against the open
requests, since one Request is one Run:

```bash
for s in $(vizier_request_open_slugs); do
  [ "$(vizier_request_get "$s" run_id)" = "$run_id" ] && slug=$s && break
done
```

## 1. Read the batch

```bash
batch=$(orca orchestration check --run "$run_id" --peek --json)
```

## 2. Plan every message before acting on any

Pass a mode only for a dispatch whose mode you have **actually established**
from the request file (the project default from `vizier_project_mode`,
overridden per task by any `task N: mode=<mode> because <reason>` note
`brief` left) — never a guess:

```bash
printf '%s\n' "$batch" | vizier_supervise_plan "<the established delivery mode, or empty if you have not established one>"
```

`vizier_supervise_plan` treats anything other than the exact string
`direct-PR` — including an empty or unrecognised mode — as `no-mistakes`
and requires the outcome line. A peeked batch can hold `worker_done`
messages from **several tasks with different modes** at once: when that
happens, resolve the mode **per dispatch** (call `vizier_supervise_plan`
once per message with that dispatch's own mode) rather than one mode for
the whole batch, or pass nothing and accept the strict path for all of them.
Never pass `direct-PR` for a dispatch you have not confirmed is `direct-PR`.

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

## 4. Ack last

```bash
orca orchestration check --run "$run_id" --ack "<the ACK id from the plan>" --json
```

## 5. Report once

**One** consolidated message, containing only what is worth saying: outcomes,
PR URLs, and decisions the captain must make.

- `escalation` / `question` → turn into a question with full context. The
  captain's answer goes back with `orca orchestration reply --id <msg> --body`.
- A `question` carrying a **no-mistakes ask-user finding** does not go straight
  to the captain: run it through the `delivery` skill's policy first.
- A worker gone unusually quiet → `orca orchestration worker-read --dispatch <id>`
  to diagnose. Report what you found; do not guess.
