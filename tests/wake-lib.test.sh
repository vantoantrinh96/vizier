#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
ofm_test_setup
. "$OFM_TEST_REPO/lib/ofm-home.sh"
. "$OFM_TEST_REPO/lib/ofm-wake-lib.sh"

mk_request() {  # <slug> <run_id> <status>
  printf -- '---\nrun_id: %s\nproject: demo\nhost: local\nstatus: %s\nopened: 2026-08-31\n---\nyêu cầu gốc\n' \
    "$2" "$3" > "$(ofm_requests_dir)/$1.md"
}

assert_eq "$(ofm_open_run_ids)" "" "không có request thì không có run"

mk_request one run_a open
mk_request two run_b closed
assert_eq "$(ofm_open_run_ids)" "run_a" "chỉ lấy request open"

mk_request three run_c open
got=$(ofm_open_run_ids | sort | tr '\n' ',')
assert_eq "$got" "run_a,run_c," "lấy được nhiều run open"

# Hết giờ mà không có message thì in rỗng, rc vẫn 0
out=$(ofm_open_run_ids | ofm_wait_any_run 200); rc=$?
assert_rc "$rc" 0 "hết giờ vẫn rc 0"
assert_eq "$out" "" "hết giờ thì không in gì"

# Message ở run thứ hai vẫn được bắt: chờ song song, không tuần tự
fake_orca_queue run_c '{"type":"worker_done","run_id":"run_c","outcome":"succeeded","body":"PR https://x/1"}'
out=$(ofm_open_run_ids | ofm_wait_any_run 3000)
assert_contains "$out" "worker_done" "bắt được message của run thứ hai"
assert_contains "$out" "run_c" "tóm tắt nêu run id"

# Tóm tắt luôn gói về một dòng
lines=$(printf '%s' "$out" | wc -l | tr -d ' ')
assert_eq "$lines" "0" "tóm tắt là đúng một dòng, không newline cuối"

# Dòng keepalive bị bỏ qua, không bị coi là message
fake_orca_queue run_a '{"_keepalive":true}'
out=$(printf 'run_a\n' | ofm_wait_any_run 300)
assert_eq "$out" "" "keepalive không tính là message"

ofm_test_teardown
ofm_test_report
