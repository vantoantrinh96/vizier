# Vizier Orchestration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the coordination loop — open a Request, route it to a host, brief a worker, supervise the mailbox, decide delivery findings, close the Request — on top of the install and activation layer Plan 1 shipped.

**Architecture:** Shell libraries hold every rule that can be tested without a model (`lib/vizier-*-lib.sh`); Markdown skills hold the judgement the first mate applies (`skills/*/SKILL.md`). The libraries never call the model and the skills never re-implement a rule a library owns. All Orca access goes through the real CLI surface captured in this plan; `tests/fake-orca/orca` mirrors that surface so the whole loop is testable with no app running.

**Tech Stack:** bash (POSIX-leaning, `set -u`), `jq`, `orca` CLI, `git`/`gh`, Markdown skills.

**Spec:** `docs/superpowers/specs/2026-08-30-orca-firstmate-design.md`

**Prior plan:** `docs/superpowers/plans/2026-08-31-orca-firstmate-install-activation.md` (shipped; PR #1 merged as `2b0c4cb`). Its real smoke record is `docs/verification/2026-09-01-smoke-install.md`.

## Global Constraints

Copied from the spec. Every task's requirements implicitly include this section.

- **The captain merges every PR.** Standing merge authority (`yolo`) is out of scope for v1.
- **No third-party CLI wrappers.** `git` and `gh` only — never `gh-axi`, `tasks-axi`, `lavish-axi`, `chrome-devtools-axi`, `quota-axi`. `no-mistakes` is the single deliberate exception because it *is* the pipeline, not a wrapper over one.
- **A pinned host that becomes unreachable mid-flight → stop and report to the captain.** Never silently move a task to another host. An unavailable route never becomes a local replacement.
- **Release only after a real, processed `worker_done`.** Never release on timeout, TUI idle, heartbeat, status, question, escalation, or a rejected/stale `worker_done`.
- **In `no-mistakes` mode a `worker_done` is terminal only when the body reports a terminal axi outcome** (`passed`, `checks-passed`, `failed`, `cancelled`). Missing that → do not release.
- **The first mate never calls `axi respond` for a worker's run.** A run has exactly one driver.
- **The first mate never stops, restarts, or updates the `no-mistakes` daemon.** One instance is shared across every worktree and host.
- **Never ack before every message in the batch is processed.**
- **The host is asked of the captain exactly once per Request.** Every task in that Request inherits it, including retries, review fixes, and spawned work.
- **Delivery mode is locked in per task at creation time**, and any departure from the project's posture is written into the request file with a one-line reason.
- **A project with no knowledge file yet → ask the captain for the mode, never guess.**
- **Read the receipt, do exactly the recovery it specifies, never retry blind.**
- **`worker-release` returning `release_pending`/`release_unknown` → follow the receipt. Substituting `terminal close` is forbidden.**
- All shell is `set -u`; every library is sourced, never executed; every new library sources `lib/vizier-home.sh` first.
- Tests never touch the real `~/.vizier`, `~/.claude/skills`, `~/.cursor/hooks.json`, or `~/.local/bin/vizier`. `tests/helpers.sh` owns those overrides; `tests/run-all.sh` fails the suite if any real path changed.

## Verified Orca CLI surface

Captured on 2026-09-01 from the live app, `appVersion` **1.4.193**, via `orca agent-context --json` (`schemaVersion` present, 168 KB) and real read-only calls. **Use these strings verbatim.** Do not infer a flag that is not listed here — Plan 1 shipped a `doctor` bug precisely because a fixture and its parser were both built from an imagined shape.

Every response is enveloped:

```json
{"id":"<string>","ok":true,"result":{...},"_meta":{"runtimeId":"<uuid>"}}
```

| Command | Usage (verbatim) |
|---|---|
| `orca status` | `orca status [--json]`, also accepts `--environment` |
| `orca host list` | `orca host list [--json]` |
| `orca project setups` | `orca project setups [--project <id>] [--host <host-id>] [--json]` |
| `orca worktree ps` | `orca worktree ps [--json]` |
| `orca orchestration run-create` | `--objective <text> [--from <handle>] [--json]` |
| `orca orchestration task-create` | `--spec <text> [--task-title <text>] [--display-name <text>] [--deps <json_array>] [--parent <task_id>] [--run <run_id>] [--json]` |
| `orca orchestration worker-start` | `--task <task_id> [--on <saved-environment>] [--worktree <current\|selector\|new-child\|new-top-level>] (--agent <agent> \| --terminal <handle>) [--model <id>] [--effort <level>] [--name <name>] [--repo <selector>] [--base-branch <ref>] [--setup <run\|skip\|inherit>] [--retry-of <dispatch_id>] [--timeout-ms <n>] [--run <run_id>] [--json]` |
| `orca orchestration worker-show` | `--dispatch <dispatch_id> [--json]` |
| `orca orchestration worker-release` | `--dispatch <dispatch_id> [--json]` |
| `orca orchestration worker-list` | `[--run <run_id>] [--terminal-state <active\|reclaimable\|retained\|release_pending\|release_unknown\|released>] [--json]` |
| `orca orchestration check` | `[--terminal <handle>] [--run <run_id>] [--ack <delivery_id>] [--unread \| --peek \| --all] [--types <type,...>] [--wait] [--timeout-ms <n>] [--json]` |
| `orca orchestration send` | `--subject <text> [--to <run:id\|dispatch:id>] [--run <run_id>] [--body <text>] [--type <type>] [--task-id <id>] [--dispatch-id <id>] [--outcome <succeeded\|failed>] [--json]` |
| `orca orchestration reply` | `--id <msg_id> --body <text> [--run <run_id>] [--json]` |
| `orca orchestration ask` | `(--question <text> \| --resume <message_id>) [--run <run_id>] [--options <csv>] [--timeout-ms <n>] [--json]` |

### The three host flags are different, and that is not a typo

`orca host list --json` returns, per host, exactly the keys `id`, `kind`, `name`, `selector` — and **no** health fields. Real values observed:

```json
{"name":"this machine","kind":"local","selector":"--host local"}
{"name":"Mac mini","kind":"environment","selector":"--environment Mac mini"}
```

So the same host is addressed three different ways depending on the command:

| Purpose | Command | Flag | Value to pass |
|---|---|---|---|
| Health | `orca status` | `--environment` | the host's `name`, and **omitted entirely** for `kind == "local"` |
| Project availability | `orca project setups` | `--host` | the host's `id` (`"local"` or a uuid) |
| Dispatch | `orca orchestration worker-start` | `--on` | the host's `name`, and **omitted entirely** for `kind == "local"` |

`selector` is a ready-made flag pair (`"--host local"`, `"--environment Mac mini"`) and is **not** interchangeable with the three above. Do not pass `selector` to `--on`.

`orca project setups --json` returns `result.setups[]` with keys `createdAt, displayName, gitUsername, hookSettings, hostId, id, kind, path, projectId, repoId, setupMethod, setupState, updatedAt`. The real observed values are `setupState: "ready"`, `projectId: "github:<owner>/<repo>"`, `hostId: "local"`.

`orca status --json` returns health under `result.runtime`, **not** directly under `result`:

```
.result.runtime.state       "ready"
.result.runtime.reachable   true
.result.runtime.appVersion  "1.4.193"
.result.runtime.capabilities  [ ... ]
```

`orca worktree ps --json` returns `result` with keys `totalCount`, `truncated`, `worktrees`.

`orca orchestration run-list --json` returns `result.runs[]` with keys `consumer_generation, coordinator_handle, coordinator_pane_key, created_at, home_database, id, legacy, objective, updated_at`.

## Plan rulings

Decided while writing the plan. Recorded so an implementer does not re-litigate them.

1. **A `request` skill exists, even though the spec names only `brief`, `supervise`, and `delivery`.** The spec describes the Request lifecycle in full but assigns it to no skill. Folding it into `identity` is wrong: `identity` is re-read on every compaction, so it must stay short. Cost if wrong: one skill file moves.
2. **Routing is a library plus a section of the `request` skill, not its own skill.** Routing runs at exactly one moment — request open — and its output is a table plus one question. Cost if wrong: a `skills/routing/SKILL.md` gets split out later.
3. **`projects/<name>.md` is keyed by a captain-facing short name (`platform`), not by the Orca `projectId` (`github:luminpdf/platform`).** The spec's own example frontmatter says `project: platform`. The request file stores both: `project` (short) and `project_id` (Orca). Cost if wrong: a migration of file names.
4. **The libraries shell out to `orca` directly rather than through a wrapper function.** A wrapper would need to reproduce every flag shape above and would become a second place to get them wrong. Cost if wrong: mocking gets harder, but `fake-orca` already mocks at the PATH level, which is stronger.

## File structure

**New libraries** (each sourced, never executed; each begins by sourcing `lib/vizier-home.sh`):

| File | Responsibility |
|---|---|
| `lib/vizier-request-lib.sh` | Read and write `requests/<slug>.md`. Slug derivation, frontmatter get/set, open/close. |
| `lib/vizier-routing-lib.sh` | Host discovery, per-host health, project-setup availability, worker counts. Produces an eligibility table. Decides nothing. |
| `lib/vizier-brief-lib.sh` | Assemble the four brief layers into one `--spec` string. Owns the invariant layer text and the two delivery contracts. |
| `lib/vizier-supervise-lib.sh` | Classify a mailbox message and decide the terminal disposition (release / transfer / hold). Pure rules, no side effects. |

**New skills** (shipped by the installer, so `bin/vizier-adapter-claude.sh`'s manifest changes):

| File | Responsibility |
|---|---|
| `skills/request/SKILL.md` | Open a Request: identify project, run routing, ask the host once, `run-create`, write the file. Close a Request: release remaining dispatches, set `status: closed`. |
| `skills/brief/SKILL.md` | Turn the captain's task description into a `--spec` via `vizier-brief-lib.sh`, then `task-create` + `worker-start`. |
| `skills/supervise/SKILL.md` | Process a woken mailbox batch: read, decide per message, act, ack last, report once. |
| `skills/delivery/SKILL.md` | Pick the mode at intake; apply the ask-user finding policy; write the `reply`. |

**Modified:**

- `tests/fake-orca/orca` — grows from 2 commands to the full surface above.
- `tests/helpers.sh` — helpers to seed projects, requests, and fake dispatch state.
- `bin/vizier-adapter-claude.sh` — ship the four new skills.
- `skills/identity/SKILL.md` — point at the new skills; no new rules.

**New tests:** `tests/fake-orca.test.sh`, `tests/request-lib.test.sh`, `tests/routing-lib.test.sh`, `tests/brief-lib.test.sh`, `tests/supervise-lib.test.sh`, `tests/skills.test.sh`, `tests/loop.test.sh`.

**Do NOT edit `tests/run-all.sh` to register a test file.** It runs
`for t in *.test.sh` (line 48) and discovers new files by itself. Converting
that glob into an explicit list is a regression: the next test file anyone adds
would silently never run. The only reason to touch `run-all.sh` in this plan is
if a task genuinely changes how the suite runs, and no task does.

---

### Task 1: fake-orca grows to the full Run/Task/Worker surface

Every later task tests against this. It ships first so nothing downstream is blocked, and nothing downstream may edit it except to add a case.

**Files:**
- Modify: `tests/fake-orca/orca` (currently 2 commands)
- Modify: `tests/helpers.sh` (add seeding helpers)
- Test: `tests/fake-orca.test.sh` (create)

**Interfaces:**
- Consumes: `VIZIER_FAKE_ORCA_STATE` (already exported by `vizier_test_setup`), `$STATE/queue/<run_id>`, `$STATE/calls.log`.
- Produces, for every later task:
  - `fake_orca_seed_host <id> <name> <kind>` — appends a host to the host list.
  - `fake_orca_seed_setup <projectId> <hostId> <setupState>` — appends a project setup.
  - `fake_orca_set_status <hostName> <state> <reachable>` — per-host health; `""` as `hostName` sets the local host.
  - `fake_orca_seed_worker <dispatch_id> <terminal_handle>` — makes `worker-show` answer for that dispatch.
  - `fake_orca_calls` (already exists) — every argv line, one per call.
  - Deterministic ids: the Nth `run-create` returns `run-N`, the Nth `task-create` returns `task-N`, the Nth `worker-start` returns `dispatch-N`.

**Why deterministic ids:** a test that has to parse an id out of one call to feed the next is testing `jq`, not the code. Fixed ids let every assertion be a literal string.

- [ ] **Step 1: Write the failing test**

Create `tests/fake-orca.test.sh`:

```bash
#!/usr/bin/env bash
# fake-orca must answer the whole Orca surface the orchestration loop uses,
# in the SHAPE the real app returns -- envelope included. Every expectation
# here was copied from a real 1.4.193 response, not invented.
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup

# --- envelope -------------------------------------------------------------
out=$(orca status --json)
assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "true" "status is enveloped ok"
assert_eq "$(printf '%s' "$out" | jq -r '.result.runtime.state')" "ready" "health lives under result.runtime"
assert_eq "$(printf '%s' "$out" | jq -r '.result.runtime.reachable')" "true" "reachable under result.runtime"

# --- hosts ----------------------------------------------------------------
fake_orca_seed_host local "this machine" local
fake_orca_seed_host 0559ea68 "Mac mini" environment
out=$(orca host list --json)
assert_eq "$(printf '%s' "$out" | jq -r '.result.hosts | length')" "2" "two hosts"
assert_eq "$(printf '%s' "$out" | jq -r '.result.hosts[0].selector')" "--host local" "local selector verbatim"
assert_eq "$(printf '%s' "$out" | jq -r '.result.hosts[1].selector')" "--environment Mac mini" "env selector verbatim"
assert_eq "$(printf '%s' "$out" | jq -r '.result.hosts[1].name')" "Mac mini" "env host name"

# --- per-host health ------------------------------------------------------
fake_orca_set_status "Mac mini" offline false
assert_eq "$(orca status --environment "Mac mini" --json | jq -r '.result.runtime.reachable')" "false" "remote host reports its own health"
assert_eq "$(orca status --json | jq -r '.result.runtime.reachable')" "true" "local host unaffected"

# --- project setups -------------------------------------------------------
fake_orca_seed_setup "github:acme/platform" local ready
fake_orca_seed_setup "github:acme/platform" 0559ea68 pending
assert_eq "$(orca project setups --project github:acme/platform --json | jq -r '.result.setups | length')" "2" "both setups listed"
assert_eq "$(orca project setups --project github:acme/platform --host local --json | jq -r '.result.setups[0].setupState')" "ready" "filter by host id"
assert_eq "$(orca project setups --project github:acme/platform --host 0559ea68 --json | jq -r '.result.setups[0].setupState')" "pending" "non-ready setup preserved"

# --- run / task / worker ids are deterministic ----------------------------
assert_eq "$(orca orchestration run-create --objective "first" --json | jq -r '.result.run.id')" "run-1" "first run id"
assert_eq "$(orca orchestration run-create --objective "second" --json | jq -r '.result.run.id')" "run-2" "second run id"
assert_eq "$(orca orchestration task-create --spec "s" --run run-1 --json | jq -r '.result.task.id')" "task-1" "first task id"
out=$(orca orchestration worker-start --task task-1 --run run-1 --agent claude --worktree new-top-level --setup run --json)
assert_eq "$(printf '%s' "$out" | jq -r '.result.dispatch.id')" "dispatch-1" "first dispatch id"
assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "true" "worker-start ok"

# --- worker-show carries the terminal handle ------------------------------
assert_eq "$(orca orchestration worker-show --dispatch dispatch-1 --json | jq -r '.result.worker.agent_terminal_handle')" "term-1" "handle for dispatch-1"

# --- release --------------------------------------------------------------
assert_eq "$(orca orchestration worker-release --dispatch dispatch-1 --json | jq -r '.result.release.state')" "released" "release settles"

# --- check: queue, types filter, ack --------------------------------------
fake_orca_queue run-1 '{"delivery_id":"d1","type":"worker_done","dispatch_id":"dispatch-1","body":"done","outcome":"succeeded"}'
fake_orca_queue run-1 '{"delivery_id":"d2","type":"heartbeat","body":"tick"}'
assert_eq "$(orca orchestration check --run run-1 --peek --json | wc -l | tr -d ' ')" "2" "peek returns both"
assert_eq "$(orca orchestration check --run run-1 --peek --types worker_done --json | jq -r '.type')" "worker_done" "types filter"
# peek must NOT consume
assert_eq "$(orca orchestration check --run run-1 --peek --json | wc -l | tr -d ' ')" "2" "peek did not consume"
orca orchestration check --run run-1 --ack d1 --json >/dev/null
assert_eq "$(orca orchestration check --run run-1 --peek --json | wc -l | tr -d ' ')" "1" "ack removed exactly one"

# --- every call is logged -------------------------------------------------
assert_contains "$(fake_orca_calls)" "orchestration worker-release --dispatch dispatch-1" "release was logged"

# --- unknown command is loud, not silently ok -----------------------------
orca orchestration nonsense --json >/dev/null 2>&1
assert_eq "$?" "64" "unknown subcommand exits 64"

vizier_test_teardown
vizier_test_report
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/fake-orca.test.sh`
Expected: FAIL — `fake_orca_seed_host: command not found`, and every `host list` / `run-create` assertion empty.

- [ ] **Step 3: Add the seeding helpers**

Append to `tests/helpers.sh`, above `_vizier_fail`:

```bash
# --- fake-orca seeding ----------------------------------------------------
# Each seeder appends one JSON line to a state file; fake-orca assembles the
# envelope at read time. Line-per-record keeps the seeders append-only, so a
# test can add a host mid-run without rewriting the whole document.

fake_orca_seed_host() {  # <id> <name> <kind>
  case "$3" in
    local)       sel="--host $1" ;;
    environment) sel="--environment $2" ;;
    *) printf 'fake_orca_seed_host: unknown kind %s\n' "$3" >&2; return 2 ;;
  esac
  jq -cn --arg id "$1" --arg name "$2" --arg kind "$3" --arg sel "$sel" \
    '{id:$id,name:$name,kind:$kind,selector:$sel}' \
    >> "$VIZIER_FAKE_ORCA_STATE/hosts"
}

fake_orca_seed_setup() {  # <projectId> <hostId> <setupState>
  jq -cn --arg p "$1" --arg h "$2" --arg s "$3" \
    '{id:("setup-"+$h),projectId:$p,hostId:$h,setupState:$s,kind:"git",
      setupMethod:"imported-existing-folder",displayName:"seeded",path:"/seeded"}' \
    >> "$VIZIER_FAKE_ORCA_STATE/setups"
}

fake_orca_set_status() {  # <hostName|""> <state> <reachable>
  # "" is the local host, which is addressed by omitting --environment.
  f="$VIZIER_FAKE_ORCA_STATE/status/${1:-_local}"
  mkdir -p "$VIZIER_FAKE_ORCA_STATE/status"
  jq -cn --arg s "$2" --argjson r "$3" \
    '{state:$s,reachable:$r,runtimeId:"00000000-0000-0000-0000-000000000000",
      appVersion:"0.0.0",capabilities:["orchestration.contract.v1"]}' > "$f"
}

fake_orca_seed_worker() {  # <dispatch_id> <terminal_handle>
  mkdir -p "$VIZIER_FAKE_ORCA_STATE/workers"
  printf '%s\n' "$2" > "$VIZIER_FAKE_ORCA_STATE/workers/$1"
}
```

- [ ] **Step 4: Rewrite fake-orca**

Replace `tests/fake-orca/orca` entirely (this is the file as actually shipped
in `791635f`; the first draft of this plan omitted the `exit 0` on every branch
but `orchestration check`, so successful calls fell through to the `exit 64`
handler — found by the Task 1 implementer and confirmed by the reviewer):

```bash
#!/usr/bin/env bash
# Fake orca for tests. Logs every call, serves queued messages, and NEVER
# touches the network or the real app.
#
# SHAPES ARE COPIED, NOT INVENTED. Every envelope and field name below was
# taken from a real Orca 1.4.193 response (captured 2026-09-01 and recorded in
# the plan's "Verified Orca CLI surface" section). Plan 1 shipped a `doctor`
# bug because a fixture and its parser were both built from an imagined shape,
# so the fixture agreed with the bug. If you need a field that is not here,
# capture it from the real app first -- do not add it from memory.
#
# UNKNOWN COMMANDS EXIT 64, NOT 0. A fake that silently succeeds on a command
# it does not implement lets a caller ship a typo'd flag and still go green.
set -u
STATE="${VIZIER_FAKE_ORCA_STATE:?fake-orca needs VIZIER_FAKE_ORCA_STATE}"
printf '%s\n' "$*" >> "$STATE/calls.log"

# --- argument scan --------------------------------------------------------
run_id=""; timeout_ms=0; wait_mode=0; peek=0; ack=""; types=""
dispatch=""; task=""; project=""; host=""; environment=""; objective=""
spec=""; msg_id=""; on_host=""
prev=""
for arg in "$@"; do
  case "$prev" in
    --run)         run_id=$arg ;;
    --timeout-ms)  timeout_ms=$arg ;;
    --ack)         ack=$arg ;;
    --types)       types=$arg ;;
    --dispatch)    dispatch=$arg ;;
    --task)        task=$arg ;;
    --project)     project=$arg ;;
    --host)        host=$arg ;;
    --environment) environment=$arg ;;
    --objective)   objective=$arg ;;
    --spec)        spec=$arg ;;
    --id)          msg_id=$arg ;;
    --on)          on_host=$arg ;;
  esac
  [ "$arg" = "--wait" ] && wait_mode=1
  [ "$arg" = "--peek" ] && peek=1
  prev=$arg
done

envelope() {  # <result_json>
  jq -cn --argjson r "$1" '{id:"fake",ok:true,result:$r,_meta:{runtimeId:"fake-runtime"}}'
}

next_id() {  # <counter_name> <prefix> -- prints "<prefix>-<N>"
  f="$STATE/counter.$1"
  n=$(cat "$f" 2>/dev/null || printf '0'); n=$((n+1))
  printf '%s' "$n" > "$f"
  printf '%s-%s' "$2" "$n"
}

case "$1 ${2:-}" in

  "status"|"status --json"|"status --environment"*)
    # Per-host health. The local host is addressed by OMITTING --environment,
    # which is why the empty key is spelled _local rather than "".
    f="$STATE/status/${environment:-_local}"
    if [ -f "$f" ]; then rt=$(cat "$f")
    else rt='{"state":"ready","reachable":true,"runtimeId":"00000000-0000-0000-0000-000000000000","appVersion":"0.0.0","capabilities":["runtime.status.compat.v1","runtime.environments.v1","orchestration.contract.v1"]}'
    fi
    # Built in a variable first, then substituted: bash miscounts braces in
    # ${VAR:-literal{with}braces} and silently corrupts nested JSON.
    default_result=$(jq -cn --argjson rt "$rt" \
      '{target:{kind:"local"},app:{running:true,pid:0,desktopWindowStatus:"available"},runtime:$rt,graph:{state:"ready"}}')
    result="${VIZIER_FAKE_ORCA_STATUS_RESULT:-$default_result}"
    envelope "$result"
    exit 0
    ;;

  "host list")
    hosts=$(jq -cs '.' "$STATE/hosts" 2>/dev/null || printf '[]')
    envelope "$(jq -cn --argjson h "${hosts:-[]}" '{hosts:$h}')"
    exit 0
    ;;

  "project setups")
    all=$(jq -cs '.' "$STATE/setups" 2>/dev/null || printf '[]')
    envelope "$(jq -cn --argjson s "${all:-[]}" --arg p "$project" --arg h "$host" \
      '{setups: ($s | map(select(($p=="" or .projectId==$p) and ($h=="" or .hostId==$h))))}')"
    exit 0
    ;;

  "worktree ps")
    envelope '{"totalCount":0,"truncated":false,"worktrees":[]}'
    exit 0
    ;;

  "orchestration run-create")
    id=$(next_id run run)
    envelope "$(jq -cn --arg id "$id" --arg o "$objective" '{run:{id:$id,objective:$o}}')"
    exit 0
    ;;

  "orchestration task-create")
    id=$(next_id task task)
    printf '%s' "$spec" > "$STATE/spec.$id"
    envelope "$(jq -cn --arg id "$id" --arg r "$run_id" '{task:{id:$id,run_id:$r}}')"
    exit 0
    ;;

  "orchestration worker-start")
    id=$(next_id dispatch dispatch)
    n=${id#dispatch-}
    mkdir -p "$STATE/workers"
    [ -f "$STATE/workers/$id" ] || printf 'term-%s\n' "$n" > "$STATE/workers/$id"
    envelope "$(jq -cn --arg id "$id" --arg t "$task" --arg on "$on_host" \
      '{dispatch:{id:$id,task_id:$t,on:$on,state:"running"}}')"
    exit 0
    ;;

  "orchestration worker-show")
    h=$(cat "$STATE/workers/$dispatch" 2>/dev/null || printf '')
    envelope "$(jq -cn --arg d "$dispatch" --arg h "$h" \
      '{worker:{dispatch_id:$d,agent_terminal_handle:$h,state:"settled"}}')"
    exit 0
    ;;

  "orchestration worker-release")
    st="${VIZIER_FAKE_ORCA_RELEASE_STATE:-released}"
    envelope "$(jq -cn --arg d "$dispatch" --arg s "$st" '{release:{dispatch_id:$d,state:$s}}')"
    exit 0
    ;;

  "orchestration worker-list")
    envelope '{"workers":[]}'
    exit 0
    ;;

  "orchestration check")
    q="$STATE/queue/${run_id:-_none}"
    if [ -n "$ack" ]; then
      # Ack removes exactly the acked delivery, nothing else. A fake that
      # truncated the queue would hide the real bug this guards: acking a
      # batch before every message in it has been processed.
      if [ -f "$q" ]; then
        jq -c --arg a "$ack" 'select(.delivery_id != $a)' "$q" > "$q.tmp" 2>/dev/null || : > "$q.tmp"
        mv "$q.tmp" "$q"
      fi
    fi
    emit() {
      [ -s "$q" ] || return 1
      if [ -n "$types" ]; then
        jq -c --arg t "$types" 'select(($t | split(",")) as $ts | .type as $x | $ts | index($x))' "$q"
      else
        cat "$q"
      fi
      # --peek never consumes. Without --peek the messages stay too: real
      # Orca replays until --ack, and tests depend on that replay.
      return 0
    }
    if emit | grep -q .; then emit; exit 0; fi
    if [ "$wait_mode" = 1 ]; then
      slept=0
      while [ "$slept" -lt "${timeout_ms:-0}" ]; do
        if emit | grep -q .; then emit; exit 0; fi
        sleep 0.05; slept=$((slept+50))
      done
    fi
    exit 0
    ;;

  "orchestration send"|"orchestration reply"|"orchestration ask")
    id=$(next_id msg msg)
    envelope "$(jq -cn --arg id "$id" --arg r "$msg_id" '{message:{id:$id,in_reply_to:$r}}')"
    exit 0
    ;;

esac

printf 'fake-orca: unimplemented command: %s\n' "$*" >&2
exit 64
```

Note the two `emit` invocations: the first decides whether anything matches, the second prints it. A single `emit` piped to `grep -q` would consume the output.

- [ ] **Step 5: Run the test**

Run: `bash tests/fake-orca.test.sh`
Expected: PASS, all assertions.

- [ ] **Step 6: Prove the old tests still pass**

The wake tests already drive `orchestration check` and `status`. They must not have regressed:

Run: `bash tests/run-all.sh`
Expected: PASS, same count as before plus this file's assertions.

- [ ] **Step 7: Commit**

```bash
git add tests/fake-orca/orca tests/helpers.sh tests/fake-orca.test.sh
git commit -m "test: fake-orca covers the full Run/Task/Worker surface"
```

---

### Task 2: `lib/vizier-request-lib.sh` — the Request file

**Files:**
- Create: `lib/vizier-request-lib.sh`
- Test: `tests/request-lib.test.sh`

**Interfaces:**
- Consumes: `vizier_home`, `vizier_requests_dir` from `lib/vizier-home.sh`.
- **Does NOT re-implement `vizier_open_run_ids`.** That function already lives in `lib/vizier-wake-lib.sh`, is frontmatter-scoped and CRLF-tolerant, and the wake hook depends on it. This library writes the files that function reads; it must never change their frontmatter shape without changing that function too.
- Produces:
  - `vizier_request_slug <text>` → a filesystem-safe slug
  - `vizier_request_path <slug>` → absolute path
  - `vizier_request_create <slug> <run_id> <project> <project_id> <host> <body>` → writes the file, rc 1 if it already exists
  - `vizier_request_get <slug> <key>` → one frontmatter value, empty if absent
  - `vizier_request_set <slug> <key> <value>` → replaces one frontmatter value in place
  - `vizier_request_note <slug> <line>` → appends one line to the body
  - `vizier_request_close <slug>` → sets `status: closed`
  - `vizier_request_open_slugs` → slugs whose frontmatter `status` is `open`

**Frontmatter contract** (exactly these keys, in this order):

```markdown
---
run_id: run-1
project: platform
project_id: github:acme/platform
host: local
status: open
opened: 2026-09-01
---
```

`project` is the captain-facing short name and names the knowledge file `projects/<project>.md`. `project_id` is Orca's id and is what `orca project setups --project` takes. `host` is the host's `name` (`local` for the local host) — the value `worker-start --on` needs, per the ruling in the CLI section.

- [ ] **Step 1: Write the failing test**

Create `tests/request-lib.test.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-home.sh"
. "$VIZIER_TEST_REPO/lib/vizier-wake-lib.sh"
. "$VIZIER_TEST_REPO/lib/vizier-request-lib.sh"

# --- slugs ----------------------------------------------------------------
assert_eq "$(vizier_request_slug 'Fix the flaky test then add dark mode')" \
          "fix-the-flaky-test-then-add-dark-mode" "words become a kebab slug"
assert_eq "$(vizier_request_slug '  Trailing / slashes ../ and dots.  ')" \
          "trailing-slashes-and-dots" "path characters cannot survive a slug"
assert_eq "$(vizier_request_slug 'sửa lỗi đăng nhập')" "sua-loi-dang-nhap" \
          "non-ASCII is transliterated, not dropped to nothing"
assert_eq "$(vizier_request_slug '')" "request" "an empty title still yields a usable name"
# 60 words of "word " cut at 60 chars lands exactly on a dash (12 x "word-"),
# and trimming it leaves 59. Measured, not assumed -- an assertion of 60 here
# would fail against correct code.
long=$(vizier_request_slug "$(printf 'word %.0s' $(seq 1 60))")
assert_eq "${#long}" "59" "slug is capped at 60 characters, then trimmed"
assert_eq "$(printf '%s' "$long" | sed 's/.*\(.\)$/\1/')" "d" "cap never leaves a trailing dash"

# --- create ---------------------------------------------------------------
vizier_request_create dark-mode run-1 platform github:acme/platform local "Add dark mode"
f="$(vizier_request_path dark-mode)"
assert_eq "$(test -f "$f" && echo yes)" "yes" "file created"
assert_eq "$(vizier_request_get dark-mode run_id)" "run-1" "run_id round-trips"
assert_eq "$(vizier_request_get dark-mode project)" "platform" "project round-trips"
assert_eq "$(vizier_request_get dark-mode project_id)" "github:acme/platform" "project_id keeps its colon"
assert_eq "$(vizier_request_get dark-mode host)" "local" "host round-trips"
assert_eq "$(vizier_request_get dark-mode status)" "open" "new requests are open"
assert_contains "$(cat "$f")" "Add dark mode" "body preserved"

# the wake hook's reader must accept what we wrote -- this is the whole point
assert_eq "$(vizier_open_run_ids)" "run-1" "wake-lib sees the request we wrote"

# --- create is not allowed to clobber -------------------------------------
vizier_request_create dark-mode run-9 other github:acme/other local "different" 2>/dev/null
assert_eq "$?" "1" "create refuses an existing slug"
assert_eq "$(vizier_request_get dark-mode run_id)" "run-1" "refused create changed nothing"

# --- get is frontmatter-scoped --------------------------------------------
vizier_request_note dark-mode "The captain said status: closed in passing."
assert_eq "$(vizier_request_get dark-mode status)" "open" "a body line never answers a frontmatter query"
assert_eq "$(vizier_open_run_ids)" "run-1" "and never closes the request either"

# --- set / close ----------------------------------------------------------
vizier_request_set dark-mode host "Mac mini"
assert_eq "$(vizier_request_get dark-mode host)" "Mac mini" "a value with a space survives"
assert_eq "$(grep -c '^host:' "$f")" "1" "set replaces, never appends a second key"

vizier_request_create login run-2 platform github:acme/platform local "Fix login"
assert_eq "$(vizier_request_open_slugs | sort | tr '\n' ' ')" "dark-mode login " "both open"
vizier_request_close dark-mode
assert_eq "$(vizier_request_get dark-mode status)" "closed" "closed"
assert_eq "$(vizier_request_open_slugs)" "login" "closed request drops out"
assert_eq "$(vizier_open_run_ids)" "run-2" "and the hook stops waiting on its Run"

# --- CRLF tolerance, matching wake-lib ------------------------------------
printf -- '---\r\nrun_id: run-3\r\nproject: p\r\nproject_id: x\r\nhost: local\r\nstatus: open\r\nopened: 2026-09-01\r\n---\r\nbody\r\n' > "$(vizier_request_path crlf)"
assert_eq "$(vizier_request_get crlf run_id)" "run-3" "CRLF file reads cleanly"
assert_contains "$(vizier_request_open_slugs)" "crlf" "CRLF request counts as open"

vizier_test_teardown
vizier_test_report
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/request-lib.test.sh`
Expected: FAIL — `lib/vizier-request-lib.sh: No such file or directory`.

- [ ] **Step 3: Write the library**

Create `lib/vizier-request-lib.sh`:

```bash
# shellcheck shell=bash
# The Request file: one captain request = one file = one Orca Run.
# Requires lib/vizier-home.sh to be sourced first.
#
# THE FRONTMATTER SHAPE IS SHARED. lib/vizier-wake-lib.sh reads these same
# files to decide which Runs the wake hook waits on. Change a key name here
# and the hook goes silent -- with no error, because a missing key just looks
# like "no open requests". Any change to the keys below must change
# vizier_open_run_ids in the same commit.
#
# FRONTMATTER IS SCOPED, ALWAYS. Every read stops at the closing `---`. A
# request body quotes the captain verbatim, and a captain who writes
# "status: closed" in a sentence must not thereby close the request.

# Transliterate, lowercase, collapse to single dashes, cap, trim dashes.
# Cap first, THEN trim: cutting mid-word can leave a trailing dash, and a
# slug ending in a dash makes an ugly filename that also breaks the
# round-trip in tests.
# macOS iconv is NOT usable here. `iconv -t ASCII//TRANSLIT` fails outright on
# Vietnamese ("illegal byte sequence") and emits a truncated prefix, so
# "sua loi dang nhap" comes out as "ss-a-l-i-ng-nh-p". Measured on the
# captain's machine, 2026-09-01. An explicit table is longer but it is the
# only version that works for the language the captain actually writes in.
_vizier_translit() {  # <text>
  printf '%s' "$1" | sed \
    -e 's/[àáảãạăằắẳẵặâầấẩẫậ]/a/g' -e 's/[ÀÁẢÃẠĂẰẮẲẴẶÂẦẤẨẪẬ]/A/g' \
    -e 's/[èéẻẽẹêềếểễệ]/e/g' -e 's/[ÈÉẺẼẸÊỀẾỂỄỆ]/E/g' \
    -e 's/[ìíỉĩị]/i/g' -e 's/[ÌÍỈĨỊ]/I/g' \
    -e 's/[òóỏõọôồốổỗộơờớởỡợ]/o/g' -e 's/[ÒÓỎÕỌÔỒỐỔỖỘƠỜỚỞỠỢ]/O/g' \
    -e 's/[ùúủũụưừứửữự]/u/g' -e 's/[ÙÚỦŨỤƯỪỨỬỮỰ]/U/g' \
    -e 's/[ỳýỷỹỵ]/y/g' -e 's/[ỲÝỶỸỴ]/Y/g' \
    -e 's/đ/d/g' -e 's/Đ/D/g'
}

vizier_request_slug() {  # <text>
  s=$(_vizier_translit "${1:-}")
  s=$(printf '%s' "$s" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]\{1,\}/-/g' \
    | cut -c1-60 \
    | sed 's/^-*//; s/-*$//')
  [ -n "$s" ] || s=request
  printf '%s' "$s"
}

vizier_request_path() {  # <slug>
  printf '%s/%s.md' "$(vizier_requests_dir)" "$1"
}

vizier_request_create() {  # <slug> <run_id> <project> <project_id> <host> <body>
  f=$(vizier_request_path "$1")
  [ -e "$f" ] && return 1
  mkdir -p "$(vizier_requests_dir)" || return 1
  # Written to a temp file and moved into place: a half-written frontmatter
  # read by the wake hook mid-write would parse as "not open".
  t=$(mktemp "${TMPDIR:-/tmp}/vizier-req.XXXXXX") || return 1
  {
    printf -- '---\n'
    printf 'run_id: %s\n' "$2"
    printf 'project: %s\n' "$3"
    printf 'project_id: %s\n' "$4"
    printf 'host: %s\n' "$5"
    printf 'status: open\n'
    printf 'opened: %s\n' "$(date +%Y-%m-%d)"
    printf -- '---\n'
    printf '%s\n' "$6"
  } > "$t" || { rm -f "$t"; return 1; }
  mv "$t" "$f"
}

# Print the frontmatter only: everything between the first `---` and the next.
_vizier_request_frontmatter() {  # <slug>
  f=$(vizier_request_path "$1")
  [ -r "$f" ] || return 1
  tr -d '\r' < "$f" | awk 'NR==1 && $0=="---" {inside=1; next} inside && $0=="---" {exit} inside'
}

vizier_request_get() {  # <slug> <key>
  _vizier_request_frontmatter "$1" 2>/dev/null \
    | sed -n "s/^$2: *//p" | head -n 1
}

vizier_request_set() {  # <slug> <key> <value>
  f=$(vizier_request_path "$1")
  [ -w "$f" ] || return 1
  t=$(mktemp "${TMPDIR:-/tmp}/vizier-req.XXXXXX") || return 1
  # awk, not sed -i: BSD and GNU disagree on -i, and the value may contain
  # slashes (a project_id does). Passing the value as an awk variable means
  # it is never re-parsed as a pattern.
  tr -d '\r' < "$f" | awk -v k="$2" -v v="$3" '
    NR==1 && $0=="---" { inside=1; print; next }
    inside && $0=="---" { inside=0; print; next }
    inside && index($0, k ":") == 1 { print k ": " v; next }
    { print }
  ' > "$t" || { rm -f "$t"; return 1; }
  mv "$t" "$f"
}

vizier_request_note() {  # <slug> <line>
  f=$(vizier_request_path "$1")
  [ -w "$f" ] || return 1
  printf '%s\n' "$2" >> "$f"
}

vizier_request_close() {  # <slug>
  vizier_request_set "$1" status closed
}

vizier_request_open_slugs() {
  d=$(vizier_requests_dir)
  [ -d "$d" ] || return 0
  for f in "$d"/*.md; do
    [ -e "$f" ] || continue
    s=$(basename "$f" .md)
    [ "$(vizier_request_get "$s" status)" = "open" ] && printf '%s\n' "$s"
  done
  return 0
}
```

- [ ] **Step 4: Run the test**

Run: `bash tests/request-lib.test.sh`
Expected: PASS.

- [ ] **Step 5: Run the whole suite**


Run: `bash tests/run-all.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/vizier-request-lib.sh tests/request-lib.test.sh
git commit -m "feat: request file lifecycle"
```

---

### Task 3: `lib/vizier-routing-lib.sh` — host eligibility

**Files:**
- Create: `lib/vizier-routing-lib.sh`
- Test: `tests/routing-lib.test.sh`

**Interfaces:**
- Consumes: the `orca` CLI on PATH (fake-orca in tests), `jq`.
- Produces:
  - `vizier_hosts` → one TSV line per host: `id<TAB>name<TAB>kind`
  - `vizier_host_health <name> <kind>` → prints `ready` or a reason (`unreachable`, `state=<x>`, `error`); rc 0 only when eligible
  - `vizier_host_setup_state <project_id> <host_id>` → prints the `setupState`, or `none`
  - `vizier_routing_table <project_id>` → one TSV line per host: `name<TAB>health<TAB>setup<TAB>eligible`
- **Decides nothing.** Eligibility is computed; the *choice* belongs to the captain, and the `request` skill asks. A library that picked a host would violate the spec's only-ask-once-and-never-substitute rule by making the substitution invisible.

**The three-flag rule, restated because it is the whole difficulty of this task:**

```
health:  orca status --json                      (local: no host flag at all)
         orca status --environment <name> --json (remote: the host's NAME)
setup:   orca project setups --project <project_id> --host <host_id> --json
dispatch: worker-start --on <name>               (handled in Task 5, not here)
```

- [ ] **Step 1: Write the failing test**

Create `tests/routing-lib.test.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-home.sh"
. "$VIZIER_TEST_REPO/lib/vizier-routing-lib.sh"

fake_orca_seed_host local "this machine" local
fake_orca_seed_host 0559ea68 "Mac mini" environment
fake_orca_seed_host beef "Broken box" environment

assert_eq "$(vizier_hosts | wc -l | tr -d ' ')" "3" "three hosts discovered"
assert_eq "$(vizier_hosts | head -1)" "$(printf 'local\tthis machine\tlocal')" "TSV shape"

# --- health ---------------------------------------------------------------
fake_orca_set_status ""           ready   true
fake_orca_set_status "Mac mini"   ready   true
fake_orca_set_status "Broken box" ready   false

assert_eq "$(vizier_host_health "this machine" local)" "ready" "local is ready"
assert_eq "$(vizier_host_health "Mac mini" environment)" "ready" "remote ready"
assert_eq "$(vizier_host_health "Broken box" environment)" "unreachable" "reachable=false is not eligible"
vizier_host_health "Broken box" environment >/dev/null; assert_eq "$?" "1" "and returns rc 1"

fake_orca_set_status "Mac mini" starting true
assert_eq "$(vizier_host_health "Mac mini" environment)" "state=starting" "a non-ready state is named, not summarised"

# the local host must be probed with NO host flag at all
assert_contains "$(fake_orca_calls)" "status --json" "local health used no host flag"
assert_contains "$(fake_orca_calls)" "status --environment Mac mini --json" "remote health used the NAME"

# --- setups ---------------------------------------------------------------
fake_orca_seed_setup "github:acme/platform" local ready
fake_orca_seed_setup "github:acme/platform" 0559ea68 pending
assert_eq "$(vizier_host_setup_state github:acme/platform local)" "ready" "ready setup"
assert_eq "$(vizier_host_setup_state github:acme/platform 0559ea68)" "pending" "pending setup reported as-is"
assert_eq "$(vizier_host_setup_state github:acme/platform beef)" "none" "no setup at all"
assert_contains "$(fake_orca_calls)" "project setups --project github:acme/platform --host local --json" "setup lookup used the host ID"

# --- the table ------------------------------------------------------------
fake_orca_set_status "Mac mini" ready true
t=$(vizier_routing_table github:acme/platform)
# printf '%s\n', not '%s': command substitution strips the trailing newline,
# so `wc -l` over a bare '%s' counts one fewer line than there are rows and
# this assertion can never pass.
assert_eq "$(printf '%s\n' "$t" | wc -l | tr -d ' ')" "3" "one row per host"
assert_eq "$(printf '%s\n' "$t" | awk -F'\t' '$1=="this machine"{print $4}')" "yes" "local eligible"
assert_eq "$(printf '%s\n' "$t" | awk -F'\t' '$1=="Mac mini"{print $4}')" "no" "healthy host with a pending setup is NOT eligible"
assert_eq "$(printf '%s\n' "$t" | awk -F'\t' '$1=="Broken box"{print $4}')" "no" "unreachable host is not eligible"
assert_eq "$(printf '%s\n' "$t" | awk -F'\t' '$1=="Mac mini"{print $3}')" "pending" "the reason survives into the table"

# --- an orca failure is never silently 'eligible' -------------------------
PATH="$VIZIER_TEST_TMP/nobin:$PATH" ; mkdir -p "$VIZIER_TEST_TMP/nobin"
printf '#!/bin/sh\nexit 3\n' > "$VIZIER_TEST_TMP/nobin/orca"; chmod +x "$VIZIER_TEST_TMP/nobin/orca"
assert_eq "$(vizier_host_health "this machine" local)" "error" "a failing orca is an error, not ready"
vizier_host_health "this machine" local >/dev/null; assert_eq "$?" "1" "and rc 1"

vizier_test_teardown
vizier_test_report
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/routing-lib.test.sh`
Expected: FAIL — library missing.

- [ ] **Step 3: Write the library**

Create `lib/vizier-routing-lib.sh`:

```bash
# shellcheck shell=bash
# Host discovery and eligibility. Requires lib/vizier-home.sh to be sourced.
#
# THIS LIBRARY DECIDES NOTHING. It reports which hosts are eligible; the
# captain picks. The spec's hard rule is that an unavailable route never
# silently becomes a local one, and the surest way to keep that rule is to
# leave no code path that can choose a host at all.
#
# THREE DIFFERENT FLAGS NAME THE SAME HOST -- verified against Orca 1.4.193:
#   health   : orca status [--environment <NAME>]     (local: no flag)
#   setups   : orca project setups --host <ID>
#   dispatch : worker-start --on <NAME>               (not this library)
# `orca host list` also returns a `selector` field ("--host local",
# "--environment Mac mini"). It is a ready-made flag PAIR and is not
# interchangeable with any of the three above. Do not pass it to --on.

vizier_hosts() {
  orca host list --json 2>/dev/null \
    | jq -r '.result.hosts[]? | [.id, .name, .kind] | @tsv'
}

vizier_host_health() {  # <name> <kind> -- prints ready|unreachable|state=<x>|error
  if [ "$2" = "local" ]; then
    out=$(orca status --json 2>/dev/null) || { printf 'error'; return 1; }
  else
    out=$(orca status --environment "$1" --json 2>/dev/null) || { printf 'error'; return 1; }
  fi
  [ -n "$out" ] || { printf 'error'; return 1; }
  # One jq pass, so a malformed document fails once rather than per-field.
  read -r reachable state <<EOF
$(printf '%s' "$out" | jq -r '[.result.runtime.reachable, .result.runtime.state] | @tsv' 2>/dev/null)
EOF
  case "$reachable" in
    true) ;;
    *) printf 'unreachable'; return 1 ;;
  esac
  if [ "$state" != "ready" ]; then printf 'state=%s' "${state:-unknown}"; return 1; fi
  printf 'ready'
}

vizier_host_setup_state() {  # <project_id> <host_id> -- prints setupState or "none"
  s=$(orca project setups --project "$1" --host "$2" --json 2>/dev/null \
      | jq -r '.result.setups[0].setupState // empty' 2>/dev/null)
  printf '%s' "${s:-none}"
}

vizier_routing_table() {  # <project_id> -- name TAB health TAB setup TAB eligible
  vizier_hosts | while IFS="$(printf '\t')" read -r id name kind; do
    [ -n "$id" ] || continue
    health=$(vizier_host_health "$name" "$kind") || :
    setup=$(vizier_host_setup_state "$1" "$id")
    if [ "$health" = "ready" ] && [ "$setup" = "ready" ]; then eligible=yes; else eligible=no; fi
    printf '%s\t%s\t%s\t%s\n' "$name" "$health" "$setup" "$eligible"
  done
}
```

- [ ] **Step 4: Run the test**

Run: `bash tests/routing-lib.test.sh`
Expected: PASS.

- [ ] **Step 5: Run the whole suite**


Run: `bash tests/run-all.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/vizier-routing-lib.sh tests/routing-lib.test.sh
git commit -m "feat: host routing eligibility"
```

---

### Task 4: `lib/vizier-brief-lib.sh` — the four-layer brief

**Files:**
- Create: `lib/vizier-brief-lib.sh`
- Create: `docs/project-file-format.md`
- Test: `tests/brief-lib.test.sh`

**Interfaces:**
- Consumes: `vizier_home` (knowledge files live at `$(vizier_home)/projects/<name>.md`).
- Produces:
  - `vizier_brief_invariant` → layer 1, fixed text
  - `vizier_project_path <project>` / `vizier_project_field <project> <key>`
  - `vizier_project_mode <project>` → the `delivery:` frontmatter value, rc 1 if there is no file
  - `vizier_brief_project <project>` → layer 2, the knowledge file's body
  - `vizier_brief_delivery <mode>` → layer 3, beginning with the fixed line
  - `vizier_brief_assemble <project> <mode> <task_text>` → the complete `--spec` string

**A ruling this task locks in:** in `no-mistakes` mode the worker must write the axi result as the exact line `axi_outcome: <value>`. The spec only says "the body must contain that outcome". Free-text matching is not safe — a body reading "the tests have not passed" contains the token `passed`, and a supervisor that released on it would release a worker whose pipeline still owns the branch, which is exactly the failure the rule exists to prevent. The invariant layer already mandates exact syntax for `--outcome`, so mandating it here is consistent rather than new. Cost if wrong: the brief text and one `sed` pattern change together.

- [ ] **Step 1: Write the failing test**

Create `tests/brief-lib.test.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-home.sh"
. "$VIZIER_TEST_REPO/lib/vizier-brief-lib.sh"

mkdir -p "$VIZIER_HOME/projects"
cat > "$VIZIER_HOME/projects/platform.md" <<'EOF'
---
delivery: direct-PR
---
Build with `make build`. Test with `make test`.
PRs target `develop`, never `main`.
EOF

# --- project file ---------------------------------------------------------
assert_eq "$(vizier_project_mode platform)" "direct-PR" "mode read from frontmatter"
assert_contains "$(vizier_brief_project platform)" "make test" "body is layer 2"
assert_eq "$(vizier_brief_project platform | grep -c 'delivery:')" "0" \
  "frontmatter never leaks into the brief"

# a project with NO knowledge file must not silently get a default mode
vizier_project_mode unknown-project >/dev/null 2>&1
assert_eq "$?" "1" "no knowledge file -> rc 1 so the skill asks the captain"

# --- layer 1 invariants ---------------------------------------------------
inv=$(vizier_brief_invariant)
assert_contains "$inv" "orchestration send --type worker_done" "exact done syntax"
assert_contains "$inv" "--outcome succeeded|failed" "failure goes in --outcome, not prose"
assert_contains "$inv" "orchestration ask" "stuck -> ask"
assert_contains "$inv" "Never self-merge" "no self-merge"
assert_contains "$inv" "no-mistakes daemon" "daemon rule present"
# the wrapper ban must name the tools: a worker that has never read the spec
# will not recognise "canonical CLI" as excluding something it just found
assert_contains "$inv" "gh-axi" "the banned wrapper is named"

# --- layer 3: direct-PR ---------------------------------------------------
d=$(vizier_brief_delivery direct-PR)
assert_eq "$(printf '%s\n' "$d" | head -1)" "Delivery contract: mode=direct-PR" "fixed opening line"
assert_contains "$d" "gh" "PR is opened with gh"
assert_contains "$d" "https://" "the URL must be reported in full"
assert_contains "$d" "Never push the default branch" "default branch protected"

# --- layer 3: no-mistakes -------------------------------------------------
n=$(vizier_brief_delivery no-mistakes)
assert_eq "$(printf '%s\n' "$n" | head -1)" "Delivery contract: mode=no-mistakes" "fixed opening line"
assert_contains "$n" "no-mistakes doctor" "doctor first"
assert_contains "$n" "no-mistakes init" "init when uninitialised"
assert_contains "$n" "axi run --intent" "the run command"
assert_contains "$n" "axi_outcome:" "the exact outcome syntax is mandated"
assert_contains "$n" "checks-passed" "terminal values listed"
assert_contains "$n" "cancelled" "all four terminal values listed"
assert_contains "$n" "never answer" "worker must not answer its own finding"

# an unknown mode is a hard error, not a silent default
vizier_brief_delivery local-only >/dev/null 2>&1
assert_eq "$?" "2" "an out-of-scope mode is refused"

# --- assembly: exactly four layers, in order ------------------------------
b=$(vizier_brief_assemble platform direct-PR "Add a dark mode toggle to settings.")
assert_eq "$(printf '%s\n' "$b" | grep -c '^## ')" "4" "exactly four layers"
assert_eq "$(printf '%s\n' "$b" | grep '^## ' | tr '\n' '|')" \
  "## 1. Invariants|## 2. Project|## 3. Delivery|## 4. Task|" "layers in spec order"
assert_contains "$b" "Add a dark mode toggle" "the captain's task is layer 4"
assert_contains "$b" "make test" "the project layer is included"
assert_contains "$b" "Delivery contract: mode=direct-PR" "the delivery layer is included"

# the mode passed to assemble WINS over the project posture: the spec lets the
# captain override per task, and the override is what must reach the worker
b2=$(vizier_brief_assemble platform no-mistakes "Same task.")
assert_contains "$b2" "Delivery contract: mode=no-mistakes" "per-task override reaches the brief"
assert_eq "$(printf '%s\n' "$b2" | grep -c 'mode=direct-PR')" "0" "the project posture does not also appear"

vizier_test_teardown
vizier_test_report
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/brief-lib.test.sh`
Expected: FAIL — `lib/vizier-brief-lib.sh: No such file or directory`.

- [ ] **Step 3: Write the library**

Create `lib/vizier-brief-lib.sh`:

```bash
# shellcheck shell=bash
# Assembles the four brief layers into the --spec string for task-create.
# Requires lib/vizier-home.sh to be sourced first.
#
# THE WORKER HAS NEVER READ THE SPEC. Everything a worker must not do has to
# be said here, in words -- including naming the banned tools, because "use
# the canonical CLI" does not stop an agent that has never heard of gh-axi
# from installing it the moment it looks convenient.
#
# LAYER 3 IS PARSED LATER. lib/vizier-supervise-lib.sh decides whether to
# release a terminal by looking for the exact `axi_outcome:` line this layer
# mandates. Loosen the wording here and a worker can satisfy the brief while
# producing a body the supervisor cannot read. That fails closed -- no
# release, captain gets a report -- but it still stalls the request.

vizier_projects_dir() { printf '%s/projects' "$(vizier_home)"; }
vizier_project_path() { printf '%s/%s.md' "$(vizier_projects_dir)" "$1"; }

_vizier_project_frontmatter() {  # <project>
  f=$(vizier_project_path "$1")
  [ -r "$f" ] || return 1
  tr -d '\r' < "$f" | awk 'NR==1 && $0=="---" {inside=1; next} inside && $0=="---" {exit} inside'
}

vizier_project_field() {  # <project> <key>
  _vizier_project_frontmatter "$1" 2>/dev/null | sed -n "s/^$2: *//p" | head -n 1
}

vizier_project_mode() {  # <project> -- rc 1 when there is no knowledge file
  [ -r "$(vizier_project_path "$1")" ] || return 1
  m=$(vizier_project_field "$1" delivery)
  [ -n "$m" ] || return 1
  printf '%s' "$m"
}

vizier_brief_project() {  # <project> -- the body, frontmatter stripped
  f=$(vizier_project_path "$1")
  [ -r "$f" ] || return 1
  tr -d '\r' < "$f" | awk '
    NR==1 && $0=="---" { inside=1; next }
    inside && $0=="---" { inside=0; body=1; next }
    !inside { print }
  '
}

vizier_brief_invariant() {
  cat <<'EOF'
You are a crew agent working one task inside one Orca worktree.

- Report completion with exactly:
  `orca orchestration send --type worker_done --outcome succeeded|failed ...`
  A failure goes in `--outcome`, never only in prose. A body that describes a
  failure while `--outcome` says succeeded will be read as success.
- Stuck, blocked, or facing a decision that is not yours: run
  `orca orchestration ask` and wait. Never guess.
- Never self-merge. The captain merges every PR.
- Never leave the worktree you were assigned.
- Use the canonical CLI: `git` and `gh`. Do NOT install or use `gh-axi`,
  `tasks-axi`, `lavish-axi`, `chrome-devtools-axi`, or `quota-axi`, even if
  one looks more convenient, unless this project's section below names a
  different tool for that job.
- Never stop, restart, or update the `no-mistakes` daemon. One instance is
  shared across every worktree and every host, and restarting it kills
  someone else's running pipeline. A daemon error means: escalate, then stop.
EOF
}

vizier_brief_delivery() {  # <mode>
  case "$1" in
    direct-PR)
      cat <<'EOF'
Delivery contract: mode=direct-PR

- Implement the task, then push your own branch.
- Open the PR with `gh`. Never push the default branch. Never self-merge.
- Report done with the full `https://...` PR URL in the body and
  `--outcome succeeded`.
EOF
      ;;
    no-mistakes)
      cat <<'EOF'
Delivery contract: mode=no-mistakes

- Run `no-mistakes doctor` first. If this worktree's repo is not initialised
  yet, run `no-mistakes init`.
- Implement the task and commit. Then run
  `no-mistakes axi run --intent "<the captain's intent>"`.
- Keep driving every `axi run` / `axi respond` the pipeline asks for until it
  returns a terminal outcome.
- A finding that needs a human decision is NOT yours to answer: never answer
  your own finding. Call `orca orchestration ask` with the finding ID, the
  step, the choices, and your recommendation, then apply the single decision
  that comes back.
- Send `worker_done` only once axi has returned a terminal outcome, and put
  that outcome in the body as this exact line, on its own:
      axi_outcome: <passed|checks-passed|failed|cancelled>
  Include the PR URL in the body as well. Without that exact line your
  terminal will be held rather than released, because a pipeline run may
  still own the branch.
EOF
      ;;
    *)
      printf 'vizier_brief_delivery: unsupported mode: %s\n' "$1" >&2
      return 2
      ;;
  esac
}

vizier_brief_assemble() {  # <project> <mode> <task_text>
  d=$(vizier_brief_delivery "$2") || return 2
  printf '## 1. Invariants\n\n%s\n' "$(vizier_brief_invariant)"
  printf '\n## 2. Project\n\n%s\n' "$(vizier_brief_project "$1" 2>/dev/null || printf '(no project knowledge file yet)')"
  printf '\n## 3. Delivery\n\n%s\n' "$d"
  printf '\n## 4. Task\n\n%s\n' "$3"
}
```

- [ ] **Step 4: Document the project file format**

Create `docs/project-file-format.md`:

````markdown
# Project knowledge file

One file per project at `~/.vizier/projects/<name>.md`. The captain edits it
directly. The first mate proposes additions but writes them only once the
captain agrees.

```markdown
---
delivery: direct-PR
model_scout: claude-haiku-4-5-20251001
effort_scout: low
model_ship: claude-opus-5
effort_ship: high
---
How to build: `make build`
How to test: `make test`
PRs target `develop`, never `main`. Commits use Conventional Commits.
Known pitfall: the integration suite needs `docker compose up -d db` first.
```

`delivery` is the project's standard posture and the only required key. A
project with no file at all makes the first mate **ask the captain** for the
mode rather than assume one.

The `model_*` / `effort_*` hints are applied via `worker-start --model … --effort …`.
Orca accepts `--effort` only together with `--model`, and only for a new
terminal — never when reusing one via `--terminal`.

The body is copied verbatim into layer 2 of every brief for this project, so
write it as instructions to someone who has never seen the repo.
````

- [ ] **Step 5: Run the test**

Run: `bash tests/brief-lib.test.sh`
Expected: PASS.

- [ ] **Step 6: Run the whole suite**


Run: `bash tests/run-all.sh`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/vizier-brief-lib.sh docs/project-file-format.md tests/brief-lib.test.sh
git commit -m "feat: four-layer brief assembly"
```

---

### Task 5: `lib/vizier-supervise-lib.sh` — what to do with a mailbox batch

**Files:**
- Create: `lib/vizier-supervise-lib.sh`
- Test: `tests/supervise-lib.test.sh`

**Interfaces:**
- Consumes: `jq`, and the `axi_outcome:` line mandated by `vizier_brief_delivery no-mistakes` (Task 4).
- Produces:
  - `vizier_msg_disposition <mode> <json_line>` → prints `<release|hold|none> <reason>`
  - `vizier_supervise_plan <mode>` → reads a batch of JSON lines on stdin, prints `PLAN <delivery_id> <disposition> <reason>` per message, then — **only if every message produced a disposition** — one final `ACK <last_delivery_id>` line.
- Produces no side effects: it never calls `orca`. The `supervise` skill executes the plan.

**Why a plan and not an executor:** the spec's rule is "ack only after every message in the batch is processed". As prose in a skill that rule is forgettable. As a function that withholds the `ACK` line unless every message classified, it is enforced, and testable without a model.

**Disposition rules**, each mapping to one spec sentence:

| Condition | Result | Spec sentence |
|---|---|---|
| `type` is not `worker_done` | `none not-terminal` | never release on timeout, TUI idle, heartbeat, status, question, escalation |
| `worker_done` with no `dispatch_id` | `none stale-no-dispatch` | never release on a rejected or stale `worker_done` |
| `worker_done`, mode `no-mistakes`, no `axi_outcome:` line | `hold no-axi-outcome` | a run might still own the branch — do not release |
| `worker_done`, mode `no-mistakes`, non-terminal value | `hold axi-outcome=<x>` | same |
| `worker_done` otherwise, including `--outcome failed` | `release` | release runs for both a successful and a failed `worker_done` |

- [ ] **Step 1: Write the failing test**

Create `tests/supervise-lib.test.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-home.sh"
. "$VIZIER_TEST_REPO/lib/vizier-supervise-lib.sh"

d() { vizier_msg_disposition "$1" "$2"; }

# --- nothing but a processed worker_done ever releases --------------------
for t in heartbeat status question escalation timeout worker_progress; do
  got=$(d direct-PR "{\"delivery_id\":\"d\",\"type\":\"$t\",\"dispatch_id\":\"dispatch-1\"}")
  assert_eq "${got%% *}" "none" "$t never releases"
done

# --- direct-PR ------------------------------------------------------------
assert_eq "$(d direct-PR '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","outcome":"succeeded","body":"PR https://x/1"}')" \
  "release ok" "successful worker_done releases"
assert_eq "$(d direct-PR '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","outcome":"failed","body":"broke"}')" \
  "release ok" "a FAILED worker_done still releases -- the work is over either way"
assert_eq "$(d direct-PR '{"delivery_id":"d","type":"worker_done","outcome":"succeeded"}')" \
  "none stale-no-dispatch" "no dispatch id -> stale, never release"

# --- no-mistakes ----------------------------------------------------------
assert_eq "$(d no-mistakes '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","body":"axi_outcome: passed\nPR https://x/1"}')" \
  "release axi-outcome=passed" "terminal outcome releases"
for v in checks-passed failed cancelled; do
  assert_eq "$(d no-mistakes "{\"delivery_id\":\"d\",\"type\":\"worker_done\",\"dispatch_id\":\"dispatch-1\",\"body\":\"axi_outcome: $v\"}")" \
    "release axi-outcome=$v" "$v is terminal"
done
assert_eq "$(d no-mistakes '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","outcome":"succeeded","body":"all good, shipped it"}')" \
  "hold no-axi-outcome" "no outcome line -> HOLD, do not release"
assert_eq "$(d no-mistakes '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","body":"axi_outcome: running"}')" \
  "hold axi-outcome=running" "a non-terminal outcome -> hold"

# THE FALSE POSITIVE THE EXACT SYNTAX EXISTS TO PREVENT
assert_eq "$(d no-mistakes '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","body":"the tests have not passed yet"}')" \
  "hold no-axi-outcome" "prose containing the word passed must NOT read as an outcome"
assert_eq "$(d no-mistakes '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","body":"  axi_outcome:   passed  "}')" \
  "release axi-outcome=passed" "surrounding whitespace tolerated"
# a multi-line body must still be searched line-anchored, not as one blob
assert_eq "$(d no-mistakes '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","body":"summary line\naxi_outcome: passed\ntrailer"}')" \
  "release axi-outcome=passed" "the outcome line is found anywhere in the body"

# a direct-PR task is not subject to the axi rule at all
assert_eq "$(d direct-PR '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","body":"no axi here"}')" \
  "release ok" "direct-PR needs no axi outcome"

# --- the batch plan: ack comes last, and only if all were processed -------
batch='{"delivery_id":"d1","type":"heartbeat"}
{"delivery_id":"d2","type":"worker_done","dispatch_id":"dispatch-1","outcome":"succeeded"}
{"delivery_id":"d3","type":"question","body":"which option?"}'
plan=$(printf '%s\n' "$batch" | vizier_supervise_plan direct-PR)
assert_eq "$(printf '%s\n' "$plan" | grep -c '^PLAN ')" "3" "one plan line per message"
assert_eq "$(printf '%s\n' "$plan" | tail -1)" "ACK d3" "ack is last and names the last delivery"
assert_eq "$(printf '%s\n' "$plan" | grep -n '^ACK ' | cut -d: -f1)" "4" "ack never precedes a plan line"
assert_contains "$plan" "PLAN d2 release ok" "the worker_done in the middle is planned"

# a message that cannot be parsed must block the ACK for the WHOLE batch
bad='{"delivery_id":"d1","type":"worker_done","dispatch_id":"dispatch-1"}
this is not json'
plan=$(printf '%s\n' "$bad" | vizier_supervise_plan direct-PR)
assert_eq "$(printf '%s\n' "$plan" | grep -c '^ACK ')" "0" "one unparseable message withholds the batch ack"
assert_contains "$plan" "UNPARSEABLE" "and says so"

# an empty batch acks nothing
assert_eq "$(printf '' | vizier_supervise_plan direct-PR | wc -l | tr -d ' ')" "0" "empty batch, empty plan"

vizier_test_teardown
vizier_test_report
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/supervise-lib.test.sh`
Expected: FAIL — library missing.

- [ ] **Step 3: Write the library**

Create `lib/vizier-supervise-lib.sh`:

```bash
# shellcheck shell=bash
# Decides what a mailbox batch means. Pure: never calls orca, never releases
# anything. The `supervise` skill executes what this plans.
#
# WHY A PLAN AND NOT AN EXECUTOR. The spec's rule is "ack only after every
# message in the batch is processed". Acking early loses messages
# permanently -- replay-until-ack is the only reason a hook that dies
# mid-flight is safe. As prose in a skill that rule is forgettable; here the
# ACK line simply is not printed unless every message was classified, so the
# rule holds even when the model is in a hurry.
#
# EVERY UNCERTAIN CASE FAILS CLOSED. `none` and `hold` cost the captain a
# report and a manual release. Releasing a terminal whose pipeline still owns
# the branch costs the branch.

_vizier_axi_outcome() {  # <body> -- prints the value of the axi_outcome line
  # Anchored to a line that STARTS with the exact key (after optional
  # whitespace). Free-text matching is not acceptable: a body reading "the
  # tests have not passed" contains the token `passed`, and releasing on that
  # would defeat the whole rule. The brief mandates this exact syntax -- see
  # vizier_brief_delivery no-mistakes -- so requiring it is not a guess.
  printf '%s\n' "$1" \
    | sed -n 's/^[[:space:]]*axi_outcome:[[:space:]]*\([A-Za-z-][A-Za-z-]*\).*/\1/p' \
    | head -n 1
}

vizier_msg_disposition() {  # <mode> <json_line> -- "<release|hold|none> <reason>"
  # Three separate jq reads rather than one @tsv row: a body legitimately
  # contains newlines (the axi_outcome line is on its own line), and @tsv
  # would escape them into the middle of a single field.
  type=$(printf '%s' "$2" | jq -r '.type // ""' 2>/dev/null)
  dispatch=$(printf '%s' "$2" | jq -r '.dispatch_id // ""' 2>/dev/null)
  body=$(printf '%s' "$2" | jq -r '.body // ""' 2>/dev/null)

  [ -n "$type" ] || { printf 'none unparseable'; return 0; }
  [ "$type" = "worker_done" ] || { printf 'none not-terminal'; return 0; }
  [ -n "$dispatch" ] || { printf 'none stale-no-dispatch'; return 0; }

  if [ "$1" = "no-mistakes" ]; then
    out=$(_vizier_axi_outcome "$body")
    case "$out" in
      passed|checks-passed|failed|cancelled) printf 'release axi-outcome=%s' "$out" ;;
      "")                                    printf 'hold no-axi-outcome' ;;
      *)                                     printf 'hold axi-outcome=%s' "$out" ;;
    esac
    return 0
  fi

  printf 'release ok'
}

vizier_supervise_plan() {  # <mode> -- batch JSON lines on stdin
  mode=$1
  plan=""
  last=""
  bad=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id=$(printf '%s' "$line" | jq -r '.delivery_id // empty' 2>/dev/null)
    if [ -z "$id" ]; then
      plan="${plan}UNPARSEABLE
"
      bad=1
      continue
    fi
    plan="${plan}PLAN $id $(vizier_msg_disposition "$mode" "$line")
"
    last=$id
  done
  printf '%s' "$plan"
  # No ACK when anything in the batch failed to classify. Orca replays an
  # unacked batch, so withholding the ack loses nothing and re-delivers
  # everything; acking a batch we did not fully understand loses a message
  # for good.
  if [ "$bad" -eq 0 ] && [ -n "$last" ]; then
    printf 'ACK %s\n' "$last"
  fi
  return 0
}
```

- [ ] **Step 4: Run the test**

Run: `bash tests/supervise-lib.test.sh`
Expected: PASS.

- [ ] **Step 5: Run the whole suite**


Run: `bash tests/run-all.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/vizier-supervise-lib.sh tests/supervise-lib.test.sh
git commit -m "feat: mailbox batch disposition rules"
```

---

### Task 6: `skills/request/SKILL.md` — open and close a Request

**Files:**
- Create: `skills/request/SKILL.md`
- Test: `tests/skills.test.sh` (create; Tasks 7–9 add to it)

**Interfaces:**
- Consumes: `lib/vizier-request-lib.sh`, `lib/vizier-routing-lib.sh`.
- Produces: the request file every other skill reads, and the `host` value every `worker-start` in the request inherits.

**Note on shipping:** `_sync_dist` in `bin/vizier` copies the whole `skills/`, `lib/`, `hooks/`, `commands/`, `bin/`, `.claude-plugin/` directories. A new skill or library needs **no manifest edit** — it ships as soon as it exists in the repo. Task 10 proves that rather than assuming it.

- [ ] **Step 1: Write the failing test**

Create `tests/skills.test.sh`:

```bash
#!/usr/bin/env bash
# Skills are prompts, so what is testable is that the exact strings a skill
# MUST contain are present: the commands it tells the model to run, and the
# refusals it must not soften. A skill that quietly loses its hard rule is
# the failure mode this file exists to catch.
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
R="$VIZIER_TEST_REPO"

has() {  # <file> <needle> <label>
  assert_contains "$(cat "$R/$1" 2>/dev/null)" "$2" "$3"
}

# --- request --------------------------------------------------------------
f=skills/request/SKILL.md
assert_eq "$(test -f "$R/$f" && echo yes)" "yes" "request skill exists"
assert_eq "$(head -1 "$R/$f")" "---" "frontmatter present"
has $f "name: request" "skill is named"
has $f "orca orchestration run-create --objective" "the exact run-create call"
has $f "vizier_routing_table" "routing comes from the library"
has $f "exactly once" "the host is asked exactly once"
has $f "never silently" "no silent host substitution"
has $f "orca project setup-clone" "setup-clone is proposed, not run"
has $f "vizier_request_create" "the request file is written through the library"
has $f "vizier_request_close" "closing goes through the library"
has $f "worker-release" "closing releases remaining dispatches"

vizier_test_teardown
vizier_test_report
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/skills.test.sh`
Expected: FAIL — `request skill exists` got empty.

- [ ] **Step 3: Write the skill**

Create `skills/request/SKILL.md`:

```markdown
---
name: request
description: Open or close a Request. Use when the captain states a new request, or says a request is done.
---

# Request lifecycle

**One captain request = one Request = one Orca Run.** Not one feature — "fix
the flaky test then add dark mode" is *one* request with two tasks.

Source the libraries first:

```bash
. "$VIZIER_DIST/lib/vizier-home.sh"
. "$VIZIER_DIST/lib/vizier-request-lib.sh"
. "$VIZIER_DIST/lib/vizier-routing-lib.sh"
```

## Opening

### 1. Identify the project

The working directory is a **suggestion, never authority**. Read
`git remote get-url origin` if there is one, propose the project, and wait for
the captain to confirm. Record both names: the short one (`platform`, which
names `projects/platform.md`) and Orca's (`github:owner/repo`).

### 2. Route

```bash
vizier_routing_table "<project_id>"
```

Each row is `name<TAB>health<TAB>setup<TAB>eligible`. Add the running-worker
count per host from `orca worktree ps --json`. Present every host with its
reason, not only the eligible ones — a captain who cannot see why the Mac mini
is missing will ask.

### 3. Ask the captain to choose — **exactly once**

This is the request's only mandatory question. Every task in this request
inherits the answer: retries, review fixes, spawned work. Never ask again.

- The captain picks a host with no `ready` setup → propose
  `orca project setup-clone` and run it **only after they agree**.
- No host is eligible → say so and stop. Do not fall back to local.
- **Never silently move work to another host.** Not at open, not later.

### 4. Create the Run and the file

```bash
run=$(orca orchestration run-create --objective "<the captain's request>" --json | jq -r '.result.run.id')
slug=$(vizier_request_slug "<short title>")
vizier_request_create "$slug" "$run" "<project>" "<project_id>" "<host>" "<the captain's words, verbatim>"
```

Quote the captain verbatim in the body. Later tasks are briefed from it, and a
paraphrase drifts.

## Closing

Only when **the captain says** the request is complete.

1. List the request's dispatches that are still holding a terminal:
   `orca orchestration worker-list --run <run_id> --json`.
2. For each: `orca orchestration worker-release --dispatch <id> --json`.
   A receipt saying `release_pending` or `release_unknown` → do exactly what
   the receipt says. **Substituting `terminal close` is forbidden.**
3. `vizier_request_close "$slug"`.

Host pinning ends here. The next request routes from scratch.

## Hard rules

- The host is asked **exactly once** per request, and never re-asked.
- A pinned host that dies mid-flight → **stop and report**. Changing a
  request's host is the captain's decision, not yours.
- Never close a request the captain has not called complete.
```

- [ ] **Step 4: Run the test**

Run: `bash tests/skills.test.sh`
Expected: PASS.

- [ ] **Step 5: Run the whole suite**


Run: `bash tests/run-all.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add skills/request/SKILL.md tests/skills.test.sh
git commit -m "feat: request lifecycle skill"
```

---

### Task 7: `skills/brief/SKILL.md` — brief and dispatch a task

**Files:**
- Create: `skills/brief/SKILL.md`
- Modify: `tests/skills.test.sh`

**Interfaces:**
- Consumes: `vizier_brief_assemble`, `vizier_project_mode` (Task 4); the request file's `host` and `project` (Task 2).
- Produces: a `task_id` and a `dispatch_id` recorded in the request file.

- [ ] **Step 1: Add the failing assertions**

Insert into `tests/skills.test.sh`, before `vizier_test_teardown`:

```bash
# --- brief ----------------------------------------------------------------
f=skills/brief/SKILL.md
assert_eq "$(test -f "$R/$f" && echo yes)" "yes" "brief skill exists"
has $f "vizier_brief_assemble" "the spec comes from the library, never hand-written"
has $f "orca orchestration task-create --spec" "exact task-create"
has $f "orca orchestration worker-start --task" "exact worker-start"
has $f "--worktree new-top-level" "isolation default"
has $f "--setup run" "setup runs"
has $f "--on" "the host is passed through"
has $f "inherits the request's host" "host inheritance is stated"
has $f "ask the captain" "an unknown delivery mode is asked, never guessed"
has $f "--effort" "model hints are applied"
has $f "requires --model" "effort depends on model"
has $f "--retry-of" "retries chain"
has $f "never retry blind" "receipts are read"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/skills.test.sh`
Expected: FAIL — `brief skill exists` got empty.

- [ ] **Step 3: Write the skill**

Create `skills/brief/SKILL.md`:

```markdown
---
name: brief
description: Turn one task from an open Request into a briefed, dispatched worker. Use for every task, including retries and review fixes.
---

# Brief and dispatch

```bash
. "$VIZIER_DIST/lib/vizier-home.sh"
. "$VIZIER_DIST/lib/vizier-request-lib.sh"
. "$VIZIER_DIST/lib/vizier-brief-lib.sh"
```

## 1. Settle the delivery mode — before writing anything

```bash
mode=$(vizier_project_mode "<project>") || mode=""
```

- Empty → the project has no knowledge file. **Ask the captain** which mode.
  Never guess, and never default to `direct-PR` just because it is the default
  posture elsewhere.
- The captain named a different mode for *this* task → theirs wins, and you
  write a one-line reason into the request file:
  `vizier_request_note "$slug" "task N: mode=<mode> because <reason>"`.

Mode is locked in **per task, at creation time**. It never changes mid-task.

## 2. Assemble the brief

```bash
spec=$(vizier_brief_assemble "<project>" "$mode" "<the concrete task and its definition of done>")
```

Never hand-write a spec. The four layers exist so that layer 1 (the
invariants) cannot be forgotten, and a hand-written spec forgets it first.

## 3. Create the task

```bash
task=$(orca orchestration task-create --spec "$spec" --task-title "<short title>" --run "$run_id" --json | jq -r '.result.task.id')
```

## 4. Start the worker

The host **inherits the request's host** — read it from the request file, never
re-ask, never substitute:

```bash
host=$(vizier_request_get "$slug" host)
```

Local host → omit `--on` entirely. Any other host → `--on "$host"` with the
host's *name*.

```bash
orca orchestration worker-start \
  --task "$task" --run "$run_id" \
  --agent claude --worktree new-top-level --setup run \
  --name "<short-name>" \
  ${host:+--on "$host"} \
  --json
```

Model hints from the project file (`model_scout`, `effort_scout`, …) are applied
as `--model <id> --effort <level>`. Orca **requires `--model` whenever
`--effort` is given**, and accepts neither when reusing a terminal via
`--terminal`.

Record the dispatch in the request file:
`vizier_request_note "$slug" "task <id> -> dispatch <id> (<mode>)"`.

## 5. When worker-start fails

The receipt is the instruction. It carries `stage`/`failedStage`, `setup`,
`effects`, `residualResources`, and a recovery command.

**Read the receipt, do exactly the recovery it names, never retry blind.** On a
retry use `--retry-of <dispatch_id>` to chain the history — and repeat the
placement flags, because a retry does not inherit them. Leftover resources are
reported to the captain.

A wait-for-setup timeout that leaves setup `running` is **normal**, not
evidence of failure. Check again before concluding anything.
```

- [ ] **Step 4: Run the test**

Run: `bash tests/skills.test.sh`
Expected: PASS.

- [ ] **Step 5: Run the suite and commit**

```bash
bash
git add skills/brief/SKILL.md tests/skills.test.sh
git commit -m "feat: brief and dispatch skill"
```

---

### Task 8: `skills/supervise/SKILL.md` — process a woken batch

**Files:**
- Create: `skills/supervise/SKILL.md`
- Modify: `tests/skills.test.sh`

**Interfaces:**
- Consumes: `vizier_supervise_plan` (Task 5); the wake hook from Plan 1, which is what causes this skill to run.
- Produces: released or held terminals, one consolidated report to the captain.

- [ ] **Step 1: Add the failing assertions**

```bash
# --- supervise ------------------------------------------------------------
f=skills/supervise/SKILL.md
assert_eq "$(test -f "$R/$f" && echo yes)" "yes" "supervise skill exists"
has $f "vizier_supervise_plan" "dispositions come from the library"
has $f "orca orchestration check" "the mailbox is read with check"
has $f "--ack" "ack exists"
has $f "only after" "ack comes only after processing"
has $f "agent_terminal_handle" "terminal transfer reads the handle"
has $f "--terminal" "transfer reuses the terminal"
has $f "worker-release --dispatch" "release is by dispatch"
has $f "release_pending" "pending release receipts are handled"
has $f "terminal close" "the forbidden substitution is named"
has $f "one" "the captain gets one consolidated report"
has $f "delivery" "questions route through the delivery policy"
has $f "worker-read" "a quiet worker is diagnosed, not guessed at"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/skills.test.sh`
Expected: FAIL.

- [ ] **Step 3: Write the skill**

Create `skills/supervise/SKILL.md`:

```markdown
---
name: supervise
description: Process the mailbox after the wake hook fires. Use whenever a wake message says a Run has traffic.
---

# Supervise

The wake hook has already told you a Run has traffic. It **never acks** —
acking is yours, and only after processing.

```bash
. "$VIZIER_DIST/lib/vizier-home.sh"
. "$VIZIER_DIST/lib/vizier-request-lib.sh"
. "$VIZIER_DIST/lib/vizier-supervise-lib.sh"
```

## 1. Read the batch

```bash
batch=$(orca orchestration check --run "$run_id" --peek --json)
```

## 2. Plan every message before acting on any

```bash
printf '%s\n' "$batch" | vizier_supervise_plan "<the task's delivery mode>"
```

Each `PLAN <delivery_id> <disposition> <reason>` line is a decision:

- **`release`** — the work is over. A *failed* `worker_done` releases too.
- **`hold`** — a `no-mistakes` task whose body has no terminal
  `axi_outcome:` line. **Do not release.** A pipeline run may still own the
  branch. `orca orchestration worker-read --dispatch <id>` to diagnose, then
  report to the captain.
- **`none`** — not a terminal event. Never release on a timeout, TUI idle,
  heartbeat, status, question, escalation, or a stale `worker_done`.

If the plan prints no `ACK` line, something in the batch did not classify.
**Do not ack anything.** Orca replays an unacked batch, so nothing is lost;
acking now would lose a message permanently.

## 3. Act on each `release`

Decide where the terminal goes **before** acking.

A follow-on task exists for the same agent → transfer, don't release:

```bash
handle=$(orca orchestration worker-show --dispatch "<id>" --json | jq -r '.result.worker.agent_terminal_handle')
orca orchestration worker-start --task "<next_task>" --terminal "$handle" --run "$run_id" --json
```

Otherwise release:

```bash
orca orchestration worker-release --dispatch "<id>" --json
```

A receipt of `release_pending` or `release_unknown` → follow the receipt's own
recovery action. **Substituting `terminal close` is forbidden.** Repeating
`worker-release` after a replayed delivery is safe.

The captain asked to keep a terminal (`worker-retain`) → keep it.

## 4. Ack last

```bash
orca orchestration check --run "$run_id" --ack "<the ACK id from the plan>" --json
```

## 5. Report once

**One** consolidated message, containing only what is worth saying: outcomes,
PR URLs, and decisions the captain must make.

- `escalation` / `question` → turn into a question with full context. The
  captain's answer goes back with `orca orchestration reply --id <msg> --body`.
- A `question` carrying a **no-mistakes ask-user finding** does not go straight
  to the captain: run it through the `delivery` skill's policy first.
- A worker gone unusually quiet → `orca orchestration worker-read --dispatch <id>`
  to diagnose. Report what you found; do not guess.
```

- [ ] **Step 4: Run the test, then the suite, then commit**

```bash
bash tests/skills.test.sh
bash
git add skills/supervise/SKILL.md tests/skills.test.sh
git commit -m "feat: supervision skill"
```

---

### Task 9: `skills/delivery/SKILL.md` — the ask-user finding policy

**Files:**
- Create: `skills/delivery/SKILL.md`
- Modify: `tests/skills.test.sh`

**Interfaces:**
- Consumes: a `question` message routed here by `supervise` (Task 8).
- Produces: one `orca orchestration reply` carrying exactly one decision, or an escalation to the captain.

- [ ] **Step 1: Add the failing assertions**

```bash
# --- delivery -------------------------------------------------------------
f=skills/delivery/SKILL.md
assert_eq "$(test -f "$R/$f" && echo yes)" "yes" "delivery skill exists"
has $f "never call" "the first mate never drives a worker's run"
has $f "axi respond" "the command it must not run is named"
has $f "one precise decision" "the reply is a single decision"
has $f "expand the contract" "the escalation test is stated"
has $f "not authority" "a reviewer label is evidence, not authority"
has $f "security" "security-sensitive findings escalate"
has $f "orca orchestration reply --id" "the exact reply command"
has $f "smallest option" "escalations offer the smallest non-expanding option"
has $f "daemon" "the shared-daemon rule is restated"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/skills.test.sh`
Expected: FAIL.

- [ ] **Step 3: Write the skill**

Create `skills/delivery/SKILL.md`:

```markdown
---
name: delivery
description: Decide a no-mistakes ask-user finding. Use when supervise routes a question carrying a pipeline finding.
---

# Delivery decisions

A `no-mistakes` pipeline stopped at a finding that needs a human. The worker
did the right thing by asking instead of answering.

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
```

- [ ] **Step 4: Run the test, then the suite, then commit**

```bash
bash tests/skills.test.sh
bash
git add skills/delivery/SKILL.md tests/skills.test.sh
git commit -m "feat: delivery decision skill"
```

---

### Task 10: wire the skills into `identity`, and prove they ship

**Files:**
- Modify: `skills/identity/SKILL.md`
- Modify: `tests/cli.test.sh`

**Interfaces:**
- Consumes: `_sync_dist` in `bin/vizier`, which copies `lib hooks skills commands bin .claude-plugin` wholesale.
- Produces: an identity file that names the four skills, and a test proving a new skill actually reaches `dist` without a manifest edit.

**Why prove it:** the claim "new skills ship automatically" is read off `_sync_dist`'s directory list. That is strong evidence but not a test, and a future change to `_sync_dist` that switched to an explicit file list would break shipping silently — `install` would still succeed, and the skill would simply never appear.

- [ ] **Step 1: Write the failing test**

Add to `tests/cli.test.sh`, after the existing install assertions:

```bash
# A skill added to the repo must reach dist with no manifest edit. If
# _sync_dist ever switches to an explicit file list, install still succeeds
# and the skill silently never appears -- so assert the payload, not the
# exit code.
for s in request brief supervise delivery identity; do
  assert_eq "$(test -f "$VIZIER_HOME/dist/skills/$s/SKILL.md" && echo yes)" "yes" \
    "skill $s reached dist"
done
for l in vizier-home vizier-request-lib vizier-routing-lib vizier-brief-lib vizier-supervise-lib; do
  assert_eq "$(test -f "$VIZIER_HOME/dist/lib/$l.sh" && echo yes)" "yes" \
    "library $l reached dist"
done
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/cli.test.sh`
Expected: FAIL for the four new skills (the libraries pass, since Tasks 2–5 already created them).

- [ ] **Step 3: Point identity at the new skills**

In `skills/identity/SKILL.md`, replace the `## State` section's file list with a section naming the skills. Add, after `## Division of roles`:

```markdown
## Your skills

- **request** — the captain states a new request, or says one is done.
- **brief** — every task you dispatch, including retries and review fixes.
- **supervise** — the wake hook says a Run has traffic.
- **delivery** — a question carries a `no-mistakes` ask-user finding.

Load the skill when its moment arrives. Do not re-derive a rule a skill owns;
they exist so the rules survive a compaction that this file alone would not
carry.
```

Do **not** copy the rules themselves into `identity`. It is re-read on every
compaction, so it stays short on purpose.

- [ ] **Step 4: Run the test, then the suite**

Run: `bash tests/cli.test.sh` then `bash tests/run-all.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/identity/SKILL.md tests/cli.test.sh
git commit -m "feat: identity names the four coordination skills"
```

---

### Task 11: `tests/loop.test.sh` — the whole loop against fake-orca

**Files:**
- Create: `tests/loop.test.sh`

**Interfaces:**
- Consumes: every library from Tasks 2–5 and the fake-orca surface from Task 1.
- Produces: the regression that catches an integration break no single library test would.

**Why this exists separately:** each library is correct in isolation. What no unit test covers is the *order* — that the request file is written before a worker starts, that the host recorded at open is the host passed at dispatch, and that a `hold` really does leave the terminal unreleased all the way through.

- [ ] **Step 1: Write the test**

Create `tests/loop.test.sh`:

```bash
#!/usr/bin/env bash
# The whole coordination loop, end to end, with no app and no model:
# open -> route -> brief -> dispatch -> worker_done -> plan -> release -> close.
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-home.sh"
. "$VIZIER_TEST_REPO/lib/vizier-wake-lib.sh"
. "$VIZIER_TEST_REPO/lib/vizier-request-lib.sh"
. "$VIZIER_TEST_REPO/lib/vizier-routing-lib.sh"
. "$VIZIER_TEST_REPO/lib/vizier-brief-lib.sh"
. "$VIZIER_TEST_REPO/lib/vizier-supervise-lib.sh"

mkdir -p "$VIZIER_HOME/projects"
printf -- '---\ndelivery: direct-PR\n---\nTest with `make test`.\n' > "$VIZIER_HOME/projects/platform.md"

fake_orca_seed_host local "this machine" local
fake_orca_seed_host 0559ea68 "Mac mini" environment
fake_orca_set_status ""         ready true
fake_orca_set_status "Mac mini" ready true
fake_orca_seed_setup "github:acme/platform" local ready
fake_orca_seed_setup "github:acme/platform" 0559ea68 ready

# --- open -----------------------------------------------------------------
t=$(vizier_routing_table github:acme/platform)
assert_eq "$(printf '%s\n' "$t" | awk -F'\t' '$4=="yes"' | wc -l | tr -d ' ')" "2" "both hosts eligible"

run=$(orca orchestration run-create --objective "Add dark mode" --json | jq -r '.result.run.id')
slug=$(vizier_request_slug "Add dark mode")
# the captain picked the remote host
vizier_request_create "$slug" "$run" platform github:acme/platform "Mac mini" "Add dark mode"
assert_eq "$(vizier_open_run_ids)" "$run" "the hook would now wait on this Run"

# --- brief and dispatch ---------------------------------------------------
mode=$(vizier_project_mode platform)
assert_eq "$mode" "direct-PR" "mode from the project posture"
spec=$(vizier_brief_assemble platform "$mode" "Add a toggle in settings.")
task=$(orca orchestration task-create --spec "$spec" --run "$run" --json | jq -r '.result.task.id')
host=$(vizier_request_get "$slug" host)
dispatch=$(orca orchestration worker-start --task "$task" --run "$run" \
  --agent claude --worktree new-top-level --setup run --on "$host" --json \
  | jq -r '.result.dispatch.id')

# the host chosen at OPEN is the host used at DISPATCH -- the single rule that
# no unit test can check, because it spans two libraries and a file
assert_contains "$(fake_orca_calls)" "--on Mac mini" "dispatch inherited the request's host"
# and the brief that reached Orca really had all four layers
assert_eq "$(grep -c '^## ' "$VIZIER_FAKE_ORCA_STATE/spec.$task")" "4" "the stored spec has four layers"
assert_contains "$(cat "$VIZIER_FAKE_ORCA_STATE/spec.$task")" "gh-axi" "invariants reached the worker"

# --- worker reports done --------------------------------------------------
fake_orca_queue "$run" "{\"delivery_id\":\"d1\",\"type\":\"worker_done\",\"dispatch_id\":\"$dispatch\",\"outcome\":\"succeeded\",\"body\":\"PR https://x/1\"}"
plan=$(orca orchestration check --run "$run" --peek --json | vizier_supervise_plan "$mode")
assert_contains "$plan" "PLAN d1 release ok" "a successful worker_done plans a release"
assert_eq "$(printf '%s\n' "$plan" | tail -1)" "ACK d1" "and the batch is ackable"

orca orchestration worker-release --dispatch "$dispatch" --json >/dev/null
orca orchestration check --run "$run" --ack d1 --json >/dev/null
assert_eq "$(orca orchestration check --run "$run" --peek --json | wc -l | tr -d ' ')" "0" "mailbox drained"

# --- close ----------------------------------------------------------------
vizier_request_close "$slug"
assert_eq "$(vizier_open_run_ids)" "" "the hook stops waiting once the request closes"

# --- the no-mistakes variant HOLDS instead of releasing -------------------
run2=$(orca orchestration run-create --objective "Ship it" --json | jq -r '.result.run.id')
vizier_request_create shipit "$run2" platform github:acme/platform local "Ship it"
fake_orca_queue "$run2" '{"delivery_id":"e1","type":"worker_done","dispatch_id":"dispatch-9","outcome":"succeeded","body":"all done"}'
plan=$(orca orchestration check --run "$run2" --peek --json | vizier_supervise_plan no-mistakes)
assert_contains "$plan" "PLAN e1 hold no-axi-outcome" "no axi outcome -> hold"
# holding still acks: the message WAS processed, the terminal just stays put
assert_eq "$(printf '%s\n' "$plan" | tail -1)" "ACK e1" "a held message is still a processed message"
# and nothing was released
assert_eq "$(fake_orca_calls | grep -c 'worker-release --dispatch dispatch-9')" "0" "a held terminal is never released"

vizier_test_teardown
vizier_test_report
```

- [ ] **Step 2: Run it**

Run: `bash tests/loop.test.sh`
Expected: PASS. If the `--on Mac mini` assertion fails, the host is being
re-derived somewhere instead of read from the request file — fix that, not the
assertion.

- [ ] **Step 3: Run the whole suite**


Run: `bash tests/run-all.sh` — five times in a row.
Expected: PASS every time, identical assertion count. A varying count means a
test depends on timing or on state left by a previous file.

- [ ] **Step 4: Commit**

```bash
git add tests/loop.test.sh
git commit -m "test: the coordination loop end to end"
```

---

### Task 12: real smoke with real Orca

**Files:**
- Create: `docs/verification/2026-09-01-smoke-orchestration.md`

**This task changes real state on the captain's machine and creates a real PR.**
Per the subagent-driven-development rules that is a stop-and-ask: **get the
captain's agreement before step 2**, and tell them what will be created.

- [ ] **Step 1: Confirm the environment**

```bash
orca status --json | jq -r '.result.runtime | "\(.state) reachable=\(.reachable) v\(.appVersion)"'
vizier version
vizier doctor
```

Record the `appVersion`. Orca has no protocol version marker, so the version
stamp plus the capability list is the compatibility evidence.

- [ ] **Step 2: Open a real request with one echo task**

Pick a throwaway repo — **never** a repo with work in it. One task whose whole
job is to create a file with one line and open a PR.

Walk the real skills, not a script: `request` → `brief` → wait for the hook →
`supervise` → close. The point is to exercise the path a captain uses.

- [ ] **Step 3: Record what actually happened**

Create `docs/verification/2026-09-01-smoke-orchestration.md` with, for each
stage, the command run and the real response — not a summary:

- `run-create` response and the request file that was written
- the routing table as presented to the captain, and which host was chosen
- the full `--spec` that reached `task-create` (all four layers)
- the `worker-start` receipt
- the wake hook firing: the stderr line, and the delay between `worker_done`
  and the session waking
- the `check` batch, the plan, the release receipt
- the PR URL, and confirmation that **the captain merged it**, not the crew

- [ ] **Step 4: Repeat once with `--on` a remote host**

Only if a second host is eligible. Record the same evidence. This is the
variant the spec names, and it is the one that catches a host name being
passed where an id belongs.

- [ ] **Step 5: Commit**

```bash
git add docs/verification/2026-09-01-smoke-orchestration.md
git commit -m "docs: real orchestration smoke"
```

---

## Self-review

Run against the spec after the plan was written.

**Spec coverage.** Every section of the spec from "The Request concept" onward
maps to a task:

| Spec section | Task |
|---|---|
| The Request concept | 2, 6 |
| Host routing | 3, 6 |
| Supervision — waking itself on events | 5, 8 (the hook itself shipped in Plan 1) |
| Automatic briefs | 4, 7 |
| Delivery mode and no-mistakes | 4, 7, 9 |
| Ask-user findings go through Orca's mailbox | 9 |
| Release safety | 5, 8 |
| Merge authority | 4 (invariant layer), 12 (smoke confirms the captain merged) |
| External dependencies | 4 (the invariant layer names the banned wrappers) |
| Error handling | 6 (release receipts), 7 (worker-start receipts), 8 (release receipts) |
| Testing — fake-orca cases | 1, 3, 5, 11 |
| Testing — real smoke | 12 |

**Gaps deliberately left.** Two spec items have no task:

1. **The project file "thickens on its own"** — a worker hits a pitfall, the
   first mate proposes a line, the captain nods, the line is added. The
   mechanism is a proposal in chat plus `vizier_request_note`'s sibling for
   project files, and it is one sentence of skill text rather than a task. It
   is folded into the `supervise` skill's reporting step. Flagging it here
   because a reviewer looking for a task will not find one.
2. **Cursor** — every skill in this plan is Markdown that Cursor can read, but
   Cursor still has no activation path (`bin/vizier-activate.sh` reads
   `CLAUDE_CODE_SESSION_ID`, and Cursor sees `skills/` but not `commands/`).
   That is recorded in `docs/verification/2026-09-01-smoke-install.md` and
   belongs to its own plan, not this one. **The libraries in this plan are
   harness-agnostic**, so that later plan needs no change here.

**Placeholder scan.** No "TBD", no "add error handling", no "similar to Task N".
Every code step carries the code. Task 12 deliberately does not script the
smoke: it is a manual walk of the real skills, and scripting it would test the
script instead of the path a captain uses.

**Type consistency.** Checked across tasks: `vizier_request_get`/`_set`/`_close`
(Task 2) are used with those exact names in Tasks 6, 7, 11.
`vizier_routing_table` (Task 3) in 6 and 11. `vizier_brief_assemble`,
`vizier_project_mode` (Task 4) in 7 and 11. `vizier_supervise_plan`,
`vizier_msg_disposition` (Task 5) in 8 and 11. The `axi_outcome:` line is
written by Task 4's brief and read by Task 5's `sed` — the one cross-task
coupling that is not a function signature, and it is called out in the header
comment of both files.
