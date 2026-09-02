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
  # ABSOLUTE RULE: no test may read/write the REAL ~/.claude/skills,
  # ~/.cursor/hooks.json, or ~/.local/bin/vizier. bin/vizier resolves all
  # three from env vars that default to those real paths, and any call made
  # before a test file exports its own value reaches the real one. Set ALL
  # FOUR location defaults HERE, not in each test file: this suite already
  # deleted the captain's real ~/.local/bin/vizier symlink because
  # cli.test.sh ran `uninstall` several lines before it got around to
  # exporting VIZIER_BIN_DIR, and cmd_uninstall fell back to the real
  # default in between. A test that forgets one of these damages the
  # machine it runs on, not just the test run -- so this belongs in the
  # harness, where no individual test can forget it, not repeated per test
  # where someone will eventually "simplify" it back out.
  export VIZIER_CLAUDE_SKILLS_DIR="$VIZIER_TEST_TMP/claude-skills"
  export VIZIER_CURSOR_HOOKS_JSON="$VIZIER_TEST_TMP/cursor-hooks.json"
  export VIZIER_BIN_DIR="$VIZIER_TEST_TMP/bin"
  mkdir -p "$VIZIER_BIN_DIR"
  # This test runner itself COULD be running under a child session/subagent
  # (the variable has actually been observed set in this very project's CI)
  # -- if that leaked through, every activate test would eat FIX 5's
  # refusal by mistake while testing a completely different branch. The
  # test environment must be clear of the real harness variable of the
  # PROCESS RUNNING THE TESTS, not of the scenario under test.
  unset CLAUDE_CODE_CHILD_SESSION
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

fake_orca_queue() {  # <run_id> <json_line> -- raw escape hatch, prefer fake_orca_message
  printf '%s\n' "$2" >> "$VIZIER_FAKE_ORCA_STATE/queue/$1"
}

# THE MESSAGE SHAPE, COPIED FROM A REAL RESPONSE, IN ONE PLACE.
# Every field name, and the fact that `payload` is a JSON *string* rather than
# an object, comes from tests/fixtures/check-delivery.json -- a real
# `orca orchestration check` response captured from Orca 1.4.193 on
# 2026-09-02. Tests used to hand-write `{"delivery_id":…,"dispatch_id":…}`
# message literals; none of those field names has ever existed, and because
# the parser was written from the same imagination the suite stayed green
# while supervision was completely inert against the real app. Hand-writing a
# message literal in a test is what made that possible, so tests build them
# here now, from the captured shape.
fake_orca_payload() {  # <dispatch_id> [<outcome>] [<extra_json_object>]
  # `payload` is a STRING containing JSON, so `-r` (raw) is required: the
  # value handed to fake_orca_message must be the JSON *text*, which that
  # function then encodes as a string field. Encoding it as an object here
  # would reproduce the original bug inside the fixture builder itself.
  #
  # The default `{}` goes through a variable and NOT through
  # `${3:-{}}` -- bash miscounts the braces in a `${VAR:-...}` default that
  # contains any, and silently produces corrupt JSON. tests/fake-orca/orca
  # carries the same warning over the same mistake.
  local extra="${3:-}"
  [ -n "$extra" ] || extra='{}'
  jq -rn --arg d "$1" --arg o "${2:-succeeded}" --argjson x "$extra" \
    '({taskId:"task_fake", dispatchId:$d, outcome:$o} + $x) | tojson'
}

fake_orca_message_json() {  # <run_id> <msg_id> <type> [<body>] [<payload_json_string>] [<sequence>]
  # Prints one message. `fake_orca_message` queues it; disposition tests that
  # need a single message and no mailbox use this directly, so that BOTH kinds
  # of test are pinned to the same captured shape and neither can drift.
  local run="$1" id="$2" type="$3" body="${4:-}" payload="${5:-}" seq="${6:-1}"
  jq -c --arg id "$id" --arg run "$run" --arg t "$type" --arg b "$body" \
     --arg p "$payload" --argjson seq "$seq" -n \
    '{id:$id, run_id:$run, delivery_contract:"current_delivery",
      from_handle:"term_fake", to_handle:("run:" + $run),
      subject:($b[0:40]), body:$b, type:$t, priority:"normal", thread_id:null,
      payload:(if $p == "" then null else $p end),
      read:0, sequence:$seq,
      created_at:"2026-09-02T00:00:00Z", delivered_at:null,
      sender_pane_key:"fake-pane"}'
}

fake_orca_message() {  # <run_id> <msg_id> <type> [<body>] [<payload_json_string>]
  local run="$1" id="$2" type="$3" body="${4:-}" payload="${5:-}"
  local seq qf="$VIZIER_FAKE_ORCA_STATE/queue/$run"
  # Guarded with `[ -f ]` rather than `wc -l < "$qf" 2>/dev/null`: the shell
  # performs the input redirection BEFORE applying `2>/dev/null`, so a missing
  # file -- which is simply the first message on a run -- printed a bare
  # `No such file or directory` onto the test run's stderr.
  if [ -f "$qf" ]; then seq=$(( $(wc -l < "$qf") + 1 )); else seq=1; fi
  fake_orca_message_json "$run" "$id" "$type" "$body" "$payload" "$seq" >> "$qf"
}

fake_orca_calls() { cat "$VIZIER_FAKE_ORCA_STATE/calls.log" 2>/dev/null; }

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

fake_orca_seed_setup() {  # <projectId> <hostId> <setupState> [<path>]
  # The path DEFAULTS per host rather than being one shared literal: brief
  # derives `--repo path:<...>` from the setup record for a specific project
  # on a specific host, and if every seeded setup carried the same path a test
  # that resolved the wrong host -- or no host at all -- would still assert the
  # right answer.
  jq -cn --arg p "$1" --arg h "$2" --arg s "$3" --arg path "${4:-/seeded/$2}" \
    '{id:("setup-"+$h),projectId:$p,hostId:$h,setupState:$s,kind:"git",
      setupMethod:"imported-existing-folder",displayName:"seeded",path:$path}' \
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

fake_orca_seed_terminal() {  # <handle> [<title>]
  jq -cn --arg h "$1" --arg t "${2:-~}" '{handle:$h,title:$t}' \
    >> "$VIZIER_FAKE_ORCA_STATE/terminals"
}

fake_orca_seed_worker() {  # <dispatch_id> <terminal_handle>
  mkdir -p "$VIZIER_FAKE_ORCA_STATE/workers"
  printf '%s\n' "$2" > "$VIZIER_FAKE_ORCA_STATE/workers/$1"
}

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
