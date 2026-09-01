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
if [ -z "$slug" ]; then
  printf 'vizier: wake for run_id=%s, but no OPEN request names that Run.\n' "$run_id" >&2
  printf 'vizier: not processing this batch. Check ~/.vizier/requests/ -- the\n' >&2
  printf 'vizier: request was probably closed while a worker was still running.\n' >&2
fi
```

**An empty `slug` stops this skill.** Say the above to the captain and go no
further: do not read the batch, do not release anything, and above all **do
not ack** — an unacked batch is replayed, so stopping here loses nothing,
while acking a batch you cannot attribute to a request loses it for good.

The guard is not decoration. `vizier_request_slug_for_run` returns rc 0 with
empty output when nothing matches, so without it every later step runs against
`vizier_request_path ""` and the only symptom is
`sed: .../requests/.md: No such file` on stderr. That fails closed, but it
fails closed *unexplained* — and an unexplained failure in a wake hook is
indistinguishable from the hook not having fired.

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

Keep the plan in `$plan`: §5 acks off it, one `--ack` per `ACK` line.

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
- **`reply`** — a `question` or an `escalation`: **a human owes an answer.**
  Never a release, whatever the body says. This is the one disposition that
  leaves work outstanding after the plan is done, and §4 must clear it before
  anything is acked.
- **`none`** — not a terminal event. Never release on a timeout, TUI idle,
  heartbeat, status, or a stale `worker_done`.

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

## 4. Answer every `reply` — before the ack

Every `reply` line has to be **answered or escalated before the batch is
acked**. Acking is what tells Orca the message is dealt with; a `reply` that
is acked without an answer is a captain decision dropped silently, and no
replay will bring it back.

- A `question` carrying a **no-mistakes ask-user finding** → run it through
  the `delivery` skill's policy first. That policy, not this skill, decides
  whether you answer it or the captain does.
- Anything else → put it to the captain with full context, and send their
  answer back with `orca orchestration reply --id <msg> --body ... --run
  "$run_id"`.

Answering counts as processed. Escalating counts as processed only once the
question is actually in front of the captain — not once you have decided to
ask it.

## 5. Ack last — one `--ack` per `ACK` line

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

## 6. Report once

**One** consolidated message for the whole wake, containing only what is worth
saying: outcomes, PR URLs, and decisions the captain must make. Not one
message per delivery, and not a narration of the steps above.

- Everything §4 escalated goes in this one message, with full context, not in
  a separate note of its own.
- A worker gone unusually quiet → `orca orchestration worker-read --dispatch <id>`
  to diagnose. Report what you found; do not guess.
