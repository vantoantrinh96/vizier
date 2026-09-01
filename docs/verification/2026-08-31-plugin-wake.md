# Verification: wake mechanism as a Claude Code plugin

Date: 2026-08-31
Claude Code: 2.1.236
How it was run: throwaway plugin `ofm-probe` scaffolded via `claude plugin init` into `~/.claude/skills/`
(auto-loads as `<name>@skills-dir`), Stop hook is a bash script that sleeps 12s then exits 2 once, gated on `cwd`
so it doesn't touch other sessions. Deleted after measuring.

## Question

The spec assumes the Stop hook's `asyncRewake` can wake an idle first mate. Claude Code's docs
confirm this field for a **command hook** in `settings.json`, but **do not say** whether a plugin's
`hooks/hooks.json` honors it or not. The entire supervision mechanism depends on the answer.

## How it was measured

Headless `claude -p` can't distinguish sync from async: both phases (with and without
`asyncRewake`) take ~37-39s, because the process doesn't exit while the hook is still running. A
session had to be kept alive with `--input-format stream-json --output-format stream-json`, sending
one turn then holding stdin open for 45s, timestamping every line of output.

## Result

```
847.224  ASSISTANT 'ok'
847.275  hook FIRE            hook starts, blocks for 12s
847.303  RESULT success       session did NOT wait for the hook -> async
859.339  hook EXIT2
859.377  SYSTEM init          idle session wakes up, runs a new turn
860.711  ASSISTANT 'ok'
872.839  hook EXIT0           silent, no wake
887.832  (stdin closed)       session stayed idle from 872 to here
```

Five things were proven, all in plugin form:

1. The Stop hook a plugin provides **does fire**.
2. `asyncRewake: true` **is honored**: RESULT comes back after 0.08s while the hook keeps running
   for another 12s.
3. exit 2 **wakes the idle session** after 40ms, with stderr entering context as a system reminder.
4. exit 0 is **absolutely silent** -- no turn is generated, the session stays idle for 15s until
   stdin closes.
5. The stdin payload has `session_id`, `cwd`, `stop_hook_active`, `transcript_path`,
   `permission_mode`, `last_assistant_message`, `prompt_id`.

## Implications for the design

- Plugin form is viable; no need to fall back to project-level `.claude/settings.json`.
- `session_id` in the payload is what lets us gate on "is this session the first mate" with a
  single file read, so the hook can stay silent in every other Claude Code session on the machine.
- Claude Code fires the Stop hook on **every** Stop and **does not dedupe** (see the header of
  `firstmate/bin/fm-claude-stop-autoarm.sh`), so the gate must be the cheapest possible operation.

## Limits of the measurement

Measured on a stream-json session, not an interactive TUI. Async behavior is proven at the
protocol level; how the TUI displays it has not been checked. Not measured with a long timeout
(used 120s; the spec calls for ~28800s).

---

# Verification: user-level Cursor hooks

Date: 2026-08-31
cursor-agent: 2026.08.11-e8db854 (the exact version firstmate verified the Cursor adapter against)

## Question

firstmate proved Cursor's `stop` mechanism at `.cursor/hooks.json` **project-level** with `--trust`.
vizier installs at **user level**. Does the user level fire?

## Result: headless can't measure that question

Three configurations, same hook probe, running `cursor-agent -p --trust`:

| Where the hook is declared | Hook fires? |
|---|---|
| plugin `~/.cursor/skills/ofm-probe` (auto-discovery) | no |
| same plugin, forced via `--plugin-dir` | no |
| `~/.cursor/hooks.json` at user level -- the exact place Orca uses | **no** |

The third configuration is the control: it's a location known for certain to work, since Orca
installs its own 8 events there. It didn't fire either.

**Conclusion: `cursor-agent -p` doesn't run any hooks, not just turn-end.** firstmate's README
only states "no turn-end hook in headless"; this measurement shows the scope is broader than that.

The captain's `~/.cursor/hooks.json` file was backed up beforehand and restored byte-exact right
after the measurement (sha256 matches: `ba94bfa2...5c7e35c7`).

## Implications for the design

- The Cursor adapter **cannot have an automated test** for the wake path. It must be smoke-tested
  by hand, the same way firstmate does it.
- The question "does a user-level plugin load hooks" **remains open**; it must be measured with an
  interactive session.
- `cursor-agent` requires trust per workspace directory (`--trust` or an interactive decision).
  Since vizier "runs everywhere," that means every new directory where the captain types
  `/vizier:vizier` hits a trust prompt once. This needs consideration in the Cursor adapter.

## Probe left on the machine

`~/.cursor/skills/ofm-probe/` -- gated on cwd so it stays silent in every other session. Removed
with `rm -rf ~/.cursor/skills/ofm-probe`.

## Re-measured with an interactive session (pty)

Since headless can't measure it, drive a real TUI session via `pty.fork()`: type text, send Enter
separately (typing text and Enter at the same time makes Cursor receive the characters but **not**
submit), then read the terminal with timestamps. The cursor-agent TUI reports version
**2026.08.25-3e8eec8**, newer than the number `--version` prints (`2026.08.11-e8db854`) and newer
than the version firstmate verified.

### Result 1 -- user-level plugin does NOT load hooks

The same hook probe placed at `~/.cursor/skills/ofm-probe/` with `.cursor-plugin/plugin.json`
declaring `"hooks": "./hooks/hooks-cursor.json"`: a full interactive turn ran to completion (agent
replies, spinner stops, composer returns to idle, sits still for 75s) and **no hook fired**. An
explicit `--plugin-dir` didn't either.

### Result 2 -- user-level `~/.cursor/hooks.json` RUNS, the full wake loop included

The same probe declared in `~/.cursor/hooks.json`:

```
530.3  stop fire (turn 1 ends)
538.4  WOKE after 8s parked       <- hook blocks, session waits
538.5  EMIT {"followup_message": ...}
       TUI shows "Working" -> model runs a new turn -> prints "PROBEWAKE"
541.2  stop fires again (turn 2 ends)
549.3  WOKE, NO emit              <- guard blocks it, the loop has a floor
```

`beforeSubmitPrompt`, `stop`, `afterAgentResponse` all fire. The `stop` payload carries:
`session_id`, `workspace_roots`, `loop_count`, `conversation_id`, `generation_id`,
`cursor_version`, `transcript_path`, `model`, `status`, `user_email`, and token counters.

Confirms exactly what firstmate describes: the hook runs synchronously and parks, the only channel
is a `{"followup_message": ...}` on stdout with exit 0, `loop_count` is Cursor's version of
`stop_hook_active`.

`~/.cursor/hooks.json` was backed up and restored byte-exact after **each** measurement (sha256
`ba94bfa2...5c7e35c7` matched both times).

## Mandatory implications for the design

**The Cursor adapter cannot be a plugin.** It's forced to write into `~/.cursor/hooks.json` -- the
very file where Orca already has 8 entries. So `install` for Cursor must be a **surgical,
idempotent merge**: add exactly its own entry, don't touch anyone else's entries, re-running
doesn't duplicate; `uninstall` removes exactly its own entry. This is an evidence-backed exception
to the principle of "don't edit another tool's config file," not arbitrariness.

The two adapters therefore differ in *where they install*, not just in the wake mechanism:

| | Claude Code | Cursor |
|---|---|---|
| Installs into | its own plugin, `~/.claude/skills/<name>/` | **merges into the shared `~/.cursor/hooks.json`** |
| Removal | delete the directory | remove exactly its own entry |
| Install risk | none | overwrites someone else's config if the merge is wrong |

Not yet checked: whether Cursor loads `skills/` from `~/.cursor/skills/` (superpowers lives there
so it's likely, but it hasn't been measured).

---

# Verification: `stop_hook_active` across a wake chain

Date: 2026-08-31
Claude Code: 2.1.236

## Question

`hooks/wake-claude.sh` uses `stop_hook_active` to block an infinite loop: the hook `--peek`s, so an
unacked message is still there at the next Stop, and every wake spawns another one. But the public
docs describe `stop_hook_active` as a flag for the case where the hook **blocks** the stop -- and
`asyncRewake` was measured to NOT block (RESULT comes back after 0.08s while the hook keeps
running for 12s). So whether this flag gets set on the Stop **after** a wake via exit 2 is
something that has to be measured.

## How it was measured

A throwaway plugin with an `asyncRewake` Stop hook, gated on `cwd`, records `stop_hook_active`
every time it fires, exits 2 on the first two firings then exits 0. Driven by an
`--input-format stream-json` session kept alive.

## Result

```
fire#1  stop_hook_active=false     <- after a real user turn
fire#2  stop_hook_active=true      <- after the wake by exit 2
fire#3  stop_hook_active=true      <- after the second wake
```

## Implications

1. **A ceiling based on `stop_hook_active` DOES engage.** The infinite loop is genuinely blocked.
2. **But this flag can't distinguish "an old unacked message" from "a new message."** After *any*
   exit 2 -- including a re-arm from a timeout that has nothing to do with any message -- every
   subsequent Stop in the chain carries the flag true. So a NEW message arriving during a re-arm
   chain would be treated as a repeat and swallowed silently.
3. So loop-blocking has to be based on **the identity of the message already reported**, not on
   the flag. The flag only says "this turn was caused by the hook," not "we already reported this
   exact thing."
