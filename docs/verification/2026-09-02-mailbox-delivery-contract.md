# The mailbox delivery contract — measured

Orca **1.4.193**, `state=ready reachable=true`, 2026-09-02. Every response
below was captured from the live app on this machine; the four that the tests
depend on are committed verbatim under `tests/fixtures/`.

This exists because `docs/verification/2026-09-02-smoke-orchestration.md` found
that the supervision layer parsed a message shape that does not exist, and the
handoff written from it (`docs/HANDOFF-mailbox-fix.md`) described the fix from
one captured message. Capturing the whole `check` surface before fixing it
found **three more things the handoff had wrong or did not know**, all of them
load-bearing. They are marked ⚠ below.

---

## 1. `check --json` returns ONE PRETTY-PRINTED ENVELOPE, always

⚠ The handoff described the message shape but not the transport. There is no
newline-delimited mode: `--wait`, `--peek`, `--all` and the default read all
return a single pretty-printed envelope on stdout.

```
{"id":…,"ok":true,"result":{…},"_meta":{"runtimeId":…}}
```

Measured consequence, against the captured 3-message response:

```
$ cat tests/fixtures/check-delivery.json | vizier_supervise_plan direct-PR
UNPARSEABLE   x77
PLAN lines: 0   ACK lines: 0
```

Seventy-seven, because pretty-printing puts one **field** on each line. The
same shape defeats `vizier_wait_any_run`, whose per-line
`select(.type? != null)` matches nothing at the envelope's top level:

```
$ jq -rc 'select(._keepalive|not) | select(.type? != null)' tests/fixtures/check-delivery.json
(no output)
```

⚠ **So the wake hook never fired either.** The handoff named
`lib/vizier-supervise-lib.sh` as "the whole job"; `lib/vizier-wake-lib.sh`
reads the same response and was equally broken, silently and
indistinguishably from an idle fleet.

Keepalives are **stderr**, not stdout — `check --help`: "`--wait` … Emits JSON
keepalive lines to stderr every 15s … Filter with `jq "select(._keepalive|not)"`
when merging streams."

## 2. ⚠ The ack handle is the DELIVERY's, and there is one per batch

The handoff's mapping table says `.delivery_id` → `.id`. That is right for
identifying a message and **wrong for acking one.** `check --help`:

```
--ack <delivery_id>: acknowledge the prior whole batch before checking/waiting.
A bound Run replays the same Delivery until --ack; process every message
before acknowledging.
```

Measured round trip on `run_d479e1e3370b`:

| Call | `result` |
|---|---|
| `check --run R --json` (default) | `deliveryId: delivery_aad01f2a4ab7`, `replayed: false`, `count: 3` |
| `check --run R --json` again | **same** `deliveryId`, `replayed: true`, `count: 3` |
| `--ack delivery_aad01f2a4ab7` | `ok:true`, `acknowledged: "delivery_aad01f2a4ab7"`, `count: 0` |
| `check --run R --json` after | `deliveryId: null`, `count: 0` |

And the two refusals that settle it:

```
--ack msg_08381966f603      -> ok:false  stale_delivery  rc 1
   "Delivery msg_08381966f603 does not belong to this Run."
--ack not-a-real-delivery   -> ok:false  stale_delivery  rc 1
```

After the refusal all three messages were **still queued**: a rejected ack acks
nothing. So the previous design — one `ACK <delivery_id>` line per message,
one `--ack` each, defended in the library as "correct either way" — was correct
in neither way. Every one of those calls fails, and the batch replays forever.

## 3. ⚠ `--peek` and `--all` create no delivery, so a peeked batch cannot be acked

| Read | `result` keys |
|---|---|
| `--peek` / `--all` | `acknowledged, count, messages, runId` |
| default, with messages | `+ deliveryId, replayed, mutation, timedOut, cancelled, connectionLost` |
| `--wait`, timed out | `acknowledged, cancelled, connectionLost, count, messages, runId, timedOut` |

No `deliveryId` on a peek — and `--ack` accepts nothing else. The supervise
skill read the batch with `--peek` and then acked, which cannot work at all:
the messages would be processed, released, reported, and replayed forever.

A timed-out `--wait` still answers, with `messages: []` and `timedOut: true`.
It does not go silent. "No output" and "no messages" are different results,
and only the first means orca failed.

## 4. Orca's own rejection notice — captured, and it releases without a guard

`tests/fixtures/check-delivery.json`, message `msg_c3fc501363f5`:

```json
"subject": "Rejected worker_done: done",
"body":    "Orca rejected this worker_done: worker_done references unknown
            dispatch dispatch-probe.\n\nOriginal body:\naxi_outcome: passed\nPR …",
"type":    "worker_done",
"payload": "{\"taskId\":…,\"dispatchId\":\"dispatch-probe\",\"outcome\":\"succeeded\",
             \"_orcaLifecycleRejection\":{\"code\":\"unknown_dispatch\",\"reason\":…}}"
```

It keeps `type: worker_done`, it keeps a **non-blank** `dispatchId` (so the
stale-dispatch guard does not bite), and it quotes the original body verbatim
— terminal `axi_outcome:` line and all. Measured, with the field access fixed
and no rejection gate:

```
no-mistakes -> release axi-outcome=passed
direct-PR   -> release ok
```

A terminal released on the strength of a message whose entire content is Orca
saying the terminal event never happened.

## 5. ⚠ `consumer_fenced` — a coordinator terminal is bound to ONE Run

Not in the handoff at all. Checking a second open Run from the same shell:

```json
{"ok":false,"error":{"code":"consumer_fenced",
 "message":"This coordinator terminal is bound to run_d479e1e3370b, not run_a15bd6bb9939."}}
```

`run-list` shows why: `run_d479e1e3370b` carries
`coordinator_handle: term_c4396b9b-…`, the other two Runs carry none. The CLI
resolved this plain shell to that terminal and fenced it.

**This is a live question for `vizier_wait_any_run`, which waits on every open
Run in parallel.** If at most one Run's mailbox is readable from a given
session, the parallel wait is not the design the spec assumes. It is the same
root issue as the sender-terminal question — see
`docs/decisions/2026-09-02-sender-terminal.md`, which records what is known and
what still has to be measured.

The plan layer now reports this rather than swallowing it: an `ok:false`
envelope produces `UNPARSEABLE envelope consumer_fenced`, never "no traffic".

## 6. Selector vocabulary, from `worker-start --help`

Still absent from `agent-context --json`, as the smoke found:

- `--repo <selector>`: `id:<id>`, `name:<name>`, `path:<path>`
- `--worktree <selector>`: `identity:<identity>`, `id:<repo-id>::<path>`,
  `name:<displayName>`, `branch:<branch>`, `issue:<number>`, `path:<path>`,
  `active`/`current`

Two notes that bear directly on the smoke's `--worktree` finding, and that
**conflict with it**:

- "Remote current and new-child are invalid; discover an exact remote selector
  or **use `new-top-level`**."
- "Creation flags (`--name`, `--repo`, `--base-branch`, `--display-name`,
  `--comment`, `--setup`) are **rejected for current/existing worktrees**. Use
  exact `--repo` on the selected server."

So `new-top-level` is how Orca documents *asking for a new worktree*, there is
no selector form meaning "make me a new one", and a `path:` selector is
mutually exclusive with the creation flags the dispatch also passes. The smoke
measured `new-top-level` returning `selector_not_found`, but did not record
whether that probe passed `--name`, which the real dispatch does. **The two
readings have not been separated**, and separating them needs one live
dispatch, which the sender-terminal decision gates. `skills/brief/SKILL.md`
carries all of this at the point of failure.

---

## What was left on the machine

- `run_d479e1e3370b`'s mailbox was **drained** by the ack round trip in §2 —
  deliberately, and only after every message in it was captured to
  `tests/fixtures/`. It was the diagnostic Run, created for exactly this.
- `run_a15bd6bb9939` untouched. Nothing dispatched, no worktree created, and
  nothing written to `~/data/me/lumin/platform`.
