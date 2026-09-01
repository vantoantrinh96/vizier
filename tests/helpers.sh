# tests/helpers.sh -- isolated test environment. Source it, don't run it.
# Every test runs inside a temporary OFM_HOME and a PATH with fake-orca
# ahead of the real one, so no test ever touches the captain's real home or
# real Orca.
OFM_TEST_FAILURES=0
OFM_TEST_ASSERTS=0

ofm_test_setup() {
  OFM_TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ofm-test.XXXXXX") || exit 1
  export OFM_TEST_TMP
  export OFM_HOME="$OFM_TEST_TMP/home"
  mkdir -p "$OFM_HOME/requests" "$OFM_HOME/projects"
  # ABSOLUTE RULE: no test may read/write the REAL ~/.claude/skills or
  # ~/.cursor/hooks.json. Set the default HERE, not in each test file, so
  # that a doctor/install call running BEFORE a test file exports its own
  # variable can never fall back to the real $HOME.
  export OFM_CLAUDE_SKILLS_DIR="$OFM_TEST_TMP/claude-skills"
  export OFM_CURSOR_HOOKS_JSON="$OFM_TEST_TMP/cursor-hooks.json"
  # This test runner itself COULD be running under a child session/subagent
  # (the variable has actually been observed set in this very project's CI)
  # -- if that leaked through, every activate test would eat FIX 5's
  # refusal by mistake while testing a completely different branch. The
  # test environment must be clear of the real harness variable of the
  # PROCESS RUNNING THE TESTS, not of the scenario under test.
  unset CLAUDE_CODE_CHILD_SESSION
  export OFM_FAKE_ORCA_STATE="$OFM_TEST_TMP/fake-orca"
  mkdir -p "$OFM_FAKE_ORCA_STATE/queue"
  : > "$OFM_FAKE_ORCA_STATE/calls.log"
  OFM_TEST_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  export OFM_TEST_REPO
  export PATH="$OFM_TEST_REPO/tests/fake-orca:$PATH"
}

ofm_test_teardown() {
  [ -n "${OFM_TEST_TMP:-}" ] && rm -rf "$OFM_TEST_TMP"
}

fake_orca_queue() {  # <run_id> <json_line>
  printf '%s\n' "$2" >> "$OFM_FAKE_ORCA_STATE/queue/$1"
}

fake_orca_calls() { cat "$OFM_FAKE_ORCA_STATE/calls.log" 2>/dev/null; }

_ofm_fail() {
  OFM_TEST_FAILURES=$((OFM_TEST_FAILURES+1))
  printf 'FAIL: %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2" >&2
}

assert_eq() {  # <got> <want> <label>
  OFM_TEST_ASSERTS=$((OFM_TEST_ASSERTS+1))
  [ "$1" = "$2" ] || _ofm_fail "$1" "$2" "$3"
}

assert_rc() {  # <got_rc> <want_rc> <label>
  OFM_TEST_ASSERTS=$((OFM_TEST_ASSERTS+1))
  [ "$1" = "$2" ] || _ofm_fail "rc=$1" "rc=$2" "$3"
}

assert_contains() {  # <haystack> <needle> <label>
  OFM_TEST_ASSERTS=$((OFM_TEST_ASSERTS+1))
  case "$1" in *"$2"*) ;; *) _ofm_fail "$1" "contains '$2'" "$3" ;; esac
}

ofm_test_report() {
  if [ "$OFM_TEST_FAILURES" -eq 0 ]; then
    printf 'ok: %s asserts passed (%s)\n' "$OFM_TEST_ASSERTS" "$(basename "$0")"
    exit 0
  fi
  printf 'FAILED: %s of %s asserts (%s)\n' "$OFM_TEST_FAILURES" "$OFM_TEST_ASSERTS" "$(basename "$0")" >&2
  exit 1
}
