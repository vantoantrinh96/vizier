# Real orchestration smoke — findings

> **Superseded in part, 2026-09-02.** Everything below still stands as
> recorded, but capturing the whole `check` surface before fixing it found
> more: the response is one **pretty-printed** envelope (so the wake hook was
> broken too, not just supervision), the ack handle is the **delivery's** and
> there is one per batch (`--ack <a message id>` is refused), a **peeked batch
> can never be acked at all**, and a coordinator terminal is fenced to one Run
> (`consumer_fenced`). Read
> `docs/verification/2026-09-02-mailbox-delivery-contract.md` alongside this —
> §1's mapping table here is correct but not sufficient.

Orca **1.4.193**, `state=ready reachable=true`, 2026-09-02.

The smoke did not complete a loop. It stopped at `worker-start`, and in stopping
it produced the most valuable result of the project: **the supervision layer
cannot read a real Orca mailbox.** Every field name it parses was invented by
our own tests.

---

## 1. The mailbox shape is not what we assumed

Captured from a real `orca orchestration check --run <id> --all --json`:

```json
{"id":"msg_c3fc501363f5","run_id":"run_d479e1e3370b",
 "delivery_contract":"current_delivery",
 "from_handle":"term_c4396b9b-…","to_handle":"run:run_d479e1e3370b",
 "subject":"…","body":"…","type":"worker_done","priority":"high",
 "thread_id":null,
 "payload":"{\"taskId\":\"task_7a0a7aaf6d0f\",\"dispatchId\":\"dispatch-probe\",\"outcome\":\"succeeded\"}",
 "read":0,"sequence":3,
 "created_at":"2026-09-02T00:57:31Z","delivered_at":null,
 "sender_pane_key":"…"}
```

Against what `lib/vizier-supervise-lib.sh` reads:

| Our code | Reality |
|---|---|
| `.delivery_id` | **does not exist** — the field is `.id` |
| `.dispatch_id` | **does not exist** — it is `dispatchId` inside `.payload`, which is a **JSON string**, not an object |
| `.outcome` | **does not exist** at top level — same place, `outcome` |
| `.body` | correct |
| `.type` | correct |

And the transport differs too. `check` returns one enveloped object:

```
.result = { acknowledged, count, messages[], runId }
```

`tests/fake-orca` emits newline-delimited JSON objects, and
`vizier_supervise_plan` reads JSON lines on stdin. Real Orca returns an array
inside an envelope, with `runId` in camelCase while the message fields are
snake_case.

**Consequence:** every real message classifies as unparseable (no
`delivery_id`), so the plan withholds its ACK and nothing is ever acked or
released. It fails closed — the one piece of good news — but supervision is
non-functional against the real app.

This is the fourth instance in this project of two halves that are each correct
and individually tested and do not fit. It is the one the tests could never have
caught, because both halves were pinned only to strings we wrote ourselves. The
whole-branch review flagged exactly this as a Minor ("the mailbox message schema
has no captured fixture") and it was deferred as *ship as recorded*. **That
deferral was wrong.**

## 2. Orca validates `worker_done` itself

Sending a `worker_done` naming a dispatch that does not exist does not fail the
call. Orca **accepts it and rewrites it** into a high-priority rejection:

```
subject: "Rejected worker_done: done"
body:    "Orca rejected this worker_done: worker_done references unknown dispatch …"
payload: { …, "_orcaLifecycleRejection": {"code":"unknown_dispatch", "reason": …} }
```

A safety net we did not know existed, and a message shape nothing in our code
handles: it still has `type: worker_done`, so a naive reader would treat a
rejection notice as a completion report.

## 3. Mutating orchestration commands need a sender terminal

```
no_active_sender_terminal
"Could not determine the sender terminal for this orchestration command.
 Pass --from <terminal-handle> or run the command inside a live Orca terminal
 with ORCA_TERMINAL_HANDLE set."
```

A plain editor session is not an Orca terminal and has no
`ORCA_TERMINAL_HANDLE`. Measured scope — **read paths are unaffected**:

| Command | From a plain shell |
|---|---|
| `check`, `task-list`, `worker-list`, `run-list`, `repo show`, `project setups`, `host list`, `status` | work |
| `send` | needs `--from <handle>` |
| `worker-start` | needs a sender terminal, and more (below) |

`--from <a live terminal handle>` satisfies it. `orca terminal list` gives the
live handles; a Run also records one in `coordinator_handle`.

## 4. `--worktree new-top-level` is not a valid value

The usage line advertises `--worktree <current|selector|new-child|new-top-level>`,
but the option help describes only selectors, and measurement agrees with the
option help. Same task, same repo, only `--worktree` varied:

| `--worktree` | Result |
|---|---|
| *(omitted)* | `invalid_argument` — the flag is required |
| `new-top-level` | `selector_not_found` |
| `new-child` | `selector_not_found` |
| `current` | `selector_not_found` |
| `path:/Users/…/vizier-smoke` | `no_active_sender_terminal` — **resolved, moved to the next check** |

`skills/brief/SKILL.md` and the plan's CLI table both use `new-top-level`. It
never worked.

## 5. `selector_not_found` carries no information

Four variants — no `--repo`, valid `--repo`, bogus `--run`, bogus `--agent` —
all returned exactly `selector_not_found`, with `stage: null`,
`failedStage: null`, no `effects`, no `residualResources`, no recovery command.

The first mate that hit this in the live smoke read the receipt, refused to
retry blind, bisected, stopped when the bisect produced no signal, and checked
for leftover resources. That is exactly what the brief mandates, and it is the
one part of the loop this smoke did confirm working.

Note a genuinely bad repo selector returns `repo_not_found`, so
`selector_not_found` is specifically about the **worktree** selector.

## 6. `agent-context --json` does not document the selector formats

`--repo <selector>` and `--worktree <selector>` accept `id:` / `name:` / `path:`
/ `branch:` / `identity:` forms. That vocabulary appears **only in `--help`**;
it is absent from `orca agent-context --json`, the interface Orca advertises for
agents. An agent working from the machine-readable schema alone cannot use
either flag correctly.

---

## What this changes

1. **`lib/vizier-supervise-lib.sh` must read the real shape** — `.id`, and
   `dispatchId`/`outcome` parsed out of the `payload` **string**. Every
   assertion that feeds it a hand-written message must be regenerated from a
   captured fixture.
2. **`tests/fake-orca`'s `check` must return `.result.messages[]` in an
   envelope**, not JSON lines, and its own header already forbids inventing
   field names — it was inventing them.
3. **`skills/brief/SKILL.md` must stop using `--worktree new-top-level`** and
   pass a real selector plus `--repo`.
4. **The first mate needs a terminal handle to dispatch.** Either it runs inside
   an Orca terminal, or it discovers a live handle and passes `--from`. The spec
   assumes a plain editor session, and that assumption does not hold for
   `worker-start`. This is an architectural question, not a patch.
5. **Rejection notices arrive as `type: worker_done`.** The disposition logic
   must recognise `_orcaLifecycleRejection` in the payload and never treat one
   as a completion.

## State left on the machine

- Orca repo registered: `/Users/toantv/tmp/vizier-smoke`, id `47ce5164-…`
- Runs `run_a15bd6bb9939` (the live smoke, against `platform`) and
  `run_d479e1e3370b` (this diagnostic) both still open, with tasks in `ready`
  — **update 2026-09-02:** `run_d479e1e3370b`'s mailbox was deliberately
  drained while measuring the ack contract, after every message in it was
  captured to `tests/fixtures/`. `run_a15bd6bb9939` is untouched.
- No worktree was created, no dispatch started, no branch or PR anywhere.
  **Nothing was written to the `platform` repo.**
