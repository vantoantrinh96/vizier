# Handoff: make vizier's supervision read a real Orca mailbox

> **DONE — 2026-09-02, except Fix 3 and the two things it gates.** Fixes 1 and
> 2 are implemented, and doing them found three things this handoff had wrong.
> Read `docs/verification/2026-09-02-mailbox-delivery-contract.md` for the
> measurements and `docs/decisions/2026-09-02-sender-terminal.md` for what is
> still open. **Corrections to this document are marked ⚠ inline below — the
> original text is left standing so the corrections are legible.** Do not work
> from the uncorrected claims.
>
> | # | State |
> |---|---|
> | 1 mailbox shape | done, and larger than described — see ⚠ 1a/1b/1c |
> | 2 `--worktree` | **ANSWERED by the real smoke** — `new-top-level` genuinely fails, `--name` or not. The working path is `worktree create` **then** `worker-start`; `skills/brief/SKILL.md` still needs rewriting to it. See `docs/verification/2026-09-02-smoke-real-loop.md` §1 |
> | 3 sender terminal | recorded, **not decided**, and now bigger than described — see ⚠ 3 |

**Start a fresh session in this repo and read only this file plus the two it
names.** It is self-contained on purpose — the conversation that produced it ran
too long to continue.

```
repo    ~/data/me/lumin/self-harness/orca-firstmate
branch  feat/orchestration   (do the work here; do not open a new branch)
state   as handed off: 20 test files, 626 assertions, suite green
        after this work: 21 test files, 771 assertions, suite green,
        34 mutations run and 34 caught, plus a real smoke against Orca
        1.4.193 (docs/verification/2026-09-02-smoke-real-loop.md)
```

## What this project is, in three sentences

`vizier` turns a Claude Code or Cursor session into a coordinating "first mate"
over crew agents running in Orca-managed worktrees. Six shell libraries in
`lib/` hold every rule that can be tested without a model; four Markdown skills
in `skills/` hold the judgement the model applies. A previous plan shipped
install and activation; this branch added the coordination loop and is finished
and reviewed **except for what is below**.

## Why you are here

A real smoke test against Orca 1.4.193 found that the supervision layer parses a
mailbox message shape that does not exist. Everything was green because both
sides of the contract — the test double and the parser — were built from the
same invented field names.

**Read `docs/verification/2026-09-02-smoke-orchestration.md` first.** It has the
captured real messages and the measurements behind every claim here. Do not
re-derive them; do verify anything you are about to depend on.

## The three fixes

### Fix 1 — the mailbox shape (this is the whole job)

Real `orca orchestration check --run <id> --all --json` returns **one envelope**:

```
.result = { acknowledged, count, messages[], runId }
```

and each message looks like:

```json
{"id":"msg_c3fc501363f5","run_id":"run_…","type":"worker_done","body":"…",
 "subject":"…","priority":"high","thread_id":null,"read":0,"sequence":3,
 "payload":"{\"taskId\":\"task_…\",\"dispatchId\":\"…\",\"outcome\":\"succeeded\"}",
 "from_handle":"term_…","to_handle":"run:run_…","delivery_contract":"current_delivery",
 "created_at":"…","delivered_at":null,"sender_pane_key":"…"}
```

`lib/vizier-supervise-lib.sh` currently reads `.delivery_id`, `.dispatch_id` and
`.outcome`. **None of those exist.** The mapping is:

| Current | Correct |
|---|---|
| `.delivery_id` | `.id` |
| `.dispatch_id` | `.payload` is a **JSON string** — parse it, then `.dispatchId` |
| `.outcome` | same place, `.outcome` |
| `.body`, `.type` | already correct |

> ⚠ **1a — the transport, not just the fields.** `check --json` returns ONE
> **pretty-printed** envelope, in `--wait` mode as much as out of it. There is
> no JSON-lines mode. Fed the real capture, the old plan produced **77**
> `UNPARSEABLE` lines, no plan and no ack.
>
> ⚠ **1b — `.delivery_id` → `.id` is right for identifying a message and wrong
> for acking one.** `--ack` takes `result.deliveryId`: **one per batch**, only
> ever produced by a *default* read. `--ack <a message id>` is refused with
> `stale_delivery` and acks nothing. So the library's per-message ACK design,
> and the skill's `--peek` read, could not have worked even with the fields
> fixed: a peeked batch has no ack handle at all.
>
> ⚠ **1c — `lib/vizier-wake-lib.sh` was broken too**, and this handoff calls
> Fix 1 "the whole job" without mentioning it. It reads the same response the
> same wrong way, so **the wake hook never fired** — silently, and
> indistinguishably from an idle fleet.

`tests/fake-orca/orca` emits newline-delimited JSON from `check`; it must emit
the envelope. Its own header comment already says shapes are copied and never
invented — it was inventing them. Every test that hand-writes a message must be
regenerated from the captured shape.

**Also handle Orca's own rejection notice.** A `worker_done` naming an unknown
dispatch is not rejected at the call; Orca rewrites it into a message that still
has `type: worker_done`, with `_orcaLifecycleRejection` inside `payload`. A
naive reader treats it as a completion. It must never be classified as one.

Keep the disposition rules exactly as they are — they were reviewed hard and are
correct: release only on a processed `worker_done`; strict `axi_outcome` unless
the mode is positively `direct-PR`; ambiguity holds; blank `dispatch_id` is
stale; `reply` for `question`/`escalation`; ACK withheld for the whole batch if
anything fails to classify. **Only the field access changes.**

### Fix 2 — `--worktree new-top-level` has never been a valid value

Measured, same task and repo, only `--worktree` varied:

```
(omitted)                    invalid_argument      (the flag is required)
new-top-level                selector_not_found
new-child                    selector_not_found
current                      selector_not_found
path:/Users/toantv/tmp/vizier-smoke   no_active_sender_terminal   ← resolved
```

> ⚠ **2 — `--repo` was added; the selector swap was NOT made, deliberately.**
> `worker-start --help` says "Remote current and new-child are invalid;
> discover an exact remote selector or **use `new-top-level`**" — so
> `new-top-level` is how Orca documents *asking for a new worktree*, and no
> selector form means "make me a new one". It also says the creation flags
> (`--name`, `--repo`, `--setup`, …) are **rejected for current/existing
> worktrees**, so a `path:` selector is mutually exclusive with the `--repo`
> this same fix requires. The smoke's probe did measure `selector_not_found`,
> but did not record whether it passed `--name`, which the real dispatch does;
> that alternative reading was never separated. Swapping in a `path:` selector
> would ship a call the tool's own docs say will be rejected, on a measurement
> whose conditions cannot be reconstructed — so `skills/brief/SKILL.md` now
> carries the exact `--repo`, both documented cases, and everything known
> about the failure, at the point where the receipt is read. Separating the
> two readings needs one live dispatch, which Fix 3 gates.

`skills/brief/SKILL.md` (~line 88) and the plan's CLI table both use
`new-top-level`. Replace it with a real worktree selector and pass `--repo`,
which Orca's own notes require for a new worktree ("Use exact `--repo` on the
selected server"). Selector forms come from `orca orchestration worker-start
--help`: `id:<id>`, `name:<name>`, `path:<path>` for `--repo`; `identity:`,
`id:<repo-id>::<path>`, `name:`, `branch:`, `issue:`, `path:`, `active/current`
for `--worktree`. **These forms are absent from `orca agent-context --json`** —
only `--help` documents them.

### Fix 3 — dispatching needs a sender terminal

```
no_active_sender_terminal
"Could not determine the sender terminal for this orchestration command.
 Pass --from <terminal-handle> or run the command inside a live Orca terminal
 with ORCA_TERMINAL_HANDLE set."
```

A plain editor session is not an Orca terminal. Read paths are unaffected —
`check`, `task-list`, `worker-list`, `run-list`, `status`, `host list`,
`project setups` all work from a plain shell. Only `send` and `worker-start`
need it. `orca terminal list --json` gives live handles; a Run records one in
`coordinator_handle`.

> ⚠ **3 — bigger than dispatching.** Measured 2026-09-02: a plain shell with no
> `ORCA_TERMINAL_HANDLE` is **still resolved to a terminal**, and fenced from
> every Run but that terminal's:
> `consumer_fenced — "This coordinator terminal is bound to run_d479e1e3370b,
> not run_a15bd6bb9939."` If that generalises it breaks the **read** path,
> where `vizier_wait_any_run` waits on every open Run in parallel — and no
> amount of `--from` fixes a read. The decision is written up, undecided, in
> `docs/decisions/2026-09-02-sender-terminal.md`, with the one measurement
> that has to come first.

**This one is a design question, not a patch.** The spec assumes the first mate
is an ordinary session. Decide deliberately — discover a handle and pass
`--from`, or require the first mate to run inside an Orca terminal — and write
the decision down before implementing it. Do not guess.

## How this repo works

- `bash tests/run-all.sh` from `tests/`. It runs `for t in *.test.sh` and
  **auto-discovers** — never add a file to a list, and never turn that glob into
  one.
- Libraries are sourced, never executed. `set -u`, never `set -e`. `local` on
  every function-scoped variable — this branch shipped a real caller-clobbering
  bug by omitting it.
- `shellcheck` is **not installed**. Do not claim a static pass.
- Skills are prompts. `tests/skills.test.sh` greps them for literal,
  case-sensitive substrings, so a capital letter, a backtick inside a phrase, or
  a shell line continuation breaks a match that looks correct. Grep the skill
  text for your needle before trusting it.
- `tests/skill-preamble.test.sh` sources each skill's own source block and
  checks every `vizier_*` name it mentions resolves. It exists because a skill
  once called a function nothing sourced and 574 assertions stayed green. Keep
  it working.

## Traps on this machine, each one learned by getting it wrong

- `IFS` is tab/newline/NUL with **no space**. `cmd $var` passes **one** argument,
  not several. Pass separate literal words in any probe.
- The interactive shell is zsh: write `${var}:path` in git revision arguments,
  or `$var:l` gets eaten as a history modifier.
- Capture exit codes immediately (`cmd; rc=$?`). Reading `$?` after a pipeline
  gives the pipeline's last element.
- Command substitution strips trailing newlines, so `printf '%s' "$x" | wc -l`
  undercounts by one. Use `printf '%s\n'`.
- When measuring a race window, sample **during** it with a deadline on the
  poller. Measuring the end state answers a different question.

## The standard this branch is held to

A green suite is not evidence. Four criticals here survived green suites: a
skill sourcing a variable nothing defined, a skill calling a function nothing
sourced, a lock guard that was a no-op, and a test seam placed where it could
not see the bug. Each was caught by **reading the code as the thing that will
execute it**, or by **breaking it deliberately and watching a test go red**.

So: for every assertion you add, mutate the code it covers and confirm that
assertion — and ideally only that one — fails. Report what you observed.

## State already on the machine

- Throwaway repo registered with Orca: `~/tmp/vizier-smoke`, repo id
  `47ce5164-51f9-4f2e-9a3f-f32a1aa9c1a0`. Use it for anything that dispatches.
- Two open Runs with `ready` tasks: `run_a15bd6bb9939` (against the real
  `platform` repo — **do not dispatch into it**) and `run_d479e1e3370b`
  (the diagnostic).
- A live Orca terminal handle, if you need `--from`:
  `term_c4396b9b-4c66-4e7f-8676-337a1b58f2e1` — re-check it is still alive with
  `orca terminal list --json`.
- Installed `vizier` is still the **Plan 1** build (`1d95c70`). Run
  `bin/vizier install` from this branch before any live test, and
  `git checkout main && bin/vizier install` to put it back.
- Nothing has been written to `~/data/me/lumin/platform`. Keep it that way.

## Definition of done

1. ✅ `lib/vizier-supervise-lib.sh` reads the captured shape, with a test built
   from a **real** captured message rather than a hand-written one.
   `tests/fixtures/check-delivery.json` is the app's own response, committed
   verbatim; the rejection case is read straight out of it with no builder in
   between. Also done, and not on this list: `lib/vizier-wake-lib.sh` (⚠ 1c),
   the delivery/ack contract (⚠ 1b), and `lib/vizier-mailbox-lib.sh` — a new
   single owner for the response shape, which had none, which is why two
   callers each invented their own.
2. ✅ `tests/fake-orca/orca`'s `check` returns the envelope — pretty-printed,
   which is load-bearing — and models the real delivery: peek forms none,
   a default read forms and replays one, `--ack` takes the delivery id and
   refuses a message id with `stale_delivery`. Message fixtures come from
   `tests/fixtures/` through one builder in `tests/helpers.sh`.
3. ✅ An Orca lifecycle-rejection notice is never classified as a completion.
   Gated structurally, before the body is read, on `_orcaLifecycleRejection`
   in the payload; proven against the real notice, which releases without it.
4. ⚠ **Partly.** `--repo` is derived from the request's own project and host
   and passed exactly. The `new-top-level` swap was deliberately not made —
   see ⚠ 2 above for why, and `skills/brief/SKILL.md` for what a reader hits
   at the point of failure.
5. ✅ Written down in `docs/decisions/2026-09-02-sender-terminal.md`, then
   **decided and built**: read path R1 (`inbox` poll in the hook, `run-use` +
   `check` in supervise), dispatch A (`--from` a discovered handle). Deciding
   it needed one more measurement the handoff did not know was needed — the
   coordinator fence is real and 1:1, which meant the parallel `check --wait`
   fan-out in `vizier-wake-lib.sh` could never have worked either.
6. ✅ Full suite green — 21 files, 733 assertions — and **34 mutations run,
   34 caught**, each by the assertion meant to catch it. Five of them
   *survived* on the first pass and were the useful ones: each exposed an
   assertion of mine that proved nothing (a compact fake passes a
   "not JSON lines" test just as well as a pretty one), and the assertions
   were rewritten until the mutation bit. The battery covers
   the rejection gate, the payload read, the message id, the per-batch ack,
   the unreadable-envelope report, the unackable-peek report, the compact vs
   pretty envelope, ack granularity, and the `--repo` derivation.
7. ✅ **Run, and the whole loop closes with a real crew agent.**
   `docs/verification/2026-09-02-smoke-real-loop.md`. The whole mailbox loop
   closes against the live app (inbox wake → `run-use` → `check` → plan → ack
   → drained → no re-wake), and the rejection gate was proven on a notice Orca
   produced during the run: without it, that one batch releases three
   dispatches that never ran.

   Second attempt, after the captain trusted the folder in Claude Code: the
   agent launched, did the work, **refused to expand the contract** when it
   found no git remote, asked, took the captain's answer through
   `orchestration reply`, reported honestly, and the batch released and acked.
   Nothing in the loop needed a fix.

   **All of it is now done except one coverage gap:**
   - ✅ `skills/brief/SKILL.md` is the two-step `worktree create` **then**
     `worker-start` shape, with no creation flags on the dispatch.
   - ✅ `agent_prompt_blocked` is a named receipt in `brief`, with the two
     facts that make it survivable: it latches (no CLI call clears it, not
     even `terminal send`), and trust is per **exact path**, so trusting the
     repo root does not cover `~/orca/workspaces/…`.
   - ✅ The rebind rule is measured, not reasoned — `consumer_fenced`, "This
     mailbox Delivery belongs to a fenced consumer generation" — and its
     recovery (a fresh read forms a new delivery) is written down too.
   - ⬜ `gh pr create` is still unexercised: the smoke repo has no git remote,
     and creating one is an outward action nobody has asked for. This is the
     only part of `direct-PR` never run against the real thing.

   Fixed during the smoke, same bug class as the mailbox: `worker-start`,
   `worker-show`, `worker-release` and `worker-list` all returned shapes the
   fake and the skills had invented (§3).
