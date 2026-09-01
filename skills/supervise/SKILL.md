---
name: supervise
description: Process the mailbox after the wake hook fires. Use whenever a wake message says a Run has traffic.
---

# Supervise

The wake hook has already told you a Run has traffic. It **never acks** —
acking is yours, and only after processing.

```bash
. "$VIZIER_DIST/lib/vizier-home.sh"
. "$VIZIER_DIST/lib/vizier-request-lib.sh"
. "$VIZIER_DIST/lib/vizier-supervise-lib.sh"
```

## 1. Read the batch

```bash
batch=$(orca orchestration check --run "$run_id" --peek --json)
```

## 2. Plan every message before acting on any

```bash
printf '%s\n' "$batch" | vizier_supervise_plan "<the task's delivery mode>"
```

Each `PLAN <delivery_id> <disposition> <reason>` line is a decision:

- **`release`** — the work is over. A *failed* `worker_done` releases too.
- **`hold`** — a `no-mistakes` task whose body has no terminal
  `axi_outcome:` line. **Do not release.** A pipeline run may still own the
  branch. `orca orchestration worker-read --dispatch <id>` to diagnose, then
  report to the captain.
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
