#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
ofm_test_setup
. "$OFM_TEST_REPO/lib/ofm-home.sh"

assert_eq "$(ofm_home)" "$OFM_HOME" "ofm_home tôn trọng OFM_HOME"
assert_eq "$(ofm_lock_path)" "$OFM_HOME/lock" "đường dẫn lock"

# Không có lock thì không phiên nào khớp
ofm_lock_matches "sess-a"; assert_rc $? 1 "không lock thì không khớp"

# Chiếm lock lần đầu
out=$(ofm_lock_claim "sess-a" claude $$); assert_rc $? 0 "chiếm được lock trống"
assert_contains "$out" "claimed" "báo claimed"
assert_eq "$(ofm_lock_get session_id)" "sess-a" "ghi session_id"
assert_eq "$(ofm_lock_get harness)" "claude" "ghi harness"
ofm_lock_matches "sess-a"; assert_rc $? 0 "chủ khớp"
ofm_lock_matches "sess-b"; assert_rc $? 1 "phiên khác không khớp"

# Chủ còn sống thì phiên khác bị từ chối
out=$(ofm_lock_claim "sess-b" claude $$); assert_rc $? 1 "từ chối khi chủ còn sống"
assert_contains "$out" "held_by=sess-a" "nêu tên chủ đang giữ"
assert_eq "$(ofm_lock_get session_id)" "sess-a" "lock không bị đổi chủ"

# Chính chủ gọi lại thì làm mới, không từ chối
ofm_lock_claim "sess-a" claude $$ >/dev/null; assert_rc $? 0 "chính chủ gọi lại thì ok"

# Chủ đã chết thì thu hồi được
printf 'session_id=sess-dead\nharness=claude\npid=999999\nsince=1\n' > "$(ofm_lock_path)"
out=$(ofm_lock_claim "sess-c" claude $$); assert_rc $? 0 "thu hồi được lock chết"
assert_contains "$out" "reclaimed" "báo reclaimed"
assert_eq "$(ofm_lock_get session_id)" "sess-c" "chủ mới đã ghi"

# Pid không phải số thì coi như không chứng minh được, KHÔNG thu hồi bừa
printf 'session_id=sess-x\nharness=claude\npid=abc\nsince=1\n' > "$(ofm_lock_path)"
ofm_lock_claim "sess-d" claude $$ >/dev/null; assert_rc $? 1 "pid rác thì không cướp lock"

# Release chỉ có tác dụng với đúng chủ
printf 'session_id=sess-e\nharness=claude\npid=%s\nsince=1\n' $$ > "$(ofm_lock_path)"
ofm_lock_release "sess-other" >/dev/null
assert_eq "$(ofm_lock_get session_id)" "sess-e" "người lạ không release được"
ofm_lock_release "sess-e" >/dev/null
assert_eq "$(ofm_lock_get session_id)" "" "đúng chủ thì release được"

ofm_test_teardown
ofm_test_report
