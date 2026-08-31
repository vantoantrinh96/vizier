#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
ofm_test_setup
. "$OFM_TEST_REPO/lib/ofm-home.sh"
HOOK="$OFM_TEST_REPO/hooks/wake-cursor.sh"
export OFM_WAIT_TIMEOUT_MS=300

payload() {  # <session_id> <loop_count>
  printf '{"session_id":"%s","loop_count":%s,"workspace_roots":["/tmp"],"status":"completed"}' "$1" "$2"
}
mk_request() {
  printf -- '---\nrun_id: %s\nproject: demo\nhost: local\nstatus: open\nopened: 2026-08-31\n---\nx\n' \
    "$2" > "$(ofm_requests_dir)/$1.md"
}

# Không lock: câm
out=$(payload sess-a 0 | bash "$HOOK" 2>/dev/null); rc=$?
assert_rc "$rc" 0 "không lock thì exit 0"
assert_eq "$out" "" "không lock thì stdout rỗng"

printf 'session_id=sess-a\nharness=cursor-agent\npid=%s\nsince=1\n' $$ > "$(ofm_lock_path)"
mk_request one run_a

# Có message: in đúng một object followup_message, exit 0 (KHÔNG phải exit 2)
fake_orca_queue run_a '{"type":"worker_done","run_id":"run_a","outcome":"succeeded"}'
out=$(payload sess-a 0 | bash "$HOOK" 2>/dev/null); rc=$?
assert_rc "$rc" 0 "Cursor luôn exit 0, kể cả khi đánh thức"
assert_contains "$out" "followup_message" "in followup_message"
assert_contains "$out" "worker_done" "followup mang tóm tắt"
lines=$(printf '%s\n' "$out" | grep -c . )
assert_eq "$lines" "1" "in đúng MỘT dòng JSON"
printf '%s' "$out" | jq -e '.followup_message' >/dev/null 2>&1
assert_rc $? 0 "stdout là JSON hợp lệ"

# Trần loop cắn trước loop_limit của Cursor
out=$(payload sess-a 5 | bash "$HOOK" 2>/dev/null); rc=$?
assert_rc "$rc" 0 "chạm trần thì exit 0"
assert_eq "$out" "" "chạm trần thì không emit"

# Park cũ hơn phải đứng im khi đã có park mới hơn
printf '7\n' > "$OFM_HOME/park-owner"
out=$(payload sess-a 0 | OFM_CURSOR_PARK_SEQ=3 bash "$HOOK" 2>/dev/null)
assert_eq "$out" "" "park cũ không emit khi đã bị thay"

ofm_test_teardown
ofm_test_report
