# Running the real orchestration smoke

**Rewritten 2026-09-02, after a first pass that changed most of what this said.**
The mechanical half — every Orca call the skills make — has now been run against
the real app and is recorded in
`docs/verification/2026-09-02-smoke-real-loop.md`. What is left is the half only
a person can drive: **a live first-mate session exercising the skills as
prompts.**

Against Orca **1.4.193** on this machine.

---

## The four questions the old version of this guide asked are answered

Do not re-derive them; they are measured and pinned to fixtures.

| Question | Answer |
|---|---|
| Does `--ack` acknowledge cumulatively or one delivery at a time? | **Per delivery, one per batch.** The handle is `result.deliveryId`, only a default read creates one, and `--ack <a message id>` is refused with `stale_delivery`. |
| What does a real mailbox message look like? | Captured — `tests/fixtures/check-delivery.json`. `.id`, and `dispatchId`/`outcome` inside `payload`, which is a JSON **string**. |
| Does the wake hook fire against a real mailbox? | It **never had.** `check --json` returns one pretty-printed envelope, so the old JSON-lines reader matched nothing. It fires now, via `inbox`. |
| Does `worker-release` ever return `release_pending`/`release_unknown`? | Yes — `release_unknown` with `lastError: tab_not_found`, and `retained` on a healthy dispatch. Three states, not one. |

## What this smoke is now FOR

Only these. Everything else has either a test or a measurement behind it.

1. **The skills as prompts.** A live first mate confirming the project instead
   of assuming it, showing a routing table with a *reason* per host, asking the
   host question **exactly once**, and writing the captain's **verbatim** words
   into the request file.
2. **The Stop hook waking a real session by itself**, with nobody typing. The
   wait function is tested directly; the hook firing end-to-end in a live
   session is not.
3. **Wake latency** against a real mailbox — now a poll, not a block.
4. **`gh pr create`** — the closing step of `direct-PR`, never once exercised,
   because the smoke repo has no remote.

---

## Step 0 — what is already done on this machine

Skip these; they are set up. Verify rather than redo.

```sh
orca project setups --json | jq -r '.result.setups[] | "\(.projectId) \(.hostId) \(.setupState)"'
#   -> repo:47ce5164-51f9-4f2e-9a3f-f32a1aa9c1a0 local ready   (~/tmp/vizier-smoke)
cat ~/.vizier/projects/vizier-smoke.md          # delivery: direct-PR
ls ~/.vizier/requests/                          # all closed; `vizier_open_run_ids` is empty
```

`~/tmp/vizier-smoke` is also **trusted in Claude Code**, which matters — see the
trust trap in Step 5.

⚠ It has **no git remote**. Without one, `direct-PR` cannot finish and the crew
agent will (correctly) stop and ask. If you want question 4 answered, create one
first:

```sh
cd ~/tmp/vizier-smoke
gh auth switch --user vantoantrinh96
gh repo create vizier-smoke --private --source=. --push
gh auth switch --user toantvlumin        # always switch back
```

## Step 1 — install this branch

The installed `vizier` is still the Plan 1 build (`1d95c70`) and its dist does
not even match its src. **None of the orchestration work is live until you do
this.**

```sh
cd ~/data/me/lumin/self-harness/orca-firstmate
git rev-parse --abbrev-ref HEAD          # expect: feat/orchestration
bin/vizier install
vizier version                           # source: should now be the branch head
vizier doctor                            # Orca reachable, jq/git/gh present
```

⚠ `install` re-points the harness adapters, so it **changes the skills of any
Claude session already running**. Do it when no first mate is mid-task.

**To undo, at any point:**

```sh
cd ~/data/me/lumin/self-harness/orca-firstmate
git checkout main && bin/vizier install
```

## Step 2 — free the lock

```sh
cat ~/.vizier/lock          # session_id / harness / pid
ps -p <pid>                 # is that session still alive?
```

Either run the smoke **in** that session — it is already the first mate — or
`vizier unlock` if you would rather start fresh. `unlock` does not ask, so be
sure the holder is finished first.

## Step 3 — activate a fresh session

Open Claude Code **in the smoke repo**, not in this one, then `/vizier:vizier`.

```sh
cd ~/tmp/vizier-smoke && claude
```

**Watch for:** it says it is the first mate, reports `0 requests open`, and
proposes the project from `git remote get-url origin` as a *suggestion it asks
you to confirm*. If it announces a project as decided, that is a finding — the
working directory is never authority.

## Step 4 — open a Request, and watch routing

Tell it, in your own words:

> Add a LICENSE file with the MIT text. One task.

**In order:**

1. It confirms the project with you.
2. It shows a routing table with **both** hosts and a reason for each —
   `this machine` eligible, `Mac mini` **not** eligible for want of a ready
   setup.
3. It asks you to choose a host, **once**.

**Findings to write down:** a host presented without a reason; a choice made for
you; being asked twice; `Mac mini` offered as eligible.

```sh
cat ~/.vizier/requests/*.md
```

Frontmatter carries `run_id`, `project`, `project_id`, `host`, `status: open`,
`opened`. The body quotes **your** words, not a paraphrase.

## Step 5 — the brief and the dispatch

Ask to see the `--spec` before it dispatches. Four layers:

```
## 1. Invariants   ## 2. Project   ## 3. Delivery   ## 4. Task
```

Layer 1 must name the banned tools (`gh-axi`, `tasks-axi`, …); layer 3 must open
with `Delivery contract: mode=direct-PR`.

**The dispatch is TWO calls.** `worker-start` only ever *selects* a worktree;
`orca worktree create` makes one. `--worktree new-top-level` returns
`selector_not_found` — measured twice, the second time with `--name` and a valid
`--repo` both present. If you see `new-top-level` in the transcript, that is a
finding.

⚠ **THE TRUST TRAP, and it will bite.** A brand-new worktree lands in
`~/orca/workspaces/<repo>/<name>` — a **different path** from the repo root, and
Claude Code's trust is per exact path. The agent launches into its first-run
"Is this a project you trust?" dialog, Orca's prompt paste lands in the dialog,
and the dispatch fails with:

```
worker-show -> status "failed", last_failure "agent_prompt_blocked"
```

**It latches. No CLI call clears it** — `orca terminal send --text 1 --enter`
against that terminal is itself refused with `agent_prompt_blocked`. Clear it in
the **Orca UI** (accept the dialog once for that path), then re-dispatch. A good
first mate reports exactly this instead of retrying; if it retries blind, that is
a finding.

A successful dispatch reads `state: ready` **and** `stage: input_accepted` —
launched *and* prompted. Confirm the host you chose reached it:

```sh
orca orchestration worker-list --json | jq '.result.workers'
```

`.dispatchId`, `.workerState`, `.agentTerminalHandle` — camelCase here, and
snake_case in `worker-show`. That is Orca's own inconsistency.

**This is the single most important assertion of the whole smoke:** the host you
picked in Step 4 is the host on the dispatch. Everything else has a unit test;
this crosses three files and a file on disk.

## Step 6 — the wake, and supervision

Leave the session alone. The hook polls `orca orchestration inbox` (unbound,
across Runs, `read == 0` means new) and should wake the session **by itself**.

**Time it.** Default cadence is 3000 ms, so expect seconds, not the 40 ms of the
Plan 1 idle measurement — it is a poll now, not a block.

When it wakes it should `run-use` to bind, read the batch as a **delivery**,
plan a disposition per message, act, report once, and ack **last** with a single
`--ack <deliveryId>`.

**Watch for:**
- a `--peek` anywhere in the read — a peeked batch has no ack handle at all
- more than one `--ack`, or an `--ack` naming a *message* id
- an ack before the terminal is dealt with, or before a `reply` is answered
- more than one report for one batch
- a `worker-release` on anything that is not a real `worker_done`
- a `command not found` anywhere — that was a real bug here and its only
  symptom was one line in a transcript

⚠ **Do not touch `run-use` while a batch is in flight.** A rebind bumps
`consumer_generation` and the ack is then refused with `consumer_fenced`, "This
mailbox Delivery belongs to a fenced consumer generation." Nothing is lost — the
next read forms a fresh delivery — but the first mate must notice and re-plan
rather than assume the ack went through.

**If there is no remote**, the crew agent should stop and **ask** rather than
create a repo. That is correct behaviour, and it is what happened on the last
pass: it offered three options and said it would not create a GitHub repo
without explicit go-ahead. Answer through the first mate, not directly.

## Step 7 — close, then look at what is left

```sh
cat ~/.vizier/requests/*.md               # status: closed
orca orchestration worker-list --json     # nothing still holding a terminal
orca terminal list --json                 # no leftover agent terminals
orca worktree list --json                 # no leftover worktrees
pgrep -fl 'orchestration inbox'           # no orphaned pollers
```

The PR, if there is one, must still be **open and unmerged** — the captain
merges; a crew agent that merged its own is a serious finding.

⚠ **Every `--terminal "$h"` needs `[ -n "$h" ]` in front of it.** `orca terminal
close` with an empty `--terminal` closes the **active** terminal. That mistake
cost a captain's terminal tab on the last pass.

## Step 8 — record it

Write a dated file in `docs/verification/` with, per stage, the command and the
**real response**, not a summary. Stamp the Orca version: Orca exposes no
protocol marker, so version plus capability list is the compatibility evidence.

---

## Optional second pass: the remote host

Only after the local pass is clean. Set the smoke repo up on `Mac mini`
(`orca project setup-clone --project <id> --host <host-id> --url <clone-url>
--destination <path>`), then open a second Request and choose that host.

This is the variant that catches a host **name** passed where an **id** belongs
— three Orca commands take the same host three different ways, and only a real
remote dispatch proves we got it right.

## Cleaning up afterwards

```sh
rm -f ~/.vizier/requests/*.md ~/.vizier/projects/vizier-smoke.md
gh auth switch --user vantoantrinh96
gh repo delete vantoantrinh96/vizier-smoke --yes     # only if you created it
gh auth switch --user toantvlumin
rm -rf ~/tmp/vizier-smoke
cd ~/data/me/lumin/self-harness/orca-firstmate && git checkout main && bin/vizier install
```
