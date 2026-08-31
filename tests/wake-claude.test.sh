#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
ofm_test_setup
. "$OFM_TEST_REPO/lib/ofm-home.sh"
HOOK="$OFM_TEST_REPO/hooks/wake-claude.sh"
export OFM_WAIT_TIMEOUT_MS=300

payload() { printf '{"session_id":"%s","cwd":"/tmp","hook_event_name":"Stop"}' "$1"; }
mk_request() {
  printf -- '---\nrun_id: %s\nproject: demo\nhost: local\nstatus: %s\nopened: 2026-08-31\n---\nx\n' \
    "$2" "$3" > "$(ofm_requests_dir)/$1.md"
}

# Không có lock: câm tuyệt đối. Đây là cổng bảo vệ mọi phiên khác trên máy.
out=$(payload sess-a | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 0 "không lock thì exit 0"
assert_eq "$out" "" "không lock thì không in gì"
assert_eq "$(fake_orca_calls)" "" "không lock thì không gọi orca"

# Lock của phiên khác: vẫn câm
printf 'session_id=sess-other\nharness=claude\npid=%s\nsince=1\n' $$ > "$(ofm_lock_path)"
out=$(payload sess-a | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 0 "session_id khác lock thì exit 0"
assert_eq "$(fake_orca_calls)" "" "session_id khác thì không gọi orca"

# Đúng chủ nhưng không có request mở: exit 0, vẫn không gọi orca
printf 'session_id=sess-a\nharness=claude\npid=%s\nsince=1\n' $$ > "$(ofm_lock_path)"
out=$(payload sess-a | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 0 "không request mở thì exit 0"
assert_eq "$(fake_orca_calls)" "" "không request mở thì không gọi orca"

# Đúng chủ, có request mở, không có message: exit 0 và CÓ gọi orca
mk_request one run_a open
out=$(payload sess-a | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 0 "hết giờ thì exit 0"
assert_contains "$(fake_orca_calls)" "--run run_a" "có chờ đúng run"

# Có message: exit 2 và in tóm tắt ra STDERR
fake_orca_queue run_a '{"type":"worker_done","run_id":"run_a","outcome":"succeeded"}'
err=$(payload sess-a | bash "$HOOK" 2>&1 >/dev/null); rc=$?
assert_rc "$rc" 2 "có message thì exit 2"
assert_contains "$err" "worker_done" "stderr mang tóm tắt"
stdout=$(payload sess-a | bash "$HOOK" 2>/dev/null);
assert_eq "$stdout" "" "không in gì ra stdout"

# Payload rác không làm hook nổ
out=$(printf 'not json' | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 0 "payload rác thì exit 0"

ofm_test_teardown
ofm_test_report
