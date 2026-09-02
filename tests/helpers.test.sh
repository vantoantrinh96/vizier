#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"

vizier_test_setup

assert_contains "$VIZIER_HOME" "$VIZIER_TEST_TMP" "VIZIER_HOME is inside the temp directory"
[ -d "$VIZIER_HOME" ]; assert_rc $? 0 "VIZIER_HOME was created"

# fake-orca must come before the real orca on PATH
resolved=$(command -v orca)
assert_contains "$resolved" "fake-orca" "orca resolves to fake-orca"

# An empty check returns a real EMPTY ENVELOPE, not nothing. "No output" and
# "no messages" are different answers -- no output means orca failed -- and a
# fake that conflated them let the supervision plan treat a failed read as a
# quiet mailbox.
# `check` is FENCED to the bound Run -- bind first, exactly as supervise does.
orca orchestration run-use --id run_a --json >/dev/null
out=$(orca orchestration check --run run_a --peek --json); rc=$?
assert_rc "$rc" 0 "empty check returns rc 0"
assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "true" "empty check still returns an ok envelope"
assert_eq "$(printf '%s' "$out" | jq -r '.result.messages | length')" "0" "with an empty messages array"

# queue then check returns that message inside the envelope
fake_orca_message run_a msg_h1 worker_done "PR opened" "$(fake_orca_payload dispatch-1)"
out=$(orca orchestration check --run run_a --peek --json)
assert_eq "$(printf '%s' "$out" | jq -r '.result.messages[0].type')" "worker_done" \
  "check returns the queued message, under result.messages"

# every call gets logged
assert_contains "$(fake_orca_calls)" "orchestration check --run run_a" "the call was logged"

vizier_test_teardown
vizier_test_report
