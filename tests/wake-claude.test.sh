#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
ofm_test_setup
. "$OFM_TEST_REPO/lib/ofm-home.sh"
HOOK="$OFM_TEST_REPO/hooks/wake-claude.sh"
export OFM_WAIT_TIMEOUT_MS=300

payload() { printf '{"session_id":"%s","cwd":"/tmp","hook_event_name":"Stop"}' "$1"; }
payload_active() {  # <session_id> -- stop_hook_active:true, used for the FIX 1 case
  printf '{"session_id":"%s","cwd":"/tmp","hook_event_name":"Stop","stop_hook_active":true}' "$1"
}
mk_request() {
  printf -- '---\nrun_id: %s\nproject: demo\nhost: local\nstatus: %s\nopened: 2026-08-31\n---\nx\n' \
    "$2" "$3" > "$(ofm_requests_dir)/$1.md"
}

# No lock: absolutely silent. This is the gate that protects every other session on the machine.
out=$(payload sess-a | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 0 "no lock gives exit 0"
assert_eq "$out" "" "no lock prints nothing"
assert_eq "$(fake_orca_calls)" "" "no lock calls orca zero times"

# A different session's lock: still silent
printf 'session_id=sess-other\nharness=claude\npid=%s\nsince=1\n' $$ > "$(ofm_lock_path)"
out=$(payload sess-a | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 0 "a mismatched session_id gives exit 0"
assert_eq "$(fake_orca_calls)" "" "a mismatched session_id calls orca zero times"

# The right owner but no open request: exit 0, still no orca call
printf 'session_id=sess-a\nharness=claude\npid=%s\nsince=1\n' $$ > "$(ofm_lock_path)"
out=$(payload sess-a | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 0 "no open request gives exit 0"
assert_eq "$(fake_orca_calls)" "" "no open request calls orca zero times"

# The right owner, an open request, no message: FIX 2 -- a timeout must now
# exit 2 (re-arm), NOT exit 0. exit 0 here means supervision dies permanently,
# because an idle session generates no Stop event on its own to re-arm the wait.
mk_request one run_a open
out=$(payload sess-a | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 2 "FIX 2: a timeout exits 2 to re-arm, not exit 0"
assert_contains "$out" "re-arm" "stderr clearly states the reason is re-arm"
assert_contains "$(fake_orca_calls)" "--run run_a" "waited on the right run"

# A message, stop_hook_active:false (the FIRST report): exit 2, prints a
# summary to STDERR, and records that summary into last-wake -- this is the
# FIX 1 record used to compare identity on later turns, not the
# stop_hook_active flag alone.
fake_orca_queue run_a '{"type":"worker_done","run_id":"run_a","outcome":"succeeded"}'
err=$(payload sess-a | bash "$HOOK" 2>&1 >/dev/null); rc=$?
assert_rc "$rc" 2 "the first report (stop_hook_active=false) exits 2"
assert_contains "$err" "worker_done" "stderr carries the summary"
stdout=$(payload sess-a | bash "$HOOK" 2>/dev/null);
assert_eq "$stdout" "" "nothing is printed to stdout"
assert_contains "$(cat "$(ofm_home)/last-wake" 2>/dev/null)" "worker_done" \
  "the first report must record the summary into last-wake for later identity comparison"

# FIX 1 -- the SAME message (--peek doesn't ack, so it's still there) AND
# stop_hook_active:true (this turn was caused by the hook itself) AND a
# summary identical to the last-wake just recorded above: exactly the
# "already reported, still unacked" case -- the ceiling that blocks the
# infinite loop. Must exit 0, NOT exit 2 -- otherwise every wake would spawn
# another wake forever. It must still say one thing to stderr before going
# quiet, not go absolutely silent. (Disconfirming check: reverting to
# comparing the flag alone still gives this same exit 0 -- this case does
# NOT distinguish the old version from the new one; the case below does.)
err=$(payload_active sess-a | bash "$HOOK" 2>&1 >/dev/null); rc=$?
assert_rc "$rc" 0 "FIX 1: the same message with stop_hook_active=true exits 0, no infinite repeat"
assert_contains "$err" "ceiling" "stderr clearly states the ceiling was hit, not absolute silence"
assert_contains "$err" "not acked" "stderr clearly states the message is still not acked"
stdout=$(payload_active sess-a | bash "$HOOK" 2>/dev/null)
assert_eq "$stdout" "" "the ceiling also prints nothing to stdout"

# THIS IS THE CASE WHERE THE OLD VERSION (comparing the flag alone) WAS
# WRONG, measured in docs/verification/2026-08-31-plugin-wake.md
# ("stop_hook_active across a wake chain"): fire#2 and fire#3 after ANY
# exit 2 -- including the timeout re-arm, unrelated to any message -- all
# carry the flag true. A NEW message arriving while the flag is still true
# (the mailbox's content changed, e.g. an escalation overwriting an old
# worker_done) must still be reported: its identity differs from last-wake,
# so it MUST exit 2 and print the NEW summary, and must not be silently
# swallowed just because the flag is true. A version that only compares the
# flag would exit 0 and silently swallow this case -- exactly the Critical
# this catches.
printf '%s\n' '{"type":"escalation","run_id":"run_a","outcome":"needs captain decision"}' \
  > "$OFM_FAKE_ORCA_STATE/queue/run_a"
err=$(payload_active sess-a | bash "$HOOK" 2>&1 >/dev/null); rc=$?
assert_rc "$rc" 2 "FIX 1: a message DIFFERENT from last-wake must exit 2 even with stop_hook_active=true, not be swallowed"
assert_contains "$err" "escalation" "stderr must carry the NEW message's summary (not the old worker_done)"
assert_contains "$(cat "$(ofm_home)/last-wake" 2>/dev/null)" "escalation" \
  "last-wake must update to the new message after reporting it"

# stop_hook_active:true but NO message (empty queue) is the timeout branch
# (FIX 2); FIX 1's ceiling does not apply because there is nothing to loop
# infinitely on. Identity comparison does not touch this branch: exit 2 and
# the re-arm line must remain intact regardless of what the flag or
# last-wake currently hold.
: > "$OFM_FAKE_ORCA_STATE/queue/run_a"
out=$(payload_active sess-a | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 2 "stop_hook_active=true but no message (a timeout) still exits 2 (re-arm)"
assert_contains "$out" "re-arm" "the timeout branch still wins with no message, regardless of stop_hook_active"

# Garbage payload does not crash the hook
out=$(printf 'not json' | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 0 "a garbage payload gives exit 0"

ofm_test_teardown
ofm_test_report
