# Captured Orca responses

Real `orca orchestration` responses, captured from the running app on
2026-09-02 and committed **verbatim** — no reformatting, no trimming, no
tidying of ids or paths. The pretty-printing is part of the fixture: reading
these as newline-delimited JSON is the bug they exist to pin.

## `check --json` — the mailbox (Orca 1.4.193)

| File | What it is |
|---|---|
| `check-delivery.json` | a default read: 3 messages, a real `deliveryId`, and Orca's own lifecycle-rejection notice |
| `check-peek-empty.json` | `--peek` on a drained mailbox — note it has **no** `deliveryId` |
| `check-timeout.json` | `--wait` that timed out: `messages: []`, `timedOut: true` |
| `check-error.json` | `ok:false`, `consumer_fenced` — a readable failure, not an empty mailbox |

`docs/verification/2026-09-02-mailbox-delivery-contract.md` records the
commands that produced each one and the measurements around them.

## `worker-list --json` — the worker accounting

Read by `lib/vizier-reconcile-lib.sh`. camelCase (`worker-show` is snake_case
for the same concepts — the real CLI's own inconsistency), and `resource` is a
nested **object**, unlike a mailbox message's `payload`, which is a JSON
string.

| File | Command | What it is |
|---|---|---|
| `worker-list-failed-retained.json` | `--run run_52f834f62a96` | **the measured hole.** One dispatch, `workerState: failed`, `terminalState: retained`, `retainedReason: user_takeover`, and a worktree still held — on a request that was `status: open` with no mailbox message at all |
| `worker-list-all.json` | *(no `--run`)* | machine-wide: three dispatches across three Runs — failed+retained, succeeded+retained, and failed+`release_unknown` with `releaseError: tab_not_found` |
| `worker-list-empty.json` | `--run <a Run Orca does not know>` | `ok:true` with `workers: []`. An unknown Run is **not** an error, which is why "the file names a dispatch Orca does not account for" is a real state |
| `worker-list-error.json` | `--terminal-state bogus` | `ok:false`, `invalid_argument` — a readable failure, not an empty fleet |

`docs/verification/2026-09-02-worker-list-reconcile.md` records the commands that produced each
one and the measurements around them.

Two of the six `terminalState` values the CLI enumerates
(`active|reclaimable|retained|release_pending|release_unknown|released`) are
**not** capturable on this machine: nothing was `active`, and no dispatch has
ever reached `released` — a real `worker-release` on a healthy dispatch
returned `retained`, and one on a dead terminal returned `release_unknown`
(`docs/verification/2026-09-02-smoke-real-loop.md`). Those two rows are built
by `fake_orca_worker_json` in `tests/helpers.sh` **from the field set of the
captures above**, the same way `fake_orca_message` handles messages the app
has not been made to produce. Every case the app *did* produce is read from
the fixture with no builder in between.

**Do not edit these to make a test pass.** They are the only thing in this
repo that the app itself wrote. If one has to change, capture a new one from
the real app and say so in the verification doc; a fixture edited to agree
with the parser is exactly the failure that made supervision ship inert with
574 green assertions behind it.

Messages for cases the app has not been made to produce are built by
`fake_orca_message` in `tests/helpers.sh`, from the field set in
`check-delivery.json` — one builder, so a test cannot invent a shape by hand.
