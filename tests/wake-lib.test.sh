#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
ofm_test_setup
. "$OFM_TEST_REPO/lib/ofm-home.sh"
. "$OFM_TEST_REPO/lib/ofm-wake-lib.sh"

# Nhịp poll production là 1000ms; test hạ xuống để chạy nhanh.
export OFM_WAKE_POLL_MS=50

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

# Frontmatter là nguồn duy nhất: "status: open" trong phần văn xuôi không tính
printf -- '---\nrun_id: run_body\nstatus: closed\n---\nstatus: open\n' > "$(ofm_requests_dir)/body.md"
assert_eq "$(ofm_open_run_ids | grep -c run_body || true)" "0" "status trong văn xuôi không tính"
# File không mở bằng `---` thì bỏ qua hẳn
printf 'lời nói đầu\n---\nrun_id: run_late\nstatus: open\n---\n' > "$(ofm_requests_dir)/late.md"
assert_eq "$(ofm_open_run_ids | grep -c run_late || true)" "0" "frontmatter không ở đầu file thì bỏ qua"
rm -f "$(ofm_requests_dir)/body.md" "$(ofm_requests_dir)/late.md"

# CRLF không được âm thầm biến một request đang mở thành không-mở
printf -- '---\r\nrun_id: run_crlf\r\nstatus: open\r\n---\r\n' > "$(ofm_requests_dir)/crlf.md"
assert_eq "$(ofm_open_run_ids | grep -c run_crlf || true)" "1" "frontmatter CRLF vẫn đọc được"
rm -f "$(ofm_requests_dir)/crlf.md"

# ofm_summarize: newline lọt qua .type hay .run_id cũng phải bị gói về một dòng
s=$(ofm_summarize '{"type":"worker\ndone","run_id":"r\n1","body":"a\nb"}')
assert_eq "$(printf '%s' "$s" | grep -c . )" "1" "tóm tắt luôn đúng một dòng dù mọi trường có newline"

# Giết CẢ PROCESS GROUP — đúng cách harness thật kết thúc hook. Giết riêng pid
# của subshell ngoài KHÔNG lan tới subshell trong (đã đo: leaked=1), nên phép đo
# đó không phản ánh production. `set -m` ở ĐÂY, trong test, để job nền thành
# group leader; library thì tuyệt đối không được bật nó.
printf -- '---\nrun_id: run_orphanprobe\nstatus: open\n---\nx\n' > "$(ofm_requests_dir)/orphan.md"
set -m
( printf 'run_orphanprobe\n' | ofm_wait_any_run 30000 >/dev/null 2>&1 ) & waiter=$!
set +m
sleep 0.8
kill -TERM -"$waiter" 2>/dev/null || kill -TERM "$waiter" 2>/dev/null || true
sleep 0.8
leaked=$(pgrep -f 'run_orphanprobe' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$leaked" "0" "giết process group thì không còn orca mồ côi"
pkill -f 'run_orphanprobe' 2>/dev/null || true
rm -f "$(ofm_requests_dir)/orphan.md"

# Dòng keepalive bị bỏ qua, không bị coi là message
fake_orca_queue run_a '{"_keepalive":true}'
out=$(printf 'run_a\n' | ofm_wait_any_run 300)
assert_eq "$out" "" "keepalive không tính là message"

ofm_test_teardown
ofm_test_report
