# Real smoke, second attempt — the mailbox loop closes; dispatch does not

Orca **1.4.193**, 2026-09-02, throwaway repo `~/tmp/vizier-smoke`
(`repo:47ce5164-…`). Run `run_d521599841dd`.

The first smoke (`2026-09-02-smoke-orchestration.md`) stopped at
`worker-start`. This one got past it, ran the **whole mailbox half against the
live app**, and stopped at a different place — one nothing had seen.

## What was NOT run, and why

The guide's Steps 2–5 need a fresh interactive Claude Code session driven by a
human. The lock was held by a **live** session (pid 24852), and
`bin/vizier install` would have swapped that session's skills mid-flight, so
neither the install nor `vizier unlock` was done. Everything below is the
mechanical half: the exact commands the skills instruct, issued directly.

⚠ **The smoke repo has no git remote.** Guide Step 1's `gh repo create` was
never run, so `direct-PR`'s closing `gh pr create` cannot succeed here. That
gap is untested either way — the dispatch never got far enough to reach it.

---

## 1. ✅ `--worktree new-top-level` — the open question is closed

The handoff left this ambiguous: the earlier probe measured
`selector_not_found`, but had not recorded whether it passed `--name`, which a
real dispatch does. **Measured with `--name` AND a valid `--repo`:**

```
worker-start --task … --run … --from … --agent claude \
  --worktree new-top-level --repo path:/Users/toantv/tmp/vizier-smoke \
  --setup run --name smoke-license
  -> ok:false  selector_not_found   (stage null, failedStage null, no recovery)
```

The alternative reading is dead. `new-top-level` does not work, `--name`
present or not. **The path that does work is two commands, not one:**

```
orca worktree create --name smoke-license --repo path:/Users/toantv/tmp/vizier-smoke --setup run
  -> ok, id 47ce5164-…::/Users/toantv/orca/workspaces/vizier-smoke/smoke-license
     branch refs/heads/smoke-license

orca orchestration worker-start --task … --run … --from … --agent claude \
  --worktree path:/Users/toantv/orca/workspaces/vizier-smoke/smoke-license
  -> ok:true, dispatch ctx_354ce874603e
```

No creation flags on the second call — `--help` is explicit that `--name`,
`--repo`, `--base-branch`, `--display-name`, `--comment` and `--setup` are
rejected for an existing worktree, and the worktree exists by then.

This matches `worktree create --help`'s own `--project`/`--host` routing
options, and the `worker-start` note that "project/host convenience routing
remains on worktree create". **`skills/brief/SKILL.md` still has to be
rewritten to this two-step shape** — that is the one code change this smoke
identified and did not make.

## 2. ⛔→✅ The blocker was Claude Code's trust dialog. Once trusted, everything ran.

**Second attempt, after the captain trusted `~/tmp/vizier-smoke` in Claude
Code**, dispatching into that (now trusted) worktree:

```
worker-start --task … --run … --from … --agent claude   --worktree path:/Users/toantv/tmp/vizier-smoke
  -> ok:true   state: "ready"   stage: "input_accepted"
```

`state: ready` + `stage: input_accepted` is what success looks like: the agent
launched **and** took the prompt. Those are two different things, and the
first attempt got the first without the second.

**The full loop then ran with a real crew agent**, and it behaved exactly as
the brief mandates:

1. It did the work — LICENSE with the MIT text, one file, committed as
   `a27cfdb` on branch `add-mit-license`.
2. It hit the missing remote and **refused to expand the contract**: it sent a
   `question` with three options and the sentence *"I will not create a GitHub
   repo without your explicit go-ahead."*
3. The wake fired on it; the plan said `PLAN msg_befc120b3d93 reply question`;
   the question went to the captain **before any ack**, exactly as §4 requires.
4. The captain answered "local commit is enough"; `orca orchestration reply`
   carried it back; the batch was acked only then.
5. The agent obeyed, reported honestly — naming the branch and sha, and saying
   plainly that direct-PR could not be fulfilled — and sent `worker_done`.
6. Second wake → `PLAN msg_61562be95548 release ok` → `worker-release` →
   `ACK delivery_4d12eecce4bd` → drained.

That is the whole coordination loop, end to end, against the real app, with a
real model on the other end. **Nothing in it needed a fix.**

### The original blocker, recorded for whoever meets it again

Before the folder was trusted, `--agent claude` into a **fresh** worktree could
not start at all:

```
worker-list -> workerState "failed", dispatchStatus "failed"
worker-show -> last_failure: "agent_prompt_blocked"
worker-read -> the terminal sitting on Claude Code's trust dialog:
   "Quick safety check: Is this a project you created or one you trust?"
   …with Orca's prompt pasted into it as a literal `^[[200~` escape.
```

And **the CLI cannot recover it** — `agent_prompt_blocked` latches:

```
orca terminal send --terminal <the agent terminal> --text 1 --enter
  -> ok:false  agent_prompt_blocked
```

Only the Orca UI, or trusting the path in Claude Code first, clears it.
`--terminal <an ordinary shell>` is not a way round it either:
`agent_unconfigured` — "Terminal … is not running a recognized agent."

⚠ **Trust is per exact path.** Trusting `~/tmp/vizier-smoke` does *not* trust
`~/orca/workspaces/vizier-smoke/<name>`, which is where `worktree create` puts
a new one — so a genuinely isolated worktree still hits this on first use.
`brief` has to survive it: either pre-trust the path, or treat
`agent_prompt_blocked` as a named receipt in §6 and tell the captain to clear
it in the UI.

## 2b. (superseded) the first attempt

The dispatch above succeeded and then failed:

```
worker-list -> workerState "failed", dispatchStatus "failed"
worker-show -> last_failure: "agent_prompt_blocked"
worker-read -> the terminal is sitting on Claude Code's trust dialog:
   "Quick safety check: Is this a project you created or one you trust?"
   "❯ 1. Yes, I trust this folder"
   …with Orca's prompt pasted into it as a literal `^[[200~` escape.
```

Orca launched the agent, then pasted the task prompt before Claude Code was
past its first-run dialog. **And the CLI cannot recover it:**

```
orca terminal send --terminal <the agent terminal> --text 1 --enter
  -> ok:false  agent_prompt_blocked
```

`agent_prompt_blocked` **latches**: the same condition that blocks the prompt
blocks the keystroke that would clear it. Only the Orca UI can.

Nothing in `~/.claude.json` trusts `~/tmp/vizier-smoke` or anything under
`~/orca/workspaces/`, so **every** first dispatch into a new worktree in this
repo hits this. A new worktree is exactly what `brief` is designed to create.

`--terminal` is not a way round it: pointing `worker-start` at an ordinary
shell terminal gives `agent_unconfigured` — "Terminal … is not running a
recognized agent."

**This is the blocker to take to the next session.** It is not a vizier bug;
it is an Orca↔TUI first-run interaction that vizier has to survive. Options
worth measuring: pre-trusting the worktree path, `worktree create --agent
<id>` (which launches the agent at creation, possibly before any prompt is
pasted), or handling `agent_prompt_blocked` explicitly in brief §6.

## 2c. ✅ A rebind DOES invalidate an open delivery — measured, not reasoned

The supervise skill stated this as a rule on the strength of
`consumer_generation` bumping. Now measured directly:

```
send a status message to Run A
check --run A            -> deliveryId delivery_4e05591e77a6
run-use --id B           -> ok, consumer_generation 3
run-use --id A           -> ok, consumer_generation 5
check --run A --ack delivery_4e05591e77a6
  -> ok:false  consumer_fenced
     "This mailbox Delivery belongs to a fenced consumer generation."
```

**And the recovery is clean, which matters as much as the failure.** A fresh
read forms a *new* delivery over the same messages —
`deliveryId delivery_1cc46ace1dfe, replayed: false, count: 1` — and that one
acks normally. Nothing is lost; the batch simply has to be re-planned. Both
halves are now in `skills/supervise/SKILL.md`.

## 3. ⚠ More invented shapes — the same bug class, found again

Three commands return something other than what `tests/fake-orca` and
`skills/supervise` assumed. All three were corrected in this pass.

| Command | We assumed | Reality (captured) |
|---|---|---|
| `worker-show` | `.result.worker.agent_terminal_handle` | `.result.dispatch.assignee_handle` — no `worker` key, no `agent_terminal_handle` anywhere |
| `worker-show` | `.result.worker.dispatch_id` | `.result.dispatch.id` |
| `worker-release` | `.result.release.state` | `.result.state` — the receipt **is** `.result`: `{dispatchId, state, processAction, archive, lastError, recovery}` |
| `worker-list` | `{workers:[…]}` snake_case | camelCase: `dispatchId`, `taskId`, `runId`, `workerState`, `agentTerminalHandle`, `terminalState` — plus `counts` |
| `worker-start` | `.result.dispatch.id` | `.result.dispatchId` — camelCase, top of `result`, no `dispatch` object. Also `state`, `stage`, `setup`, `launch`, `timeoutMs`, `effects[]` |

A real `worker-release` on a healthy dispatch returned `state: "retained"`,
not `released` — a third state value, alongside the `release_unknown` above.

Note the real CLI is **internally inconsistent**: `worker-show` is snake_case
and `worker-list` is camelCase for the same concepts. Not something to
normalise in the double — reproduced as measured.

A real `worker-release` receipt, for a dispatch whose terminal had gone:

```json
{"dispatchId":"ctx_354ce874603e","state":"release_unknown","processAction":"none",
 "archive":{"source":"terminal","status":"captured"},
 "lastError":"tab_not_found","recovery":"Inspect with: orca orchestration worker-show …"}
```

`release_unknown` is a normal answer with a usable `recovery` sentence, not a
crash. The supervise skill now says so.

## 4. ✅ `send` validates `worker_done` — AND posts a rejection notice anyway

Three distinct pre-flight refusals, all `ok:false` with rc 1:

```
--dispatch-id <nonexistent>            -> unknown_dispatch
--dispatch-id <real> (no --task-id)    -> missing_task_id  "worker_done requires taskId."
--dispatch-id <real, released>         -> dispatch_capability_invalid  "capability is revoked."
```

This looked at first like a contradiction of the earlier smoke's §2 ("does not
fail the call; Orca accepts it and rewrites it"). **It is not.** Both happen:
the call fails *and* Orca posts a rejection notice into the Run's mailbox. It
was only invisible because the first look was at the CLI's return value and
not at the mailbox. Three refused sends produced three notices.

## 5. ✅ The mailbox loop closes, end to end, against the live app

```
wake   (inbox poll, unbound, cross-Run)
       -> "worker_done run=run_d521599841dd Orca rejected this worker_done: …"
supervise
  run-use --id run_d521599841dd        -> ok
  check --run … --json                 -> deliveryId delivery_7fbdb9162a37, 4 messages
  vizier_supervise_plan direct-PR      ->
      PLAN msg_00a3abdc8c3e reply question
      PLAN msg_937a9eb5eaec hold lifecycle-rejection
      PLAN msg_214131ac090e hold lifecycle-rejection
      PLAN msg_4b074f617741 hold lifecycle-rejection
      ACK  delivery_7fbdb9162a37
  check --ack delivery_7fbdb9162a37    -> acknowledged, count 0
  check --run … --json                 -> deliveryId null, count 0   (drained)
  wake again                           -> silent; inbox still holds 4 rows, 0 unread
```

Every piece of the fix is exercised here by real data: the envelope transport,
the `payload` string, `.id`, the delivery/ack contract, the `run-use` bind, the
`read == 0` wake boundary, and the all-or-nothing ack.

### The rejection gate, proven on a live notice

`msg_937a9eb5eaec`, made by Orca minutes earlier, body:

```
Orca rejected this worker_done: worker_done references unknown dispatch ctx_does_not_exist.

Original body:
Added the LICENSE file. Tests pass. Nothing left.
axi_outcome: passed
```

Same message, gate on and off:

```
WITH the gate,  direct-PR   -> hold lifecycle-rejection
WITH the gate,  no-mistakes -> hold lifecycle-rejection
WITHOUT it,     direct-PR   -> release ok
WITHOUT it,     no-mistakes -> release axi-outcome=passed
```

Without the gate this batch releases **three** dispatches that never ran.

---

## State left on the machine

Everything created here was removed and the result verified:

- worktree `…/orca/workspaces/vizier-smoke/smoke-license` — **removed**
  (`worktree list` is back to the original two)
- the agent terminal and the plain terminal — **closed** (`terminal list` is
  back to the original three; `term_e3f5595c` returned `runtime_error` on close
  but is gone from the listing)
- coordinator binding — **restored** to `run_d479e1e3370b`
- request `smoke-loop` — **closed**, so no session wakes on a dead Run
- `~/tmp/vizier-smoke` — clean, still at `e1d41f1 init`
- `~/data/me/lumin/platform` — never written to; still on `develop-growth`

Left in place on purpose: `~/.vizier/projects/vizier-smoke.md` (guide Step 1's
knowledge file, needed to resume), Run `run_d521599841dd` (drained, closed
request), and the pre-existing Run `run_a15bd6bb9939`.

`bin/vizier install` was **not** run, so the installed vizier is still the
Plan 1 build (`1d95c70`) — nothing to put back.

Left deliberately: branch `add-mit-license` (`a27cfdb`) in `~/tmp/vizier-smoke`
— the crew agent's actual output, kept as evidence.

⚠ **One thing was damaged and not restored.** While cleaning up terminals, a
`close` was issued with an **empty** `--terminal` value (the handle lookup had
returned nothing because the terminal was already gone, and the `&&` chain did
not guard for it). `orca terminal close` with no `--terminal` closes the
**active** terminal, so it closed the captain's `~` terminal
(`term_c4396b9b-…`). Consequences: that tab and its scrollback are gone, and
`run_d479e1e3370b` still records the now-dead handle as its
`coordinator_handle`. Nothing is unrecoverable — `run-use` from any live
terminal restores read access to any Run — but the tab was not recreated,
because guessing where to put it back is worse than saying so.

**Trap to carry forward:** every `orca ... --terminal "$h"` needs `[ -n "$h" ]`
in front of it. An empty selector is not a no-op; it means "the active one".
