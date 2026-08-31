#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"

ofm_test_setup

assert_contains "$OFM_HOME" "$OFM_TEST_TMP" "OFM_HOME nằm trong thư mục tạm"
[ -d "$OFM_HOME" ]; assert_rc $? 0 "OFM_HOME đã được tạo"

# fake-orca phải đứng trước orca thật trên PATH
resolved=$(command -v orca)
assert_contains "$resolved" "fake-orca" "orca giải ra fake-orca"

# check không có message thì trả rỗng và rc 0
out=$(orca orchestration check --run run_a --peek --json); rc=$?
assert_rc "$rc" 0 "check rỗng trả rc 0"
assert_eq "$out" "" "check rỗng không in gì"

# queue rồi check thì trả đúng dòng đó
fake_orca_queue run_a '{"type":"worker_done","outcome":"succeeded","body":"PR opened"}'
out=$(orca orchestration check --run run_a --peek --json)
assert_contains "$out" "worker_done" "check trả message đã queue"

# mọi lệnh đều được ghi log
assert_contains "$(fake_orca_calls)" "orchestration check --run run_a" "lệnh được ghi log"

ofm_test_teardown
ofm_test_report
