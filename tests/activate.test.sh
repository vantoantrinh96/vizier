#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
ofm_test_setup
. "$OFM_TEST_REPO/lib/ofm-home.sh"
ACT="$OFM_TEST_REPO/bin/ofm-activate.sh"

out=$(bash "$ACT" claude sess-a); rc=$?
assert_rc "$rc" 0 "kích hoạt lần đầu thành công"
assert_contains "$out" "claimed" "báo claimed"
assert_eq "$(ofm_lock_get session_id)" "sess-a" "lock ghi đúng phiên"

# Home được tạo đầy đủ ngay lần kích hoạt đầu
[ -d "$OFM_HOME/requests" ]; assert_rc $? 0 "tạo requests/"
[ -d "$OFM_HOME/projects" ]; assert_rc $? 0 "tạo projects/"

# Phiên thứ hai bị từ chối khi chủ còn sống
out=$(bash "$ACT" claude sess-b); rc=$?
assert_rc "$rc" 1 "phiên thứ hai bị từ chối"
assert_contains "$out" "held_by=sess-a" "nói rõ ai đang giữ"

# FIX 4 — refusal held_by= phải kèm gợi ý đường thoát `orca-firstmate unlock`,
# để captain không phải lục docs khi va phải lock kẹt-nhưng-sống.
err=$(bash "$ACT" claude sess-b 2>&1 >/dev/null)
assert_contains "$err" "orca-firstmate unlock" "gợi ý lệnh unlock trong refusal held_by="

# FIX 5 — phiên con/subagent (CLAUDE_CODE_CHILD_SESSION đặt) kích hoạt là hỏng
# im lặng toàn phần: session id của nó không khớp payload hook Stop nhận cho
# phiên cha, nên lock ghi từ đây không bao giờ tự khớp lại được. Phải từ chối
# tường minh, không bao giờ được để lọt qua để ghi lock.
rm -f "$(ofm_lock_path)"
out=$(CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CODE_SESSION_ID=sess-child bash "$ACT" claude 2>&1); rc=$?
assert_rc "$rc" 2 "FIX 5: phiên con thì rc 2, không được kích hoạt"
assert_contains "$out" "child_session" "nói rõ lý do là phiên con"
assert_eq "$(ofm_lock_get session_id)" "" "FIX 5: không ghi lock nào khi là phiên con"

# Không có session id từ môi trường thì TỪ CHỐI, không bịa một giá trị
rm -f "$(ofm_lock_path)"
out=$(env -u CLAUDE_CODE_SESSION_ID bash "$ACT" claude 2>&1); rc=$?
assert_rc "$rc" 2 "không có CLAUDE_CODE_SESSION_ID thì rc 2"
assert_contains "$out" "no_session_id" "nói rõ lý do"
assert_eq "$(ofm_lock_get session_id)" "" "không ghi lock nào khi thiếu session id"
# Có biến môi trường thì dùng nó, model không phải điền gì
out=$(CLAUDE_CODE_SESSION_ID=from-env bash "$ACT" claude); rc=$?
assert_rc "$rc" 0 "lấy được session id từ môi trường"
assert_eq "$(ofm_lock_get session_id)" "from-env" "lock ghi đúng session id của môi trường"

# Không xác định được pid harness thì TỪ CHỐI. Nhánh này trước đó KHÔNG có test
# nào chạm tới, vì mọi lời gọi đều đọc CLAUDE_PID có thật của môi trường test.
# Bỏ CLAUDE_PID và đặt một tên harness không thể có trong cây tiến trình.
rm -f "$(ofm_lock_path)"
out=$(env -u CLAUDE_PID bash "$ACT" no-such-harness-xyz 2>&1); rc=$?
assert_rc "$rc" 2 "không tìm được pid harness thì rc 2"
assert_contains "$out" "no_harness_pid" "nói rõ lý do"
assert_eq "$(ofm_lock_get session_id)" "" "không ghi lock nào khi thiếu pid harness"

# PostCompact: khớp lock thì in identity ra stderr, lệch thì câm
rm -f "$(ofm_lock_path)"
CLAUDE_CODE_SESSION_ID=sess-a bash "$ACT" claude sess-a > /dev/null
HOOK="$OFM_TEST_REPO/hooks/reidentify-claude.sh"
err=$(printf '{"session_id":"sess-a"}' | bash "$HOOK" 2>&1 >/dev/null); rc=$?
assert_rc "$rc" 0 "reidentify luôn exit 0"
assert_contains "$err" "first mate" "in lại identity"
err=$(printf '{"session_id":"sess-zzz"}' | bash "$HOOK" 2>&1 >/dev/null)
assert_eq "$err" "" "phiên khác thì câm"

ofm_test_teardown
ofm_test_report
