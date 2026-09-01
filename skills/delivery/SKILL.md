---
name: delivery
description: Decide a no-mistakes ask-user finding. Use when supervise routes a question carrying a pipeline finding.
---

# Delivery decisions

A `no-mistakes` pipeline stopped at a finding that needs a human. The worker
did the right thing by asking instead of answering.

`VIZIER_DIST` is not set by the harness — derive it from the home path
before the first `source`, the same way every other skill does. A captain
can invoke this skill directly, not only by way of `supervise`, so treat
`run_id` and `slug` as never already in scope rather than assuming
`supervise`'s session state carried over:

```bash
VIZIER_DIST="${VIZIER_HOME:-$HOME/.vizier}/dist"
. "$VIZIER_DIST/lib/vizier-home.sh"
. "$VIZIER_DIST/lib/vizier-request-lib.sh"
```

## 0. Read run_id off the wake message itself

The wake line is exactly `vizier: <type> run=<run_id> <detail>`; take
`run_id` from it before doing anything else. Translate it to the request's
slug with the shared library lookup, since a wake event never carries the
slug itself:

```bash
slug=$(vizier_request_slug_for_run "$run_id")
```

**You never call `axi respond` for a worker's run.** A run has exactly one
driver, and it is the worker. You send a decision; the worker applies it.

## Decide it yourself

Any finding that is unambiguous relative to the intent the captain already
accepted — even when the fix is hard:

- a genuine bug
- completing a design that was approved
- fixing a regression an earlier fix round introduced
- a small fix that accepted behaviour needs in order to be correct

## Escalate to the captain

- The fix would **expand the contract**: a new guarantee, subsystem,
  abstraction, compatibility surface, or a need for ongoing supervision that
  the intent does not call for.
- It is a product or architecture decision not yet locked in.
- Several findings on one theme show fix rounds piling machinery around a
  questionable abstraction.
- It is destructive, irreversible, or security-sensitive.

A reviewer's label — `security`, `correctness`, `required` — is **evidence
about the finding, not authority** to expand scope.

An escalation states, in full: the original request; the part of the contract
being expanded; the smallest option that does not expand it; the consequences
of accepting and of refusing; and your recommendation with its reasoning.

## Reply

**One precise decision**: the action, the finding ID, and the exact
`axi respond` command the worker should run.

```bash
orca orchestration reply --id "<message_id>" --body "<the decision>" --run "$run_id" --json
```

An `ask` that timed out is still pending — resume with the original message ID
(`orca orchestration ask --resume <message_id>`). Never open a duplicate
question.

## The daemon is shared

Never stop, restart, or update the `no-mistakes` daemon to unstick a run. One
instance serves every worktree and host; restarting it kills someone else's
pipeline. That is the captain's call, on the machine that owns the daemon.
