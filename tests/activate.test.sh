#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
ofm_test_setup
. "$OFM_TEST_REPO/lib/ofm-home.sh"
ACT="$OFM_TEST_REPO/bin/ofm-activate.sh"

out=$(bash "$ACT" sess-a claude); rc=$?
assert_rc "$rc" 0 "kích hoạt lần đầu thành công"
assert_contains "$out" "claimed" "báo claimed"
assert_eq "$(ofm_lock_get session_id)" "sess-a" "lock ghi đúng phiên"

# Home được tạo đầy đủ ngay lần kích hoạt đầu
[ -d "$OFM_HOME/requests" ]; assert_rc $? 0 "tạo requests/"
[ -d "$OFM_HOME/projects" ]; assert_rc $? 0 "tạo projects/"

# Phiên thứ hai bị từ chối khi chủ còn sống
out=$(bash "$ACT" sess-b claude); rc=$?
assert_rc "$rc" 1 "phiên thứ hai bị từ chối"
assert_contains "$out" "held_by=sess-a" "nói rõ ai đang giữ"

# Thiếu tham số thì fail rõ ràng, không im lặng
out=$(bash "$ACT" 2>&1); rc=$?
assert_rc "$rc" 2 "thiếu tham số thì rc 2"
assert_contains "$out" "usage" "in usage"

# PostCompact: khớp lock thì in identity ra stderr, lệch thì câm
HOOK="$OFM_TEST_REPO/hooks/reidentify-claude.sh"
err=$(printf '{"session_id":"sess-a"}' | bash "$HOOK" 2>&1 >/dev/null); rc=$?
assert_rc "$rc" 0 "reidentify luôn exit 0"
assert_contains "$err" "first mate" "in lại identity"
err=$(printf '{"session_id":"sess-zzz"}' | bash "$HOOK" 2>&1 >/dev/null)
assert_eq "$err" "" "phiên khác thì câm"

ofm_test_teardown
ofm_test_report
