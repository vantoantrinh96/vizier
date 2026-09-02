# Decision needed: how the first mate gets a sender terminal

**Status: DECIDED 2026-09-02 by the captain — read path R1, dispatch A.
IMPLEMENTED the same day; see "What was built" at the end.**

The handoff (`docs/HANDOFF-mailbox-fix.md`, Fix 3) says this one is "a design
question, not a patch… Decide deliberately… and write the decision down before
implementing it. Do not guess." This is that write-up. It stops at a
recommendation, because deciding it changes a premise of the spec — that the
first mate is an ordinary editor session — and that is the captain's call, not
a detail of the mailbox fix.

## What is measured

Mutating orchestration commands need a sender terminal:

```
no_active_sender_terminal
"Could not determine the sender terminal for this orchestration command.
 Pass --from <terminal-handle> or run the command inside a live Orca terminal
 with ORCA_TERMINAL_HANDLE set."
```

- Only `send` and `worker-start` need it. Every read path works from a plain
  shell: `check`, `task-list`, `worker-list`, `run-list`, `repo show`,
  `project setups`, `host list`, `status`.
- `orca terminal list --json` returns live handles. A Run also records one, in
  `coordinator_handle`.
- `worker-start` takes `--from <handle>`; so does `send`.

## ⚠ What was NOT known when the handoff was written

`consumer_fenced` — measured 2026-09-02, recorded in
`docs/verification/2026-09-02-mailbox-delivery-contract.md` §5:

```
"This coordinator terminal is bound to run_d479e1e3370b, not run_a15bd6bb9939."
```

A plain shell with no `ORCA_TERMINAL_HANDLE` was **still resolved to a
terminal** — the one that had created that Run — and fenced from every other
Run. `run-list` confirms only that Run carries a `coordinator_handle`.

This makes the question bigger than dispatching, because
`vizier_wait_any_run` waits on **every open Run in parallel** and the spec
allows several to be open at once. If a session can only ever read the mailbox
of the Run its terminal is bound to, the parallel wait is not the design the
spec assumes — and the fix would be in the same place as this decision, not in
the mailbox layer.

### ✅ Measured 2026-09-02 — the fence is real, and there is a way round it

Three read-only probes:

```
plain shell,        check --run <Run B>   -> consumer_fenced
                       "This coordinator terminal is bound to <Run A>, not <Run B>."
--terminal <other>, check --run <Run B>   -> consumer_fenced
                       "This coordinator terminal is no longer bound to Run <Run B>."
--terminal <other>, check --run <Run A>   -> consumer_fenced  (same wording)
```

Two *different* messages, and together they settle it: **reading a Run's
mailbox with `check` is done as that Run's bound coordinator terminal.** The
binding is 1:1, a terminal bound to one Run cannot read another, and an
**unbound** terminal can read nothing at all.

So `vizier_wait_any_run` — one session, `check --wait` on every open Run in
parallel — cannot work against real Orca. At most one of those waits can
succeed. This is a fourth "two halves that each work and do not fit", and it
is larger than the mailbox shape was.

But `orchestration --help` lists two commands this project has never used:

- **`run-use --id <run_id> [--from <handle>]`** — "Bind this coordinator
  terminal to an existing Run". The binding is *switchable*, not fixed at
  Run creation.
- **`inbox [--limit] [--terminal] [--full]`** — "Show messages across (or
  for) recipients". Measured: it returns `ok:true` **from a plain shell with
  no binding**, and every row carries `run_id` and a `read` flag that flips
  to 1 once a delivery is formed.

`inbox` has **no `--wait`** (so it polls, where `check --wait` blocks) and
**no `--ack`**. That is not a gap — it maps exactly onto the split this
project already has: *the hook never acks; the first mate does.*

### ✅ Measured 2026-09-02 (captain authorised the rebind) — `run-use` needs no sender terminal

```
run-current                              -> bound to run_d479e1e3370b (Run A)
run-use --id run_a15bd6bb9939            -> ok:true, rc 0   <- plain shell, NO --from
check --run run_a15bd6bb9939 --peek      -> ok:true
check --run run_d479e1e3370b --peek      -> consumer_fenced
     "This coordinator terminal is bound to run_a15bd6bb9939, not run_d479e1e3370b."
run-use --id run_d479e1e3370b            -> ok:true          (restored, verified)
```

So binding is a **read-path** operation that an ordinary session can perform,
and the fence follows the binding exactly — it mirrors as the terminal moves.
The two decisions do **not** collapse: only `send` and `worker-start` need a
sender terminal.

⚠ **`consumer_generation` bumps on every rebind** (observed 1 → 3). Rebinding
almost certainly invalidates an open delivery, so `run-use` → `check` →
process → `--ack` must be one uninterrupted sequence for a single Run. A
rebind interleaved into it would very likely make the ack fail. One session
doing this serially is safe; **anything that rebinds concurrently is not.**
This has not been measured directly and is the constraint to verify first
when R1 is built.

## The options — READ PATH (new, and now the bigger half)

**R1. Split detection from processing.** The wake hook polls `inbox` — no
binding, sees every Run, and it never needed to ack. `supervise` then does
`run-use --id "$run_id"` and `check --run` to form a delivery it can ack.
Fits the architecture already written down. Costs: polling instead of a long
block, and a `read`-flag convention for "new since last look".

**R2. Rebind per Run, keep `check --wait`.** `run-use` before each wait.
Serialises the waits — one silent Run blocks another's message for the whole
timeout, which is the exact failure `vizier_wait_any_run` was built to avoid.

**R3. One first mate per Run.** Honest to the fence, and gives up the thing
the spec is for.

## The options — DISPATCH (the original question on this page)

**A. The first mate discovers a handle and passes `--from`.**
Keeps the spec's premise: an ordinary editor session, no new setup for the
captain. `brief` gains a handle-discovery step before `worker-start`. Costs:
one more failure mode to handle (no live terminal at all), the handle can go
stale between discovery and use, and — if the fence applies — it does nothing
for the read path, which is where supervision actually lives.

**B. The first mate runs inside an Orca terminal.**
`ORCA_TERMINAL_HANDLE` is then set and both problems may go away at once,
including the fence, since the session would be a terminal in its own right.
Costs: it changes what the captain has to do to start a first mate, it is a
real constraint on where the session can live (editor, plain shell, CI), and
it makes Orca a hard dependency of the session rather than of the commands.

**C. Bind the first mate as coordinator of the Runs it opens.**
Only worth exploring if the fence is real and A cannot clear it. Larger, and
its shape depends on measurements not yet taken.

## DECISION

**Read path: R1** — the wake hook polls `inbox` (unbound, cross-Run, never
acks); `supervise` does `run-use --id "$run_id"` then `check --run` to form a
delivery it can ack.

**Dispatch: A** — the first mate stays an ordinary editor session. It
discovers a live handle from `orca terminal list --json` and passes `--from`
to `send` and `worker-start`, the only two commands that need one. The spec's
premise survives, and the measurement above is why: binding costs nothing,
so nothing about the read path forces the session into an Orca terminal.

### What was built

- **`lib/vizier-wake-lib.sh`** — the parallel `check --wait` fan-out is gone,
  replaced by an `inbox` poll. Three filters now live client-side, because
  `inbox` has none of them: `read == 0` (nobody has taken delivery yet),
  `run_id` in the open set, and `type` in `VIZIER_WAKE_TYPES`. The newest
  match is chosen by an explicit sort rather than by trusting `inbox` order.
  **The background children, the two traps and the pid file are all deleted**
  — polling one short-lived call has nothing to orphan, so the eight-hour
  orphan risk is removed rather than managed. Cadence default moved 1000ms →
  3000ms, since every tick is now a real call into the app.
- **`skills/supervise/SKILL.md`** — binds with `run-use --id "$run_id"` before
  reading, and states the rule that no rebind may happen between the bind and
  the ack (`consumer_generation` bumps on every rebind).
- **`skills/brief/SKILL.md`** — discovers a handle from `orca terminal list`
  and passes `--from` to `worker-start`; an empty handle stops the dispatch.
- **`tests/fake-orca/orca`** — now models the fence (`check` is refused unless
  the terminal is bound to that Run), `run-use`/`run-current`, `inbox`
  (unbound, cross-Run, `--limit`), `terminal list`, and the `read` flag
  flipping to 1 when a delivery forms. A permissive double here would have let
  a `check` with no `run-use` in front of it go green.

Suite: 21 files, 733 assertions, green. 13 further mutations run against this
work, 13 caught — but four of them *survived* the first pass and were the
useful ones: they showed the wake tests covered none of the three filters, the
newest-vs-oldest choice, or an `ok:false` body being read anyway. The
assertions those mutations exposed as missing are now in
`tests/wake-lib.test.sh`.

### Still open

- The live smoke, and with it the `--worktree new-top-level` question that one
  real dispatch settles.
- ~~The rebind-invalidates-delivery constraint is reasoned, not measured.~~
  **Measured 2026-09-02:** acking a delivery formed before a rebind gives
  `consumer_fenced` — "This mailbox Delivery belongs to a fenced consumer
  generation." A fresh read then forms a new delivery (`replayed: false`) over
  the same messages and acks normally. Both the rule and the recovery are in
  `skills/supervise/SKILL.md`.

## Reasoning behind the recommendation (kept as written before the decision)

**Read path: R1.** The fence is real, so the current parallel wait has to go
either way. `inbox` is unfenced, crosses Runs, and carries the `read` flag —
and it lands the split exactly where this project already put it: the hook
detects and never acks, the first mate binds, processes and acks. R2 keeps the
blocking wait but reintroduces head-of-line blocking across Runs; R3 abandons
the spec's premise.

**Dispatch: measure `run-use` from a plain shell before choosing.** One
mutating call decides it. If `run-use` works unbound, Option A holds and the
spec's premise survives — the first mate stays an ordinary session and only
`send`/`worker-start` need a discovered `--from`. If it does not, then binding
itself needs a terminal, the read path needs one too, and B becomes the only
coherent answer.

Choosing the dispatch option before that measurement risks shipping a fix for
`worker-start` while supervision stays broken for every Run but one — the same
shape as the bug this branch just spent its time on.

## What this blocks

- The live smoke (`docs/verification/smoke-guide-orchestration.md`) cannot
  dispatch until this is decided.
- `skills/brief/SKILL.md`'s `--worktree` question — whether `new-top-level`
  genuinely fails or only failed in a probe that omitted `--name` — needs one
  real dispatch to separate, so it is blocked on this too.
