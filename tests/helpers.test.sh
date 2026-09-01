#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"

ofm_test_setup

assert_contains "$OFM_HOME" "$OFM_TEST_TMP" "OFM_HOME is inside the temp directory"
[ -d "$OFM_HOME" ]; assert_rc $? 0 "OFM_HOME was created"

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

ofm_test_teardown
ofm_test_report
