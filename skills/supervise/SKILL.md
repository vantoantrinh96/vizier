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
. "$VIZIER_DIST/lib/vizier-mailbox-lib.sh"
. "$VIZIER_DIST/lib/vizier-supervise-lib.sh"
. "$VIZIER_DIST/lib/vizier-brief-lib.sh"
```

`brief-lib` is here for `vizier_project_mode` in §2 — it is not only `brief`'s
library. Without it that call is a `command not found` swallowed by `||
default_mode=""`, which silently holds every healthy `direct-PR` worker.

`mailbox-lib` owns the shape of a `check --json` response and must be sourced
**before** `supervise-lib`, which calls into it. Without it every message is
`command not found` inside the plan, and the plan fails closed with no ack.

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
  # The snippet STOPS here, it does not just complain and fall through. A
  # printf followed by a fall-through leaves the ack step reachable, which is
  # the one thing this guard exists to forbid -- and a non-zero exit is also
  # what tells the caller the wake was not processed.
  exit 1
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

## 1. Bind this session to the Run, then read the batch

```bash
orca orchestration run-use --id "$run_id" --json
batch=$(orca orchestration check --run "$run_id" --json)
```

**`run-use` is not optional and it is not a no-op.** Reading a Run's mailbox
with `check` is done as that Run's *bound coordinator terminal*. The binding
is 1:1: a session bound to another Run — or to none — gets `consumer_fenced`
and reads nothing. This is why the wake hook uses `inbox` instead, which needs
no binding; `inbox` is also why you got here, and it cannot ack, which is why
this step exists. See `docs/decisions/2026-09-02-sender-terminal.md`.

It needs no sender terminal: measured, `run-use` from an ordinary session with
no `--from` returns `ok:true`.

**Do not rebind between here and the ack in §6.** Measured: every `run-use`
bumps the Run's `consumer_generation`, and a delivery formed before a rebind
is refused at the ack —

```
consumer_fenced
"This mailbox Delivery belongs to a fenced consumer generation."
```

Bind once, process one Run to completion, then move on. If it does happen,
nothing is lost: read the mailbox again and it forms a **new** delivery
(`replayed: false`) over the same messages, which acks normally. Report it and
re-plan from the new batch — never assume the old ack "probably went through".

**No `--peek`, and no `--all`.** This is not a style choice and it is not an
optimisation. Only a default read forms a *delivery*: Orca returns the batch
together with `result.deliveryId`, replays that same delivery on every later
read until it is acked, and accepts **only that id** at `--ack`. A peek
returns the messages and forms no delivery, so a peeked batch has no ack
handle at all — the messages would be processed, released, reported, and then
replayed forever, because nothing could ever acknowledge them. Measured:
`--ack <a message id>` is refused outright with `stale_delivery`.

The reply is one pretty-printed envelope, not one message per line. Do not
read it with `head`, `grep`, or a line loop — `vizier_supervise_plan` takes
the raw envelope and `mailbox-lib` is the only thing that opens it.

## 2. Plan every message before acting on any

Build a per-dispatch mode map from the request file's own dispatch notes.
`brief` writes one line per dispatch, `task <id> -> dispatch <id> (<mode>)` —
keyed by dispatch id. The per-task override note is **not** a usable join
key here: it's keyed by task number, and the only dispatch id the batch
carries is the `dispatchId` inside each message's `payload` string, which is
what the plan looks up.

`vizier_request_dispatch_notes` is the one reader of that note, and it is
**anchored to the start of the line** — never a bare `.*` search across the
whole file. The notes live in the request *body*, which holds the captain's
own words verbatim, and a captain who pastes a previous run's notes into a
new request can reproduce `-> dispatch <id> (<mode>)`-shaped prose by
accident, with no need for anyone to exploit anything. Only a line that
actually starts with `task ` and has the real note's shape counts. It prints
`<task_id><TAB><dispatch_id><TAB><mode>`; the map this step needs is its
second and third columns:

```bash
map=$(mktemp)
vizier_request_dispatch_notes "$slug" | cut -f2,3 > "$map"
```

**Do not re-inline that pattern here.** Activation's reconciliation reads the
same notes (`commands/vizier.md` step 5), and two copies of one anchored
pattern in two files is two chances for one of them to drift open. It lives
in `lib/vizier-request-lib.sh`, beside the writer of the file it reads.

The fallback for a dispatch the map doesn't name is the project's own
default mode — never a guess, and if even that is unavailable, the strict
check applies (see below):

```bash
default_mode=$(vizier_project_mode "$(vizier_request_get "$slug" project)") || default_mode=""
plan=$(printf '%s\n' "$batch" | vizier_supervise_plan "$default_mode" "$map")
printf '%s\n' "$plan"
```

Keep the plan in `$plan`: §6 acks off it, with the single `--ack` that
clears the whole delivery.

This is **one call over the whole batch**, never one call per message —
`vizier_supervise_plan` resolves the mode per dispatch internally from the
map you gave it. Splitting it into per-message calls breaks the ACK
invariant below: "did anything fail to classify" has to be computed over
the one true batch, not recomputed separately per message. One ack clears
the whole delivery, so that question has exactly one answer for the batch.
`vizier_supervise_plan` treats anything other than the exact string
`direct-PR` — including an empty or unrecognised mode, from the map or from
`default_mode` — as `no-mistakes` and requires the outcome line.

Each `PLAN <message_id> <disposition> <reason>` line is a decision. The id
is the message's own `.id` — useful for reporting and for matching a message
back to its plan line, but **not** an ack handle; see §6.

- **`release`** — the work is over. A *failed* `worker_done` releases too.
- **`hold`** — a task whose body has no terminal `axi_outcome:` line, under
  the strict (default) check. **Do not release.** A pipeline run may still
  own the branch. `orca orchestration worker-read --dispatch <id>` to
  diagnose, then report to the captain.
- **`hold lifecycle-rejection`** — Orca rejected a `worker_done` and rewrote
  it into a notice. It still calls itself a `worker_done` and it quotes the
  original body verbatim, terminal outcome line and all, so it reads exactly
  like a completion and is not one: the dispatch it names does not exist.
  Never release on it. Report it — something dispatched wrong, and the
  captain needs to know which task has no worker behind it.
- **`reply`** — a `question` or an `escalation`: **a human owes an answer.**
  Never a release, whatever the body says. This is the one disposition that
  leaves work outstanding after the plan is done, and §4 must clear it before
  anything is acked.
- **`none`** — not a terminal event. Never release on a timeout, TUI idle,
  heartbeat, status, or a stale `worker_done`.

If the plan prints no `ACK` line, **do not ack anything.** Orca replays an
unacked delivery, so nothing is lost; acking now would lose the whole batch
permanently, because one ack clears all of it. Three ways that happens, and
they are not the same problem:

- an `UNPARSEABLE` line — a message in the batch did not classify. Report it
  with the message beside it.
- `UNPARSEABLE envelope <code>` — the response could not be read at all. A
  real one is `consumer_fenced`: this coordinator terminal is bound to a
  different Run. Nothing was read, so there is nothing to process; say so and
  stop.
- `UNACKABLE no-delivery-id` — the batch was peeked, so it has no ack handle.
  Re-read it without `--peek` before doing anything else.

## 3. Act on each `release`

Decide where the terminal goes **before** acking.

A follow-on task exists for the same agent → transfer, don't release:

```bash
handle=$(orca orchestration worker-show --dispatch "<id>" --json | jq -r '.result.dispatch.assignee_handle')
orca orchestration worker-start --task "<next_task>" --terminal "$handle" --run "$run_id" --json
```

Otherwise release:

```bash
orca orchestration worker-release --dispatch "<id>" --json
```

The receipt is `.result` itself — `{dispatchId, state, processAction, archive,
lastError, recovery}` — not `.result.release`. A `state` of `release_pending`
or `release_unknown` → follow the receipt's **own `recovery` sentence**, which
names the exact command to run. **Substituting `terminal close` is
forbidden.** Repeating `worker-release` after a replayed delivery is safe.

`release_unknown` is not rare and not a crash: it was the real answer for a
dispatch whose terminal had already gone (`lastError: "tab_not_found"`), with
the archive still captured. Report it, run its recovery, do not retry blind.

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

**Sending §5's one consolidated report is what
puts an escalation in front of the captain.** Deciding to escalate does not;
drafting it does not; only sending that message does. So a `reply` delivery is
not discharged until §5's message is sent, and the ack in §6 waits for it —
`--ack` that delivery only afterwards. That is the whole reason the ack
comes after the report and not before: an ack is what tells Orca the message
is dealt with, and Orca replays only what is unacked. Ack the batch first and
the replay safety net for the un-put question is gone — which is exactly the
loss the `reply` disposition exists to prevent.

## 5. Report once

**One** consolidated message for the whole wake, containing only what is worth
saying: outcomes, PR URLs, and decisions the captain must make. Not one
message per delivery, and not a narration of the steps above.

- Everything §4 escalated goes in this one message, with full context, not in
  a separate note of its own. Sending it is what discharges those `reply`
  lines, so it happens before anything is acked.
- A worker gone unusually quiet → `orca orchestration worker-read --dispatch <id>`
  to diagnose. Report what you found; do not guess.

## 6. Ack last — one `--ack` for the whole batch

Last means last: after §3's releases and after §5's report, never before
either.

The plan prints **at most one `ACK <delivery_id>` line**, and the id is the
*batch's*, not any message's. That is Orca's contract, measured: a default
read forms one delivery over the whole batch, `--ack` takes that
`result.deliveryId` and clears all of it at once, and `--ack <a message id>`
is refused with `stale_delivery`. So there is exactly one call to make, and
acking per message is not a safer version of it — it is a call that fails.

```bash
ack_id=$(printf '%s\n' "$plan" | sed -n 's/^ACK //p')
[ -n "$ack_id" ] && orca orchestration check --run "$run_id" --ack "$ack_id" --json
```

Because one ack clears the whole delivery, the all-or-nothing rule in §2 is
not a nicety: there is no way to acknowledge the messages you understood and
leave the rest. Ack only when the plan says to.

Acking the same delivery twice is harmless — it is already gone, and the
second call simply reports nothing to acknowledge. Leaving it unacked is not:
the delivery replays on every wake until it is cleared.
