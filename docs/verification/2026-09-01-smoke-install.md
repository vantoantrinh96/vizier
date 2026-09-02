# Verification: real install and activation smoke

Date: 2026-09-01
Orca app: 1.4.193 (live, running)
Claude Code: 2.1.236
Commit under test: c5eb41d on `feat/install-activation`

This is the smoke the automated suite deliberately cannot do. Every test in
`tests/` runs against a fake `orca` in a temporary home, so nothing there proves
the product works against the real app, the real harness, or the real GitHub
repository. This document records what happened when it did.

## What was exercised, and what it proved

| Step | Result |
|---|---|
| `curl -fsSL .../install.sh \| sh` from GitHub | cloned `~/.vizier/src`, symlinked `~/.local/bin/vizier`, and did NOT touch any harness config |
| `vizier version` through the PATH symlink | reported the fetched commit; `payload: not installed` |
| `vizier doctor` through the symlink, against the live app | `doctor: ok -- orca ready, jq/git/gh available`, exit 0 |
| `vizier install --harness claude` | payload copied to `~/.vizier/dist` including `lib/`; adapter written to `~/.claude/skills/vizier` |
| registered hook | `Stop` with `asyncRewake=true`, `timeout=28800`; `PostCompact` present |
| `vizier version` after install | `payload: dist matches src` |
| `~/.cursor/hooks.json` | byte-identical before and after; the bare install skipped Cursor as designed |
| Claude Code plugin load | `vizier@skills-dir`, status `loaded`; components `identity` and `vizier` |
| `${CLAUDE_PLUGIN_ROOT}` | **resolved** -- the model ran `"~/.claude/skills/vizier/bin/vizier-activate.sh" claude` |
| child-session guard (since removed, see Correction below) | fired in the real world: `refused reason=child_session`, exit 2 -- this was NOT a success: it was the guard blocking the captain's only real activation attempt outright, the defect described in the Correction section |
| the command file's rc rules | followed: the model stopped on rc 2, did not retry, did not touch the lock |

The `${CLAUDE_PLUGIN_ROOT}` row is the one that mattered most. The variable is
NOT an environment variable at Bash time -- measured directly, `env | grep
plugin_root` prints nothing in a session. It is substituted into the command and
skill file text when Claude Code loads them. Had that not been true, the
activation instruction would have resolved to `/bin/vizier-activate.sh` and the
product would have been dead on arrival with no test able to see it.

## Defects this smoke found

**1. Critical, fixed in `2e941e9`.** `cmd_doctor` read Orca readiness from
`.result.reachable`, `.result.state` and `.result.capabilities`. The real
`orca status --json` puts all three under `.result.runtime`. So on a healthy
machine doctor reported:

```
NOT_READY: Orca reachable=false state=unknown (fix: orca open, then wait for the app to be ready)
NOT_READY: Orca is missing capability orchestration.contract.v1 (fix: update the Orca app)
```

Both false. Since `commands/vizier.md` step 3 tells the agent to stop when any
doctor line fails, the product could never be activated on any machine.

The deeper cause is worth recording: `tests/fake-orca/orca` emitted the shape the
code expected rather than the shape Orca produces, so fixture and parser were
wrong in the same way, agreed with each other, and kept the suite green. The fix
corrects both and adds a regression assertion proving the parser now REJECTS the
old flat shape -- a test that would have caught this.

**2. Fixed in `c5eb41d`.** `tests/smoke/pty-drive.py` left its SIGTERM handler
armed during `shutdown()`, so a second signal arriving mid-cleanup raised out of
`os.waitpid` and aborted the cleanup it was there to guarantee. Worse, the
process then exited 0 while printing a traceback, so a caller reading the exit
code would conclude the smoke passed. Handlers are now disarmed before cleanup
and an interrupted run exits non-zero with a one-line `FAIL:`.

**3. Known, not a defect.** The install command in the spec points at
`raw.githubusercontent.com/.../main/install.sh`, which returns 404 because
`install.sh` lives only on the feature branch until the PR merges.

## What remains unverified, and why

**Activation itself has not been observed succeeding.** Every session that can be
started programmatically -- `claude -p`, with or without `env -u
CLAUDE_CODE_CHILD_SESSION` -- is marked as a child session by Claude Code itself
(measured: the variable is still present inside the spawned session after
unsetting it in the parent). The activation script refused there (see Correction:
that refusal is now known to be a defect, not correct behavior, and has been
removed). So a genuine claim can only be observed by a person typing `/vizier:vizier` in
their own interactive session -- and, as recorded below, that person also hit the
same refusal, because it fires on every ordinary session, not only on
programmatically-started ones.

Everything up to that last step is verified: the plugin loads, the path resolves,
and the script runs. The unobserved step is `vizier_lock_claim` writing the lock
and the wake loop that follows it.

**The wake loop against a real Orca Run** is likewise unobserved, because it
depends on a lock that only a parent session can create. The wake MECHANISM was
measured separately and is recorded in `2026-08-31-plugin-wake.md`: a plugin Stop
hook honours `asyncRewake`, exit 2 wakes an idle session, exit 0 is silent, and
`stop_hook_active` is true on every Stop after a wake. What is untested is the
composition of that mechanism with a lock, an open request and a real message.

**Cursor was not installed.** A bare install skips it by design, and its
activation path does not exist yet.

## Correction (2026-09-01, after this smoke): the child-session guard was a defect, and it has been removed

The row above recording the child-session guard firing was written as if the
refusal were a working safeguard. It was not: the guard fired on the captain's
own ordinary interactive session -- typing the slash command in the actual
first-mate session, not in any subagent -- and refused it with `refused
reason=child_session`. That is not a guard doing its job; it is the product
refusing its only real activation path outright.

**Why the guard existed.** A reviewer reported that a subagent session sets
`CLAUDE_CODE_CHILD_SESSION=1` and carries a *different* session id from its
parent, so activating from inside a subagent would write a lock the parent's
Stop hook could never match -- a silent total failure. That claim was accepted
and coded into `bin/vizier-activate.sh` as an explicit refusal without
measuring the other half of it: whether a subagent's session id actually
differs from its parent's.

**What was actually measured.** On the captain's machine:

- Ordinary top-level interactive session: `CLAUDE_CODE_CHILD_SESSION=1`,
  `CLAUDE_CODE_SESSION_ID=fddb6e1c-322f-...`, `CLAUDE_PID=60217`.
- A subagent dispatched from that same session: **identical** --
  `CLAUDE_CODE_CHILD_SESSION=1`, the **same**
  `CLAUDE_CODE_SESSION_ID=fddb6e1c-322f-...`, the same `CLAUDE_PID=60217`.

The variable does not distinguish a subagent from its parent -- it appears to
mark the shell as a child of the session, which is true of every tool-run
command -- and a subagent shares its parent's session id, so a lock claimed
from a subagent matches the parent session's hook payload exactly. The failure
the guard was built to prevent cannot happen. The guard had no true-positive
case and blocked every genuine activation, including the captain's.

**Conclusion.** The guard's premise was false. It has been removed from
`bin/vizier-activate.sh`, and `tests/activate.test.sh` now asserts that
activation succeeds with `CLAUDE_CODE_CHILD_SESSION` set, since that is the
normal case. The lesson this smoke should have caught, and did not: an
unverified claim from a reviewer was accepted and shipped as a refusal without
being measured, and the row above recorded that refusal as if it were success
instead of naming it a defect.

## Real activation, Claude Code — PASS

Run from a second interactive Claude Code session in `~/data/me/lumin/self-harness/no-mistakes`,
after removing the `child_session` guard and refreshing the install to `1d95c70`.

`/vizier:vizier hướng dẫn sử dụng no-mistakes tool` activated the session. Verified
from a third session, not from the model's own report:

```
$ cat ~/.vizier/lock
session_id=43af847f-0c06-4dca-9628-cdfb9b01ea0f
harness=claude
pid=36460
since=1788238193
$ kill -0 36460 && ps -o comm= -p 36460
claude
```

The claiming session id differs from the observing session's, and the recorded pid is a
live `claude` process — so the lock was written by the activation, not fabricated.

Behaviour matched the spec on three points that were never explicitly tested:

- It reported the ledger empty and `0 request đang mở` rather than inventing state.
- It read `git remote get-url origin` in the cwd and offered the project as a **suggestion**
  requiring the captain's confirmation — cwd is never authority.
- It surfaced the missing Cursor entry as a non-blocking note and continued.

## Cursor merge, real `~/.cursor/hooks.json` — PASS

`vizier install --harness cursor` ran at 11:54 against the live file that the Orca app
also maintains.

| Check | Result |
| --- | --- |
| Backup written before the edit | `~/.vizier/backups/cursor-hooks.20260901-115439.0.json` |
| Events in the file | 8, unchanged |
| Entry counts | every event unchanged except `stop` 1 → 2 |
| Orca's `stop` entry | still first, byte-identical |
| `vizier` references | exactly 1 |
| Cursor's own `hooks.json.bak` | untouched (0 `vizier` references) |

Deleting only our `stop` entry from the current file and normalising both with `jq -S`
reproduces the backup exactly — the merge added one entry and changed nothing else.

## Cursor stop hook gates — PASS

Driven directly with three payloads while the lock was held by a **Claude** session:

| Payload | rc | stdout | stderr | lock |
| --- | --- | --- | --- | --- |
| valid stop, unknown `session_id` | 0 | empty | empty | unchanged |
| stop with no `session_id` | 0 | empty | empty | unchanged |
| not JSON at all | 0 | empty | empty | unchanged |

`exit 0` with empty stdout is Cursor's silent no-op, so an installed-but-inactive
Vizier cannot disturb a Cursor session.

## Cursor activation — DOES NOT EXIST

Cursor discovers our skill: typing `/vizier` in `cursor-agent` v2026.08.25 offers
`/identity`, which exists only at `~/.claude/skills/vizier/skills/identity/SKILL.md`.
Cursor scans Claude's skills directory — undocumented, but observed.

It scans `skills/` only. `commands/vizier.md` is not discovered, so **Cursor has no
`/vizier` entry point** and no way to claim the lock. Even given one,
`bin/vizier-activate.sh` reads `CLAUDE_CODE_SESSION_ID`, which Cursor does not set.

Two facts already measured constrain the fix: Cursor's `stop` and `beforeSubmitPrompt`
payloads both carry `session_id`, so a hook can record the id without any environment
variable. Designing that belongs to a plan of its own, not to Plan 1.
