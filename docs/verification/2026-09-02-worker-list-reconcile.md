# `worker-list` and the reconciliation contract — measured 2026-09-02

Every claim below was produced by running the command against the real Orca app on the
captain's machine. The four responses are committed verbatim under `tests/fixtures/` and
catalogued in `tests/fixtures/README.md`.

## 1. The hole that started this

`~/.vizier/requests/mit-license-demo-vizier.md`:

```
run_id: run_52f834f62a96
status: open
…
task task_f5a588ccf365 -> dispatch ctx_70061775b9ca (direct-PR)
```

```sh
orca orchestration worker-list --run run_52f834f62a96 --json
```

```
workerState: failed          dispatchStatus: failed
terminalState: retained      resource.retainedReason: user_takeover
agentTerminalHandle: term_e2a3fc69-05f9-4726-b908-55fd94dd2120
resource.worktreeId: 5d217a28-…::/Users/toantv/orca/workspaces/demo-vizier/mit-license
```

- That Run had **no message at all** in `orca orchestration inbox`.
- The session that held the first-mate lock (`pid=22985`) was dead.

So: a failed worker, a retained terminal, a worktree still held — and **nothing in vizier would
ever have mentioned it.** Activation counted files with `status: open` and stopped there
(`commands/vizier.md` step 5, as it was), and the wake hook only ever fires on a message.

Captured: `tests/fixtures/worker-list-failed-retained.json`.

## 2. `worker-list` needs no binding and no sender terminal

Run from a plain shell with no `run-use` and no `--from`: `ok:true`. This is what makes
reconciliation possible at activation at all — `check` cannot be read that way, because reading a
Run's mailbox is done as that Run's *bound* coordinator terminal
(`docs/decisions/2026-09-02-sender-terminal.md`).

## 3. An unknown Run is not an error

```sh
orca orchestration worker-list --run run_doesnotexist000 --json
# -> ok:true, result.workers: [], result.counts: {}, rc 0
```

Captured: `tests/fixtures/worker-list-empty.json`. This is why *"the request file names a
dispatch and `worker-list` does not return it"* is a real, reachable state rather than an
invented one — and why "no dispatches" and "could not read this at all" must never look alike to
the caller.

## 4. A failure envelope, and it is the same envelope `check` uses

```sh
orca orchestration worker-list --terminal-state bogus --json
# -> ok:false, error.code invalid_argument
#    "invalid --terminal-state 'bogus', expected one of:
#     active, reclaimable, retained, release_pending, release_unknown, released"
```

Captured: `tests/fixtures/worker-list-error.json`.

Two things came out of this one. First, the `{id, ok, result, _meta}` envelope and the
`{"ok":false,"error":{"code":…}}` failure shape are **shared** across orchestration commands —
only the `result` payload is per-command. That is why `vizier_mailbox_ok` was generalised into
`vizier_envelope_ok <raw> <result_array_key>`, with `vizier_mailbox_ok` kept as the `messages`
wrapper, instead of `reconcile-lib` growing a second private reader. Second, the error message
**enumerates `terminalState`**, which is the only measured list of those values there is.

## 5. `workerState` is NOT enumerated anywhere

Only two values have ever been observed on this machine: `failed` and `succeeded`. So
`vizier_reconcile_health` cannot define `running` as "workerState is one of the live values" —
there is no such list to check against, and inventing one is the exact mistake that shipped
supervision inert. `running` is the leftover branch (terminal `active`, worker neither `failed`
nor `succeeded`), and the raw value is printed verbatim in `worker=` so the report names whatever
word Orca used even where this code has no rule for it. Stated as a residual in the library
header.

## 6. Two `terminalState` values cannot be captured

`--terminal-state active` and `--terminal-state released` both returned `[]`.

```sh
orca orchestration worker-list --terminal-state retained --json
#   ctx_ae9c346dbbee  succeeded / completed / retained     (user_takeover)
#   ctx_70061775b9ca  failed    / failed    / retained     (user_takeover)
orca orchestration worker-list --terminal-state release_unknown --json
#   ctx_354ce874603e  failed    / failed    / release_unknown  (releaseError tab_not_found)
```

Nothing on this machine has ever reached `released`: a real `worker-release` on a healthy
dispatch returned `retained`, and one on a dead terminal returned `release_unknown`
(`docs/verification/2026-09-02-smoke-real-loop.md`). So the `active` and `released` rows in
`tests/reconcile-lib.test.sh` come from `fake_orca_worker_json` in `tests/helpers.sh`, built from
the captured field set — the same treatment `fake_orca_message` gives messages the app has not
been made to produce. Every case the app *did* produce is read straight from a fixture.

**Consequence that is not resolved:** it is unknown whether a `released` dispatch stays in
`worker-list` or drops out of the accounting. The CLI accepting `--terminal-state released` as a
filter is strong evidence rows are kept — a filter that could never match anything would be odd
— but it is evidence, not a measurement. `missing` therefore means exactly *"worker-list does not
account for it"*, and `worker-show --dispatch <id>` is the call that distinguishes the two. The
library says so rather than guessing.

## 7. `worker-list` is camelCase; `worker-show` is snake_case

Unchanged from `docs/verification/2026-09-02-smoke-real-loop.md` §3 and reconfirmed here:
`dispatchId`, `taskId`, `runId`, `workerState`, `dispatchStatus`, `agentTerminalHandle`,
`terminalState`, plus a nested `resource` **object** and a `counts` map. `resource` is an object,
*not* a JSON string — unlike a mailbox message's `payload`, which is a string that has to be
parsed. Getting that difference wrong in either direction is how a double teaches a parser the
wrong shape, so both are pinned to captures.

## 8. The shipped activation snippet, run verbatim

The snippet in `commands/vizier.md` step 5, extracted from the Markdown and executed unmodified:

```
REQUEST mit-license-demo-vizier run=run_52f834f62a96
RECONCILE failed ctx_70061775b9ca task=task_f5a588ccf365 mode=direct-PR health=failed \
  worker=failed status=failed terminal=retained reason=user_takeover \
  handle=term_e2a3fc69-05f9-4726-b908-55fd94dd2120 \
  worktree=/Users/toantv/orca/workspaces/demo-vizier/mit-license
SUMMARY total=1 running=0 settled=0 failed=1 retained=0 missing=0 unrecorded=0 unreadable=0 held=1 other_run=0
```

(one line in reality; wrapped here.) The same snippet against a `VIZIER_HOME` with no open
request printed **nothing at all**. `~/.vizier` was byte-identical before and after — verified by
hashing every file under it on both sides, which is the property `tests/run-all.sh` enforces for
the suite and which reconciliation must hold for the live home too.
