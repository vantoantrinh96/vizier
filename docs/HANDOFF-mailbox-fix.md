# Handoff: make vizier's supervision read a real Orca mailbox

**Start a fresh session in this repo and read only this file plus the two it
names.** It is self-contained on purpose — the conversation that produced it ran
too long to continue.

```
repo    ~/data/me/lumin/self-harness/orca-firstmate
branch  feat/orchestration   (do the work here; do not open a new branch)
state   44 commits ahead of main, 20 test files, 626 assertions, suite green
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

1. `lib/vizier-supervise-lib.sh` reads the captured shape, with a test built
   from a **real** captured message rather than a hand-written one.
2. `tests/fake-orca/orca`'s `check` returns the envelope, and its message
   fixtures come from `docs/verification/2026-09-02-smoke-orchestration.md`.
3. An Orca lifecycle-rejection notice is never classified as a completion.
4. `skills/brief/SKILL.md` dispatches with a real worktree selector and `--repo`.
5. The sender-terminal decision is written down before it is implemented.
6. Full suite green, and every new assertion proven by mutation.
7. Then the real smoke can be attempted again — the guide is
   `docs/verification/smoke-guide-orchestration.md`.
