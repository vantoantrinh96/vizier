# Captured Orca responses

Real `orca orchestration check --json` responses, captured from Orca 1.4.193
on 2026-09-02 and committed **verbatim** — no reformatting, no trimming, no
tidying of ids. The pretty-printing is part of the fixture: reading these as
newline-delimited JSON is the bug they exist to pin.

| File | What it is |
|---|---|
| `check-delivery.json` | a default read: 3 messages, a real `deliveryId`, and Orca's own lifecycle-rejection notice |
| `check-peek-empty.json` | `--peek` on a drained mailbox — note it has **no** `deliveryId` |
| `check-timeout.json` | `--wait` that timed out: `messages: []`, `timedOut: true` |
| `check-error.json` | `ok:false`, `consumer_fenced` — a readable failure, not an empty mailbox |

`docs/verification/2026-09-02-mailbox-delivery-contract.md` records the
commands that produced each one and the measurements around them.

**Do not edit these to make a test pass.** They are the only thing in this
repo that the app itself wrote. If one has to change, capture a new one from
the real app and say so in the verification doc; a fixture edited to agree
with the parser is exactly the failure that made supervision ship inert with
574 green assertions behind it.

Messages for cases the app has not been made to produce are built by
`fake_orca_message` in `tests/helpers.sh`, from the field set in
`check-delivery.json` — one builder, so a test cannot invent a shape by hand.
