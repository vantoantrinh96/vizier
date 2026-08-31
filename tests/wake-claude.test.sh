#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
ofm_test_setup
. "$OFM_TEST_REPO/lib/ofm-home.sh"
HOOK="$OFM_TEST_REPO/hooks/wake-claude.sh"
export OFM_WAIT_TIMEOUT_MS=300

payload() { printf '{"session_id":"%s","cwd":"/tmp","hook_event_name":"Stop"}' "$1"; }
payload_active() {  # <session_id> — stop_hook_active:true, dùng cho ca FIX 1
  printf '{"session_id":"%s","cwd":"/tmp","hook_event_name":"Stop","stop_hook_active":true}' "$1"
}
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

# Đúng chủ, có request mở, không có message: FIX 2 -- hết giờ giờ đây phải
# exit 2 (re-arm), KHÔNG PHẢI exit 0. exit 0 ở đây là giám sát chết vĩnh viễn
# vì phiên idle không tự sinh Stop event nào để cắm lại vòng chờ.
mk_request one run_a open
out=$(payload sess-a | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 2 "FIX 2: hết giờ thì exit 2 để re-arm, không phải exit 0"
assert_contains "$out" "re-arm" "stderr nêu rõ lý do là re-arm"
assert_contains "$(fake_orca_calls)" "--run run_a" "có chờ đúng run"

# Có message: exit 2 và in tóm tắt ra STDERR
fake_orca_queue run_a '{"type":"worker_done","run_id":"run_a","outcome":"succeeded"}'
err=$(payload sess-a | bash "$HOOK" 2>&1 >/dev/null); rc=$?
assert_rc "$rc" 2 "có message thì exit 2"
assert_contains "$err" "worker_done" "stderr mang tóm tắt"
stdout=$(payload sess-a | bash "$HOOK" 2>/dev/null);
assert_eq "$stdout" "" "không in gì ra stdout"

# FIX 1 -- message vẫn còn đó (--peek không ack) VÀ stop_hook_active:true tức
# lượt này chính hook gây ra: đây là trần chặn vòng vô hạn. Phải exit 0, KHÔNG
# exit 2 -- nếu không mỗi lần tỉnh lại sinh thêm một lần tỉnh nữa mãi mãi. Vẫn
# phải nói một câu ra stderr trước khi im, không được câm lặng tuyệt đối.
err=$(payload_active sess-a | bash "$HOOK" 2>&1 >/dev/null); rc=$?
assert_rc "$rc" 0 "FIX 1: stop_hook_active=true và còn message thì exit 0, không lặp vô hạn"
assert_contains "$err" "trần" "stderr nói rõ đã chạm trần, không im lặng tuyệt đối"
stdout=$(payload_active sess-a | bash "$HOOK" 2>/dev/null)
assert_eq "$stdout" "" "trần cũng không in gì ra stdout"

# stop_hook_active:true nhưng KHÔNG có message (queue rỗng) thì đây là nhánh
# hết giờ (FIX 2), trần của FIX 1 không áp dụng vì không có gì để lặp vô hạn.
: > "$OFM_FAKE_ORCA_STATE/queue/run_a"
out=$(payload_active sess-a | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 2 "stop_hook_active=true nhưng không có message thì vẫn exit 2 (re-arm)"
assert_contains "$out" "re-arm" "nhánh hết giờ vẫn thắng khi không có message, bất kể stop_hook_active"

# Payload rác không làm hook nổ
out=$(printf 'not json' | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 0 "payload rác thì exit 0"

ofm_test_teardown
ofm_test_report
