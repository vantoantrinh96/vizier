#!/usr/bin/env bash
# The mailbox contract, pinned to REAL captured responses.
#
# This file exists because the shape of an `orca orchestration check --json`
# response previously had no owner and no fixture: two callers each read it
# their own way, both from imagination, and both were green. Every assertion
# here is either read from a file captured off Orca 1.4.193 on 2026-09-02
# (tests/fixtures/) or is a case those captures prove cannot be distinguished
# any other way.
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-mailbox-lib.sh"

F="$VIZIER_TEST_REPO/tests/fixtures"
delivery=$(cat "$F/check-delivery.json")
timeout=$(cat "$F/check-timeout.json")
peek_empty=$(cat "$F/check-peek-empty.json")
err=$(cat "$F/check-error.json")

# --- the fixtures are what they claim to be -------------------------------
# Asserted first, so a fixture quietly replaced by something else fails HERE
# rather than making every assertion below vacuous.
assert_eq "$(printf '%s' "$delivery" | jq -r '.result.messages | length')" "3" "the delivery fixture carries three messages"
assert_eq "$(printf '%s' "$delivery" | jq -r '.result.deliveryId')" "delivery_aad01f2a4ab7" "and a real delivery id"
assert_eq "$(printf '%s' "$err" | jq -r '.error.code')" "consumer_fenced" "the error fixture is a real consumer_fenced"
assert_eq "$(printf '%s' "$timeout" | jq -r '.result.timedOut')" "true" "the timeout fixture really timed out"

# --- ONE PRETTY-PRINTED ENVELOPE, NEVER JSON LINES ------------------------
# The original bug, stated as an assertion: read the real response one line at
# a time and it yields no messages at all, because pretty-printing puts one
# FIELD on a line, not one message.
as_lines=$(printf '%s\n' "$delivery" | jq -rc 'select(.type? != null)' 2>/dev/null | grep -c . || true)
assert_eq "$as_lines" "0" "read as JSON lines, a real 3-message response yields ZERO messages"
assert_eq "$(vizier_mailbox_messages "$delivery" | grep -c .)" "3" "read as an envelope, it yields all three"
# and each extracted message must be ONE line, or every caller's `while read`
# loop reintroduces the same bug one layer in
assert_eq "$(vizier_mailbox_messages "$delivery" | wc -l | tr -d ' ')" "3" "each message is exactly one compact line"

# --- readable vs unreadable, which is NOT the same as empty vs non-empty --
vizier_mailbox_ok "$delivery";   assert_rc $? 0 "a delivery envelope is readable"
vizier_mailbox_ok "$timeout";    assert_rc $? 0 "a timed-out envelope is readable -- it is EMPTY, not broken"
vizier_mailbox_ok "$peek_empty"; assert_rc $? 0 "an empty peek is readable too"
vizier_mailbox_ok "$err";        assert_rc $? 1 "an ok:false envelope is NOT readable"
vizier_mailbox_ok "";            assert_rc $? 1 "no output at all is not readable -- orca printing nothing is a failure"
vizier_mailbox_ok "not json";    assert_rc $? 1 "neither is a non-JSON response"
vizier_mailbox_ok '{"ok":true,"result":{}}'; assert_rc $? 1 \
  "nor an ok envelope whose result has no messages array -- shape drift must not read as an empty mailbox"
assert_eq "$(vizier_mailbox_error_code "$err")" "consumer_fenced" "the error code is reported, not swallowed"

# --- the ack handle -------------------------------------------------------
assert_eq "$(vizier_mailbox_delivery_id "$delivery")" "delivery_aad01f2a4ab7" "the delivery id is the batch's ack handle"
# EMPTY IS THE EXPECTED ANSWER FOR A PEEK. `--peek` and `--all` create no
# delivery, so a peeked batch cannot be acked at all -- measured: `--ack` on
# anything else is refused with `stale_delivery`.
assert_eq "$(vizier_mailbox_delivery_id "$peek_empty")" "" "a peek response carries no delivery id"
assert_eq "$(vizier_mailbox_delivery_id "$timeout")" "" "a timed-out wait delivered nothing, so it has no delivery id"

# --- the payload is a JSON STRING -----------------------------------------
# The single field access that broke everything: the parser read
# `.dispatch_id` at the top level, which has never existed.
rejection=$(vizier_mailbox_messages "$delivery" | jq -c 'select(.type == "worker_done")')
assert_eq "$(printf '%s' "$rejection" | jq -r '.payload | type')" "string" "payload really is a STRING, not an object"
assert_eq "$(printf '%s' "$rejection" | jq -r '.dispatch_id // "absent"')" "absent" "there is no top-level dispatch_id"
assert_eq "$(printf '%s' "$rejection" | jq -r '.delivery_id // "absent"')" "absent" "and no top-level delivery_id"
assert_eq "$(printf '%s' "$rejection" | jq -r '.outcome // "absent"')" "absent" "and no top-level outcome"
assert_eq "$(vizier_mailbox_payload_field "$rejection" dispatchId)" "dispatch-probe" "the dispatch id comes out of the payload"
assert_eq "$(vizier_mailbox_payload_field "$rejection" outcome)" "succeeded" "so does the outcome"
assert_eq "$(vizier_mailbox_payload_field "$rejection" taskId)" "task_7a0a7aaf6d0f" "and the task id"

# A nested object is re-serialised, so PRESENCE tests work the same way for
# it as for a plain string -- this is how the rejection gate detects a notice.
assert_contains "$(vizier_mailbox_payload_field "$rejection" _orcaLifecycleRejection)" "unknown_dispatch" \
  "a nested object comes back as JSON text, so presence is testable"

# Every way a payload can fail must yield EMPTY, never a value and never an
# abort under `set -u`.
status_msg=$(vizier_mailbox_messages "$delivery" | jq -c 'select(.type == "status")' | head -1)
assert_eq "$(printf '%s' "$status_msg" | jq -r '.payload | type')" "null" "a real status message has a null payload"
assert_eq "$(vizier_mailbox_payload_field "$status_msg" dispatchId)" "" "a null payload yields nothing"
assert_eq "$(vizier_mailbox_payload_field "$rejection" nosuchfield)" "" "an absent key yields nothing"
assert_eq "$(vizier_mailbox_payload_field '{"payload":"not json"}' dispatchId)" "" "a payload that is not JSON yields nothing"
assert_eq "$(vizier_mailbox_payload_field '{"payload":"[1,2]"}' dispatchId)" "" "a payload that parses to a non-object yields nothing"
assert_eq "$(vizier_mailbox_payload_field '{"payload":"{\"dispatchId\":null}"}' dispatchId)" "" "an explicitly null value yields nothing"
assert_eq "$(vizier_mailbox_payload_field '{}' dispatchId)" "" "no payload key at all yields nothing"
# whitespace must survive intact -- the staleness check in vizier_msg_disposition
# distinguishes "   " from "", and a trimming extractor would erase that
assert_eq "$(vizier_mailbox_payload_field '{"payload":"{\"dispatchId\":\"  \"}"}' dispatchId)" "  " \
  "a whitespace-only value is preserved exactly, so the stale check can still see it"

# --- keepalives ------------------------------------------------------------
# `check --help`: --wait "Emits JSON keepalive lines to stderr ... Filter with
# jq select(._keepalive|not)". They go to STDERR, so they cannot reach a
# caller that keeps the streams apart -- this filter is for one that merges
# them, and it is the only place a keepalive can be tested at all.
mixed='{"ok":true,"result":{"messages":[{"_keepalive":true},{"id":"m1","type":"worker_done"}]}}'
assert_eq "$(vizier_mailbox_messages "$mixed" | grep -c .)" "1" "a keepalive inside the messages is dropped"
assert_eq "$(vizier_mailbox_messages "$mixed" | jq -r '.id')" "m1" "and the real message survives"

# --- empty is empty, and never an error -----------------------------------
assert_eq "$(vizier_mailbox_messages "$timeout" | grep -c . || true)" "0" "a timed-out wait yields no messages"
assert_eq "$(vizier_mailbox_messages "$err" | grep -c . || true)" "0" "and neither does an error envelope"

vizier_test_teardown
vizier_test_report
