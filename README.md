# vizier

> Talk to one first mate; it runs an Orca-managed crew.

`vizier` is an **agent distro**: a Claude Code plugin plus a small install/diagnostics CLI.
Type `/vizier:vizier` in any Claude Code session, in any directory, and that session becomes
the **first mate** — the single liaison you (the *captain*) talk to. The first mate splits your
request into tasks, briefs crew agents, and runs them in worktrees and terminals managed by the
Orca app, including across hosts.

## How it splits responsibility

| Owner | Owns |
| --- | --- |
| **Orca** | The mechanics: worktrees, terminals, Run/Task/Dispatch, mailbox, release, cross-host federation. Never duplicated into vizier's state. |
| **The first mate** | The judgment: splitting a request into tasks, generating briefs, choosing a host, reading `worker_done`, deciding the next step, reporting outcomes. |
| **`~/.vizier/`** | The little state Orca has no place for: the first-mate `lock`, the `requests/` ledger, and per-project knowledge in `projects/`. |

```
captain — chat (Orca floating window / any terminal)
   |
   v
any Claude Code session + vizier plugin
   |  /vizier:vizier  ->  holds the lock  ->  is the first mate
   |
   +--> ~/.vizier/       lock, requests/, projects/
   |
   +--> orca orchestration ...   one request = one Orca Run
            |
       Dispatch   Dispatch   Dispatch      (local / remote host)
       worktree + terminal + agent, lifecycle owned by Orca
```

A `Stop` hook (`asyncRewake`) wakes the first-mate session whenever one of its Runs has mailbox
traffic, so you don't have to poll each worktree by hand. A `PostCompact` hook re-prints the
identity rules after a context compaction.

## Requirements

- macOS with the **Orca** app installed and running, exposing the `orchestration.contract.v1`
  capability (`vizier doctor` checks this).
- **Claude Code** (`claude`) — the only harness with a working activation path today.
- `git`, `jq`, `gh` (logged in via `gh auth login`).

```sh
brew install git jq gh && gh auth login
```

## Install

**1. Bootstrap.** Fetches the source into `~/.vizier/src` and puts a `vizier` symlink on PATH.
It deliberately does *not* install into a harness — that step edits harness config, so it stays
an explicit decision:

```sh
curl -fsSL https://raw.githubusercontent.com/vantoantrinh96/vizier/HEAD/install.sh | sh
```

Make sure `~/.local/bin` is on your `PATH` (the script tells you if it isn't).

**2. Check the toolchain.**

```sh
vizier doctor
```

Fix every `MISSING:` / `NOT_READY:` line it prints before continuing.

**3. Install into the harness.**

```sh
vizier install                     # Claude Code (default)
vizier install --harness cursor    # opt-in only; see "Status" below
```

The Claude adapter copies the payload into its own directory (`~/.claude/skills/vizier`) and
touches nobody else's config.

**4. Activate.** Open a new Claude Code session and type:

```
/vizier:vizier
```

The session claims the single first-mate lock, loads the identity skill, runs `doctor`, and
reports how many requests are open. Only **one** session at a time can hold the lock.

## CLI

The CLI runs at install time and diagnostic time only — never on the hot path. After install,
the first mate talks to `orca` directly.

| Command | What it does |
| --- | --- |
| `vizier doctor` | Checks orca/jq/git/gh, Orca readiness and capabilities, and whether an adapter is installed. |
| `vizier install [--harness claude\|cursor]` | Syncs the payload to `~/.vizier/dist` and installs it into the harness. |
| `vizier update` | Fetches and hard-resets `~/.vizier/src` to the remote default branch, then reinstalls. |
| `vizier version` | Prints the source commit, whether `dist` matches `src`, and the manifest version. |
| `vizier unlock` | Prints the current lock owner and clears it. The only sanctioned way out of a stuck lock — never delete the lock file by hand. |
| `vizier uninstall` | Removes the adapter, payload, and PATH symlink. `requests/` and `projects/` are kept. |

### Environment overrides

| Variable | Default |
| --- | --- |
| `VIZIER_HOME` | `~/.vizier` |
| `VIZIER_BIN_DIR` | `~/.local/bin` |
| `VIZIER_REPO_URL` | `https://github.com/vantoantrinh96/vizier.git` |
| `VIZIER_CLAUDE_SKILLS_DIR` | `~/.claude/skills` |
| `VIZIER_CURSOR_HOOKS_JSON` | `~/.cursor/hooks.json` |

## Repo layout

```
.claude-plugin/plugin.json   plugin manifest
commands/vizier.md           /vizier:vizier — activates the session and claims the lock
skills/
  identity/                  identity + hard rules (loaded on activate and after compaction)
  request/                   open and close a Request: project, routing, the one host question
  brief/                     build the four-layer spec for a task, then dispatch
  supervise/                 process a mailbox batch: release/reuse, ack, report
  delivery/                  decide a no-mistakes ask-user finding
hooks/
  hooks.json                 Stop -> wake-claude.sh, PostCompact -> reidentify-claude.sh
  wake-claude.sh             gate on the lock, wait on the mailbox, re-wake the session
  wake-cursor.sh             same gate for Cursor (synchronous hooks: parks instead)
  reidentify-claude.sh       re-print identity after a compaction
lib/                         shell libraries: home/lock, request, brief, mailbox, supervise,
                             routing, wake, merge
bin/
  vizier                     the install/diagnostics CLI
  vizier-activate.sh         claims the first-mate lock for a session
  vizier-adapter-claude.sh   install/uninstall for Claude Code
  vizier-adapter-cursor.sh   install/uninstall for Cursor
install.sh                   POSIX-sh bootstrap (curl | sh)
tests/                       21 bash test files + a fake-orca fixture
docs/                        spec, plans, decisions, verification notes
```

## Development

```sh
tests/run-all.sh              # run everything
tests/cli.test.sh             # run one file
```

The suite runs against a fake `orca` fixture and snapshots your real installed state
(`~/.local/bin/vizier`, `~/.claude/skills/vizier`, `~/.cursor/hooks.json`) before and after,
failing loudly if anything real was touched.

To try a local checkout without the bootstrap, run the CLI from the checkout itself:

```sh
./bin/vizier install
```

Installing or updating always runs from the **source checkout**, never from the installed copy
under `~/.vizier/dist` — the CLI refuses the latter to avoid deleting itself mid-run.

## Status

Version `0.1.0`. Claude Code is the supported harness. Cursor has an adapter and a wake hook,
but no activation path yet (activation reads `CLAUDE_CODE_SESSION_ID`), so a bare
`vizier install` never touches `~/.cursor/hooks.json` — a file Orca also owns. Install it
only with an explicit `--harness cursor`.

Design, plans, and verification notes live under [`docs/`](docs/).
