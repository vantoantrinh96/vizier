# vizier -- Plan 1: Install and activation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install vizier with one command into Claude Code and Cursor, so that typing `/vizier` in any directory turns that session into a first mate, and a message in Orca's mailbox can wake an idle session.

**Architecture:** One repo carrying a shared payload (skill, command) plus two harness adapters. The payload installs into `~/.vizier/dist/`; state runs at `~/.vizier/` and never depends on cwd. A single `lock` file both elects the one first mate and serves as the hook's gate -- because the hook runs after every turn of **every** harness session on the machine. The Claude adapter is a plugin in its own directory; the Cursor adapter is forced to merge into the shared `~/.cursor/hooks.json`.

**Tech Stack:** bash (`set -u`, POSIX-ish), `jq` for JSON, the `orca` CLI, Claude Code plugin hooks, Cursor user-level hooks. Tested with bash + a `fake-orca` on PATH; Cursor's wake path is tested with a Python pty driver.

**Spec:** `docs/superpowers/specs/2026-08-30-vizier-design.md`
**Measured evidence:** `docs/verification/2026-08-31-plugin-wake.md` -- every hook-behavior constant below is taken from this file, not from memory.

## Global Constraints

- **Platform: macOS only.** Orca only runs on macOS; do not write a Linux/Windows branch.
- **No external runtime dependency besides:** the `orca` CLI, `jq`, `git`, `gh`. `jq` is required because both hooks parse a JSON payload on stdin -- the spec already added it to the dependency table. Absolutely no `*-axi` npm family (`gh-axi`, `tasks-axi`, `quota-axi`, `chrome-devtools-axi`, `lavish-axi`) -- the captain refuses third-party wrappers when a canonical CLI exists.
- **The CLI exists only at install time and diagnostic time.** No runtime path may call `vizier`. The hook and skill talk straight to `orca`.
- **Every hook exits 0 on every uncertain branch.** The hook runs in every harness session on the captain's machine; a broken hook is a machine-wide bug.
- **Claude Stop hook:** `"asyncRewake": true`, `"timeout": 28800`. Wakes via `exit 2`, content goes to **stderr**.
- **Cursor stop hook:** `exit 2` is a **silent no-op**. The only channel is exactly one `{"followup_message": "..."}` object on **stdout** with `exit 0`. Registers `"loop_limit": 200`; our self-imposed ceiling is `VIZIER_CURSOR_LOOP_CEILING=5`, lower so our bound bites first.
- **`~/.cursor/hooks.json` is a shared file** -- Orca already has 8 entries in it. Only add/remove exactly our own entry, identified by the string `wake-cursor.sh` in `command`. Always back up before writing.
- **Orca commands always pass `--run <run_id>` explicitly.** Never rely on a terminal-bound Run: a first-mate session is not an Orca terminal.
- **`VIZIER_HOME` overrides home** for tests. Production defaults to `$HOME/.vizier`.
- **Never gate Cursor compatibility on `cursor-agent --version`** -- the TUI reports `2026.08.25-3e8eec8` while `--version` reports `2026.08.11-e8db854`.

## File structure

| File | Responsibility |
|---|---|
| `lib/vizier-home.sh` | home paths, reading/writing `lock`, determining the harness pid and its liveness |
| `lib/vizier-wake-lib.sh` | scans open requests, waits on several Runs at once, extracts one summary line |
| `hooks/wake-claude.sh` | Claude Stop hook: lock gate -> wait -> `exit 2` + stderr |
| `hooks/wake-cursor.sh` | Cursor stop hook: lock gate -> loop ceiling -> park-owner -> `followup_message` |
| `hooks/reidentify-claude.sh` | PostCompact: if the lock matches, reprints identity to stderr |
| `hooks/hooks.json` | Claude hook manifest (Stop + PostCompact) |
| `skills/identity/SKILL.md` | the first mate's identity and hard rules |
| `commands/vizier.md` | `/vizier` -- activates a session |
| `.claude-plugin/plugin.json` | Claude Code plugin manifest |
| `bin/vizier-adapter-claude.sh` | installs/removes the Claude adapter |
| `lib/vizier-merge-lib.sh` | the lost-update decision rule, split out of the adapter so it can be sourced in tests |
| `bin/vizier-adapter-cursor.sh` | merges/unmerges `~/.cursor/hooks.json` |
| `bin/vizier` | CLI: `install`, `doctor`, `update`, `uninstall` |
| `install.sh` | `curl \| sh` bootstrap -- clones the source, symlinks the CLI, does NOT install into a harness |
| `tests/helpers.sh` | isolated test environment, fake harness, assertions |
| `tests/fake-orca/orca` | a fake `orca` on PATH |
| `tests/*.test.sh` | one test file per unit |
| `tests/run-all.sh` | runs everything |

---

### Task 1: Test harness and `fake-orca`

Without this, nothing in any later task can be proven. Do it first.

**Files:**
- Create: `tests/helpers.sh`
- Create: `tests/fake-orca/orca`
- Create: `tests/run-all.sh`
- Create: `tests/helpers.test.sh`

**Interfaces:**
- Consumes: nothing
- Produces: `vizier_test_setup` (puts `VIZIER_HOME` into a temp directory, puts `fake-orca` ahead on `PATH`, exports `VIZIER_TEST_TMP`), `vizier_test_teardown`, `assert_eq <got> <want> <label>`, `assert_rc <got> <want> <label>`, `assert_contains <haystack> <needle> <label>`, `fake_orca_queue <run_id> <json_line>` (preloads a message for that run's `check`), `fake_orca_calls` (prints the log of calls made).

- [ ] **Step 1: Write a failing test for helpers**

```bash
# tests/helpers.test.sh
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"

vizier_test_setup

assert_contains "$VIZIER_HOME" "$VIZIER_TEST_TMP" "VIZIER_HOME is inside the temp directory"
[ -d "$VIZIER_HOME" ]; assert_rc $? 0 "VIZIER_HOME was created"

# fake-orca must come before the real orca on PATH
resolved=$(command -v orca)
assert_contains "$resolved" "fake-orca" "orca resolves to fake-orca"

# check with no message returns empty and rc 0
out=$(orca orchestration check --run run_a --peek --json); rc=$?
assert_rc "$rc" 0 "empty check returns rc 0"
assert_eq "$out" "" "empty check prints nothing"

# queue then check returns exactly that line
fake_orca_queue run_a '{"type":"worker_done","outcome":"succeeded","body":"PR opened"}'
out=$(orca orchestration check --run run_a --peek --json)
assert_contains "$out" "worker_done" "check returns the queued message"

# every call gets logged
assert_contains "$(fake_orca_calls)" "orchestration check --run run_a" "the call was logged"

vizier_test_teardown
vizier_test_report
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/helpers.test.sh`
Expected: FAIL -- `tests/helpers.sh: No such file or directory`

- [ ] **Step 3: Write `tests/helpers.sh`**

```bash
# tests/helpers.sh -- isolated test environment. Source it, don't run it.
# Every test runs inside a temporary VIZIER_HOME and a PATH with fake-orca
# ahead of the real one, so no test ever touches the captain's real home or
# real Orca.
VIZIER_TEST_FAILURES=0
VIZIER_TEST_ASSERTS=0

vizier_test_setup() {
  VIZIER_TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/vizier-test.XXXXXX") || exit 1
  export VIZIER_TEST_TMP
  export VIZIER_HOME="$VIZIER_TEST_TMP/home"
  mkdir -p "$VIZIER_HOME/requests" "$VIZIER_HOME/projects"
  export VIZIER_FAKE_ORCA_STATE="$VIZIER_TEST_TMP/fake-orca"
  mkdir -p "$VIZIER_FAKE_ORCA_STATE/queue"
  : > "$VIZIER_FAKE_ORCA_STATE/calls.log"
  VIZIER_TEST_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  export VIZIER_TEST_REPO
  export PATH="$VIZIER_TEST_REPO/tests/fake-orca:$PATH"
}

vizier_test_teardown() {
  [ -n "${VIZIER_TEST_TMP:-}" ] && rm -rf "$VIZIER_TEST_TMP"
}

fake_orca_queue() {  # <run_id> <json_line>
  printf '%s\n' "$2" >> "$VIZIER_FAKE_ORCA_STATE/queue/$1"
}

fake_orca_calls() { cat "$VIZIER_FAKE_ORCA_STATE/calls.log" 2>/dev/null; }

_vizier_fail() {
  VIZIER_TEST_FAILURES=$((VIZIER_TEST_FAILURES+1))
  printf 'FAIL: %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2" >&2
}

assert_eq() {  # <got> <want> <label>
  VIZIER_TEST_ASSERTS=$((VIZIER_TEST_ASSERTS+1))
  [ "$1" = "$2" ] || _vizier_fail "$1" "$2" "$3"
}

assert_rc() {  # <got_rc> <want_rc> <label>
  VIZIER_TEST_ASSERTS=$((VIZIER_TEST_ASSERTS+1))
  [ "$1" = "$2" ] || _vizier_fail "rc=$1" "rc=$2" "$3"
}

assert_contains() {  # <haystack> <needle> <label>
  VIZIER_TEST_ASSERTS=$((VIZIER_TEST_ASSERTS+1))
  case "$1" in *"$2"*) ;; *) _vizier_fail "$1" "contains '$2'" "$3" ;; esac
}

vizier_test_report() {
  if [ "$VIZIER_TEST_FAILURES" -eq 0 ]; then
    printf 'ok: %s asserts passed (%s)\n' "$VIZIER_TEST_ASSERTS" "$(basename "$0")"
    exit 0
  fi
  printf 'FAILED: %s of %s asserts (%s)\n' "$VIZIER_TEST_FAILURES" "$VIZIER_TEST_ASSERTS" "$(basename "$0")" >&2
  exit 1
}
```

- [ ] **Step 4: Write `tests/fake-orca/orca`**

```bash
#!/usr/bin/env bash
# Fake orca for tests. Logs every call, serves queued messages, and NEVER
# touches the network or the real app. Implements only the surface the tests
# need, nothing more.
set -u
STATE="${VIZIER_FAKE_ORCA_STATE:?fake-orca needs VIZIER_FAKE_ORCA_STATE}"
printf '%s\n' "$*" >> "$STATE/calls.log"

run_id=""
wait_mode=0
timeout_ms=0
prev=""
for arg in "$@"; do
  case "$prev" in
    --run) run_id=$arg ;;
    --timeout-ms) timeout_ms=$arg ;;
  esac
  [ "$arg" = "--wait" ] && wait_mode=1
  prev=$arg
done

case "$1 ${2:-}" in
  "orchestration check")
    q="$STATE/queue/${run_id:-_none}"
    if [ -s "$q" ]; then
      cat "$q"
      exit 0
    fi
    if [ "$wait_mode" = 1 ]; then
      # Simulate waiting: sleep up to the timeout then return empty, exactly
      # like a real timeout. Tests use a very small timeout.
      slept=0
      while [ "$slept" -lt "${timeout_ms:-0}" ]; do
        [ -s "$q" ] && { cat "$q"; exit 0; }
        sleep 0.05
        slept=$((slept+50))
      done
    fi
    exit 0
    ;;
  "status --json"|"status")
    printf '%s\n' "${VIZIER_FAKE_ORCA_STATUS:-{\"ok\":true,\"result\":{\"reachable\":true,\"state\":\"ready\",\"capabilities\":[\"orchestration.contract.v1\"]}}}"
    exit 0
    ;;
esac
exit 0
```

- [ ] **Step 5: Write `tests/run-all.sh`**

```bash
#!/usr/bin/env bash
# Runs every tests/*.test.sh, reports a combined result. Exits non-zero if any file fails.
set -u
cd "$(dirname "$0")" || exit 1
failed=0
for t in *.test.sh; do
  if bash "$t"; then :; else failed=$((failed+1)); fi
done
if [ "$failed" -eq 0 ]; then
  printf '\nALL TEST FILES PASSED\n'; exit 0
fi
printf '\n%s TEST FILE(S) FAILED\n' "$failed" >&2; exit 1
```

- [ ] **Step 6: Run the test until it passes**

Run: `chmod +x tests/fake-orca/orca tests/run-all.sh && bash tests/helpers.test.sh`
Expected: PASS -- the last line is `ok: <n> asserts passed (helpers.test.sh)`. The exact number is NOT a contract: if it's off, recounting the asserts in the test is correct, don't change the test to match the number.

- [ ] **Step 7: Commit**

```bash
git add tests/
git commit -m "test: add isolated test harness and a fake orca CLI"
```

---

### Task 2: Home and lock

`lock` does two jobs with one file: it elects the single first mate, and it's the cheapest gate for the hook.

**Files:**
- Create: `lib/vizier-home.sh`
- Create: `tests/lock.test.sh`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `vizier_home` -> prints the home path
  - `vizier_lock_path`, `vizier_requests_dir` -> print paths
  - `vizier_lock_get <key>` -> prints the value, empty if absent
  - `vizier_harness_pid <harness>` -> prints the nearest matching ancestor pid, empty if not found
  - `vizier_lock_claim <session_id> <harness> <pid>` -> rc 0 claimed (prints `claimed` or `reclaimed`), rc 1 refused (prints `held_by=<session_id>`)
  - `vizier_lock_matches <session_id>` -> rc 0 when it matches
  - `vizier_lock_release <session_id>` -> rc 0, only removes it when it's the true owner

- [ ] **Step 1: Write a failing test**

```bash
# tests/lock.test.sh
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-home.sh"

assert_eq "$(vizier_home)" "$VIZIER_HOME" "vizier_home respects VIZIER_HOME"
assert_eq "$(vizier_lock_path)" "$VIZIER_HOME/lock" "the lock path"

# With no lock, no session matches
vizier_lock_matches "sess-a"; assert_rc $? 1 "no lock means no match"

# Claim the lock for the first time
out=$(vizier_lock_claim "sess-a" claude $$); assert_rc $? 0 "claims an empty lock"
assert_contains "$out" "claimed" "reports claimed"
assert_eq "$(vizier_lock_get session_id)" "sess-a" "writes session_id"
assert_eq "$(vizier_lock_get harness)" "claude" "writes harness"
vizier_lock_matches "sess-a"; assert_rc $? 0 "the owner matches"
vizier_lock_matches "sess-b"; assert_rc $? 1 "a different session does not match"

# While the owner is alive, a different session is refused
out=$(vizier_lock_claim "sess-b" claude $$); assert_rc $? 1 "refused while the owner is alive"
assert_contains "$out" "held_by=sess-a" "names the current owner"
assert_eq "$(vizier_lock_get session_id)" "sess-a" "the lock's owner does not change"

# The same owner calling again just refreshes, no refusal
vizier_lock_claim "sess-a" claude $$ >/dev/null; assert_rc $? 0 "the same owner calling again is ok"

# A dead owner can be reclaimed
printf 'session_id=sess-dead\nharness=claude\npid=999999\nsince=1\n' > "$(vizier_lock_path)"
out=$(vizier_lock_claim "sess-c" claude $$); assert_rc $? 0 "a dead lock can be reclaimed"
assert_contains "$out" "reclaimed" "reports reclaimed"
assert_eq "$(vizier_lock_get session_id)" "sess-c" "the new owner was written"

# A non-numeric pid counts as unproven, DOES NOT get reclaimed carelessly
printf 'session_id=sess-x\nharness=claude\npid=abc\nsince=1\n' > "$(vizier_lock_path)"
vizier_lock_claim "sess-d" claude $$ >/dev/null; assert_rc $? 1 "a garbage pid does not let the lock be stolen"

# vizier_harness_pid: finds bash (the test shell itself) as an ancestor, and never makes up a pid
hp=$(vizier_harness_pid bash)
case "$hp" in ''|*[!0-9]*) assert_eq "$hp" "<numeric pid>" "finds bash's ancestor pid" ;; esac
kill -0 "${hp:-0}" 2>/dev/null; assert_rc $? 0 "the returned ancestor pid is alive"
assert_eq "$(vizier_harness_pid definitely-not-a-real-harness-xyz)" "" "returns empty when nothing is found"

# Anti-race invariant: many sessions claiming an empty lock at once means NO
# MORE THAN ONE session believes it holds the lock. Not asserting "exactly
# one" here, because the last writer can write after the last reader's
# read-back; the real invariant is "no more than one".
rm -f "$(vizier_lock_path)"
race="$VIZIER_TEST_TMP/race"; mkdir -p "$race"
for i in 1 2 3 4 5 6 7 8 9 10; do
  ( vizier_lock_claim "race-$i" claude $$ > "$race/$i.out" 2>&1 ) &
done
wait
# EXACTLY ONE, not "no more than one": the last `mv` that succeeds, by
# definition, has no one writing after it, so its own read-back must see
# itself. A previous version asserted <=1 and measured 0 -- but that was a
# tmp-name collision, not the race.
wins=$(grep -l '^claimed' "$race"/*.out 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$wins" "1" "exactly one session wins the empty lock"
losers=$(grep -l '^refused' "$race"/*.out 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$losers" "9" "the other nine sessions are all refused, none errors while writing"
owners=$(sed -n 's/^session_id=//p' "$(vizier_lock_path)" | wc -l | tr -d ' ')
assert_eq "$owners" "1" "the final lock only names one session"

# A session_id containing a newline would corrupt the lock file, so it must be blocked right at the door
rm -f "$(vizier_lock_path)"
out=$(vizier_lock_claim "$(printf 'a\nb')" claude $$); rc=$?
assert_rc "$rc" 1 "a session_id containing a newline is refused"
assert_contains "$out" "newline" "clearly states the reason"
assert_eq "$(vizier_lock_get session_id)" "" "no lock is written for a bad session_id"
out=$(vizier_lock_claim "" claude $$); rc=$?
assert_rc "$rc" 1 "an empty session_id is refused"

# Release only works for the true owner
printf 'session_id=sess-e\nharness=claude\npid=%s\nsince=1\n' $$ > "$(vizier_lock_path)"
vizier_lock_release "sess-other" >/dev/null
assert_eq "$(vizier_lock_get session_id)" "sess-e" "a stranger cannot release it"
vizier_lock_release "sess-e" >/dev/null
assert_eq "$(vizier_lock_get session_id)" "" "the true owner can release it"

vizier_test_teardown
vizier_test_report
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/lock.test.sh`
Expected: FAIL -- `lib/vizier-home.sh: No such file or directory`

- [ ] **Step 3: Write `lib/vizier-home.sh`**

```bash
# shellcheck shell=bash
# Home path and the single first-mate lock. Sourced by the hook, the CLI, and tests.
#
# THE LOCK IS THE HOOK'S GATE. The hook runs after every turn of EVERY harness
# session on the machine, so vizier_lock_matches must be the cheapest possible
# operation (a single file read), and every uncertain branch must return "no match".
#
# LIVENESS IS NEVER GUESSED. A pid that fails to resolve is "not proven",
# not "dead": stealing the lock from a first mate that is still alive is a far
# worse failure than making the captain manually clear a stale lock.

vizier_home() { printf '%s' "${VIZIER_HOME:-$HOME/.vizier}"; }
vizier_lock_path() { printf '%s/lock' "$(vizier_home)"; }
vizier_requests_dir() { printf '%s/requests' "$(vizier_home)"; }

vizier_lock_get() {  # <key>
  local f
  f=$(vizier_lock_path)
  [ -f "$f" ] || return 0
  sed -n "s/^$1=//p" "$f" 2>/dev/null | head -1
}

vizier_harness_pid() {  # <harness> -- print the nearest matching ancestor pid, empty if none
  local want=$1 pid=$$ hops=0 comm ppid
  while [ "$pid" != "1" ] && [ "$hops" -lt 20 ]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 0
    case "$comm" in *"$want"*) printf '%s' "$pid"; return 0 ;; esac
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$ppid" ] || return 0
    pid=$ppid
    hops=$((hops + 1))
  done
}

vizier_lock_matches() {  # <session_id>
  local want=$1 have
  [ -n "$want" ] || return 1
  have=$(vizier_lock_get session_id)
  [ -n "$have" ] && [ "$have" = "$want" ]
}

_vizier_lock_write() {  # <session_id> <harness> <pid>
  local f tmp
  f=$(vizier_lock_path)
  mkdir -p "$(vizier_home)" || return 1
  # mktemp, NOT "$f.$$": in bash, `$$` inside a subshell is the PARENT shell's
  # pid, so multiple subshells with the same parent share one tmp name, overwrite
  # each other, and make `mv` fail. The race test is exactly that case, and it
  # once measured wrong because of this bug -- reporting "no one won the lock"
  # when it was really just a collision on the temp file's name.
  tmp=$(mktemp "$f.XXXXXX") || return 1
  printf 'session_id=%s\nharness=%s\npid=%s\nsince=%s\n' "$1" "$2" "$3" "$(date +%s)" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# Read the lock BACK after writing, and report success only when we are truly
# the owner. Why this is needed: the read-decide-write sequence in
# vizier_lock_claim is not atomic, so two sessions that both see an empty lock (or
# both see a dead owner) both write and both believe they won -- exactly the
# worst failure of this design: two sessions writing requests/ at once. Reading
# back turns that into an invariant -- "NEVER more than one session believes it
# holds the lock" -- without adding any mutex file or leftover mutex state.
_vizier_lock_confirm() {  # <session_id> <verb> <detail>
  local sid=$1 verb=$2 detail=$3 winner
  if vizier_lock_matches "$sid"; then
    printf '%s %s\n' "$verb" "$detail"
    return 0
  fi
  winner=$(vizier_lock_get session_id)
  printf 'refused held_by=%s pid=%s\n' "${winner:-unknown}" "$(vizier_lock_get pid)"
  return 1
}

vizier_lock_claim() {  # <session_id> <harness> <pid>
  local sid=$1 harness=$2 pid=$3 owner owner_pid
  # The lock file is line-based key=value and read with sed, so a session_id
  # containing a newline would write a file that we ourselves cannot read back
  # -> a lone claimant gets refused for no obvious reason. Block it right at
  # the door, and say exactly why.
  case "$sid" in '') printf 'refused reason=empty_session_id\n'; return 1 ;; esac
  if [ "$(printf '%s' "$sid" | tr -cd '\n' | wc -c | tr -d ' ')" != "0" ]; then
    printf 'refused reason=session_id_has_newline\n'
    return 1
  fi
  owner=$(vizier_lock_get session_id)
  if [ -n "$owner" ]; then
    if [ "$owner" = "$sid" ]; then
      _vizier_lock_write "$sid" "$harness" "$pid" || return 1
      printf 'refreshed session_id=%s\n' "$sid"
      return 0
    fi
    owner_pid=$(vizier_lock_get pid)
    case "$owner_pid" in
      ''|*[!0-9]*)
        # Could not resolve the previous owner: refuse rather than steal.
        printf 'refused held_by=%s pid=unresolvable\n' "$owner"
        return 1
        ;;
    esac
    # ONLY liveness decides. A pid that is still alive never has its lock
    # stolen, even when `ps -o comm=` doesn't match the harness: a command-name
    # mismatch is weak evidence of "not that harness", not evidence of "dead".
    # Stealing the lock of a first mate that is still alive means two sessions
    # writing requests/.
    if kill -0 "$owner_pid" 2>/dev/null; then
      printf 'refused held_by=%s pid=%s\n' "$owner" "$owner_pid"
      return 1
    fi
    _vizier_lock_write "$sid" "$harness" "$pid" || return 1
    _vizier_lock_confirm "$sid" reclaimed "from=$owner dead_pid=$owner_pid"
    return $?
  fi
  _vizier_lock_write "$sid" "$harness" "$pid" || return 1
  _vizier_lock_confirm "$sid" claimed "session_id=$sid"
}

vizier_lock_release() {  # <session_id> -- only the true owner can remove it
  vizier_lock_matches "$1" || { printf 'not_owner\n'; return 0; }
  rm -f "$(vizier_lock_path)"
  printf 'released\n'
}
```

- [ ] **Step 4: Run the test until it passes**

Run: `bash tests/lock.test.sh`
Expected: PASS -- the last line is `ok: <n> asserts passed (lock.test.sh)`. The exact number is NOT a contract: if it's off, recounting the asserts in the test is correct, don't change the test to match the number.

- [ ] **Step 5: Commit**

```bash
git add lib/vizier-home.sh tests/lock.test.sh
git commit -m "feat: add the home paths and single-first-mate lock"
```

---

### Task 3: Scanning requests and waiting on several Runs

Split out of the hook because both harnesses share it, and because this is the only part with concurrency logic.

**Files:**
- Create: `lib/vizier-wake-lib.sh`
- Create: `tests/wake-lib.test.sh`

**Interfaces:**
- Consumes: `lib/vizier-home.sh` (`vizier_requests_dir`)
- Produces:
  - `vizier_open_run_ids` -> prints one `run_id` per line for every request with `status: open`
  - `vizier_wait_any_run <timeout_ms>` -> reads run ids from stdin, waits in parallel, prints **one line** summarizing the first message to arrive; empty on timeout. Always rc 0.
  - `vizier_summarize <json_line>` -> prints one short line shaped like `<type> run=<id> <detail>`

- [ ] **Step 1: Write a failing test**

```bash
# tests/wake-lib.test.sh
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-home.sh"
. "$VIZIER_TEST_REPO/lib/vizier-wake-lib.sh"
# Production's poll cadence is 1000ms; the test lowers it to run fast.
export VIZIER_WAKE_POLL_MS=50

mk_request() {  # <slug> <run_id> <status>
  printf -- '---\nrun_id: %s\nproject: demo\nhost: local\nstatus: %s\nopened: 2026-08-31\n---\noriginal request\n' \
    "$2" "$3" > "$(vizier_requests_dir)/$1.md"
}

assert_eq "$(vizier_open_run_ids)" "" "no requests means no runs"

mk_request one run_a open
mk_request two run_b closed
assert_eq "$(vizier_open_run_ids)" "run_a" "only picks up open requests"

mk_request three run_c open
got=$(vizier_open_run_ids | sort | tr '\n' ',')
assert_eq "$got" "run_a,run_c," "picks up multiple open runs"

# A timeout with no message prints empty, rc is still 0
out=$(vizier_open_run_ids | vizier_wait_any_run 200); rc=$?
assert_rc "$rc" 0 "a timeout still gives rc 0"
assert_eq "$out" "" "a timeout prints nothing"

# A message on the second run is still caught: waiting in parallel, not sequentially
fake_orca_queue run_c '{"type":"worker_done","run_id":"run_c","outcome":"succeeded","body":"PR https://x/1"}'
out=$(vizier_open_run_ids | vizier_wait_any_run 3000)
assert_contains "$out" "worker_done" "catches the second run's message"
assert_contains "$out" "run_c" "the summary names the run id"

# The summary is always wrapped into one line
lines=$(printf '%s' "$out" | wc -l | tr -d ' ')
assert_eq "$lines" "0" "the summary is exactly one line, no trailing newline"

# Frontmatter is the only source of truth: "status: open" in the prose body does not count
printf -- '---\nrun_id: run_body\nstatus: closed\n---\nstatus: open\n' > "$(vizier_requests_dir)/body.md"
assert_eq "$(vizier_open_run_ids | grep -c run_body || true)" "0" "status in the prose body does not count"
# A file not opened with `---` is skipped entirely
printf 'a preamble\n---\nrun_id: run_late\nstatus: open\n---\n' > "$(vizier_requests_dir)/late.md"
assert_eq "$(vizier_open_run_ids | grep -c run_late || true)" "0" "frontmatter not at the start of the file is skipped"
rm -f "$(vizier_requests_dir)/body.md" "$(vizier_requests_dir)/late.md"

# CRLF must not silently turn an open request into a not-open one
printf -- '---\r\nrun_id: run_crlf\r\nstatus: open\r\n---\r\n' > "$(vizier_requests_dir)/crlf.md"
assert_eq "$(vizier_open_run_ids | grep -c run_crlf || true)" "1" "CRLF frontmatter is still read correctly"
rm -f "$(vizier_requests_dir)/crlf.md"

# vizier_summarize: a newline slipping through .type or .run_id must also get wrapped into one line
s=$(vizier_summarize '{"type":"worker\ndone","run_id":"r\n1","body":"a\nb"}')
assert_eq "$(printf '%s' "$s" | grep -c . )" "1" "the summary is always exactly one line even when every field has a newline"

# Kill the WHOLE PROCESS GROUP -- exactly how the real harness ends a hook.
# Killing only the outer subshell's pid does NOT propagate to the inner
# subshell (measured: leaked=1), so that measurement wouldn't reflect
# production. `set -m` HERE, in the test, makes the background job its own
# group leader; the library must absolutely never turn it on.
printf -- '---\nrun_id: run_orphanprobe\nstatus: open\n---\nx\n' > "$(vizier_requests_dir)/orphan.md"
set -m
( printf 'run_orphanprobe\n' | vizier_wait_any_run 30000 >/dev/null 2>&1 ) & waiter=$!
set +m
sleep 0.8
kill -TERM -"$waiter" 2>/dev/null || kill -TERM "$waiter" 2>/dev/null || true
sleep 0.8
leaked=$(pgrep -f 'run_orphanprobe' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$leaked" "0" "killing the process group leaves no orphaned orca"
# `pgrep -f run_orphanprobe` ONLY matches the child orca's argv, so it used to
# report 0 while the wrapping shell was still alive and spinning its poll
# loop. Counting the whole process group is what actually catches it:
# $waiter is the pgid because this block runs under `set -m`.
remaining=$(pgrep -g "$waiter" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$remaining" "0" "the whole process group is gone, not just the child orca"
pkill -f 'run_orphanprobe' 2>/dev/null || true
rm -f "$(vizier_requests_dir)/orphan.md"

# A keepalive line is dropped, not treated as a message
fake_orca_queue run_a '{"_keepalive":true}'
out=$(printf 'run_a\n' | vizier_wait_any_run 300)
assert_eq "$out" "" "a keepalive does not count as a message"

vizier_test_teardown
vizier_test_report
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/wake-lib.test.sh`
Expected: FAIL -- `lib/vizier-wake-lib.sh: No such file or directory`

- [ ] **Step 3: Write `lib/vizier-wake-lib.sh`**

```bash
# shellcheck shell=bash
# Scans open requests and waits on the mailbox of several Runs at once.
# Requires lib/vizier-home.sh to be sourced first.
#
# WHY WAIT IN PARALLEL: `orca orchestration check` is per-Run (`--run <id>`),
# and the spec allows several requests to be open at once. Waiting
# sequentially would let one silent Run block another Run's message for the
# whole timeout. We fork one background process per Run, whichever gets a
# message first wins, then we kill the rest.
#
# ALWAYS PASS --run: a first-mate session is not an Orca terminal, so there is
# no terminal-bound Run to fall back on.

VIZIER_WAKE_TYPES="${VIZIER_WAKE_TYPES:-worker_done,escalation,question}"
# Poll cadence. Production keeps it at 1000ms: at an eight-hour timeout that's
# 28,500 loops instead of 285,000, and the extra sub-second wake latency is not
# something a human notices. Tests lower it to 50ms for speed.
VIZIER_WAKE_POLL_MS="${VIZIER_WAKE_POLL_MS:-1000}"

# Return only the frontmatter: the block between the first `---` line and the
# second. A "status:" that happens to appear in the prose body must never get
# to decide anything, and `tr -d '\r'` keeps a CRLF file from silently being
# treated as not-open.
_vizier_frontmatter() {  # <file>
  awk '
    NR==1 && $0 != "---" { exit }
    /^---[[:space:]]*$/ { n++; if (n==2) exit; next }
    n==1 { print }
  ' "$1" 2>/dev/null | tr -d '\r'
}

vizier_open_run_ids() {
  local dir f fm status run
  dir=$(vizier_requests_dir)
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    fm=$(_vizier_frontmatter "$f")
    [ -n "$fm" ] || continue
    status=$(printf '%s\n' "$fm" | sed -n 's/^status:[[:space:]]*//p' | head -1)
    [ "$status" = "open" ] || continue
    run=$(printf '%s\n' "$fm" | sed -n 's/^run_id:[[:space:]]*//p' | head -1)
    [ -n "$run" ] && printf '%s\n' "$run"
  done
}

vizier_summarize() {  # <json_line>
  local line=$1 type run detail
  type=$(printf '%s' "$line" | jq -r '.type // "message"' 2>/dev/null)
  run=$(printf '%s' "$line" | jq -r '.run_id // ""' 2>/dev/null)
  detail=$(printf '%s' "$line" | jq -r '.outcome // .body // ""' 2>/dev/null | tr '\n\r\t' '   ' | cut -c1-120)
  # EVERY field goes through tr, not just detail: the caller relies on "exactly
  # one line", and a newline slipping through .type or .run_id breaks that
  # contract exactly as badly as one slipping through .body.
  printf '%s run=%s %s' "${type:-message}" "${run:-?}" "${detail}" \
    | tr '\n\r\t' '   ' | sed 's/[[:space:]]*$//'
}

# Read run ids from stdin, wait up to <timeout_ms>, print one summary line or
# empty.
vizier_wait_any_run() {  # <timeout_ms>
  # The whole function body lives in a subshell so `trap` belongs only to it,
  # not to the caller's shell.
  (
    local timeout_ms=$1 tmp run i=0 line poll_s deadline f
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/vizier-wake.XXXXXX") || return 0
    # TRAP BEFORE SPAWNING ANYTHING. If this process is killed from the
    # outside -- the harness cuts the hook, the captain closes the session, the
    # machine sleeps -- every child `orca --wait` must die with it. Without the
    # trap, EVERY TURN of EVERY session on the machine would leave behind an
    # orphaned process that can live for up to eight hours. The trap is also
    # the only cleanup path for all three normal exits, so there is nowhere
    # left where cleanup has to be remembered by hand.
    # TWO traps, not one. In bash, a SIGNAL trap runs its handler then
    # CONTINUES execution -- it does not end the process. A single trap
    # combined for both EXIT and INT/TERM would clean up but leave this shell
    # spinning through the poll loop to the original deadline (eight hours in
    # production), once per hook run: exactly the accumulation the trap exists
    # to block. The signal branch must therefore `exit` explicitly. Cleaning up
    # twice is harmless: kill against an already-dead pid and rm -rf against an
    # already-gone directory are both no-ops.
    trap '_vizier_wake_kill_all "$tmp"; rm -rf "$tmp"' EXIT
    trap '_vizier_wake_kill_all "$tmp"; rm -rf "$tmp"; exit 0' INT TERM HUP
    # NEVER `set -m` here. Bash does not create a new process group for a
    # background job, so every child `orca` stays in the process group the
    # HARNESS owns -- and that is exactly what lets the harness ending the hook
    # clean up the whole cluster
    # (firstmate/bin/fm-claude-stop-autoarm.sh:35-37: "Claude owns the process
    # group, so its timeout/session teardown kills arm and watcher together").
    # Turning on `set -m` would push the children into a NEW group and escape
    # that cleanup -- exactly the opposite of what we want. The trap above
    # covers the clean-exit path; the process group covers the cut-off path.
    while IFS= read -r run; do
      [ -n "$run" ] || continue
      i=$((i + 1))
      (
        orca orchestration check --wait --peek --run "$run" \
          --types "$VIZIER_WAKE_TYPES" --timeout-ms "$timeout_ms" --json \
          2>/dev/null > "$tmp/$i.out"
      ) &
      printf '%s\n' "$!" >> "$tmp/pids"
    done
    [ "$i" -gt 0 ] || return 0

    # Deadline by REAL wall-clock time, not a logical counter: a counter that
    # accumulates poll ticks drifts away from real time, since each iteration
    # also costs time running the loop body -- and it drifts further as the
    # file grows.
    poll_s=$(awk -v m="${VIZIER_WAKE_POLL_MS:-1000}" 'BEGIN{printf "%.3f", m/1000}')
    deadline=$(( $(date +%s) + (timeout_ms + 999) / 1000 ))
    while :; do
      for f in "$tmp"/*.out; do
        [ -s "$f" ] || continue
        # Cheap grep before jq: `--types` already guarantees every returned
        # message has a `type`, and Orca's keepalive goes to stderr and gets
        # dropped, so most loop iterations fork no jq at all.
        grep -q '"type"' "$f" 2>/dev/null || continue
        line=$(jq -rc 'select(._keepalive|not) | select(.type? != null)' "$f" 2>/dev/null | head -1)
        [ -n "$line" ] || continue
        vizier_summarize "$line"
        return 0
      done
      [ "$(date +%s)" -lt "$deadline" ] || return 0
      sleep "$poll_s"
    done
  )
}

_vizier_wake_kill_all() {  # <tmpdir>
  local p
  [ -f "$1/pids" ] || return 0
  while IFS= read -r p; do
    case "$p" in ''|*[!0-9]*) continue ;; esac
    kill "$p" 2>/dev/null || true
  done < "$1/pids"
  wait 2>/dev/null || true
}
```

- [ ] **Step 4: Run the test until it passes**

Run: `bash tests/wake-lib.test.sh`
Expected: PASS -- the last line is `ok: <n> asserts passed (wake-lib.test.sh)`. The exact number is NOT a contract: if it's off, recounting the asserts in the test is correct, don't change the test to match the number.

- [ ] **Step 5: Commit**

```bash
git add lib/vizier-wake-lib.sh tests/wake-lib.test.sh
git commit -m "feat: wait on every open run's mailbox concurrently"
```

---

### Task 4: The Claude Code Stop hook

**Files:**
- Create: `hooks/wake-claude.sh`
- Create: `tests/wake-claude.test.sh`

**Interfaces:**
- Consumes: `vizier_lock_matches`, `vizier_open_run_ids`, `vizier_wait_any_run`
- Produces: the hook receives a JSON payload on stdin; a silent `exit 0` or `exit 2` with one stderr line. `VIZIER_WAIT_TIMEOUT_MS` overrides the timeout for tests.

- [ ] **Step 1: Write a failing test**

```bash
# tests/wake-claude.test.sh
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-home.sh"
HOOK="$VIZIER_TEST_REPO/hooks/wake-claude.sh"
export VIZIER_WAIT_TIMEOUT_MS=300

payload() { printf '{"session_id":"%s","cwd":"/tmp","hook_event_name":"Stop"}' "$1"; }
mk_request() {
  printf -- '---\nrun_id: %s\nproject: demo\nhost: local\nstatus: %s\nopened: 2026-08-31\n---\nx\n' \
    "$2" "$3" > "$(vizier_requests_dir)/$1.md"
}

# No lock: absolutely silent. This is the gate that protects every other session on the machine.
out=$(payload sess-a | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 0 "no lock gives exit 0"
assert_eq "$out" "" "no lock prints nothing"
assert_eq "$(fake_orca_calls)" "" "no lock calls orca zero times"

# A different session's lock: still silent
printf 'session_id=sess-other\nharness=claude\npid=%s\nsince=1\n' $$ > "$(vizier_lock_path)"
out=$(payload sess-a | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 0 "a mismatched session_id gives exit 0"
assert_eq "$(fake_orca_calls)" "" "a mismatched session_id calls orca zero times"

# The right owner but no open request: exit 0, still no orca call
printf 'session_id=sess-a\nharness=claude\npid=%s\nsince=1\n' $$ > "$(vizier_lock_path)"
out=$(payload sess-a | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 0 "no open request gives exit 0"
assert_eq "$(fake_orca_calls)" "" "no open request calls orca zero times"

# The right owner, an open request, no message: exit 0 and DOES call orca
mk_request one run_a open
out=$(payload sess-a | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 0 "a timeout gives exit 0"
assert_contains "$(fake_orca_calls)" "--run run_a" "waited on the right run"

# A message: exit 2 and prints the summary to STDERR
fake_orca_queue run_a '{"type":"worker_done","run_id":"run_a","outcome":"succeeded"}'
err=$(payload sess-a | bash "$HOOK" 2>&1 >/dev/null); rc=$?
assert_rc "$rc" 2 "a message gives exit 2"
assert_contains "$err" "worker_done" "stderr carries the summary"
stdout=$(payload sess-a | bash "$HOOK" 2>/dev/null); 
assert_eq "$stdout" "" "nothing is printed to stdout"

# A garbage payload does not crash the hook
out=$(printf 'not json' | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 0 "a garbage payload gives exit 0"

vizier_test_teardown
vizier_test_report
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/wake-claude.test.sh`
Expected: FAIL -- `hooks/wake-claude.sh: No such file or directory`

- [ ] **Step 3: Write `hooks/wake-claude.sh`**

```bash
#!/usr/bin/env bash
# Claude Code's Stop hook -- the Claude half of the self-wake mechanism.
#
# Registered with "asyncRewake": true and "timeout": 28800. Verified on
# Claude Code 2.1.236 (docs/verification/2026-08-31-plugin-wake.md):
#   - asyncRewake IS honored in a plugin hook: the session is not blocked.
#   - exit 2 wakes an IDLE session, stderr enters context as a system reminder.
#   - exit 0 is absolutely silent.
#
# THIS HOOK RUNS AFTER EVERY TURN OF EVERY CLAUDE CODE SESSION ON THE MACHINE,
# with no dedup. So the gate ordering is mandatory, cheap checks before
# expensive ones, and every uncertain branch exits 0.
#
# THE HOOK NEVER ACKS. Acking belongs to the first mate, once it has finished
# processing the batch; thanks to Orca's replay-to-ack, the hook dying midway
# never loses a message.
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)" || exit 0
[ -r "$LIB/vizier-home.sh" ] || exit 0
# shellcheck source=/dev/null
. "$LIB/vizier-home.sh"
# shellcheck source=/dev/null
. "$LIB/vizier-wake-lib.sh"

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null || true)
session_id=$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null) || exit 0

# Gate 1 -- cheapest: is this session the first mate?
vizier_lock_matches "$session_id" || exit 0

# Gate 2: is there anything to wait on? An empty home costs zero orca calls.
runs=$(vizier_open_run_ids)
[ -n "$runs" ] || exit 0

# Wait for less than the hook's own timeout by a safety margin, so the hook
# always exits under its own control rather than being killed mid-flight by
# the harness.
summary=$(printf '%s\n' "$runs" | vizier_wait_any_run "${VIZIER_WAIT_TIMEOUT_MS:-28500000}")
[ -n "$summary" ] || exit 0

printf 'vizier: %s\n' "$summary" >&2
exit 2
```

- [ ] **Step 4: Run the test until it passes**

Run: `chmod +x hooks/wake-claude.sh && bash tests/wake-claude.test.sh`
Expected: PASS -- the last line is `ok: <n> asserts passed (wake-claude.test.sh)`. The exact number is NOT a contract: if it's off, recounting the asserts in the test is correct, don't change the test to match the number.

- [ ] **Step 5: Commit**

```bash
git add hooks/wake-claude.sh tests/wake-claude.test.sh
git commit -m "feat: add the Claude Code stop hook that wakes an idle first mate"
```

---

### Task 5: The Cursor stop hook

Different from Claude in **every** primitive: it runs synchronously, `exit 2` is void, the only channel is `followup_message` on stdout, and two parks can be alive at once so there must be a park-owner.

**Files:**
- Create: `hooks/wake-cursor.sh`
- Create: `tests/wake-cursor.test.sh`

**Interfaces:**
- Consumes: `vizier_lock_matches`, `vizier_open_run_ids`, `vizier_wait_any_run`
- Produces: the hook reads Cursor's payload on stdin (`session_id`, `loop_count`); prints exactly one `{"followup_message": "..."}` object to stdout then `exit 0`, or prints nothing and `exit 0`. Uses `$(vizier_home)/park-owner` as the ownership ledger.

- [ ] **Step 1: Write a failing test**

```bash
# tests/wake-cursor.test.sh
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-home.sh"
HOOK="$VIZIER_TEST_REPO/hooks/wake-cursor.sh"
export VIZIER_WAIT_TIMEOUT_MS=300
# Production's poll cadence is 1000ms. Without setting it here, every hook
# call would take ~1s and would only find the message thanks to the loop
# checking the file BEFORE checking the deadline -- the test would pass by
# accident of ordering rather than by the behavior its name claims to test.
export VIZIER_WAKE_POLL_MS=50

payload() {  # <session_id> <loop_count>
  printf '{"session_id":"%s","loop_count":%s,"workspace_roots":["/tmp"],"status":"completed"}' "$1" "$2"
}
mk_request() {
  printf -- '---\nrun_id: %s\nproject: demo\nhost: local\nstatus: open\nopened: 2026-08-31\n---\nx\n' \
    "$2" > "$(vizier_requests_dir)/$1.md"
}

# No lock: silent
out=$(payload sess-a 0 | bash "$HOOK" 2>/dev/null); rc=$?
assert_rc "$rc" 0 "no lock gives exit 0"
assert_eq "$out" "" "no lock gives empty stdout"

printf 'session_id=sess-a\nharness=cursor-agent\npid=%s\nsince=1\n' $$ > "$(vizier_lock_path)"
mk_request one run_a

# A message: prints exactly one followup_message object, exit 0 (NOT exit 2)
fake_orca_queue run_a '{"type":"worker_done","run_id":"run_a","outcome":"succeeded"}'
out=$(payload sess-a 0 | bash "$HOOK" 2>/dev/null); rc=$?
assert_rc "$rc" 0 "Cursor always exits 0, even when waking"
assert_contains "$out" "followup_message" "prints followup_message"
assert_contains "$out" "worker_done" "the followup carries the summary"
lines=$(printf '%s\n' "$out" | grep -c . )
assert_eq "$lines" "1" "prints exactly ONE line of JSON"
printf '%s' "$out" | jq -e '.followup_message' >/dev/null 2>&1
assert_rc $? 0 "stdout is valid JSON"

# The loop ceiling bites before Cursor's own loop_limit
out=$(payload sess-a 5 | bash "$HOOK" 2>/dev/null); rc=$?
assert_rc "$rc" 0 "hitting the ceiling gives exit 0"
assert_eq "$out" "" "hitting the ceiling does not emit"

# A replaced park stays quiet -- checked with an explicit claim
printf 'someone-else\n' > "$VIZIER_HOME/park-owner"
out=$(payload sess-a 0 | VIZIER_CURSOR_PARK_CLAIM=mine bash "$HOOK" 2>/dev/null)
# The hook writes its own claim at the start, so it WILL be the owner; this
# case only confirms an explicit claim doesn't break the hook. The real test
# is in the concurrent block below.
printf '%s' "$out" | jq -e '.followup_message' >/dev/null 2>&1
assert_rc $? 0 "an explicit claim still emits normally when not replaced"

# TWO REAL parks running overlapped, both seeing the same message: only ONE emits.
# Keep the queue empty until both have entered the wait, otherwise the first
# park could finish before the second one starts and we'd only measure two
# sequential parks.
: > "$VIZIER_FAKE_ORCA_STATE/queue/run_a"
rm -f "$VIZIER_HOME/park-owner"
( payload sess-a 0 | bash "$HOOK" > "$VIZIER_TEST_TMP/p1.out" 2>/dev/null ) & p1=$!
( payload sess-a 0 | bash "$HOOK" > "$VIZIER_TEST_TMP/p2.out" 2>/dev/null ) & p2=$!
sleep 0.6
fake_orca_queue run_a '{"type":"worker_done","run_id":"run_a","outcome":"succeeded"}'
wait "$p1" 2>/dev/null || true
wait "$p2" 2>/dev/null || true
emitters=$(grep -l followup_message "$VIZIER_TEST_TMP/p1.out" "$VIZIER_TEST_TMP/p2.out" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$emitters" "1" "two overlapping parks means exactly one emits"

# Read-back gate: claim written, then REPLACED BY SOMEONE ELSE partway
# through -> must stay quiet, even though it already saw the message. This is
# the case that actually proves the read-back gate; the earlier `chmod 000`
# case is blocked right at the WRITE step and exits through a completely
# different gate, so it passes without ever touching this one.
: > "$VIZIER_FAKE_ORCA_STATE/queue/run_a"
rm -f "$VIZIER_HOME/park-owner"
( payload sess-a 0 | bash "$HOOK" > "$VIZIER_TEST_TMP/p3.out" 2>/dev/null ) & p3=$!
sleep 0.15
printf 'usurper\n' > "$VIZIER_HOME/park-owner"
fake_orca_queue run_a '{"type":"worker_done","run_id":"run_a","outcome":"succeeded"}'
wait "$p3" 2>/dev/null || true
assert_eq "$(cat "$VIZIER_TEST_TMP/p3.out")" "" "being replaced as owner partway through stays quiet, even after seeing the message"

# Failing to write owner_file must also stay quiet -- a different gate, a different case, clearly labeled as different
: > "$VIZIER_FAKE_ORCA_STATE/queue/run_a"
printf 'x\n' > "$VIZIER_HOME/park-owner"; chmod 000 "$VIZIER_HOME/park-owner" 2>/dev/null || true
out=$(payload sess-a 0 | bash "$HOOK" 2>/dev/null)
assert_eq "$out" "" "failing to write owner_file stays quiet (the WRITE gate, not the read-back one)"
chmod 644 "$VIZIER_HOME/park-owner" 2>/dev/null || true

vizier_test_teardown
vizier_test_report
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/wake-cursor.test.sh`
Expected: FAIL -- `hooks/wake-cursor.sh: No such file or directory`

- [ ] **Step 3: Write `hooks/wake-cursor.sh`**

```bash
#!/usr/bin/env bash
# Cursor's stop hook -- the Cursor half of the self-wake mechanism.
#
# CANNOT REUSE CLAUDE'S RECIPE. Measured on cursor-agent TUI 2026.08.25-3e8eec8
# (docs/verification/2026-08-31-plugin-wake.md):
#   - Cursor runs the hook SYNCHRONOUSLY and waits for it: the hook "parks"
#     and keeps the turn boundary open.
#   - exit 2 is a SILENT NO-OP. Never rely on it.
#   - The only channel is exactly one {"followup_message": "..."} on STDOUT
#     plus exit 0. Cursor receives it and runs a new model turn.
#   - `loop_count` in the payload is Cursor's version of stop_hook_active.
#   - This hook CANNOT be installed as a plugin; it only fires from
#     ~/.cursor/hooks.json.
#
# PARK-OWNER. A message the captain types while a hook is parked is received
# immediately and does NOT kill the parked hook. So two parks can be alive at
# once, both see the same message (we use --peek, so neither acks it), and
# both report -> a duplicate. Each run claims an increasing sequence number;
# before emitting, it must confirm it is still the most recent one.
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)" || exit 0
[ -r "$LIB/vizier-home.sh" ] || exit 0
# shellcheck source=/dev/null
. "$LIB/vizier-home.sh"
# shellcheck source=/dev/null
. "$LIB/vizier-wake-lib.sh"

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null || true)
session_id=$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null) || exit 0
loop_count=$(printf '%s' "$payload" | jq -r '.loop_count // 0' 2>/dev/null)

vizier_lock_matches "$session_id" || exit 0

# Self-imposed ceiling, set LOWER than the loop_limit registered in
# hooks.json, so our bound bites first and Cursor never silently stops
# calling the hook at its own ceiling.
ceiling=${VIZIER_CURSOR_LOOP_CEILING:-5}
case "$loop_count" in ''|*[!0-9]*) loop_count=0 ;; esac
[ "$loop_count" -lt "$ceiling" ] || exit 0

runs=$(vizier_open_run_ids)
[ -n "$runs" ] || exit 0

# Claim park ownership before waiting.
#
# THE CONTRACT IS "WHOEVER WRITES LAST WINS", not "the bigger number gets to
# speak". The previous version read the old number, added one, and wrote it
# back -- not atomic, so two parks running at the same time could pick the
# SAME number and both believe they were the newest: exactly the duplicate
# report this mechanism exists to block. Adding a unique token to the claim
# and READING IT BACK before emitting means the last writer wins and everyone
# else stays silent, with no atomicity needed anywhere. Invariant: NEVER more
# than one park emits.
#
# It also fixes the failure direction: if the file can't be read, `current`
# won't match `my_claim`, so we STAY SILENT. The previous version defaulted
# `current=$my_seq` when the file was garbage, meaning every park believed
# itself the owner and all of them emitted -- the wrong direction, and worse
# than the race itself.
owner_file="$(vizier_home)/park-owner"
my_claim="${VIZIER_CURSOR_PARK_CLAIM:-$$.$(date +%s).${RANDOM:-0}}"
printf '%s\n' "$my_claim" > "$owner_file" 2>/dev/null || exit 0

summary=$(printf '%s\n' "$runs" | vizier_wait_any_run "${VIZIER_WAIT_TIMEOUT_MS:-28500000}")
[ -n "$summary" ] || exit 0

# Are we still the last writer? If not, stay quiet: the new park will see the
# same message anyway, since no one has acked it.
current=$(cat "$owner_file" 2>/dev/null)
[ "$current" = "$my_claim" ] || exit 0

jq -cn --arg m "vizier: $summary" '{followup_message:$m}'
exit 0
```

- [ ] **Step 4: Run the test until it passes**

Run: `chmod +x hooks/wake-cursor.sh && bash tests/wake-cursor.test.sh`
Expected: PASS -- the last line is `ok: <n> asserts passed (wake-cursor.test.sh)`. The exact number is NOT a contract: if it's off, recounting the asserts in the test is correct, don't change the test to match the number.

- [ ] **Step 5: Commit**

```bash
git add hooks/wake-cursor.sh tests/wake-cursor.test.sh
git commit -m "feat: add the Cursor stop hook that answers with a follow-up message"
```

---

### Task 6: Identity, `/vizier`, and the PostCompact hook

**Files:**
- Create: `skills/identity/SKILL.md`
- Create: `commands/vizier.md`
- Create: `hooks/reidentify-claude.sh`
- Create: `bin/vizier-activate.sh`
- Create: `tests/activate.test.sh`

**Interfaces:**
- Consumes: `vizier_lock_claim`, `vizier_lock_matches`, `vizier_harness_pid`
- Produces: `bin/vizier-activate.sh [harness] [session_id_override]` -> rc 0 and prints `claimed`/`reclaimed`/`refreshed`; rc 1 and prints `refused held_by=<id>`; rc 2 when the session or the harness pid can't be determined. The session id defaults from `CLAUDE_CODE_SESSION_ID`; the second parameter is only for test overrides. `/vizier` calls exactly this script through Bash, with no parameters.

> **Why `bin/vizier-activate.sh` exists:** `/vizier` is a markdown file, it can't run logic. It tells the agent to run exactly one command; the script keeps all the lock semantics in one testable place, instead of scattering them as prose for the model to interpret on its own.

- [ ] **Step 1: Write a failing test**

```bash
# tests/activate.test.sh
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-home.sh"
ACT="$VIZIER_TEST_REPO/bin/vizier-activate.sh"

out=$(bash "$ACT" claude sess-a); rc=$?
assert_rc "$rc" 0 "the first activation succeeds"
assert_contains "$out" "claimed" "reports claimed"
assert_eq "$(vizier_lock_get session_id)" "sess-a" "the lock records the right session"

# The home is fully created on the very first activation
[ -d "$VIZIER_HOME/requests" ]; assert_rc $? 0 "creates requests/"
[ -d "$VIZIER_HOME/projects" ]; assert_rc $? 0 "creates projects/"

# A second session is refused while the owner is still alive
out=$(bash "$ACT" claude sess-b); rc=$?
assert_rc "$rc" 1 "the second session is refused"
assert_contains "$out" "held_by=sess-a" "clearly states who holds it"

# No session id from the environment: REFUSE, never make up a value
rm -f "$(vizier_lock_path)"
out=$(env -u CLAUDE_CODE_SESSION_ID bash "$ACT" claude 2>&1); rc=$?
assert_rc "$rc" 2 "no CLAUDE_CODE_SESSION_ID gives rc 2"
assert_contains "$out" "no_session_id" "clearly states the reason"
assert_eq "$(vizier_lock_get session_id)" "" "no lock is written when the session id is missing"
# When the environment variable is present, use it -- the model fills in nothing
out=$(CLAUDE_CODE_SESSION_ID=from-env bash "$ACT" claude); rc=$?
assert_rc "$rc" 0 "the session id is taken from the environment"
assert_eq "$(vizier_lock_get session_id)" "from-env" "the lock records the environment's session id"

# Failing to determine the harness pid: REFUSE. This branch previously had NO
# test reaching it at all, because every call read the test environment's
# real CLAUDE_PID. Remove CLAUDE_PID and give a harness name that cannot
# possibly exist in the process tree.
rm -f "$(vizier_lock_path)"
out=$(env -u CLAUDE_PID bash "$ACT" no-such-harness-xyz 2>&1); rc=$?
assert_rc "$rc" 2 "failing to find the harness pid gives rc 2"
assert_contains "$out" "no_harness_pid" "clearly states the reason"
assert_eq "$(vizier_lock_get session_id)" "" "no lock is written when the harness pid is missing"

# PostCompact: a matching lock reprints identity to stderr, a mismatch stays silent
HOOK="$VIZIER_TEST_REPO/hooks/reidentify-claude.sh"
err=$(printf '{"session_id":"sess-a"}' | bash "$HOOK" 2>&1 >/dev/null); rc=$?
assert_rc "$rc" 0 "reidentify always exits 0"
assert_contains "$err" "first mate" "reprints identity"
err=$(printf '{"session_id":"sess-zzz"}' | bash "$HOOK" 2>&1 >/dev/null)
assert_eq "$err" "" "a different session stays silent"

vizier_test_teardown
vizier_test_report
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/activate.test.sh`
Expected: FAIL -- `bin/vizier-activate.sh: No such file or directory`

- [ ] **Step 3: Write `bin/vizier-activate.sh`**

```bash
#!/usr/bin/env bash
# Activates this session as the first mate. /vizier calls exactly this
# script. Prints one result line; rc 0 = this session is the first mate,
# rc 1 = refused.
set -u

# SESSION ID COMES FROM THE ENVIRONMENT, NOT FROM THE MODEL. Measured on the
# captain's machine: Claude Code sets CLAUDE_CODE_SESSION_ID (a 36-character
# UUID, matching the session's transcript file name) in the environment of
# every shell command -- while the model has NO way at all to know its own
# session id. If the model were left to fill it in, it would make up a value
# that never matches the `session_id` in the payload the hook receives, and
# then BOTH the wake hook AND the PostCompact hook would go silent forever
# while the lock stayed held -- the whole product broken, silently. Better to
# refuse activation.
# Usage: vizier-activate.sh [harness] [session_id_override]
harness=${1:-claude}
session_id=${2:-${CLAUDE_CODE_SESSION_ID:-}}
if [ -z "$session_id" ]; then
  printf 'refused reason=no_session_id\n' >&2
  printf 'could not read a session id (CLAUDE_CODE_SESSION_ID is empty): this session\n' >&2
  printf 'is not running under Claude Code, or the harness is not supported yet.\n' >&2
  exit 2
fi

LIB="$(cd "$(dirname "$0")/../lib" 2>/dev/null && pwd)" || { printf 'error: lib not found\n' >&2; exit 2; }
# shellcheck source=/dev/null
. "$LIB/vizier-home.sh"

# PID must be the long-lived HARNESS process, not the transient shell calling
# this script. $PPID is the Bash tool's shell and can die right afterward,
# which would make `kill -0` treat a first mate that's still alive as dead
# and let another session steal the lock -- exactly the failure the liveness
# rule calls worse than a stuck lock. Measured: CLAUDE_PID and
# vizier_harness_pid give the same pid, so prefer the environment variable and
# only then walk the process tree, and there is NO other fallback.
pid=${CLAUDE_PID:-}
case "$pid" in ''|*[!0-9]*) pid=$(vizier_harness_pid "$harness") ;; esac
case "$pid" in
  ''|*[!0-9]*)
    printf 'refused reason=no_harness_pid harness=%s\n' "$harness" >&2
    exit 2 ;;
esac

# Only create the home AFTER every refusal check has passed: a refused
# activation should not leave behind any directory that a later, successful
# activation would find unfamiliar.
mkdir -p "$(vizier_home)/requests" "$(vizier_home)/projects" || { printf 'error: cannot create home\n' >&2; exit 2; }

vizier_lock_claim "$session_id" "$harness" "$pid"
```

- [ ] **Step 4: Write `hooks/reidentify-claude.sh`**

```bash
#!/usr/bin/env bash
# PostCompact hook: after context compaction, the first mate forgets who it
# is but is still holding the lock and still being woken up. Reprint identity
# to stderr for the session that actually holds the lock, stay silent for
# every other session.
set -u
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)" || exit 0
[ -r "$LIB/vizier-home.sh" ] || exit 0
# shellcheck source=/dev/null
. "$LIB/vizier-home.sh"
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null || true)
session_id=$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null) || exit 0
vizier_lock_matches "$session_id" || exit 0

SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills/identity" 2>/dev/null && pwd)/SKILL.md"
if [ -r "$SKILL" ]; then
  printf 'vizier: this session is still the first mate. Reprinting identity:\n' >&2
  cat "$SKILL" >&2
else
  printf 'vizier: this session is still the first mate but the identity skill could not be read.\n' >&2
fi
exit 0
```

- [ ] **Step 5: Write `skills/identity/SKILL.md`**

```markdown
---
name: identity
description: The first mate's identity and hard rules. Loaded when /vizier activates a session and every time context gets compacted.
---

# You are the first mate

The captain talks to **one** single point of contact: you. Crew agents run in worktrees and
terminals managed by Orca. You coordinate, you don't do the work yourself.

## Division of roles

- **Orca owns the mechanics**: worktrees, terminals, Run/Task/Dispatch, mailbox, release,
  cross-host federation. Never copy that state into home.
- **You own the judgment**: split a request into tasks, generate briefs, choose a host, read
  `worker_done`, decide the next step, talk to the captain in the language of outcomes, not
  the language of mechanics.

## Hard rules

1. **Never edit project code yourself.** That's the worker's job, in the worktree Orca assigned.
2. **Never infer authority.** Merges, destructive actions, irreversible actions, and
   security-sensitive choices all require the captain to say so explicitly.
3. **The host chosen for a request stays with it for the whole request.** If the host dies
   partway through, **stop and tell the captain** -- never silently move the task to another host.
4. **Only release after a real `worker_done` has been processed.** Never release for a timeout,
   TUI idle state, heartbeat, status, question, escalation, or a rejected or stale `worker_done`.
5. **Never ack before every message in the batch has been processed.** Orca replays until acked;
   that's what makes losing a session not lose a message.
6. **Always pass `--run <run_id>` explicitly** to every orchestration command. This session is
   not an Orca terminal, so there is no bound Run to fall back on.
7. **Never stop/restart/update the `no-mistakes` daemon.** One instance is shared across every
   worktree and host.
8. **Use the tool's own CLI**: `git`, `gh`. No third-party wrapper.

## State

Home lives at `~/.vizier/` -- `requests/` is the ledger of open requests, `projects/` is
the knowledge for each project. This session's cwd is **not related** to that state, and is never
the authority for choosing a project.

## Reporting

Roll it into one message, say only what's worth saying: the outcome, the PR in full
`https://...` form, and any decision the captain needs to make. Don't narrate step by step.
```

- [ ] **Step 6: Write `commands/vizier.md`**

```markdown
---
description: Turns this session into the first mate -- the liaison coordinating crew agents through Orca
---

Activate this session as the first mate.

1. Run exactly this command through Bash, **with no extra arguments**:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/vizier-activate.sh" claude
   ```

   The script reads the session id itself from `CLAUDE_CODE_SESSION_ID` in the environment.
   **Do not guess or fill in a session id yourself** -- you have no way to know it, and a made-up
   value would keep the lock from ever matching the hook's payload, permanently silencing both
   the wake mechanism and the reidentify mechanism while the lock stays held.

   Handle it according to the exact return code:

   - **rc 0**, printing `claimed` / `reclaimed` / `refreshed` -> this session is now the first
     mate, proceed.
   - **rc 1**, printing `refused held_by=<id>` -> **STOP.** Another session is already the first
     mate. Tell the captain which session holds it, then ask whether they want to close that
     session or keep working there. **Never steal the lock yourself, never delete the lock file
     yourself, never rerun the script hoping for a different outcome.**
   - **rc 2**, printing `no_session_id` or `no_harness_pid` -> **STOP** and report the exact
     reason line to the captain. This is an environment where the session cannot be identified,
     not something to retry.

2. Read `${CLAUDE_PLUGIN_ROOT}/skills/identity/SKILL.md` and follow it for the rest of the session.

3. Run `"${CLAUDE_PLUGIN_ROOT}/bin/vizier" doctor`. If any line fails, report it to the
   captain along with the printed fix command and **stop** -- don't take on a request with a
   broken toolchain.

4. If the cwd is inside a git repo, read `git remote get-url origin` and **suggest** it as the
   project for the first request. It's only a suggestion: it counts only once the captain
   confirms it. cwd is never the authority.

5. Tell the captain one short sentence: that you are now the first mate, where home is, and how
   many requests are currently open (count files with `status: open` in
   `~/.vizier/requests/`).
```

- [ ] **Step 7: Run the test until it passes**

Run: `chmod +x bin/vizier-activate.sh hooks/reidentify-claude.sh && bash tests/activate.test.sh`
Expected: PASS -- the last line is `ok: <n> asserts passed (activate.test.sh)`. The exact number is NOT a contract: if it's off, recounting the asserts in the test is correct, don't change the test to match the number.

- [ ] **Step 8: Commit**

```bash
git add skills/identity/SKILL.md commands/vizier.md hooks/reidentify-claude.sh bin/vizier-activate.sh tests/activate.test.sh
git commit -m "feat: add the identity skill, /vizier activation, and compaction re-identify"
```

---

### Task 7: The Claude Code adapter

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `hooks/hooks.json`
- Create: `bin/vizier-adapter-claude.sh`
- Create: `tests/adapter-claude.test.sh`

**Interfaces:**
- Consumes: nothing (only manipulates files)
- Produces: `vizier-adapter-claude.sh install <dist_dir> <target_root>` and `... uninstall <target_root>`; `... detect` -> rc 0 when `claude` is on PATH. `target_root` defaults to `$HOME/.claude/skills` (overridden in tests).

- [ ] **Step 1: Write a failing test**

```bash
# tests/adapter-claude.test.sh
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
AD="$VIZIER_TEST_REPO/bin/vizier-adapter-claude.sh"
DIST="$VIZIER_TEST_TMP/dist"; TARGET="$VIZIER_TEST_TMP/claude-skills"
mkdir -p "$DIST/hooks" "$DIST/lib" "$DIST/skills/identity" "$DIST/commands" "$DIST/.claude-plugin"
cp "$VIZIER_TEST_REPO/hooks/hooks.json" "$DIST/hooks/"
cp "$VIZIER_TEST_REPO/.claude-plugin/plugin.json" "$DIST/.claude-plugin/"
printf 'x\n' > "$DIST/hooks/wake-claude.sh"

bash "$AD" install "$DIST" "$TARGET"; assert_rc $? 0 "install succeeded"
[ -f "$TARGET/vizier/hooks/hooks.json" ]; assert_rc $? 0 "copies hooks.json"
[ -f "$TARGET/vizier/.claude-plugin/plugin.json" ]; assert_rc $? 0 "copies the manifest"

# hooks.json must declare exactly the two verified constants
hooks="$TARGET/vizier/hooks/hooks.json"
assert_eq "$(jq -r '.hooks.Stop[0].hooks[0].asyncRewake' "$hooks")" "true" "asyncRewake is on"
assert_eq "$(jq -r '.hooks.Stop[0].hooks[0].timeout' "$hooks")" "28800" "timeout is 28800"
assert_contains "$(jq -r '.hooks.Stop[0].hooks[0].command' "$hooks")" "CLAUDE_PLUGIN_ROOT" "uses CLAUDE_PLUGIN_ROOT"
assert_contains "$(jq -r '.hooks.PostCompact[0].hooks[0].command' "$hooks")" "reidentify-claude.sh" "has PostCompact"

# rerunning install is idempotent, does not duplicate
bash "$AD" install "$DIST" "$TARGET"; assert_rc $? 0 "installing a second time is still ok"
assert_eq "$(jq '.hooks.Stop[0].hooks | length' "$hooks")" "1" "does not duplicate the hook"

# uninstall wipes the plugin directory clean
bash "$AD" uninstall "$TARGET"; assert_rc $? 0 "uninstall succeeded"
[ -d "$TARGET/vizier" ]; assert_rc $? 1 "the plugin directory is gone"

vizier_test_teardown
vizier_test_report
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/adapter-claude.test.sh`
Expected: FAIL -- `hooks/hooks.json: No such file or directory`

- [ ] **Step 3: Write `hooks/hooks.json` and `.claude-plugin/plugin.json`**

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/wake-claude.sh",
            "asyncRewake": true,
            "timeout": 28800
          }
        ]
      }
    ],
    "PostCompact": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/reidentify-claude.sh",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

```json
{
  "$schema": "https://anthropic.com/claude-code/plugin.schema.json",
  "name": "vizier",
  "version": "0.1.0",
  "description": "Talk to one first mate; it runs an Orca-managed crew",
  "skills": "./skills/",
  "commands": "./commands/",
  "hooks": "./hooks/hooks.json"
}
```

- [ ] **Step 4: Write `bin/vizier-adapter-claude.sh`**

```bash
#!/usr/bin/env bash
# Claude Code adapter: installs the payload as a plugin in its OWN directory.
# Touches no one else's config file, so uninstalling is just deleting the
# directory.
set -u

action=${1:-}
case "$action" in
  detect)
    command -v claude >/dev/null 2>&1 || exit 1
    printf 'claude\n'; exit 0 ;;
  install)
    dist=${2:?usage: install <dist_dir> [target_root]}
    target=${3:-$HOME/.claude/skills}
    [ -d "$dist" ] || { printf 'error: dist not found: %s\n' "$dist" >&2; exit 1; }
    dest="$target/vizier"
    mkdir -p "$target" || exit 1
    # Copy clean: delete the old copy first so install is idempotent in the
    # real sense, leaving no file behind from a previous version.
    rm -rf "$dest"
    mkdir -p "$dest" || exit 1
    (cd "$dist" && tar cf - .) | (cd "$dest" && tar xf -) || exit 1
    printf 'installed claude adapter -> %s\n' "$dest"
    printf 'note: Claude Code has a full idle-session wake mechanism (asyncRewake).\n'
    exit 0 ;;
  uninstall)
    target=${2:-$HOME/.claude/skills}
    rm -rf "$target/vizier"
    printf 'removed claude adapter\n'; exit 0 ;;
  *)
    printf 'usage: vizier-adapter-claude.sh detect|install <dist> [target]|uninstall [target]\n' >&2
    exit 2 ;;
esac
```

- [ ] **Step 5: Run the test until it passes**

Run: `chmod +x bin/vizier-adapter-claude.sh && bash tests/adapter-claude.test.sh`
Expected: PASS -- the last line is `ok: <n> asserts passed (adapter-claude.test.sh)`. The exact number is NOT a contract: if it's off, recounting the asserts in the test is correct, don't change the test to match the number.

- [ ] **Step 6: Commit**

```bash
git add .claude-plugin/plugin.json hooks/hooks.json bin/vizier-adapter-claude.sh tests/adapter-claude.test.sh
git commit -m "feat: add the Claude Code plugin adapter"
```

---

### Task 8: The Cursor adapter -- surgical merge

**The plan's highest risk.** The target file is `~/.cursor/hooks.json`, where Orca already has 8 entries. A bad merge breaks Orca's supervision, not just ours.

**Files:**
- Create: `lib/vizier-merge-lib.sh`
- Create: `bin/vizier-adapter-cursor.sh`
- Create: `tests/adapter-cursor.test.sh`

**Interfaces:**
- Consumes: nothing
- Produces: `vizier-adapter-cursor.sh install <dist_dir> [hooks_json]`, `... uninstall [hooks_json]`, `... verify [hooks_json]` (rc 0 when exactly our own entry is present), `... detect`. Our entry is identified by the string `wake-cursor.sh` in `.command` -- the file name is the marker, independent of the install path, so an `VIZIER_HOME` override in tests still matches.

- [ ] **Step 1: Write a failing test**

```bash
# tests/adapter-cursor.test.sh
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
AD="$VIZIER_TEST_REPO/bin/vizier-adapter-cursor.sh"
DIST="$VIZIER_TEST_TMP/dist"; mkdir -p "$DIST/hooks"; printf 'x\n' > "$DIST/hooks/wake-cursor.sh"
H="$VIZIER_TEST_TMP/cursor-hooks.json"

# Mimics the captain's real file: Orca already has entries here beforehand.
cat > "$H" <<'JSON'
{
  "version": 1,
  "hooks": {
    "preToolUse": [{"matcher":"Shell","command":"rtk hook cursor"}],
    "stop": [{"type":"command","command":"/Users/x/.orca/agent-hooks/cursor-hook.sh","timeout":10}],
    "afterAgentResponse": [{"type":"command","command":"/Users/x/.orca/agent-hooks/cursor-hook.sh","timeout":10}]
  }
}
JSON
before=$(shasum -a 256 "$H" | awk '{print $1}')

bash "$AD" install "$DIST" "$H"; assert_rc $? 0 "install succeeded"

# The other party's entries must remain intact, one by one
assert_eq "$(jq -r '.hooks.preToolUse | length' "$H")" "1" "preToolUse preserved"
assert_eq "$(jq -r '.hooks.afterAgentResponse[0].command' "$H")" "/Users/x/.orca/agent-hooks/cursor-hook.sh" "Orca hook preserved"
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("orca/agent-hooks"))] | length' "$H")" "1" "Orca's stop hook preserved"
assert_eq "$(jq -r '.version' "$H")" "1" "version preserved"

# Our entry matches the verified constants exactly
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("wake-cursor.sh"))] | length' "$H")" "1" "exactly one entry added"
assert_eq "$(jq -r '.hooks.stop[] | select(.command | contains("wake-cursor.sh")) | .loop_limit' "$H")" "200" "loop_limit is 200"
assert_eq "$(jq -r '.hooks.stop[] | select(.command | contains("wake-cursor.sh")) | .timeout' "$H")" "28800" "timeout is 28800"

# A backup exists before writing
ls "$VIZIER_HOME"/backups/cursor-hooks.*.json >/dev/null 2>&1; assert_rc $? 0 "a backup file exists"

# Idempotent: running three times still leaves exactly one entry
bash "$AD" install "$DIST" "$H" >/dev/null
bash "$AD" install "$DIST" "$H" >/dev/null
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("wake-cursor.sh"))] | length' "$H")" "1" "rerunning does not duplicate"
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("orca/agent-hooks"))] | length' "$H")" "1" "rerunning does not duplicate the other party's entry"

bash "$AD" verify "$H"; assert_rc $? 0 "verify sees our entry"

# uninstall removes exactly our entry and returns the file to its previous state
bash "$AD" uninstall "$H"; assert_rc $? 0 "uninstall succeeded"
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("wake-cursor.sh"))] | length' "$H")" "0" "our entry is gone"
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("orca/agent-hooks"))] | length' "$H")" "1" "Orca's hook is still intact"
bash "$AD" verify "$H"; assert_rc $? 1 "verify reports the entry is gone"

# A missing file is created fresh and valid, no crash
H2="$VIZIER_TEST_TMP/fresh.json"
bash "$AD" install "$DIST" "$H2"; assert_rc $? 0 "a new file is created"
assert_eq "$(jq -r '.version' "$H2")" "1" "the new file has version 1"

# Broken JSON must be REFUSED, absolutely never overwritten
printf 'not json at all' > "$VIZIER_TEST_TMP/broken.json"
out=$(bash "$AD" install "$DIST" "$VIZIER_TEST_TMP/broken.json" 2>&1); rc=$?
assert_rc "$rc" 1 "broken JSON gives rc 1"
assert_contains "$out" "refus" "clearly states this is a refusal"
assert_eq "$(cat "$VIZIER_TEST_TMP/broken.json")" "not json at all" "the broken file is untouched"

vizier_test_teardown
vizier_test_report
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/adapter-cursor.test.sh`
Expected: FAIL -- `bin/vizier-adapter-cursor.sh: No such file or directory`

- [ ] **Step 3a: Write `lib/vizier-merge-lib.sh`**

```bash
# shellcheck shell=bash
# Decision rule for merging into a file owned by another tool.
#
# Lives in lib rather than in the adapter, because the adapter has a dispatch
# `case` block that runs the moment it's sourced -- it can't be tested without
# inventing a test-only branch inside the single riskiest file in the project.
# A lib exists precisely to be sourced.
#
# The write race itself can't be reproduced in a unit test, but the decision
# RULE must be testable, and this is it.

# 0 when there is no sign of a lost update.
# An EMPTY count (jq failed, file unreadable) counts as a MISMATCH, not as
# equal: two empty strings compared to each other are "equal", and that is how
# a real failure disguises itself as healthy state.
vizier_no_lost_update() {  # <others_before> <others_after> <mine_after>
  # Check EACH argument separately, never concatenate them. The concatenated
  # form `case "$1$2$3"` once let through the case `"" "" 1`: concatenated
  # that's "1" -- all digits, passes the digit check -- then `"" = ""` reports
  # "no mismatch" -- exactly what this guard exists to block.
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  case "$2" in ''|*[!0-9]*) return 1 ;; esac
  case "$3" in ''|*[!0-9]*) return 1 ;; esac
  [ "$2" = "$1" ] && [ "$3" = "1" ]
}
```

- [ ] **Step 3: Write `bin/vizier-adapter-cursor.sh`**

```bash
#!/usr/bin/env bash
# Cursor adapter: surgical merge into ~/.cursor/hooks.json.
#
# WHY NOT A PLUGIN. Measured (docs/verification/2026-08-31-plugin-wake.md):
# the same hook placed in ~/.cursor/skills/<name>/ with .cursor-plugin/plugin.json
# declaring "hooks" NEVER fires, even when forced with --plugin-dir; placed
# in ~/.cursor/hooks.json it runs the full cycle. Cursor gives us no choice.
#
# THIS FILE HAS ANOTHER OWNER. Orca installs its own 8 entries into it. Every
# operation must:
#   - identify our entry by exactly one string in .command (the file name
#     wake-cursor.sh, independent of the install path);
#   - only add/remove that one entry, never rewrite the whole file from a
#     template;
#   - back up before writing;
#   - REFUSE when the JSON fails to parse, rather than "fixing" it by
#     overwriting.
set -u

MARKER="wake-cursor.sh"   # the file name is the marker: no other tool has a file with this name

# The decision rule for "was an update lost" lives in the lib, NOT here: a
# script with a `case` dispatch block can't be sourced for testing, and we
# don't invent a test-only branch inside the single riskiest file in the
# project.
LIB="$(cd "$(dirname "$0")/../lib" 2>/dev/null && pwd)" || { printf 'error: lib not found\n' >&2; exit 2; }
# shellcheck source=/dev/null
. "$LIB/vizier-merge-lib.sh"

_home() { printf '%s' "${VIZIER_HOME:-$HOME/.vizier}"; }
_default_hooks() { printf '%s/.cursor/hooks.json' "$HOME"; }

# Follow the symlink before writing. `mv tmp "$H"` onto a symlink would
# REPLACE the symlink itself with a plain file -- the content survives but
# the structure the captain set up is lost.
_resolve() {  # <path> -- walk the whole link chain, not just one hop
  local p=$1 t hops=0
  while [ -L "$p" ] && [ "$hops" -lt 16 ]; do
    t=$(readlink "$p") || break
    case "$t" in
      /*) p=$t ;;
      *)  p="$(dirname "$p")/$t" ;;
    esac
    hops=$((hops + 1))
  done
  printf '%s' "$p"
}

# Backup names must not collide. `date +%S` only resolves to the second, and
# three installs in a row can easily land inside the same second -- the later
# one would overwrite the earlier one and the in-between state would become
# unrecoverable.
_backup() {  # <hooks_json> -> prints the backup path
  local dir stamp n=0 f
  dir="$(_home)/backups"
  mkdir -p "$dir" || return 1
  stamp=$(date +%Y%m%d-%H%M%S)
  while [ -e "$dir/cursor-hooks.$stamp.$n.json" ]; do n=$((n + 1)); done
  f="$dir/cursor-hooks.$stamp.$n.json"
  cp "$1" "$f" 2>/dev/null || return 1
  printf '%s' "$f"
}

# Count entries that are NOT ours. Used both before and after writing to
# detect a lost update. An entry whose `.command` is not a string can't be
# ours, so it gets COUNTED and KEPT -- a foreign entry must never be allowed
# to break an install.
_count_others() {  # <hooks_json>
  jq --arg m "$MARKER" '
    [(.hooks.stop // [])[]
     | select(((.command? | type) != "string") or ((.command | contains($m)) | not))]
    | length' "$1" 2>/dev/null
}
_count_mine() {  # <hooks_json>
  jq --arg m "$MARKER" '
    [(.hooks.stop // [])[]
     | select(((.command? | type) == "string") and (.command | contains($m)))]
    | length' "$1" 2>/dev/null
}

# Apply our entry onto the current file. Used for both the first merge and
# a retry.
_merge_ours() {  # <hooks_json> <cmd>
  local H=$1 cmd=$2 tmp="$1.vizier.$$"
  jq --arg cmd "$cmd" --arg m "$MARKER" '
    .version = (.version // 1)
    | .hooks = (.hooks // {})
    | .hooks.stop = (
        ((.hooks.stop // []) | map(select(
           (((.command? | type) == "string") and (.command | contains($m))) | not)))
        + [{type:"command", command:$cmd, timeout:28800, loop_limit:200}]
      )
  ' "$H" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$H" || { rm -f "$tmp"; return 1; }
}

# `.hooks.stop` must be an array, or not exist at all. If it's an object, jq
# would SILENTLY coerce it into an array and wipe out the key entirely --
# structural damage with no error reported, exactly the worst kind of harm
# on a file owned by another tool.
_assert_stop_shape() {  # <hooks_json>
  local t
  t=$(jq -r '(.hooks.stop // null) | type' "$1" 2>/dev/null) || return 1
  case "$t" in
    null|array) return 0 ;;
    *) printf 'refused: .hooks.stop is %s, not an array; not touching %s\n' "$t" "$1" >&2
       return 1 ;;
  esac
}

action=${1:-}
case "$action" in
  detect)
    command -v cursor-agent >/dev/null 2>&1 || exit 1
    printf 'cursor\n'; exit 0 ;;

  install)
    dist=${2:?usage: install <dist_dir> [hooks_json]}
    H=$(_resolve "${3:-$(_default_hooks)}")
    cmd="$dist/hooks/wake-cursor.sh"
    if [ -f "$H" ]; then
      jq -e . "$H" >/dev/null 2>&1 || {
        printf 'refused: %s is not valid JSON; fix it or move it aside, this tool will not overwrite it\n' "$H" >&2
        exit 1
      }
      _assert_stop_shape "$H" || exit 1
      backup=$(_backup "$H") || { printf 'refused: could not write a backup\n' >&2; exit 1; }
    else
      mkdir -p "$(dirname "$H")" || exit 1
      printf '{"version":1,"hooks":{}}\n' > "$H" || exit 1
      backup=""
    fi
    others_before=$(_count_others "$H")
    _merge_ours "$H" "$cmd" || { printf 'refused: merge failed\n' >&2; exit 1; }

    # READ BACK AFTER WRITING. macOS has no `flock`, so instead of preventing
    # the race we DETECT it. But NO auto-restore: the backup is a snapshot
    # from BEFORE our merge, so restoring it would wipe out whatever the
    # other writer wrote in between -- leaving the file older than either
    # side, worse than just leaving it alone. Instead: try re-merging ONCE
    # from the current state (which already contains their change), and if
    # it's still off, report loudly and point the captain at the backup to
    # decide for themselves.
    if ! vizier_no_lost_update "$others_before" "$(_count_others "$H")" "$(_count_mine "$H")"; then
      _merge_ours "$H" "$cmd" || { printf 'refused: retry merge failed\n' >&2; exit 1; }
      if ! vizier_no_lost_update "$(_count_others "$H")" "$(_count_others "$H")" "$(_count_mine "$H")"; then
        printf 'refused: another process wrote %s at the same time and we could not reconcile it.\n' "$H" >&2
        printf '  NOT auto-restoring, because the backup is older than their change. Backup at: %s\n' "${backup:-<none>}" >&2
        printf '  Please inspect the file and rerun install.\n' >&2
        exit 1
      fi
    fi
    printf 'installed cursor adapter -> %s\n' "$H"
    printf 'note: Cursor does NOT run hooks in headless `cursor-agent -p`; an interactive session is required.\n'
    printf 'note: Cursor requires trust per workspace directory, so every new directory needs one trust step.\n'
    exit 0 ;;

  uninstall)
    H=$(_resolve "${2:-$(_default_hooks)}")
    [ -f "$H" ] || { printf 'nothing to remove\n'; exit 0; }
    jq -e . "$H" >/dev/null 2>&1 || { printf 'refused: %s is not valid JSON\n' "$H" >&2; exit 1; }
    _assert_stop_shape "$H" || exit 1
    _backup "$H" >/dev/null || { printf 'refused: could not write a backup\n' >&2; exit 1; }
    others_before=$(_count_others "$H")
    tmp="$H.vizier.$$"
    jq --arg m "$MARKER" '
      .hooks.stop = ((.hooks.stop // []) | map(select(
         (((.command? | type) == "string") and (.command | contains($m))) | not)))
    ' "$H" > "$tmp" 2>/dev/null || { rm -f "$tmp"; exit 1; }
    jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; exit 1; }
    mv "$tmp" "$H" || { rm -f "$tmp"; exit 1; }
    [ "$(_count_others "$H")" = "$others_before" ] || {
      printf 'warn: the entry count for other tools changed while uninstalling\n' >&2; }
    printf 'removed cursor adapter entry from %s\n' "$H"
    exit 0 ;;

  verify)
    dist=${2:?usage: verify <dist_dir> [hooks_json]}
    H=$(_resolve "${3:-$(_default_hooks)}")
    [ -f "$H" ] || exit 1
    # Check the EXACT SHAPE, not just a count: a leftover stale entry with the
    # wrong timeout, or pointing at a previous install's dist, still "counts
    # as one" but is broken.
    jq -e --arg cmd "$dist/hooks/wake-cursor.sh" --arg m "$MARKER" '
      [(.hooks.stop // [])[]
       | select(((.command? | type) == "string") and (.command | contains($m)))] as $mine
      | ($mine | length) == 1
        and $mine[0].command == $cmd
        and $mine[0].timeout == 28800
        and $mine[0].loop_limit == 200
    ' "$H" >/dev/null 2>&1 || exit 1
    exit 0 ;;

  *)
    printf 'usage: vizier-adapter-cursor.sh detect|install <dist> [hooks_json]|uninstall [hooks_json]|verify <dist> [hooks_json]\n' >&2
    exit 2 ;;
esac
```

- [ ] **Step 4: Run the test until it passes**

Run: `chmod +x bin/vizier-adapter-cursor.sh && bash tests/adapter-cursor.test.sh`
Expected: PASS -- the last line is `ok: <n> asserts passed (adapter-cursor.test.sh)`. The exact number is NOT a contract: if it's off, recounting the asserts in the test is correct, don't change the test to match the number.

- [ ] **Step 5: Commit**

```bash
git add bin/vizier-adapter-cursor.sh tests/adapter-cursor.test.sh
git commit -m "feat: merge the Cursor stop hook into a file another tool owns"
```

---

### Task 9: The `vizier` CLI

**Files:**
- Create: `bin/vizier`
- Create: `tests/cli.test.sh`
- Modify: `tests/run-all.sh` (no change needed -- it already scans `*.test.sh`)

**Interfaces:**
- Consumes: `vizier-adapter-claude.sh`, `vizier-adapter-cursor.sh`, `lib/vizier-home.sh`
- Produces: `vizier install|doctor|update|uninstall`. `doctor` prints one line per problem, `MISSING: <tool> (install: <cmd>)` or `NOT_READY: <reason>`, rc 1 when there's a problem, rc 0 when clean.

- [ ] **Step 1: Write a failing test**

```bash
# tests/cli.test.sh
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
CLI="$VIZIER_TEST_REPO/bin/vizier"
# `gh auth status` touches the real keychain, so the test would pass or fail
# depending on the machine. Skip exactly that check; the real doctor still
# checks it fully.
export VIZIER_SKIP_GH_AUTH=1

# doctor is clean when fake-orca reports ready and every tool is present
out=$(bash "$CLI" doctor 2>&1); rc=$?
assert_rc "$rc" 0 "a clean doctor gives rc 0"
assert_contains "$out" "orca" "doctor mentions orca"

# Orca not ready makes doctor fail and states clearly how to fix it
export VIZIER_FAKE_ORCA_STATUS='{"ok":true,"result":{"reachable":false,"state":"starting","capabilities":[]}}'
out=$(bash "$CLI" doctor 2>&1); rc=$?
assert_rc "$rc" 1 "Orca not ready gives rc 1"
assert_contains "$out" "NOT_READY" "reports NOT_READY"
assert_contains "$out" "orca open" "suggests the fix command"

# Missing a required capability also fails
export VIZIER_FAKE_ORCA_STATUS='{"ok":true,"result":{"reachable":true,"state":"ready","capabilities":["other.v1"]}}'
out=$(bash "$CLI" doctor 2>&1); rc=$?
assert_rc "$rc" 1 "missing capability gives rc 1"
assert_contains "$out" "orchestration.contract.v1" "names the exact missing capability"
unset VIZIER_FAKE_ORCA_STATUS

# install copies the payload into dist then calls the adapter
export VIZIER_CLAUDE_SKILLS_DIR="$VIZIER_TEST_TMP/claude-skills"
export VIZIER_CURSOR_HOOKS_JSON="$VIZIER_TEST_TMP/cursor-hooks.json"
out=$(bash "$CLI" install --harness claude 2>&1); rc=$?
assert_rc "$rc" 0 "install claude succeeds"
[ -f "$VIZIER_HOME/dist/hooks/wake-claude.sh" ]; assert_rc $? 0 "the payload is in dist"
[ -f "$VIZIER_CLAUDE_SKILLS_DIR/vizier/hooks/hooks.json" ]; assert_rc $? 0 "the claude adapter is installed"

# An unsupported harness says so plainly, does not stay silent
out=$(bash "$CLI" install --harness codex 2>&1); rc=$?
assert_rc "$rc" 1 "an unknown harness gives rc 1"
assert_contains "$out" "is not supported" "says plainly it's not supported"

# uninstall keeps state
mkdir -p "$VIZIER_HOME/requests"; printf 'x\n' > "$VIZIER_HOME/requests/keep.md"
bash "$CLI" uninstall >/dev/null 2>&1
[ -f "$VIZIER_HOME/requests/keep.md" ]; assert_rc $? 0 "uninstall does NOT delete requests"
[ -d "$VIZIER_CLAUDE_SKILLS_DIR/vizier" ]; assert_rc $? 1 "uninstall removes the adapter"

# uninstall must also clean up bootstrap's own traces
export VIZIER_BIN_DIR="$VIZIER_TEST_TMP/bin"; mkdir -p "$VIZIER_BIN_DIR" "$VIZIER_HOME/src"
ln -sf /usr/bin/true "$VIZIER_BIN_DIR/vizier"
bash "$CLI" uninstall >/dev/null 2>&1
[ -L "$VIZIER_BIN_DIR/vizier" ]; assert_rc $? 1 "uninstall removes the symlink on PATH"
[ -d "$VIZIER_HOME/src" ]; assert_rc $? 1 "uninstall removes the src clone when not running from it"

# install FROM INSIDE the installed copy must be refused, not self-destruct
bash "$CLI" install --harness claude >/dev/null 2>&1
out=$(bash "$VIZIER_HOME/dist/bin/vizier" install --harness claude 2>&1); rc=$?
assert_rc "$rc" 1 "install from inside dist is refused"
assert_contains "$out" "refused" "clearly states this is a refusal"
[ -f "$VIZIER_HOME/dist/bin/vizier" ]; assert_rc $? 0 "dist is not deleted after the refusal"

# uninstall run FROM INSIDE src does not delete src, only prints the command
mkdir -p "$VIZIER_HOME/src/bin" "$VIZIER_HOME/src/lib"
cp "$VIZIER_TEST_REPO/bin/vizier" "$VIZIER_HOME/src/bin/"
cp "$VIZIER_TEST_REPO/lib/vizier-home.sh" "$VIZIER_HOME/src/lib/"
out=$(bash "$VIZIER_HOME/src/bin/vizier" uninstall 2>&1)
[ -d "$VIZIER_HOME/src" ]; assert_rc $? 0 "does not self-delete the directory it's running from"
assert_contains "$out" "rm -rf" "prints the delete command for the captain"

vizier_test_teardown
vizier_test_report
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/cli.test.sh`
Expected: FAIL -- `bin/vizier: No such file or directory`

- [ ] **Step 3: Write `bin/vizier`**

```bash
#!/usr/bin/env bash
# vizier -- install and diagnostics CLI.
#
# HARD RULE: this script runs ONLY at install time and diagnostic time. No runtime path
# may call it. After install, the first mate talks directly to `orca`.
set -u

# $0 CAN BE A SYMLINK. `install.sh` installs this CLI as exactly a symlink on
# PATH, so that is the only real invocation path -- and in that case
# `dirname "$0"` points at the bin directory on PATH, not at where the real
# script lives. The consequence has been reproduced: wrong REPO_DIR -> lib
# source fails -> `vizier_home` doesn't exist -> `$(vizier_home)` is empty -> every
# path derived from it points somewhere wrong, and the anti-self-destruct
# guard ends up operating on the caller's current directory instead. Walk the
# whole link chain BEFORE deriving any path from it.
_self=$0
_hops=0
while [ -L "$_self" ] && [ "$_hops" -lt 16 ]; do
  _t=$(readlink "$_self") || break
  case "$_t" in
    /*) _self=$_t ;;
    *)  _self="$(dirname "$_self")/$_t" ;;
  esac
  _hops=$((_hops + 1))
done
# Hitting the ceiling means REPORTING AN ERROR, not continuing with a
# half-resolved path. Continuing is a silent degradation -- exactly the kind
# of bug that has bitten this project three times (cd "" becoming a no-op, a
# signal trap continuing execution, a guard concatenating its arguments
# before validating them) -- and here it could produce a REPO_DIR that is
# wrong but still looks valid.
[ -L "$_self" ] && {
  printf 'error: symlink chain too deep (>16 hops) from %s\n' "$0" >&2; exit 2; }
SELF_DIR="$(cd "$(dirname "$_self")" 2>/dev/null && pwd)" || {
  printf 'error: could not determine the script directory\n' >&2; exit 2; }
REPO_DIR="$(cd "$SELF_DIR/.." 2>/dev/null && pwd)" || {
  printf 'error: could not determine the repo root\n' >&2; exit 2; }

# A FAILED SOURCE MUST BE FATAL. Bash only prints a warning and keeps going,
# and `set -u` does not catch a missing function -- that is exactly how a
# missing `vizier_home` turns into an empty path and the guard ends up pointed
# at the wrong place.
[ -r "$REPO_DIR/lib/vizier-home.sh" ] || {
  printf 'error: could not read %s/lib/vizier-home.sh\n' "$REPO_DIR" >&2; exit 2; }
# shellcheck source=/dev/null
. "$REPO_DIR/lib/vizier-home.sh"

VIZIER_HOME_DIR=$(vizier_home)
[ -n "$VIZIER_HOME_DIR" ] || { printf 'error: home is empty\n' >&2; exit 2; }

# Canonicalize a path ONLY when the directory truly exists. `cd ""` is a
# silent no-op in bash and returns the current directory -- exactly what
# turned this guard into a landmine.
_canon() {  # <path> -> canonical path if it exists, empty if not
  [ -n "$1" ] && [ -d "$1" ] || return 0
  (cd "$1" 2>/dev/null && pwd)
}

DIST="$VIZIER_HOME_DIR/dist"
CLAUDE_SKILLS="${VIZIER_CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
CURSOR_HOOKS="${VIZIER_CURSOR_HOOKS_JSON:-$HOME/.cursor/hooks.json}"

_sync_dist() {
  # REFUSE when running from the installed copy itself: _sync_dist deletes
  # $DIST then copies from $REPO_DIR, and when running from dist those two
  # paths are the same one -> self-destruction.
  # Compare on the CANONICAL path of a directory that ACTUALLY EXISTS. If
  # dist doesn't exist yet, REPO_DIR can't possibly be inside it, so the
  # guard doesn't need to fire -- and, more importantly, there is no branch
  # where an empty value can sneak into the comparison.
  local dist_canon
  dist_canon=$(_canon "$DIST")
  if [ -n "$dist_canon" ]; then
    case "$REPO_DIR/" in
      "$dist_canon"/*|"$dist_canon/")
        printf 'refused: running from the installed copy (%s).\n' "$REPO_DIR" >&2
        printf '  run install/update from the source checkout: %s/src/bin/vizier install\n' "$VIZIER_HOME_DIR" >&2
        return 1 ;;
    esac
  fi
  mkdir -p "$DIST" || return 1
  rm -rf "${DIST:?}/"*
  local item
  for item in lib hooks skills commands bin .claude-plugin; do
    [ -e "$REPO_DIR/$item" ] || continue
    cp -R "$REPO_DIR/$item" "$DIST/" || return 1
  done
  printf 'payload -> %s\n' "$DIST"
}

cmd_doctor() {
  local problems=0 status reachable state caps
  for t in orca jq git gh; do
    command -v "$t" >/dev/null 2>&1 || {
      case "$t" in
        orca) printf 'MISSING: orca (install: brew install orca)\n' ;;
        jq)   printf 'MISSING: jq (install: brew install jq)\n' ;;
        git)  printf 'MISSING: git (install: brew install git)\n' ;;
        gh)   printf 'MISSING: gh (install: brew install gh && gh auth login)\n' ;;
      esac
      problems=$((problems + 1))
    }
  done
  if command -v orca >/dev/null 2>&1; then
    status=$(orca status --json 2>/dev/null)
    reachable=$(printf '%s' "$status" | jq -r '.result.reachable // false' 2>/dev/null)
    state=$(printf '%s' "$status" | jq -r '.result.state // "unknown"' 2>/dev/null)
    caps=$(printf '%s' "$status" | jq -r '(.result.capabilities // []) | join(",")' 2>/dev/null)
    if [ "$reachable" != "true" ] || [ "$state" != "ready" ]; then
      printf 'NOT_READY: Orca reachable=%s state=%s (fix: orca open, then wait for the app to be ready)\n' "$reachable" "$state"
      problems=$((problems + 1))
    fi
    # EXACT membership, not a substring: `*orchestration.contract.v1*` would
    # also match `orchestration.contract.v10` and
    # `x-orchestration.contract.v1`, i.e. report success while the real
    # capability is actually missing.
    if ! printf '%s' "$status" | jq -e --arg c orchestration.contract.v1 \
         '((.result.capabilities // []) | index($c)) != null' >/dev/null 2>&1; then
      printf 'NOT_READY: Orca is missing capability orchestration.contract.v1 (fix: update the Orca app)\n'
      problems=$((problems + 1))
    fi
  fi
  if [ -z "${VIZIER_SKIP_GH_AUTH:-}" ] && command -v gh >/dev/null 2>&1 && ! gh auth status >/dev/null 2>&1; then
    printf 'NOT_READY: gh is not logged in (fix: gh auth login)\n'
    problems=$((problems + 1))
  fi
  if [ "$problems" -eq 0 ]; then
    printf 'doctor: ok -- orca ready, jq/git/gh available\n'
    return 0
  fi
  return 1
}

cmd_install() {
  local want=all
  while [ $# -gt 0 ]; do
    case "$1" in
      --harness) want=${2:?--harness needs a value}; shift 2 ;;
      *) printf 'unknown flag: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  case "$want" in
    all|claude|cursor) ;;
    *) printf 'error: harness "%s" is not supported. v1 only has claude and cursor.\n' "$want" >&2; return 1 ;;
  esac
  _sync_dist || return 1
  local did=0
  if [ "$want" = all ] || [ "$want" = claude ]; then
    if bash "$DIST/bin/vizier-adapter-claude.sh" detect >/dev/null 2>&1 || [ "$want" = claude ]; then
      bash "$DIST/bin/vizier-adapter-claude.sh" install "$DIST" "$CLAUDE_SKILLS" || return 1
      did=$((did + 1))
    fi
  fi
  if [ "$want" = all ] || [ "$want" = cursor ]; then
    if bash "$DIST/bin/vizier-adapter-cursor.sh" detect >/dev/null 2>&1 || [ "$want" = cursor ]; then
      bash "$DIST/bin/vizier-adapter-cursor.sh" install "$DIST" "$CURSOR_HOOKS" || return 1
      did=$((did + 1))
    fi
  fi
  [ "$did" -gt 0 ] || { printf 'no supported harness found on this machine\n' >&2; return 1; }
  printf 'done. Open a new session and type /vizier.\n'
}

cmd_uninstall() {
  [ -d "$DIST" ] && bash "$DIST/bin/vizier-adapter-claude.sh" uninstall "$CLAUDE_SKILLS" >/dev/null 2>&1
  [ -d "$DIST" ] && bash "$DIST/bin/vizier-adapter-cursor.sh" uninstall "$CURSOR_HOOKS" >/dev/null 2>&1
  rm -rf "$DIST"
  # Also clean up whatever install.sh created, otherwise the captain finishes
  # uninstalling and still has a dead command on PATH pointing at an orphaned
  # clone.
  local bin_link="${VIZIER_BIN_DIR:-$HOME/.local/bin}/vizier"
  [ -L "$bin_link" ] && rm -f "$bin_link"
  # DO NOT delete the directory currently holding this very script: bash
  # reads a script in chunks, and deleting it mid-run is undefined behavior.
  # Print the command for the captain instead.
  local src src_canon
  src="$VIZIER_HOME_DIR/src"
  src_canon=$(_canon "$src")
  case "$REPO_DIR/" in
    "${src_canon:-$src}"/*|"${src_canon:-$src}/")
      printf 'removed the adapter, payload, and symlink. requests/ and projects/ are kept at %s\n' "$(vizier_home)"
      printf 'the source checkout remains (cannot self-delete because this command is running from it):\n'
      printf '  rm -rf %s\n' "$src"
      return 0 ;;
  esac
  rm -rf "$src"
  printf 'removed the adapter, payload, symlink, and clone. requests/ and projects/ are kept at %s\n' "$(vizier_home)"
}

case "${1:-}" in
  doctor)    shift; cmd_doctor "$@" ;;
  install)   shift; cmd_install "$@" ;;
  update)    shift; cmd_install "$@" ;;
  uninstall) shift; cmd_uninstall "$@" ;;
  *) printf 'usage: vizier install [--harness claude|cursor]|doctor|update|uninstall\n' >&2; exit 2 ;;
esac
```

- [ ] **Step 4: Run every test until it passes**

Run: `chmod +x bin/vizier && bash tests/cli.test.sh`
Expected: PASS -- every test file prints `ok:`, ending with `ALL TEST FILES PASSED`

- [ ] **Step 5: Commit**

```bash
git add bin/vizier tests/cli.test.sh
git commit -m "feat: add the installer CLI"
```

---

### Task 10: The `install.sh` bootstrap -- installing with one command

This is the thing every user touches first, so it needs a test just like everything else. The
test uses a local bare repo over `file://` so it runs offline, with no need for a published repo.

**Files:**
- Create: `install.sh`
- Create: `tests/install-sh.test.sh`

**Interfaces:**
- Consumes: `bin/vizier` (only for the symlink; bootstrap does not run `install` itself)
- Produces: `install.sh` reads `VIZIER_REPO_URL`, `VIZIER_HOME`, `VIZIER_BIN_DIR`; clones or updates
  `$VIZIER_HOME/src`, symlinks `$VIZIER_BIN_DIR/vizier`, then prints the next step. rc 0 when
  done, rc 1 when `git`/`jq` is missing or the clone fails.

> **Precondition:** the repo already has an `origin` remote pointing at a **public** repo on
> GitHub. The captain set that remote themselves; Step 0 only reads it back, it doesn't create it.

> **Bootstrap does NOT run `vizier install` itself.** Installing the binary and installing
> into a harness are two different decisions: the latter edits the captain's
> `~/.cursor/hooks.json`. A `curl | sh` is not allowed to do that silently.

- [ ] **Step 0: Cross-check the repo URL**

Already confirmed: the remote is `git@github.com:vantoantrinh96/vizier.git`, and `gh repo
view` confirms the repo is **PUBLIC**. Run it again to make sure it hasn't changed:

```bash
git remote get-url origin && gh repo view --json visibility,nameWithOwner
```

The default in `install.sh` at Step 3 is already the **HTTPS** form of that same repo. If the
remote differs from the value above, **stop and tell the captain** -- don't change the URL in the
script yourself.

- [ ] **Step 1: Write a failing test**

```bash
# tests/install-sh.test.sh
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup

# A local bare repo stands in for the remote: the test runs offline, with no dependency on the published repo.
ORIGIN="$VIZIER_TEST_TMP/origin.git"
WORK="$VIZIER_TEST_TMP/work"
git init --quiet --bare "$ORIGIN"
git clone --quiet "$ORIGIN" "$WORK"
mkdir -p "$WORK/bin"
printf '#!/usr/bin/env bash\necho stub-cli\n' > "$WORK/bin/vizier"
chmod +x "$WORK/bin/vizier"
cp "$VIZIER_TEST_REPO/install.sh" "$WORK/install.sh"
git -C "$WORK" add -A
git -C "$WORK" -c user.email=t@t -c user.name=t commit --quiet -m init
git -C "$WORK" push --quiet origin HEAD:refs/heads/main
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main

export VIZIER_REPO_URL="file://$ORIGIN"
export VIZIER_BIN_DIR="$VIZIER_TEST_TMP/bin"

out=$(sh "$VIZIER_TEST_REPO/install.sh" 2>&1); rc=$?
assert_rc "$rc" 0 "bootstrap succeeds"
[ -d "$VIZIER_HOME/src/.git" ]; assert_rc $? 0 "clones into src/"
[ -L "$VIZIER_BIN_DIR/vizier" ]; assert_rc $? 0 "creates the symlink"
assert_eq "$("$VIZIER_BIN_DIR/vizier")" "stub-cli" "the symlink runs the right CLI"
assert_contains "$out" "vizier install" "prints the next step"

# MUST NOT auto-install into a harness: that's a separate decision, it edits someone else's file
assert_eq "$(ls "$VIZIER_HOME/dist" 2>/dev/null)" "" "bootstrap does not run install on its own"

# Running it again is an update, not a breakage
printf '#!/usr/bin/env bash\necho stub-v2\n' > "$WORK/bin/vizier"
git -C "$WORK" -c user.email=t@t -c user.name=t commit --quiet -am v2
git -C "$WORK" push --quiet origin HEAD:refs/heads/main
sh "$VIZIER_TEST_REPO/install.sh" >/dev/null 2>&1; assert_rc $? 0 "rerunning succeeds"
assert_eq "$("$VIZIER_BIN_DIR/vizier")" "stub-v2" "rerunning updates to the new version"

# Local changes inside src get overwritten, without getting bootstrap stuck
printf 'junk\n' > "$VIZIER_HOME/src/bin/vizier"
sh "$VIZIER_TEST_REPO/install.sh" >/dev/null 2>&1; assert_rc $? 0 "a dirty src still updates"
assert_eq "$("$VIZIER_BIN_DIR/vizier")" "stub-v2" "a dirty src gets restored"

# The default must be a real URL and must be HTTPS. SSH would break on a fresh
# machine with no key, and since the repo is public HTTPS needs no auth -- this
# is what catches "pasted the raw SSH remote in" instead of letting it drift
# to the first user.
default_url=$(sed -n 's/^REPO_URL="\${VIZIER_REPO_URL:-\(.*\)}"$/\1/p' "$VIZIER_TEST_REPO/install.sh")
assert_contains "$default_url" "https://github.com/" "the default is HTTPS, not SSH"
# `github.com` alone does NOT distinguish: the SSH string `git@github.com:...`
# also contains it. Must catch the actual SSH marker.
case "$default_url" in *git@*) assert_eq "ssh" "https" "the default must NOT be in SSH form" ;; esac
assert_contains "$default_url" "vizier" "the default points at the right repo"
case "$default_url" in *git@*) assert_eq "ssh" "https" "the default must NOT be in SSH form" ;; esac

# Target on PATH is already a DIRECTORY: must be REFUSED, must not report success.
# On macOS's BSD ln, `-f` does not replace a directory, it creates the link
# INSIDE it and exits 0 -- reporting "installed" while what's on PATH does not run.
mkdir -p "$VIZIER_BIN_DIR/vizier"
out=$(sh "$VIZIER_TEST_REPO/install.sh" 2>&1); rc=$?
assert_rc "$rc" 1 "target is a directory gives rc 1"
assert_contains "$out" "not a symlink" "clearly states the reason"
rmdir "$VIZIER_BIN_DIR/vizier"

# $SRC exists but is not a git repo: report it clearly and give the delete command, do NOT auto-delete
rm -rf "$VIZIER_HOME/src"; mkdir -p "$VIZIER_HOME/src"; printf 'junk\n' > "$VIZIER_HOME/src/junk"
out=$(sh "$VIZIER_TEST_REPO/install.sh" 2>&1); rc=$?
assert_rc "$rc" 1 "src not being a git repo gives rc 1"
assert_contains "$out" "rm -rf" "prints the delete command for the captain"
rm -rf "$VIZIER_HOME/src"

# Delete the local `refs/remotes/origin/HEAD` ref then rerun: the update path
# must still run smoothly.
#
# THIS IS ALL THIS CASE PROVES. It does NOT prove the `remote set-head` line
# is necessary: measured directly by removing that line and the suite still
# stayed green, because a `file://` clone environment cannot reproduce a real
# missing-origin/HEAD state. That line is kept as a defense, based on a
# reviewer having reproduced the stuck state on a bare repo with HEAD deleted.
# Name the assertion for what it actually measures, rather than let a name
# promise more than the truth -- this project has already had five tests
# stay green while measuring the wrong thing.
sh "$VIZIER_TEST_REPO/install.sh" >/dev/null 2>&1
git -C "$VIZIER_HOME/src" symbolic-ref --delete refs/remotes/origin/HEAD 2>/dev/null || true
sh "$VIZIER_TEST_REPO/install.sh" >/dev/null 2>&1
assert_rc $? 0 "rerunning after deleting the local origin/HEAD ref still updates"

# A broken URL fails clearly, without leaving behind a dead symlink
export VIZIER_REPO_URL="file://$VIZIER_TEST_TMP/does-not-exist.git"
rm -rf "$VIZIER_HOME/src" "$VIZIER_BIN_DIR/vizier"
out=$(sh "$VIZIER_TEST_REPO/install.sh" 2>&1); rc=$?
assert_rc "$rc" 1 "a broken URL gives rc 1"
[ -L "$VIZIER_BIN_DIR/vizier" ]; assert_rc $? 1 "a failure leaves no dead symlink behind"

vizier_test_teardown
vizier_test_report
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/install-sh.test.sh`
Expected: FAIL -- `install.sh: No such file or directory`

- [ ] **Step 3: Write `install.sh`**

```bash
#!/usr/bin/env sh
# Bootstrap vizier.
#
#   curl -fsSL <RAW_URL>/install.sh | sh
#
# Does exactly two things: fetches the source into $VIZIER_HOME/src and places a
# symlink on PATH. DELIBERATELY DOES NOT run `vizier install`: that
# step edits the captain's harness config (for Cursor that's
# ~/.cursor/hooks.json, a file Orca also uses), so it must be an explicit
# decision, not a side effect of `curl | sh`.
#
# POSIX sh, no bashisms: this runs through the user's `sh`, not bash.
set -eu

# The repo is public on GitHub, so both clone and curl need no auth.
#
# USE HTTPS, NOT SSH. The checkout's own remote is in SSH form
# (git@github.com:vantoantrinh96/vizier.git), but bootstrap runs on a
# fresh machine via `curl | sh` where there's no guarantee of an SSH key for
# that account -- and since the repo is already public, an HTTPS clone needs
# no auth at all. Take the owner/name from the remote, emit it as HTTPS.
REPO_URL="${VIZIER_REPO_URL:-https://github.com/vantoantrinh96/vizier.git}"

HOME_DIR="${VIZIER_HOME:-$HOME/.vizier}"
SRC="$HOME_DIR/src"
BIN_DIR="${VIZIER_BIN_DIR:-$HOME/.local/bin}"

for t in git jq; do
  command -v "$t" >/dev/null 2>&1 || { echo "error: need $t (brew install $t)" >&2; exit 1; }
done

mkdir -p "$HOME_DIR"
if [ -d "$SRC/.git" ]; then
  git -C "$SRC" fetch --quiet origin || { echo "error: fetch failed from $REPO_URL" >&2; exit 1; }
  # origin/HEAD may not be set yet (an old clone, or a remote that doesn't
  # publish HEAD). When that happens, `reset --hard origin/HEAD` reports
  # "unknown revision" and bootstrap gets stuck permanently. `set-head -a`
  # asks the remote again and self-heals; a failure here does not block.
  git -C "$SRC" remote set-head origin -a >/dev/null 2>&1 || true
  # reset --hard: $SRC is owned by the tool, not a place for hand edits. A
  # hand edit there is deliberately overwritten, rather than leaving
  # bootstrap stuck forever.
  git -C "$SRC" reset --quiet --hard origin/HEAD || { echo "error: reset failed" >&2; exit 1; }
elif [ -e "$SRC" ]; then
  # $SRC exists but is not a git repo -- usually a botched previous clone.
  # DO NOT auto-delete it: it's a directory on the captain's machine. Say so
  # clearly and give the exact command.
  echo "error: $SRC already exists but is not a git repo (a botched clone?)" >&2
  echo "  delete it and rerun:  rm -rf $SRC" >&2
  exit 1
else
  git clone --quiet "$REPO_URL" "$SRC" || { echo "error: clone failed from $REPO_URL" >&2; exit 1; }
fi

[ -x "$SRC/bin/vizier" ] || { echo "error: source is missing bin/vizier" >&2; exit 1; }
mkdir -p "$BIN_DIR" || { echo "error: could not create $BIN_DIR" >&2; exit 1; }

# `ln -sf` is NOT safe when the target is already a DIRECTORY. On macOS's
# BSD ln -- the only platform we ship to -- `-f` does not replace a
# directory; it creates the link INSIDE that directory and exits 0, so the
# script would print "installed" successfully while what's on PATH is a
# directory that can't run. Guard before, and verify again after.
LINK="$BIN_DIR/vizier"
if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
  echo "error: $LINK already exists and is not a symlink; move it aside and rerun" >&2
  exit 1
fi
ln -sf "$SRC/bin/vizier" "$LINK" || { echo "error: could not create symlink $LINK" >&2; exit 1; }
[ -L "$LINK" ] || { echo "error: $LINK is not a symlink after install" >&2; exit 1; }

echo "installed vizier -> $LINK"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: $BIN_DIR is not on PATH yet; add it to your shell profile" ;;
esac
echo
echo "next:"
echo "  vizier doctor     # check Orca, jq, git, gh"
echo "  vizier install    # install into a harness (will edit harness config)"
```

- [ ] **Step 4: Run the test until it passes**

Run: `chmod +x install.sh && bash tests/install-sh.test.sh`
Expected: PASS -- the last line is `ok: <n> asserts passed (install-sh.test.sh)`. The exact number is NOT a contract: if it's off, recounting the asserts in the test is correct, don't change the test to match the number.

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/install-sh.test.sh
git commit -m "feat: add the one-line bootstrap installer"
```

---

### Task 11: A real two-harness smoke test

Automated tests never touch real Orca and never touch a real harness. This task closes that gap, and is the **only way** to prove Cursor's wake path.

**Files:**
- Create: `tests/smoke/pty-drive.py`
- Create: `docs/verification/2026-08-31-smoke-install.md`

**Interfaces:**
- Consumes: `vizier install`, `/vizier`, both wake hooks
- Produces: an evidence file recording the exact app version and harness version checked

- [ ] **Step 1: Write `tests/smoke/pty-drive.py`**

```python
#!/usr/bin/env python3
"""Drives an interactive harness session through a pty to check the wake path.

Headless doesn't work here: cursor-agent -p runs no hooks at all
(docs/verification/2026-08-31-plugin-wake.md). And typing text plus Enter
must be SEPARATE -- sending them together makes Cursor receive the text but
not submit it.

WARNING ABOUT LOCAL ECHO: the pty echoes back exactly what we write into it,
so `--expect` would also match the `--send` text itself. Measured: running
the driver against `sleep 30` -- a program that never reads stdin at all --
with `--send hello --expect hello` still PASSES. So `--expect` MUST be a
string GENERATED BY the agent, not the string we sent it. For the Cursor
smoke test, that's `vizier:` inside the hook's follow-up.

Total run time is --wait PLUS roughly 10-11 seconds: 8s waiting for the TUI
to come up, 2s pumping after sending, and up to ~1.2s shutting down when the
child resists signals (0.2s Ctrl-C + 0.5s waiting for SIGTERM + 0.5s waiting
for SIGKILL). Every normal step has an upper bound.

Usage: pty-drive.py <cmd> [args...] --send <text> --expect <marker> --wait <sec>
"""
import os, pty, re, select, signal, struct, sys, termios, fcntl, time

ANSI = re.compile(rb'\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b[()][B0]|\x1b[=>]')

def main():
    argv = sys.argv[1:]
    send = expect = None
    wait = 120
    cmd = []
    i = 0
    while i < len(argv):
        if argv[i] == "--send": send = argv[i+1]; i += 2
        elif argv[i] == "--expect": expect = argv[i+1]; i += 2
        elif argv[i] == "--wait": wait = int(argv[i+1]); i += 2
        else: cmd.append(argv[i]); i += 1
    if not cmd or send is None or expect is None:
        print(__doc__); return 2

    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(TERM="xterm-256color", LINES="40", COLUMNS="120")
        os.execvp(cmd[0], cmd)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))

    # SIGTERM must become an exception, otherwise `finally` does NOT run.
    # Measured: pressing Ctrl-C (SIGINT) cleans up the child properly, but
    # `kill` (SIGTERM) kills Python immediately and the child agent SURVIVES
    # -- exactly the path a wrapper with a timeout would use. Registered
    # after the fork so it only applies to the parent process; the child has
    # already execvp'd and had its handler reset to the default.
    def _on_term(_signum, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, _on_term)

    buf = b""
    def pump(sec):
        nonlocal buf
        end = time.time() + sec
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.3)
            if not r: continue
            try: d = os.read(fd, 65536)
            except OSError: return False
            if not d: return False
            buf += d
            if expect.encode() in ANSI.sub(b'', buf):
                return "found"
        return True

    def shutdown():
        # Ctrl-C through the pty first (the polite way to ask a TUI), then
        # escalate through signals and REAP. Without the reap + SIGKILL step,
        # an agent that installs its own TERM/INT/HUP handler would survive
        # and become an orphan -- reproduced, and exactly the kind of process
        # leak this project already fixed once in the wake library. A driver
        # that leaves a live cursor-agent behind on every call is not
        # something that can be handed to the captain.
        try:
            os.write(fd, b"\x03"); time.sleep(0.2); os.write(fd, b"\x03")
        except OSError:
            pass
        for sig, grace in ((signal.SIGTERM, 0.5), (signal.SIGKILL, 0.5)):
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                break
            deadline = time.time() + grace
            while time.time() < deadline:
                try:
                    done, _ = os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    return
                if done == pid:
                    return
                time.sleep(0.05)
        try:
            os.waitpid(pid, 0)
        except (ChildProcessError, OSError):
            pass

    # try/finally, NOT just try/except OSError. Catching only OSError still
    # leaves every other exception unhandled -- and the most likely one is
    # KeyboardInterrupt: the captain pressing Ctrl-C on the very smoke run
    # in progress. In that case `shutdown()` wouldn't run and the agent would
    # leak, exactly the hole just closed above. `finally` covers every exit path.
    found = None
    write_err = None
    try:
        pump(8)                                  # let the TUI finish coming up
        # The write can raise OSError if the child has already died (Errno 5 on a pty).
        os.write(fd, send.encode()); pump(2)     # type the text
        os.write(fd, b"\r")                      # Enter, SEPARATELY
        found = pump(wait)
    except OSError as e:
        write_err = e
    finally:
        shutdown()
        try:
            os.close(fd)
        except OSError:
            pass

    if write_err is not None:
        print(f"FAIL: could not write to the pty ({write_err})", file=sys.stderr)
        return 1

    if found == "found":
        print(f"PASS: saw {expect!r}"); return 0
    print(f"FAIL: did not see {expect!r} within {wait}s", file=sys.stderr)
    sys.stderr.write(ANSI.sub(b'', buf)[-2000:].decode('utf-8', 'replace'))
    return 1

if __name__ == "__main__":
    raise SystemExit(main())
```

> **The driver's own verification must NOT use an `--expect` identical to `--send`.** The pty
> echoes back exactly the input, so a test like `pty-drive.py cat --send hello --expect hello`
> PASSES even against `sleep 30` -- a program that never reads stdin at all. A correct test must
> catch the child TRANSFORMING the input, for example:
>
> ```bash
> python3 tests/smoke/pty-drive.py tr 'a-z' 'A-Z' --send "hello" --expect "HELLO" --wait 5
> ```
>
> `HELLO` only appears if the child process genuinely read the input and wrote it back out --
> local echo doesn't produce it. Add one negative control: the same command with `sleep 5` must
> make the child FAIL.

- [ ] **Step 2: Run the Claude Code smoke test by hand**

```bash
vizier install --harness claude
vizier doctor          # must print "doctor: ok"
# Open a new session, type /vizier, then create a fake request so the hook has something to wait on:
cat > ~/.vizier/requests/smoke.md <<'EOF'
---
run_id: <a real run id from `orca orchestration run-create --objective smoke`>
project: smoke
host: local
status: open
opened: 2026-08-31
---
smoke test
EOF
```

From another terminal, send a message into that Run and see whether the Claude Code session wakes on its own.
Expected: the idle session runs a new turn on its own, carrying the line `vizier: worker_done run=...`.

- [ ] **Step 3: Run the Cursor smoke test via pty**

```bash
vizier install --harness cursor
python3 tests/smoke/pty-drive.py cursor-agent --trust \
  --send "hi" --expect "vizier:" --wait 90
```

Expected: `PASS: saw 'vizier:'` -- meaning the stop hook parked, waited on the mailbox, and
Cursor ran a new turn carrying the follow-up.

- [ ] **Step 4: Record the evidence**

Create `docs/verification/2026-08-31-smoke-install.md` recording: the Orca app version (`orca
status --json`), the Claude Code version (`claude --version`), the Cursor version **taken from the
TUI line** rather than `--version`, the commands run, and the result of each step. Also record
what **could not** be checked.

- [ ] **Step 5: Commit**

```bash
git add tests/smoke/pty-drive.py docs/verification/2026-08-31-smoke-install.md
git commit -m "test: add the interactive smoke driver and record its evidence"
```

---

## What Plan 2 will do (out of scope for this plan)

The request lifecycle and `requests/<slug>.md`; the `routing` skill (host discovery, eligibility,
choosing a host once per request); the `supervise` skill (mailbox batches, process-before-ack
ordering, release/reuse of terminals); the `brief` skill (4 layers); the `delivery` skill (mode,
delivery contract, ask-user policy); extending `fake-orca` for
`run-create`/`task-create`/`worker-start`/`worker-release`.

Plan 1 deliberately lays the ground for them: `vizier_open_run_ids` already reads exactly the
frontmatter that Plan 2 will write, and `skills/identity/SKILL.md` already states the hard rules
that Plan 2's skill must follow.
