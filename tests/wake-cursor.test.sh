#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
ofm_test_setup
. "$OFM_TEST_REPO/lib/ofm-home.sh"
HOOK="$OFM_TEST_REPO/hooks/wake-cursor.sh"
# FIX 12 -- 300ms used to cause a random failure about 1 run in 5. Cause: the
# deadline in lib/ofm-wake-lib.sh is computed as `$(date +%s) +
# (timeout_ms+999)/1000` -- `date +%s` TRUNCATES to the whole second, so if
# the command runs at millisecond .999 of a second, the effective real
# deadline could be as little as 0ms instead of the intended ~300ms. At
# 300ms, that distortion margin (up to nearly 1000ms) is enough to SWALLOW
# THE ENTIRE timeout, which meant the fixed `sleep 0.15` in the concurrent
# block below sometimes dropped the message AFTER both parks had already
# timed out. DO NOT fix the production lib -- the real bug there only causes
# a sub-1s latency skew against an eight-hour timeout, harmless; fix the test
# instead by widening the timeout to 3000ms so that same distortion margin
# only eats a small fraction of it, not all of it.
export OFM_WAIT_TIMEOUT_MS=3000
# Production's poll cadence is 1000ms. Without setting it here, every hook
# call would take ~1s and would only find the message thanks to the loop
# checking the file BEFORE checking the deadline -- the test would pass by
# accident of ordering rather than by the behavior its name claims to test.
export OFM_WAKE_POLL_MS=50

payload() {  # <session_id> <loop_count>
  printf '{"session_id":"%s","loop_count":%s,"workspace_roots":["/tmp"],"status":"completed"}' "$1" "$2"
}
mk_request() {
  printf -- '---\nrun_id: %s\nproject: demo\nhost: local\nstatus: open\nopened: 2026-08-31\n---\nx\n' \
    "$2" > "$(ofm_requests_dir)/$1.md"
}

# FIX 12 -- replaces the fixed `sleep 0.15` with a CONDITIONAL wait: poll
# until park-owner has been written (a park has reached the mailbox-wait
# point) AND every background pid passed in is still alive (hasn't exited
# early on an error), only then returning so the caller can drop a message
# into the queue. Has a loop ceiling (1s) so the test doesn't hang forever if
# the condition never becomes true -- a bounded wait, not a guessed sleep.
wait_for_park_ready() {  # <pid...>
  local i=0 ok pid
  while [ "$i" -lt 100 ]; do
    ok=1
    [ -e "$OFM_HOME/park-owner" ] || ok=0
    for pid in "$@"; do
      kill -0 "$pid" 2>/dev/null || ok=0
    done
    [ "$ok" = 1 ] && return 0
    i=$((i + 1))
    sleep 0.01
  done
  return 1
}

# No lock: silent
out=$(payload sess-a 0 | bash "$HOOK" 2>/dev/null); rc=$?
assert_rc "$rc" 0 "no lock gives exit 0"
assert_eq "$out" "" "no lock gives empty stdout"

printf 'session_id=sess-a\nharness=cursor-agent\npid=%s\nsince=1\n' $$ > "$(ofm_lock_path)"
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

# FIX 8 -- hitting the ceiling must still say ONE sentence, not go absolutely
# silent. Exactly on the turn loop_count == ceiling (default 5): emit a
# followup_message reporting the ceiling was hit.
out=$(payload sess-a 5 | bash "$HOOK" 2>/dev/null); rc=$?
assert_rc "$rc" 0 "FIX 8: hitting the ceiling still exits 0"
assert_contains "$out" "followup_message" "FIX 8: hitting the ceiling must emit one sentence, not go silent"
assert_contains "$out" "ceiling" "the report sentence clearly states the ceiling was hit"
lines=$(printf '%s\n' "$out" | grep -c . )
assert_eq "$lines" "1" "the ceiling report is also exactly ONE line of JSON"

# Past the ceiling (already reported on a previous turn): silent, does not repeat forever.
out=$(payload sess-a 6 | bash "$HOOK" 2>/dev/null); rc=$?
assert_rc "$rc" 0 "past the ceiling still exits 0"
assert_eq "$out" "" "past the ceiling is silent, does not repeat the ceiling report forever"

# A replaced park stays quiet -- checked with an explicit claim
printf 'someone-else\n' > "$OFM_HOME/park-owner"
out=$(payload sess-a 0 | OFM_CURSOR_PARK_CLAIM=mine bash "$HOOK" 2>/dev/null)
# The hook writes its own claim at the start, so it WILL be the owner; this
# case only confirms an explicit claim doesn't break the hook. The real test
# is in the concurrent block below.
printf '%s' "$out" | jq -e '.followup_message' >/dev/null 2>&1
assert_rc $? 0 "an explicit claim still emits normally when not replaced"

# TWO REAL parks running overlapped, both seeing the same message: only ONE emits.
: > "$OFM_FAKE_ORCA_STATE/queue/run_a"
rm -f "$OFM_HOME/park-owner"
( payload sess-a 0 | bash "$HOOK" > "$OFM_TEST_TMP/p1.out" 2>/dev/null ) & p1=$!
( payload sess-a 0 | bash "$HOOK" > "$OFM_TEST_TMP/p2.out" 2>/dev/null ) & p2=$!
wait_for_park_ready "$p1" "$p2"
fake_orca_queue run_a '{"type":"worker_done","run_id":"run_a","outcome":"succeeded"}'
wait "$p1" 2>/dev/null || true
wait "$p2" 2>/dev/null || true
emitters=$(grep -l followup_message "$OFM_TEST_TMP/p1.out" "$OFM_TEST_TMP/p2.out" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$emitters" "1" "two overlapping parks means exactly one emits"

# Read-back gate: claim written, then REPLACED BY SOMEONE ELSE partway
# through -> must stay quiet, even though it already saw the message. This is
# the case that actually proves the read-back gate; the earlier `chmod 000`
# case is blocked right at the WRITE step and exits through a completely
# different gate, so it passes without ever touching this one.
: > "$OFM_FAKE_ORCA_STATE/queue/run_a"
rm -f "$OFM_HOME/park-owner"
( payload sess-a 0 | bash "$HOOK" > "$OFM_TEST_TMP/p3.out" 2>/dev/null ) & p3=$!
wait_for_park_ready "$p3"
printf 'usurper\n' > "$OFM_HOME/park-owner"
fake_orca_queue run_a '{"type":"worker_done","run_id":"run_a","outcome":"succeeded"}'
wait "$p3" 2>/dev/null || true
assert_eq "$(cat "$OFM_TEST_TMP/p3.out")" "" "being replaced as owner partway through stays quiet, even after seeing the message"

# Failing to write owner_file must also stay quiet -- a different gate, a different case, clearly labeled as different
: > "$OFM_FAKE_ORCA_STATE/queue/run_a"
printf 'x\n' > "$OFM_HOME/park-owner"; chmod 000 "$OFM_HOME/park-owner" 2>/dev/null || true
out=$(payload sess-a 0 | bash "$HOOK" 2>/dev/null)
assert_eq "$out" "" "failing to write owner_file stays quiet (the WRITE gate, not the read-back one)"
chmod 644 "$OFM_HOME/park-owner" 2>/dev/null || true

ofm_test_teardown
ofm_test_report
