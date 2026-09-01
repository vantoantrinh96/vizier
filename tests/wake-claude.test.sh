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

# Có message, stop_hook_active:false (báo ĐẦU TIÊN): exit 2, in tóm tắt ra
# STDERR, và ghi lại tóm tắt đó vào last-wake -- đây là bản ghi FIX 1 dùng
# để so danh tính ở các lượt sau, không phải cờ stop_hook_active một mình.
fake_orca_queue run_a '{"type":"worker_done","run_id":"run_a","outcome":"succeeded"}'
err=$(payload sess-a | bash "$HOOK" 2>&1 >/dev/null); rc=$?
assert_rc "$rc" 2 "báo đầu tiên (stop_hook_active=false) thì exit 2"
assert_contains "$err" "worker_done" "stderr mang tóm tắt"
stdout=$(payload sess-a | bash "$HOOK" 2>/dev/null);
assert_eq "$stdout" "" "không in gì ra stdout"
assert_contains "$(cat "$(ofm_home)/last-wake" 2>/dev/null)" "worker_done" \
  "báo đầu tiên phải ghi tóm tắt vào last-wake để lần sau so danh tính"

# FIX 1 -- CÙNG một message (--peek không ack nên nó vẫn còn đó) VÀ
# stop_hook_active:true (lượt này chính hook gây ra) VÀ tóm tắt giống hệt
# last-wake vừa ghi ở trên: đúng ca "đã báo rồi, còn chưa ack" -- trần chặn
# vòng vô hạn. Phải exit 0, KHÔNG exit 2 -- nếu không mỗi lần tỉnh lại sinh
# thêm một lần tỉnh nữa mãi mãi. Vẫn phải nói một câu ra stderr trước khi im,
# không được câm lặng tuyệt đối. (Kiểm phản chứng: revert về so cờ một mình
# vẫn cho kết quả này exit 0 -- ca này KHÔNG phân biệt được bản cũ với bản
# mới, ca dưới đây mới phân biệt được.)
err=$(payload_active sess-a | bash "$HOOK" 2>&1 >/dev/null); rc=$?
assert_rc "$rc" 0 "FIX 1: cùng message, stop_hook_active=true thì exit 0, không lặp vô hạn"
assert_contains "$err" "ceiling" "stderr nói rõ đã chạm trần, không im lặng tuyệt đối"
assert_contains "$err" "not acked" "stderr nói rõ message vẫn chưa được ack"
stdout=$(payload_active sess-a | bash "$HOOK" 2>/dev/null)
assert_eq "$stdout" "" "trần cũng không in gì ra stdout"

# ĐÂY LÀ CA BẢN CŨ (so cờ một mình) SAI, đo được ở
# docs/verification/2026-08-31-plugin-wake.md ("stop_hook_active xuyên chuỗi
# đánh thức"): fire#2 và fire#3 sau bất kỳ exit 2 nào -- kể cả re-arm hết giờ,
# không liên quan gì tới message -- đều mang cờ true. Một message MỚI tới
# trong khi cờ vẫn true (mailbox đổi nội dung, ví dụ một escalation ghi đè
# worker_done cũ) phải vẫn được báo: danh tính khác last-wake nên PHẢI exit 2
# và in tóm tắt MỚI, không được nuốt im lặng chỉ vì cờ true. Bản chỉ so cờ sẽ
# exit 0 và nuốt câm ca này -- chính là Critical bị bắt.
printf '%s\n' '{"type":"escalation","run_id":"run_a","outcome":"cần captain quyết"}' \
  > "$OFM_FAKE_ORCA_STATE/queue/run_a"
err=$(payload_active sess-a | bash "$HOOK" 2>&1 >/dev/null); rc=$?
assert_rc "$rc" 2 "FIX 1: message KHÁC last-wake dù stop_hook_active=true vẫn phải exit 2, không bị nuốt"
assert_contains "$err" "escalation" "stderr phải mang tóm tắt của message MỚI (không phải worker_done cũ)"
assert_contains "$(cat "$(ofm_home)/last-wake" 2>/dev/null)" "escalation" \
  "last-wake phải cập nhật sang message mới sau khi báo nó"

# stop_hook_active:true nhưng KHÔNG có message (queue rỗng) thì đây là nhánh
# hết giờ (FIX 2), trần của FIX 1 không áp dụng vì không có gì để lặp vô hạn.
# So danh tính không chạm tới nhánh này: exit 2 và dòng re-arm phải nguyên vẹn
# bất kể cờ hay last-wake đang chứa gì.
: > "$OFM_FAKE_ORCA_STATE/queue/run_a"
out=$(payload_active sess-a | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 2 "stop_hook_active=true nhưng không có message (hết giờ) thì vẫn exit 2 (re-arm)"
assert_contains "$out" "re-arm" "nhánh hết giờ vẫn thắng khi không có message, bất kể stop_hook_active"

# Payload rác không làm hook nổ
out=$(printf 'not json' | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 0 "payload rác thì exit 0"

ofm_test_teardown
ofm_test_report
