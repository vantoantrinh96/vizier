# Running the real orchestration smoke

Task 12 of the orchestration plan. Everything else in the plan is built and
reviewed against `tests/fake-orca`; this is the only step that runs against the
real Orca app, and the only thing that can answer the questions at the bottom.

Written 2026-09-02 against the state of this machine: Orca **1.4.193**,
`state=ready reachable=true`.

---

## Two dangers, read before anything else

**1. The only project currently `ready` in Orca is a real work repo.**

```
github:luminpdf/platform  on host local: ready  path=/Users/toantv/data/me/lumin/platform
```

If you open a Request without registering something else first, that is what the
first mate will route to, and a crew agent will make a branch and open a PR in
it. **Step 1 exists to prevent that.** Never smoke against a repo with work in it.

**2. The installed `vizier` is Plan 1 only.**

```
$ vizier version
source:   1d95c70 …
```

None of the orchestration code is installed — no `request`/`brief`/`supervise`/
`delivery` skills, none of the six libraries. Step 0 installs the branch, and
tells you how to put it back.

---

## Step 0 — install the branch, and know how to undo it

```sh
cd ~/data/me/lumin/self-harness/orca-firstmate
git rev-parse --abbrev-ref HEAD          # expect: feat/orchestration
bin/vizier install
vizier version                           # source: should now be the branch head
vizier doctor
```

`install` refreshes `~/.vizier/src` and `~/.vizier/dist` and re-points the
harness adapters. `doctor` must report Orca reachable and `jq`/`git`/`gh` present.

**To undo, at any point:**

```sh
cd ~/data/me/lumin/self-harness/orca-firstmate
git checkout main
bin/vizier install
```

That returns you to the merged Plan 1 build. Your `~/.vizier/requests/` and
`~/.vizier/projects/` files are *not* touched by install — delete them by hand
if you want a clean slate.

---

## Step 1 — make a throwaway repo and register it with Orca

```sh
mkdir -p ~/tmp/vizier-smoke && cd ~/tmp/vizier-smoke
git init -b main
printf '# vizier smoke\n' > README.md
git add README.md && git commit -m "init"
```

It needs a real remote, because `direct-PR` mode ends in `gh pr create`:

```sh
gh auth switch --user vantoantrinh96
gh repo create vizier-smoke --private --source=. --push
gh auth switch --user toantvlumin        # put your default account back
```

Then register it with Orca and confirm it is `ready`:

```sh
orca repo add --path ~/tmp/vizier-smoke
orca project setups --json | jq -r '.result.setups[] | "\(.projectId) \(.hostId) \(.setupState)"'
```

You want a line for the smoke repo with `setupState: ready`. If it is not ready,
stop here and sort that out first — routing is supposed to refuse a host with no
ready setup, and you cannot tell a correct refusal from a broken one if the
setup genuinely is not there.

**Write the project knowledge file**, or the first mate will ask you for the
delivery mode (which is correct behaviour, but adds a question to every task):

```sh
mkdir -p ~/.vizier/projects
cat > ~/.vizier/projects/vizier-smoke.md <<'EOF'
---
delivery: direct-PR
---
Nothing to build. Nothing to test.
PRs target `main`. Keep changes to one file.
EOF
```

---

## Step 2 — free the lock

A live session currently holds it:

```
session_id=43af847f-…  harness=claude  pid=36460   (alive)
```

Two ways forward. Either **run the smoke in that session** — it is already the
first mate — or, if you would rather start fresh:

```sh
vizier unlock          # only after you are sure that session is finished with
```

`unlock` clears the lock whoever holds it. It exists precisely because a `/clear`
or a resume leaves the process alive with a new session id, which the lock can
never match again. It does not ask, so be sure first.

---

## Step 3 — activate a fresh session

Open a new Claude Code session **in the smoke repo**, not in this one:

```sh
cd ~/tmp/vizier-smoke && claude
```

Then run `/vizier:vizier`.

**Watch for:** it should say it is the first mate, report `0 requests open`, and
propose the project from `git remote get-url origin` as a *suggestion* that it
asks you to confirm. If it announces a project as decided, that is a finding —
the working directory is never authority.

Confirm the lock really moved, from any other terminal:

```sh
cat ~/.vizier/lock
```

---

## Step 4 — open a Request, and watch routing

Tell it, in your own words, something like:

> Add a LICENSE file with the MIT text. One task.

**What must happen, in order:**

1. It confirms the project with you.
2. It shows a routing table with **both** hosts and a reason for each:
   - `this machine` — eligible
   - `Mac mini` — **not** eligible, because there is no ready setup for this
     project on it
3. It asks you to choose a host — **once**. This is the request's only
   mandatory question.

**Findings to write down if you see them:** a host presented without a reason; a
choice made for you; being asked about the host more than once; `Mac mini`
offered as eligible when it has no setup.

Then check what it wrote:

```sh
cat ~/.vizier/requests/*.md
```

Frontmatter should carry `run_id`, `project`, `project_id`, `host`, `status:
open`, `opened`. The body should quote **your** words, not a paraphrase.

---

## Step 5 — the brief and the dispatch

Let it create the task and start the worker. Before it does, ask it to show you
the `--spec` it is about to send. Check the four layers are all there:

```
## 1. Invariants     ## 2. Project     ## 3. Delivery     ## 4. Task
```

Layer 1 must name the banned tools (`gh-axi`, `tasks-axi`, …) explicitly, and
layer 3 must open with `Delivery contract: mode=direct-PR`.

Confirm the host you chose is the host that reaches the dispatch:

```sh
orca orchestration worker-list --json | jq '.result'
```

**This is the single most important assertion of the whole smoke.** The host you
picked in step 4 must be the one on the dispatch. Everything else has a unit
test; this crosses three files and a file-on-disk.

---

## Step 6 — the wake, and supervision

Now leave the session alone. The worker does its task and sends `worker_done`;
the Stop hook is waiting on the mailbox and should wake the session **by itself**,
without you typing anything.

**Time it.** Note the gap between the worker finishing and the session waking.
Plan 1 measured a 40 ms wake from idle, but never with a real Orca mailbox behind
it.

When it wakes it should: read the batch, plan a disposition per message, act,
ack, and give you **one** consolidated message with the PR URL.

**Watch for:**
- more than one report for one batch
- an ack that happens before the terminal is dealt with
- a `worker-release` that runs on anything other than a real `worker_done`
- a `command not found` anywhere — that was a real bug in this branch and its
  only symptom was a line in the transcript

---

## Step 7 — close, then look at what is left

Tell it the request is done. It should release any remaining dispatch and set
`status: closed`.

```sh
cat ~/.vizier/requests/*.md               # status: closed
orca orchestration worker-list --json     # nothing still holding a terminal
pgrep -fl 'orchestration check'           # no orphaned waiters
```

The PR must still be **open and unmerged** — the captain merges every PR, and a
crew agent that merged its own is a serious finding.

---

## Step 8 — record it

Write `docs/verification/2026-09-02-smoke-orchestration.md` with, for each stage,
the command and the **real response**, not a summary: the `run-create` reply, the
request file as written, the routing table as presented, the full four-layer
`--spec`, the `worker-start` receipt, the wake line and its delay, the batch, the
plan, the release receipt, the PR URL, and confirmation that you merged it rather
than the crew.

Stamp the Orca version. Orca exposes no protocol marker, so the version plus the
capability list is the compatibility evidence.

---

## The questions this smoke exists to answer

These are open and cannot be settled against `tests/fake-orca`:

1. **Does `orca orchestration check --ack` acknowledge cumulatively, or one
   delivery at a time?** The library now emits one `ACK` per classified delivery
   and the skill issues one `--ack` each. That is safe either way, but nobody has
   watched the real mailbox. Send a batch of two and see whether one `--ack`
   drains both.
2. **What does a real mailbox message actually look like?** Every field name the
   supervisor reads — `delivery_id`, `dispatch_id`, `type`, `body`, `outcome` —
   is asserted only against strings our own tests write. Capture one real
   `check --json` and compare. Note that every *other* Orca response uses
   camelCase (`setupState`, `projectId`) while these are snake_case.
3. **Does the wake hook fire reliably against a real mailbox**, and how long does
   it take?
4. **Does `worker-release` ever return `release_pending` / `release_unknown` in
   practice?** The recovery path for those is written but has never executed.

---

## Optional second pass: the remote host

Only if you want it, and only after the local pass is clean. Set the smoke repo
up on `Mac mini` (`orca project setup-clone --project <id> --host
0559ea68-256d-4cbc-9e53-50bda88dd120 --url <clone-url> --destination <path>`),
then open a second Request and choose that host.

This is the variant that catches a host **name** being passed where an **id**
belongs — three different Orca commands take the same host three different ways,
and only a real remote dispatch proves we got them right.

---

## Cleaning up afterwards

```sh
rm -f ~/.vizier/requests/*.md ~/.vizier/projects/vizier-smoke.md
gh auth switch --user vantoantrinh96
gh repo delete vantoantrinh96/vizier-smoke --yes
gh auth switch --user toantvlumin
rm -rf ~/tmp/vizier-smoke
cd ~/data/me/lumin/self-harness/orca-firstmate && git checkout main && bin/vizier install
```
