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
  # ABSOLUTE RULE: no test may read/write the REAL ~/.claude/skills or
  # ~/.cursor/hooks.json. Set the default HERE, not in each test file, so
  # that a doctor/install call running BEFORE a test file exports its own
  # variable can never fall back to the real $HOME.
  export VIZIER_CLAUDE_SKILLS_DIR="$VIZIER_TEST_TMP/claude-skills"
  export VIZIER_CURSOR_HOOKS_JSON="$VIZIER_TEST_TMP/cursor-hooks.json"
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
