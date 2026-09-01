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
| `${CLAUDE_PLUGIN_ROOT}` | **resolved** -- the model ran `"/Users/toantv/.claude/skills/vizier/bin/vizier-activate.sh" claude` |
| child-session guard | fired in the real world: `refused reason=child_session`, exit 2 |
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
unsetting it in the parent). The activation script correctly refuses there. So a
genuine claim can only be observed by a person typing `/vizier` in their own
interactive session.

Everything up to that last step is verified: the plugin loads, the path resolves,
the script runs, the guard works, and the model follows the instructions. The
unobserved step is `vizier_lock_claim` writing the lock and the wake loop that
follows it.

**The wake loop against a real Orca Run** is likewise unobserved, because it
depends on a lock that only a parent session can create. The wake MECHANISM was
measured separately and is recorded in `2026-08-31-plugin-wake.md`: a plugin Stop
hook honours `asyncRewake`, exit 2 wakes an idle session, exit 0 is silent, and
`stop_hook_active` is true on every Stop after a wake. What is untested is the
composition of that mechanism with a lock, an open request and a real message.

**Cursor was not installed.** A bare install skips it by design, and its
activation path does not exist yet.
