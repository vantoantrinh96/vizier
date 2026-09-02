#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-home.sh"
. "$VIZIER_TEST_REPO/lib/vizier-mailbox-lib.sh"
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
fake_orca_message run_c msg_c1 worker_done "PR https://x/1" "$(fake_orca_payload dispatch-1)"
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

# A trailing space on either fence is a hand-editing typo, not a different
# file format. The closing fence already tolerated it; the NR==1 opening check
# did not, so `--- ` on line 1 made the hook silently stop waiting on a live
# Run -- indistinguishable from "no open requests".
printf -- '--- \nrun_id: run_space\nstatus: open\n--- \nstatus: closed\n' \
  > "$(vizier_requests_dir)/space.md"
assert_eq "$(vizier_open_run_ids | grep -c run_space || true)" "1" \
  "a trailing space on the fences still reads as an open request"
rm -f "$(vizier_requests_dir)/space.md"

# CRLF must not silently turn an open request into a not-open one
printf -- '---\r\nrun_id: run_crlf\r\nstatus: open\r\n---\r\n' > "$(vizier_requests_dir)/crlf.md"
assert_eq "$(vizier_open_run_ids | grep -c run_crlf || true)" "1" "CRLF frontmatter is still read correctly"
rm -f "$(vizier_requests_dir)/crlf.md"

# vizier_summarize: a newline slipping through .type or .run_id must also get wrapped into one line
s=$(vizier_summarize '{"type":"worker\ndone","run_id":"r\n1","body":"a\nb"}')
assert_eq "$(printf '%s' "$s" | grep -c . )" "1" "the summary is always exactly one line even when every field has a newline"

# WHAT THIS PROBE MEASURES, and why it is not the one that used to be here.
# The old design forked one `orca --wait` per Run: an orphan could live for
# the full eight-hour timeout, once per turn of every session on the machine,
# and it took two traps plus a pid file to guarantee it did not. Polling
# `inbox` deletes that whole class rather than managing it -- there is no
# long-lived child left to leak. So BOTH halves are asserted: that no blocking
# child is ever spawned, and that killing the process group (exactly how the
# harness ends a hook) still leaves nothing behind.
#
# `set -m` HERE, in the test, makes the background job its own group leader so
# the group can be killed; the library must absolutely never turn it on --
# that would push children out of the group the HARNESS owns and defeat the
# cleanup that covers a cut-off hook.
#
# BOTH WAITS AROUND THE KILL ARE BOUNDED POLLS, NOT SLEEPS. A longer sleep
# after the kill would hide a real leak exactly as well as it hides a race,
# whereas a poll with a deadline still fails when cleanup never happens.
count_in_group() { pgrep -g "$1" 2>/dev/null | wc -l | tr -d ' '; }
count_blocking_orca() { pgrep -f 'orchestration check --wait' 2>/dev/null | wc -l | tr -d ' '; }

wait_until_count() {  # <test-op> <n> <max_ticks> <cmd...>
  local op=$1 n=$2 max=$3; shift 3
  local i=0
  while [ "$i" -lt "$max" ]; do
    [ "$("$@")" "$op" "$n" ] && return 0
    i=$((i + 1))
    sleep 0.01
  done
  return 1
}

printf -- '---\nrun_id: run_orphanprobe\nstatus: open\n---\nx\n' > "$(vizier_requests_dir)/orphan.md"
set -m
( printf 'run_orphanprobe\n' | vizier_wait_any_run 30000 >/dev/null 2>&1 ) & waiter=$!
set +m
wait_until_count -gt 0 500 count_in_group "$waiter"; spawned=$?
assert_rc "$spawned" 0 "the wait is really running before the kill (or this probe proves nothing)"
assert_eq "$(count_blocking_orca)" "0" \
  "no blocking orca --wait child is spawned at all -- there is nothing left that can be orphaned"
kill -TERM -"$waiter" 2>/dev/null || kill -TERM "$waiter" 2>/dev/null || true
wait_until_count -eq 0 300 count_in_group "$waiter" || true
assert_eq "$(count_in_group "$waiter")" "0" "killing the process group leaves nothing behind"
rm -f "$(vizier_requests_dir)/orphan.md"

# --- WHAT MAKES A MESSAGE WAKE, AND WHAT DOES NOT -------------------------
# `inbox` has no --types, no --run and no notion of "new", so all three
# filters live in _vizier_wake_pick and every one of them is load-bearing.
: > "$VIZIER_FAKE_ORCA_STATE/queue/run_w"

# A type outside VIZIER_WAKE_TYPES must not wake anyone.
fake_orca_message run_w w_status status "just a tick"
out=$(printf 'run_w\n' | vizier_wait_any_run 200)
assert_eq "$out" "" "a type outside VIZIER_WAKE_TYPES does not wake"

# A matching one must.
fake_orca_message run_w w_done worker_done "PR https://x/9" "$(fake_orca_payload dispatch-9)"
out=$(printf 'run_w\n' | vizier_wait_any_run 3000)
assert_contains "$out" "worker_done" "a matching type wakes"
assert_contains "$out" "run_w" "and the summary names the run"

# ONCE A DELIVERY HAS BEEN FORMED OVER IT, `read` FLIPS AND IT STOPS WAKING.
# This is the whole "is it new" boundary: `inbox` shows history, not a queue,
# so without it the hook would re-report the same message on every single
# tick, forever, for as long as the request stayed open.
orca orchestration run-use --id run_w --json >/dev/null
orca orchestration check --run run_w --json >/dev/null
out=$(printf 'run_w\n' | vizier_wait_any_run 200)
assert_eq "$out" "" "a message somebody has already taken delivery of does not wake again"

# THE NEWEST UNREAD IS THE ONE NAMED. Not cosmetic: the Claude hook compares
# each summary against the last it reported and stays silent on a repeat, so
# naming a stale message while a fresh one waits suppresses the wake outright.
fake_orca_message run_w w_q   question   "older question"
fake_orca_message run_w w_esc escalation "newer escalation"
out=$(printf 'run_w\n' | vizier_wait_any_run 3000)
assert_contains "$out" "escalation" "the NEWEST unread match is named, not the oldest"

# A RUN THIS VIZIER DOES NOT OWN MUST NEVER WAKE IT. `inbox` shows every Run
# on the machine; run_w has unread matching traffic sitting in it right now,
# so this passes only because the run-id filter excludes it.
out=$(printf 'run_nonesuch\n' | vizier_wait_any_run 200)
assert_eq "$out" "" "a Run not in the open set does not wake, even with unread traffic visible on another Run"

# AN ok:false RESPONSE IS NEVER A WAKE, even if it carries rows that would
# otherwise match. This envelope is CONSTRUCTED, not captured -- no real
# response has been seen with both an error and a populated result -- because
# the rule being pinned is "do not read the body of a failed response at all",
# and only an input the real app has never produced can distinguish a reader
# that checks `ok` from one that just reaches for `.result.messages`.
mkdir -p "$VIZIER_TEST_TMP/badorca"
{
  printf '#!/usr/bin/env bash\n'
  printf 'jq -cn %s\n' "'"'{ok:false,error:{code:"consumer_fenced"},
    result:{messages:[{id:"x",run_id:"run_w",type:"worker_done",read:0,
                       sequence:99,created_at:"2026-09-02T00:00:00Z",
                       body:"should never be seen",payload:null}]}}'"'"
} > "$VIZIER_TEST_TMP/badorca/orca"
chmod +x "$VIZIER_TEST_TMP/badorca/orca"
out=$( PATH="$VIZIER_TEST_TMP/badorca:$PATH"; printf 'run_w\n' | vizier_wait_any_run 200 )
assert_eq "$out" "" "an ok:false response never becomes a wake, whatever its body carries"

# A mailbox holding nothing that matches --types does not wake anyone. The
# keepalive is the realistic instance: real Orca sends `_keepalive` lines to
# STDERR during a `--wait`, and this hook drops stderr, so one can only reach
# the mailbox by mistake -- and even then it carries no `type`, so `--types`
# excludes it and the envelope comes back with `messages: []`.
# vizier_mailbox_messages filters `_keepalive` in its own right; that is
# asserted directly in mailbox-lib.test.sh, where a keepalive can actually be
# placed inside an envelope.
fake_orca_queue run_a '{"_keepalive":true}'
out=$(printf 'run_a\n' | vizier_wait_any_run 300)
assert_eq "$out" "" "a keepalive does not count as a message"

vizier_test_teardown
vizier_test_report
