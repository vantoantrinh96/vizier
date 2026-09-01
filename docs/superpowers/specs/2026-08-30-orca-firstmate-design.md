# vizier -- Design

Date: 2026-08-30
Updated: 2026-08-31 -- added Delivery mode/no-mistakes; entry point becomes a multi-harness plugin + install CLI
Status: design approved in chat, spec approval pending

## Summary

`vizier` is an **agent distro** that takes the philosophy of [firstmate](https://github.com/kunchenguid/firstmate) but is rebuilt from scratch, Orca-native: installed as a **Claude Code plugin**, then typing `/vizier:vizier` in any Claude Code session in any directory turns that session into a **first mate** -- a single liaison the captain (the user) talks to, usually through Orca's floating window. The first mate coordinates crew agents running in worktrees/terminals managed by Orca, across multiple hosts (currently: local + Mac mini; the host list can change in the future).

Role-splitting principle:

- **Orca owns the mechanics**: worktree, terminal, Run/Task/Dispatch, mailbox, settle, release, cross-host federation. The distro never duplicates this state.
- **The first mate owns judgment**: splitting requests into tasks, generating briefs, picking a host, reading `worker_done` and deciding the next step, talking to the captain in the language of outcomes.
- **Minimal private state**: just the `requests/` ledger (the concept of a host pinned to a request belongs to the distro; Orca has no place to hold it) and `projects/` knowledge.

Different from firstmate in that: no 162 bash scripts, no homegrown watcher, no `state/*.meta`, no multi-multiplexer backend, and no need to `cd` into a distro directory. All the mechanics are replaced by `orca orchestration` + one small Stop hook.

## Context and rationale

firstmate has an Orca backend but only uses 8 low-level CLI commands (`status`, `repo add/show`, `worktree create/rm/show`, `terminal create/send/read/close`) and forces Orca into a tmux mold, so it inherits the limits: no busy signal, no secondmate, a homegrown steering inbox. Whereas Orca (verified on the captain's machine, app 1.4.191, 57 capabilities) already has:

- `orchestration run/task/dispatch/worker-*` -- a supervised worker lifecycle, explicit receipts.
- `orchestration check --wait --types worker_done,escalation,question` -- blocking mailbox, FIFO, replay-until-ack, works across hosts.
- `worktree ps --json` -- a whole-fleet snapshot in one command, including `agents[].state`, `linkedPR`, `lastOutputAt`.
- `worker-start --on <environment>` -- dispatch to another host; after that every command routes by Dispatch ID.
- Idempotency capabilities (`worktree.create-idempotency.v1`, `terminal.create-idempotency.v2`).

The value kept from firstmate is the part Orca **doesn't** have: single-point-of-contact liaison discipline, authority that isn't inferred, briefs with a contract, no release before landing, a failed host is never silently swapped.

Captain pains that need solving (confirmed): (1) having to check each worktree by hand -- needs centralized supervision, event-driven self-waking; (2) repeating context for every agent -- needs briefs auto-generated from project knowledge.

## Architecture

```
captain -- chat (Orca floating window / any terminal)
   |
   v
+------------------------------------------------+
| any Claude Code session, any cwd                |
|  + vizier plugin (skills, hook)         |
|  typed /vizier:vizier -> holds lock -> is first mate |
+------+-------------------------------------------+
       | reads/writes
       v
+------------------------------------------------+
| ~/.vizier/  (fixed home)                |
|  lock        -- session_id + pid of current owner|
|  requests/   -- ledger of open requests         |
|  projects/   -- per-project knowledge            |
+------+-------------------------------------------+
       | orca orchestration ...
       v
  Orca Run (1 request = 1 Run)
       | worker-start [--on <host>]
  +----+-----+----------+
  v          v          v
Dispatch  Dispatch  Dispatch     local / Mac mini / future host
(worktree + terminal + agent, Orca owns the full lifecycle)
```

### Plugin structure (what gets installed)

```
vizier/
  .claude-plugin/plugin.json
  commands/
    vizier.md             # /vizier:vizier -- activates the session, holds the lock, suggests a project from cwd
  skills/
    brief/SKILL.md           # generates the 4-layer spec for task-create
    routing/SKILL.md         # host discovery, eligibility, per-request host choice
    supervise/SKILL.md       # processes mailbox batches, release/reuse, ack, reporting
    delivery/SKILL.md        # delivery mode, delivery contract, ask-user policy
    identity/SKILL.md        # identity + hard rules; both /vizier:vizier and PostCompact load it
  hooks/
    hooks.json               # Stop (asyncRewake) + PostCompact
    wake.sh                  # Stop: gate on lock -> wait on mailbox -> exit 2 (~60 lines)
    reidentify.sh            # PostCompact: if the lock matches, reprints identity to stderr
  tests/
    fake-orca/               # fake orca on PATH returning sample JSON
    *.test.sh
  docs/superpowers/specs/    # this spec and later specs
  docs/verification/         # real-run evidence with the app version
```

### Home (what gets generated at runtime)

```
~/.vizier/
  lock                       # {session_id, pid, since} -- current first mate owner
  requests/<slug>.md         # ledger of an open request
  projects/<name>.md         # project knowledge: delivery mode, build/test/ship, conventions, pitfalls, model hints
```

Home is deliberately separate from the plugin: removing or upgrading the plugin doesn't touch state, and state never depends on the session's cwd.

## Entry point and activation

**Install once, use everywhere.** One command:

```sh
curl -fsSL https://raw.githubusercontent.com/vantoantrinh96/vizier/main/install.sh | sh
vizier doctor
vizier install
```

The repo is **public on GitHub**, so neither `curl` nor `git clone` needs auth. The first command only clones the source into `~/.vizier/src` and symlinks the CLI onto PATH -- it **deliberately does not** auto-install into the harness, because that step edits the captain's harness config and must be an explicit decision. The last command detects which harnesses are present on the machine and installs an adapter for each -- **and how it installs differs by harness**, see the Install CLI section. After that, every session of that harness, in every repo, **has** the skill and hook available but **does not** behave as a first mate.

**`/vizier:vizier` is the switch.** Typing it makes that session:

1. Write `~/.vizier/lock` = `{session_id, pid, since}`. If the lock already exists and its owner is alive -> **refuse**, reporting which session holds it. If the owner is dead and hasn't cleaned up -> reclaim it. **One first mate at a time**, so two sessions never write `requests/` at once.
2. Load the `identity` skill -- identity and hard rules into context.
3. Read the git remote at cwd and **suggest** a project for the first request. It's only a suggestion; cwd is never authority, only the captain's nod counts.

A session that doesn't type `/vizier:vizier` never holds the lock, so the hook stays silent and nothing changes for it.

**Surviving compaction.** The `PostCompact` hook: if the lock matches this session, reprint identity + hard rules to stderr. Without it, a single context compaction leaves the first mate forgetting who it is while still holding the lock and still being woken.

**Don't use the plugin's `CLAUDE.md`** for identity -- that file loads into *every* session, including one where you just want to edit code. Identity must be something activated, not something always on.

**Home access.** The first mate session has any cwd, while state lives at `~/.vizier/`. The first mate reads/writes home via Bash. If the captain runs a strict permission mode, add `--add-dir ~/.vizier` when opening the session.

## Install CLI and harness adapters

**Hard rule: the CLI only exists at install time and diagnostic time, never on the runtime path.** Once installed, the first mate talks straight to `orca`; no runtime path calls `vizier`. Breaking this rule is rebuilding firstmate's 162 scripts under a prettier name.

Five commands: `install [--harness ...]`, `doctor` (the preflight from the Entry point section, plus a check that the installed copy itself is intact), `update` (fetch in `src` then copy back over), `uninstall` (removes the payload, **keeps** `requests/` and `projects/` intact), and `unlock` (prints the current lock owner then removes the lock). `unlock` exists because `CLAUDE_PID` is the `claude` process, not the session: after `/clear` or a resume, the lock can hold a pid that's still alive but whose session id matches nothing -- `vizier_lock_claim` refuses forever, `/vizier:vizier` is forbidden from clearing the lock itself, and without this command there is no supported recovery path at all. Written in bash: this CLI only copies files and checks a few things, and Orca only runs on macOS anyway, so a Go binary for ~200 lines is unnecessary ceremony.

### One repo, multiple manifests

The model is already proven by `superpowers` and running on the captain's machine -- the same payload sits in both `~/.claude/skills/` and `~/.cursor/skills/`, with a small manifest for each harness side by side:

```
vizier/
  .claude-plugin/plugin.json   # Claude Code manifest (Cursor uses no manifest:
                               # the Cursor plugin doesn't load hooks, measured)
  commands/vizier.md        # shared
  skills/                      # shared: identity, brief, routing, supervise, delivery
  hooks/
    hooks.json                 # Claude schema: Stop (asyncRewake) + PostCompact
    wake-claude.sh
    wake-cursor.sh             # declared in NO manifest: the Cursor adapter
                               # merges it into ~/.cursor/hooks.json at install time
  install.sh
  bin/vizier
```

**A portable skill is almost free; wake is a one-time cost per harness.** That's the entire cost of being multi-harness, and it fits neatly into two `wake-*.sh` files.

`install` copies rather than symlinks: a symlink inside the plugin directory is the kind of thing that breaks silently.

**Cursor can't be installed as a plugin.** Measured: the same hook, placed in `~/.cursor/skills/<name>/` with `.cursor-plugin/plugin.json` declaring `"hooks"`, **never fires** -- even when forced with `--plugin-dir`; placed in `~/.cursor/hooks.json` it runs the full loop (`docs/verification/2026-08-31-plugin-wake.md`). So the Cursor adapter is forced into a **surgical, idempotent merge** into `~/.cursor/hooks.json` -- the very file where Orca already has 8 entries: add exactly its own entry, don't touch anyone else's entries, re-running doesn't duplicate, `uninstall` removes exactly its own entry. This is an **evidence-backed** exception to the principle of "don't edit another tool's config file," and it's the distro's biggest install risk.

| | Claude Code | Cursor |
|---|---|---|
| Installs into | its own plugin in `~/.claude/skills/<name>/` | **merges into the shared `~/.cursor/hooks.json`** |
| Removal | delete the directory | remove exactly its own entry |
| If it breaks | affects no one else | **can break Orca's config and other tools'** |

### Adapter contract -- three questions

Every harness must be able to answer these, and question 3 is the killer:

1. Which directory and format does it load skills from?
2. Which schema registers the turn-end hook?
3. What's the mechanism for "run in the background a long time, then wake an idle session"?

The two v1 adapters answer **completely differently**, so don't write them as one:

| | Claude Code | Cursor |
|---|---|---|
| Event | `Stop` | `stop` |
| How it runs | background, non-blocking (`asyncRewake: true`) | **synchronous, parks holding the turn boundary open** |
| Wake channel | `exit 2` + stderr | **`{"followup_message":...}` on stdout, exit 0** |
| `exit 2` | wakes | **silent no-op** |
| Loop blocking | `stop_hook_active` | `loop_count` + `loop_limit` declared in hooks |
| Contention | none -- async, one firing per Stop | **needs a park-owner**: a captain message arriving mid-park doesn't kill the hook, two parks seeing the same message would both report it |
| Headless `-p` | fires | **fires no hook at all** -- measured at all three hook-declaration locations |
| Identifying payload | `session_id`, `cwd` | `session_id`, `workspace_roots`, `loop_count`, `transcript_path`, `status` |
| Automated test | yes -- the spike fully automated it | **no** -- must drive a real TUI session via pty, and typing text with Enter must be separate |
| Tokens while waiting | 0 | 0 |

Consequence for Cursor: needs an additional `~/.vizier/park-owner` (an increasing seq); before emitting a follow-up, the park must confirm it's still the latest owner, otherwise exit 0 silently. And the `loop_limit` declared in hooks must be higher than our own self-imposed ceiling, so our bound bites first and still has time to report a line.

### Degradation disclosure

`install` must **print each harness's limits** right at install time, not leave the captain to discover them three days later:

- Cursor: unusable in headless `cursor-agent -p` -- **no hook fires in that mode**; an interactive session is required. Cursor also requires trust per workspace directory, so the promise "type `/vizier:vizier` anywhere" comes with a one-time trust step per new directory on Cursor.
- A harness with no adapter yet: `install` reports "not supported" outright, it doesn't silently skip it.
- **Bare `install` does NOT install Cursor.** The Cursor side has no activation path yet (`vizier-activate.sh` depends on an environment variable only Claude Code has), so an entry plugged into `~/.cursor/hooks.json` would just read the lock and exit 0: no function, while still taking on the full risk of writing to the file Orca shares. Installing it requires the explicit `--harness cursor`, and the adapter prints that limit clearly.
- A harness that can't answer question 3 -- Codex is the known case, its mechanism is "bounded foreground checkpoints" so it **cannot wake an idle session** -- that adapter must state plainly that vizier runs degraded there: it still dispatches, still briefs, but the captain has to ask "is it done" themselves.

## The Request concept (unit of coordination)

**One initial captain request = one Request = one Orca Run.** Not necessarily a "feature" -- any request counts ("fix the flaky test then add dark mode" is one request with two tasks).

File `requests/<slug>.md` (frontmatter + notes):

```markdown
---
run_id: <orca run id>
project: platform
host: local | <environment name>
status: open | closed
opened: 2026-08-30
---
The captain's original request, decisions locked in, tasks created.
```

Lifecycle:

1. **Open**: captain states a request -> first mate identifies the project -> runs routing (below) -> **asks the captain to pick a host once** -> `run-create --objective` -> writes the request file.
2. **Run**: for each sub-task -> the `brief` skill generates a spec -> `task-create --spec` -> `worker-start --task <id> --worktree new-top-level --name <n> --agent claude [--model ... --effort ...] [--on <host>] --setup run`. Every task in the request -- including review fixes, retries, spawned work -- **inherits the chosen host, no re-asking**. Delivery mode is the opposite: locked in per task at creation time (see the Delivery mode section), written into the request file with a one-line reason whenever it departs from the project's posture.
3. **Track**: events wake the first mate (the Supervision section), it processes them, reports what's worth reporting to the captain.
4. **Close**: captain confirms the request is complete -> first mate releases every remaining Dispatch of the Run, sets `status: closed`. The host pinning ends. A new request asks for a host again from scratch.

Multiple requests can be open in parallel, each its own Run, hosts can differ.

## Host routing

No host list lives in config -- hosts are first-class in Orca, added/removed with `orca environment add/rm`, the distro only reads them. At request-open time:

1. **Discover**: `orca host list --json` -- the current set of hosts, uncached.
2. **Health**: each host via `orca status [--environment <X>] --json`, requiring `reachable=true` and `state="ready"`. Fails -> excluded from selection.
3. **Project availability**: `orca project setups --project <id> --json` must have a `ready` setup on that host. Orca's constraint: a remote dispatch only accepts an exact remote worktree selector or `new-top-level` + an explicit remote `--repo` -- so a project not yet set up on a host can't be dispatched to. If the captain still picks that host -> first mate proposes `project setup-clone`, run only after the captain agrees.
4. **Choose**: present the list of eligible hosts along with the number of running workers per host (from `worktree ps` / `worker-list`) -> **the captain decides**. That's the request's only ask.

Hard rule (inherited from firstmate): **a pinned host that becomes unreachable mid-flight -> stop and report to the captain, never silently move the task to another host.** An unavailable route never turns into a local replacement.

Orca federation detail that must be respected: `--on` is used only at `worker-start`; Run and Task always live on the current server (local); subsequent commands route by Dispatch ID, without repeating `--on`.

## Supervision -- waking itself on events

Two halves fit together:

**The Orca half** -- blocking mailbox:

```bash
orca orchestration check --wait --types worker_done,escalation,question --timeout-ms <n> --json
```

Blocks until there's a message for the Run; FIFO; replays the same Delivery until `--ack`; JSON keepalive every 15s to stderr (filter on `_keepalive`). Works across hosts.

**The Claude Code half** -- `hooks/wake.sh` registered in the plugin's `hooks/hooks.json` as a Stop hook with `"asyncRewake": true`, a long timeout (following firstmate's lead: 28800s). Claude Code fires the Stop hook on **every** Stop of **every** session on the machine and does not dedupe, so the gate ordering is mandatory, cheap first then expensive:

- `session_id` in the stdin payload **doesn't match** `~/.vizier/lock` -> exit 0. One file read; this is what keeps the hook silent in every other Claude Code session.
- Matches the lock but no request has `status: open` -> exit 0, silent, costs nothing.
- **`stop_hook_active: true` in the payload and we ALREADY have a message -> exit 0.** Because the hook uses `--peek`, an unacked message is still there on the next turn; without this block, every wake spawns another wake -- an infinite loop. We already said it once; if the first mate doesn't ack, that's the first mate's bug, not something the hook should repeat. Before going silent, print one line stating the ceiling was hit.
- Otherwise -> `check --wait --peek` (peek: doesn't mark as read), `--timeout-ms` set shorter than the hook's own timeout by a safety margin (e.g. hook 28800s -> wait 28500s) so the hook always exits under its own control. A message arrives -> print one summary line to stderr, **exit 2** -> Claude Code wakes up even from idle. Timeout -> exit 2 with a "re-arm" reason so the next turn re-arms the wait. **exit 0 is forbidden here**: an idle session generates no further Stop events, so going silent on timeout is supervision dying permanently until the captain types something themselves. The re-arm loop is not a spin loop -- each cycle waits up to eight hours.
- **The hook never acks.** Acking belongs to the first mate, after it finishes processing. Thanks to replay-until-ack, a hook dying mid-flight never loses a message; a new session just needs `check` to see everything unacked again -- the restart-proofing comes from Orca, not from the distro.

On waking, the first mate (skill `supervise`):

1. `check` reads a batch -> processes **each** message before acking.
2. Every accepted `worker_done`: decide where the terminal goes **before acking** -- a follow-on task exists for that same agent -> read `worker.agent_terminal_handle` from `worker-show`, then `worker-start --task <next> --terminal <handle>` (Orca transfers ownership cleanup); otherwise -> `worker-release --dispatch <id>`. Release runs for both a successful and a failed `worker_done`, unless the captain asked to keep the terminal (`worker-retain`).
3. `--ack <delivery_id>` only after every message in the batch is processed.
4. Report the captain **one** consolidated message, only what's worth saying: outcome, PR, decisions the captain needs to make. `escalation`/`question` -> turned into a question with context; the captain's answer goes back through `orchestration reply`. A `question` carrying a no-mistakes ask-user finding goes through the `delivery` skill's policy first, it is not forwarded straight to the captain by default.

This entire chain has been verified running for real as a plugin -- see `docs/verification/2026-08-31-plugin-wake.md`.

Hard rule: **never release on timeout, TUI idle, heartbeat, status, question, escalation, or a rejected/stale `worker_done`** -- release only after a real, processed `worker_done`. One extra condition for `no-mistakes` mode: a `worker_done` is only considered terminal when the body reports a terminal axi outcome (`passed`, `checks-passed`, `failed`, `cancelled`); missing that, **do not release**, because a run might still own the branch. A worker gone unusually quiet -> `worker-read --dispatch` (source `auto`: hook-proven transcript or terminal-bounded) to diagnose, then report to the captain.

## Automatic briefs

One `projects/<name>.md` file per project, the captain can edit it directly. The `brief` skill assembles four layers into the `--spec` for `task-create`:

1. **Invariant** (every worker): report done with the exact syntax `orchestration send --type worker_done ... --outcome succeeded|failed` (a failure must be in `--outcome`, not only in prose); stuck -> `orchestration ask` rather than guessing; never self-merge; never leave the assigned worktree; **use the canonical CLI** -- `git` and `gh` for GitHub, no third-party wrapper, unless the project's knowledge file declares a different tool for that project; **never stop/restart/update the `no-mistakes` daemon** -- one instance shared across every worktree and host, a restart kills someone else's running run, hitting a daemon error means escalate then stop.
2. **Project** (from the knowledge file): how to build/test, conventions, how to ship (which branch the PR targets, commit format), known pitfalls, doc links.
3. **Delivery contract** (from the locked-in mode): opens with a fixed line `Delivery contract: mode=<mode>`, plus that mode's own definition of done -- details in the Delivery mode section below.
4. **Task** (from the captain's request): the concrete work + definition of done.

The captain only describes layer 4; layer 3 the first mate locks in at intake. The project file **thickens on its own**: a worker hits a new pitfall -> first mate proposes adding a line to the file (only written once the captain nods) -- later workers inherit it.

The project file can declare model hints per task type (scout -> cheap model/low effort, ship -> strong model), the first mate applies them via `worker-start --model ... --effort ...` (only for new terminals; `--effort` requires `--model`).

## Delivery mode and no-mistakes

[`no-mistakes`](https://github.com/kunchenguid/no-mistakes) is an external tool, not part of the distro: it stands up an internal git proxy in front of the real remote, and when we `git push no-mistakes` the daemon creates a one-shot worktree, runs a fixed pipeline `intent -> rebase -> review -> test -> document -> lint -> push -> pr -> ci`, only forwarding the branch to the push target and opening a PR after every step passes. An agent drives it via `no-mistakes axi`, a non-interactive surface that prints TOON to stdout.

Role-splitting keeps firstmate's exact spirit: **no-mistakes owns the pipeline, the distro only picks the mode and routes decisions.** Don't duplicate the gate mechanism here; the installed version's `axi --help` is authoritative.

### Mode

v1 has two modes:

- **`direct-PR`** (default): worker implements, pushes its own branch, opens a PR. No pipeline.
- **`no-mistakes`**: worker implements, commits, then drives the pipeline via `axi`.

Mode is declared in `projects/<name>.md`'s frontmatter (`delivery: direct-PR`) -- that's the project's standard posture. If the captain specifies something different for one specific task, that task follows the captain, and the first mate writes a one-line reason into the request file. **A project with no knowledge file yet -> ask the captain, never guess the mode.**

`local-only` (a clean local branch, no remote) is out of scope for v1.

### Delivery contract in the brief

Layer 3 of the brief opens with the fixed line `Delivery contract: mode=<mode>`, then:

- **`direct-PR`**: implement -> push its own branch -> open a PR **with `gh`** -> `worker_done --outcome succeeded` with the full `https://...` URL. Never push the default branch, never self-merge.
- **`no-mistakes`**: run `no-mistakes doctor`, if the repo isn't yet initialized in the worktree run `no-mistakes init`; implement -> commit -> `axi run --intent <the captain's intent>` -> keep driving **every** `axi run`/`axi respond` until an outcome. `worker_done` is only sent once axi returns a terminal outcome, and **the body must contain that outcome** (`passed` / `checks-passed` / `failed` / `cancelled`) plus the PR URL.

Since the brief already makes the worker run `doctor`/`init` itself, **routing doesn't need to probe gate readiness on the host** -- a host missing the binary makes the worker escalate. That saves an entire round of cross-host discovery.

### Ask-user findings go through Orca's mailbox

The pipeline stops at a finding that needs a human decision. A worker **never answers its own finding**: it calls `orchestration ask` with the finding ID, the step, the choices, and its recommendation. The first mate wakes via the exact `question` message type already covered in the Supervision section, decides per the policy below, then `orchestration reply` returns **one precise decision**: the action, the finding ID, and the specific `axi respond` command. The worker applies it and keeps driving.

**The first mate never calls `axi respond` for a worker's run itself.** A run has exactly one driver.

Decision policy (the `delivery` skill is the sole owner):

- **The first mate decides itself** any finding unambiguous relative to accepted intent: a genuine bug fix, completing an approved design, fixing a regression a previous fix round caused, a small fix required for accepted behavior to be correct -- even when it's hard.
- **Escalate to the captain** when: the fix would expand the contract (adding a guarantee, subsystem, abstraction, compatibility surface, or a requirement for ongoing supervision that intent doesn't call for); it's a product or architecture decision not yet locked in; multiple findings on the same theme show fix rounds piling machinery around a questionable abstraction; or it's destructive, irreversible, or security-sensitive.
- A reviewer's label (`security`, `correctness`, `required`) is **evidence about the finding, not authority to expand scope**.

An escalation sent to the captain states in full: the original request, the part of the contract being expanded, the smallest option that doesn't expand it, the consequences of accepting and of refusing, and a recommendation with its reasoning.

### Release safety

For a `no-mistakes`-mode task, a `worker_done` missing a terminal axi outcome means **do not release** -- `worker-read --dispatch` to diagnose, then report to the captain. This is where being Orca-native is cheaper than real firstmate: firstmate needs an attribution layer cross-referencing branch/head to guess which run belongs to which worktree, whereas here the brief contract makes the worker declare its own outcome, so the distro doesn't need that layer.

### Merge authority

v1: **the captain merges every PR.** Standing merge authority in the style of `yolo` is out of scope -- but noting it correctly: `yolo` is an axis **orthogonal** to delivery mode, it only says who may merge, not which pipeline the work goes through.

## External dependencies

Deliberately kept short. The distro's entire dependency surface:

| Thing | Required | Why |
|---|---|---|
| Orca app + `orca` CLI | always | worktree, terminal, Run/Task/Dispatch, mailbox, federation |
| Claude Code **or** Cursor | always | first mate's harness; each has its own wake mechanism, see the Install CLI section |
| `git`, `gh` | always | worker pushes branches and opens PRs |
| `jq` | always | hooks parse the JSON payload on stdin and the Cursor adapter merges JSON |
| `no-mistakes` | only for `no-mistakes`-mode tasks | runs the validation pipeline; see the Delivery mode section |

**No third-party CLI wrappers.** firstmate injects `gh-axi`, `chrome-devtools-axi`, `lavish-axi`, `tasks-axi`, `quota-axi` into every brief and every bootstrap; vizier doesn't. Reason: most of those exist to rebuild something Orca already has (`tasks-axi` is a homegrown backlog ledger -- here that's `requests/` + the Orca Run; the `lavish-axi` board is a homegrown fleet view -- here that's `worktree ps --json`), and the rest are just a thin layer over the canonical CLI. In exchange: a worker parsing `gh`'s JSON costs more tokens than TOON, which is acceptable.

`no-mistakes` is a deliberate exception, not a wrapper: it **is** the pipeline, there's no canonical CLI to replace it with.

## Error handling

- `worker-start` fails or returns `outcome_unknown`: exit != 0, JSON has `stage`/`failedStage`, `setup`, `effects`, `residualResources`, a recovery command. Rule: **read the receipt, do exactly the recovery it specifies, never retry blind.** Use `--retry-of <dispatch_id>` on retry to chain the history (remember to repeat placement, since retry doesn't inherit it). Leftover resources -> report to the captain.
- A wait-for-setup timeout leaving setup in `running` state is normal, not evidence of failure -- check again before concluding anything.
- `worker-release` returns `release_pending`/`release_unknown`: follow the exact recovery action in the receipt; substituting `terminal close` is **forbidden**. Mailbox delivery replay can safely repeat `worker-release`.
- The pinned host dies mid-request: stop, report, wait for the captain to decide (changing a request's host is the captain's decision, not the first mate's).
- A worker's `ask` times out: the question is still pending, resume with the original message ID -- don't create a duplicate question.
- A `no-mistakes` daemon error: the worker escalates then stops, it doesn't self-heal. The first mate also doesn't restart the daemon to "unstick" a run -- the daemon is shared, a restart kills another worker's run. That's the captain's job, on the machine that owns the daemon.

## Testing

- **fake-orca**: the `tests/fake-orca/orca` script placed ahead on PATH, returning sample JSON checked against the real schema (taken from `orca agent-context --json` and real output on the captain's machine). Lifecycle tests need no app: routing excludes a not-ready host, brief assembles exactly 4 layers, hook exits 0 with no open request / exits 2 with a message, supervise doesn't ack before the batch is fully processed. Three more cases for delivery: `no-mistakes`-mode brief generates the exact `Delivery contract:` line and a DoD that waits for an axi outcome; supervise **does not** release when a `no-mistakes` task's `worker_done` lacks an outcome; a `question` carrying an ask-user finding goes into the `delivery` policy instead of being acked outright. And three cases for the entry point: `wake.sh` exits 0 when `session_id` doesn't match the lock; `/vizier:vizier` refuses when the lock has a live owner; `/vizier:vizier` reclaims the lock when the owner is dead.
- **Real smoke test** (run by hand, with real Orca): open a request -> 1 echo task -> worker runs -> `worker_done` -> hook wakes -> release -> close the request. One variant with `--on "Mac mini"`.
- Record real smoke-test results into `docs/verification/` with the app version checked (following firstmate's practice of version-stamped evidence, since Orca has no protocol version marker -- capabilities in `orca status` serve as the compatibility gate).

## Out of scope for v1 (YAGNI, deliberately recorded so it doesn't creep in)

- `local-only` (a clean local branch, controlled merge into local `main`) -- v1 has only `direct-PR` and `no-mistakes`.
- A full registry-mode setup like `no-mistakes-prod-only` (conditional mode, per-task surface classification) -- v1 has a flat, per-project mode, the captain can override it per task.
- `yolo` / standing merge authority -- v1 has the captain merge every PR.
- Relay (X/Discord), AFK mode, voice.
- Nested secondmate/coordinator -- flat: one first mate, N workers.
- Automatic load balancing across hosts -- the captain choosing a host per request is enough.
- A dedicated scout report format -- v1 has scouts return results in the `worker_done` body; split out a format when it's actually needed.

## Known risks

- **Tightly coupled to Orca's orchestration schema**: Orca has no stable version marker; a contract change will surface at runtime. Mitigation: check `orchestration.contract.v1` in capabilities at session start; fake-orca fixtures record the exact app version checked against.
- **The Stop hook's `asyncRewake` is Claude Code behavior**; changing harness loses the wake mechanism -- accepted: this distro picks Claude Code as v1's sole harness. Verified on 2.1.236 as a plugin (`docs/verification/2026-08-31-plugin-wake.md`); Claude Code's docs document this field for a command hook but **don't** say whether a plugin hook honors it, so this is behavior that needs re-measuring on every new version.
- **The Cursor adapter writes to a shared file.** Verified the wake mechanism runs the full loop at user-level `~/.cursor/hooks.json`, but that also means `install` must edit a file Orca is using. A bad merge breaks Orca's supervision, not just ours. Mitigation: idempotent merge keyed on our own key, back up before writing, and `doctor` re-checks that our entry is still intact.
- **The Cursor TUI reports a different version than `--version`.** The TUI prints `2026.08.25-3e8eec8` while `--version` prints `2026.08.11-e8db854`. Don't gate compatibility on `--version`.
- **The plugin hook runs in every Claude Code session on the machine.** A broken `wake.sh` is a machine-wide bug, not just a first mate bug. Mitigation: the lock gate stands before everything else, and every uncertain branch exits 0.
- The Orca app must be running -- `orca open` at session start if it isn't.
- **An added dependency on `no-mistakes`** for the mode of the same name: outcome names and `axi` command names can change between versions. Mitigation built into the design: the distro **never parses axi's TOON output** -- the worker drives the pipeline and declares its own outcome in `worker_done`, so the coupling surface is only the four terminal outcome names, not the whole schema.
