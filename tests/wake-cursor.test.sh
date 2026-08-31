#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
ofm_test_setup
. "$OFM_TEST_REPO/lib/ofm-home.sh"
HOOK="$OFM_TEST_REPO/hooks/wake-cursor.sh"
# FIX 12 — 300ms từng gây fail ngẫu nhiên ~1/5 lần chạy. Nguyên nhân: deadline
# trong lib/ofm-wake-lib.sh tính bằng `$(date +%s) + (timeout_ms+999)/1000` —
# `date +%s` CẮT XUỐNG giây nguyên, nên nếu lệnh chạy ở mili-giây .999 của một
# giây, deadline thật hiệu quả có thể chỉ còn 0ms thay vì ~300ms dự định. Với
# 300ms, biên độ méo đó (tới gần 1000ms) đủ NUỐT TRỌN cả timeout, khiến `sleep
# 0.15` cố định ở khối đồng thời bên dưới đôi khi thả message SAU khi cả hai
# park đã hết giờ. KHÔNG được sửa lib sản xuất — bug thật ở đó chỉ gây lệch độ
# trễ dưới 1s trên nền timeout 8 tiếng, vô hại; sửa test bằng cách nới timeout
# ra 3000ms để cùng biên độ méo đó chỉ còn chiếm một phần nhỏ, không nuốt hết.
export OFM_WAIT_TIMEOUT_MS=3000
# Nhịp poll production là 1000ms. Không đặt ở đây thì mỗi lần gọi hook mất ~1s
# và chỉ tìm thấy message nhờ vòng lặp kiểm file TRƯỚC khi kiểm deadline — test
# pass nhờ một thứ tự tình cờ chứ không nhờ hành vi nó đặt tên.
export OFM_WAKE_POLL_MS=50

payload() {  # <session_id> <loop_count>
  printf '{"session_id":"%s","loop_count":%s,"workspace_roots":["/tmp"],"status":"completed"}' "$1" "$2"
}
mk_request() {
  printf -- '---\nrun_id: %s\nproject: demo\nhost: local\nstatus: open\nopened: 2026-08-31\n---\nx\n' \
    "$2" > "$(ofm_requests_dir)/$1.md"
}

# FIX 12 — thay `sleep 0.15` cố định bằng chờ CÓ ĐIỀU KIỆN: poll tới khi
# park-owner đã được ghi (một park đã vào tới điểm chờ mailbox) VÀ mọi pid nền
# truyền vào còn sống (chưa thoát sớm vì lỗi), rồi mới trả về để caller thả
# message vào hàng đợi. Có trần lặp (1s) để không treo test vô hạn nếu điều
# kiện không bao giờ đúng — bounded wait, không phải sleep đoán mò.
wait_for_park_ready() {  # <pid...>
  local i=0 ok pid
  while [ "$i" -lt 100 ]; do
    ok=1
    [ -e "$OFM_HOME/park-owner" ] || ok=0
    for pid in "$@"; do
      kill -0 "$pid" 2>/dev/null || ok=0
    done
    [ "$ok" = 1 ] && return 0
    i=$((i + 1))
    sleep 0.01
  done
  return 1
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

# FIX 8 — chạm trần vẫn phải nói MỘT câu, không im lặng tuyệt đối. Đúng lượt
# loop_count == ceiling (mặc định 5): phát followup_message báo đã chạm trần.
out=$(payload sess-a 5 | bash "$HOOK" 2>/dev/null); rc=$?
assert_rc "$rc" 0 "FIX 8: chạm trần vẫn exit 0"
assert_contains "$out" "followup_message" "FIX 8: chạm trần phải phát một câu, không câm"
assert_contains "$out" "trần" "câu báo nêu rõ lý do là đã chạm trần"
lines=$(printf '%s\n' "$out" | grep -c . )
assert_eq "$lines" "1" "câu báo trần cũng đúng MỘT dòng JSON"

# Qua trần rồi (đã báo ở lượt trước) thì câm, không lặp lại câu báo mãi mãi.
out=$(payload sess-a 6 | bash "$HOOK" 2>/dev/null); rc=$?
assert_rc "$rc" 0 "qua trần rồi thì exit 0"
assert_eq "$out" "" "qua trần rồi thì câm, không lặp lại câu báo trần vô hạn"

# Park bị thay thì đứng im — kiểm bằng claim tường minh
printf 'someone-else\n' > "$OFM_HOME/park-owner"
out=$(payload sess-a 0 | OFM_CURSOR_PARK_CLAIM=mine bash "$HOOK" 2>/dev/null)
# Hook tự ghi claim của nó lúc bắt đầu, nên nó SẼ là chủ; ca này chỉ khẳng định
# claim tường minh không làm hook vỡ. Ca thật nằm ở khối đồng thời dưới đây.
printf '%s' "$out" | jq -e '.followup_message' >/dev/null 2>&1
assert_rc $? 0 "claim tường minh vẫn phát bình thường khi không bị thay"

# HAI PARK THẬT chạy chồng nhau, cùng thấy một message: chỉ MỘT được phát.
: > "$OFM_FAKE_ORCA_STATE/queue/run_a"
rm -f "$OFM_HOME/park-owner"
( payload sess-a 0 | bash "$HOOK" > "$OFM_TEST_TMP/p1.out" 2>/dev/null ) & p1=$!
( payload sess-a 0 | bash "$HOOK" > "$OFM_TEST_TMP/p2.out" 2>/dev/null ) & p2=$!
wait_for_park_ready "$p1" "$p2"
fake_orca_queue run_a '{"type":"worker_done","run_id":"run_a","outcome":"succeeded"}'
wait "$p1" 2>/dev/null || true
wait "$p2" 2>/dev/null || true
emitters=$(grep -l followup_message "$OFM_TEST_TMP/p1.out" "$OFM_TEST_TMP/p2.out" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$emitters" "1" "hai park chồng nhau thì đúng một cái phát"

# Cổng read-back: ghi claim xong rồi bị NGƯỜI KHÁC thay giữa chừng -> phải im,
# dù đã nhìn thấy message. Đây mới là ca chứng minh cổng read-back; ca `chmod
# 000` trước đó chặn ngay ở bước GHI và thoát ở một cổng khác hẳn, nên nó pass
# mà chưa từng chạm cổng này.
: > "$OFM_FAKE_ORCA_STATE/queue/run_a"
rm -f "$OFM_HOME/park-owner"
( payload sess-a 0 | bash "$HOOK" > "$OFM_TEST_TMP/p3.out" 2>/dev/null ) & p3=$!
wait_for_park_ready "$p3"
printf 'usurper\n' > "$OFM_HOME/park-owner"
fake_orca_queue run_a '{"type":"worker_done","run_id":"run_a","outcome":"succeeded"}'
wait "$p3" 2>/dev/null || true
assert_eq "$(cat "$OFM_TEST_TMP/p3.out")" "" "bị thay chủ giữa chừng thì im, dù đã thấy message"

# Không ghi được owner_file cũng phải im — cổng khác, ca khác, ghi rõ là khác
: > "$OFM_FAKE_ORCA_STATE/queue/run_a"
printf 'x\n' > "$OFM_HOME/park-owner"; chmod 000 "$OFM_HOME/park-owner" 2>/dev/null || true
out=$(payload sess-a 0 | bash "$HOOK" 2>/dev/null)
assert_eq "$out" "" "không ghi được owner_file thì im (cổng GHI, không phải read-back)"
chmod 644 "$OFM_HOME/park-owner" 2>/dev/null || true

ofm_test_teardown
ofm_test_report
