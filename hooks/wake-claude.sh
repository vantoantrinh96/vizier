#!/usr/bin/env bash
# Stop hook của Claude Code — nửa Claude của cơ chế tự thức dậy.
#
# Đăng ký với "asyncRewake": true và "timeout": 28800. Đã kiểm chứng trên
# Claude Code 2.1.236 (docs/verification/2026-08-31-plugin-wake.md):
#   - asyncRewake được honor trong plugin hook: phiên không bị chặn.
#   - exit 2 đánh thức phiên đang IDLE, stderr vào context dạng system reminder.
#   - exit 0 câm tuyệt đối.
#
# HAI NHÁNH exit 2 CÓ CHỦ ĐÍCH KHÁC HẲN NHAU, đọc kỹ trước khi sửa:
#   - hết giờ chờ mailbox -> exit 2 "re-arm" (FIX 2): không có gì mới để báo,
#     chỉ đơn thuần cắm lại vòng chờ ở lượt kế. Không phải vòng xoáy vì mỗi
#     vòng chờ tới tám tiếng.
#   - có message thật -> exit 2 kèm tóm tắt: đây là message CHƯA TỪNG BÁO
#     (khác với "last-wake", hoặc chưa có "last-wake" nào).
# Và một nhánh exit 0 không còn "câm tuyệt đối" theo nghĩa cũ nữa: nhánh trần
# theo danh tính message (FIX 1, so với "$(ofm_home)/last-wake") vẫn in một
# dòng ra stderr trước khi exit 0, để captain thấy vòng đã dừng có chủ đích
# chứ không phải hook chết lặng.
#
# HOOK NÀY CHẠY SAU MỖI LƯỢT CỦA MỌI PHIÊN CLAUDE CODE TRÊN MÁY, không dedupe.
# Nên thứ tự cổng chặn là bắt buộc, rẻ trước đắt sau, và mọi nhánh không chắc
# chắn đều exit 0.
#
# HOOK KHÔNG BAO GIỜ ACK. Ack thuộc về first mate sau khi xử lý xong batch;
# nhờ replay-tới-ack của Orca, hook chết giữa chừng không mất message.
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)" || exit 0
[ -r "$LIB/ofm-home.sh" ] || exit 0
# shellcheck source=/dev/null
. "$LIB/ofm-home.sh"
# shellcheck source=/dev/null
. "$LIB/ofm-wake-lib.sh"

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null || true)
session_id=$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null) || exit 0

# Cổng 1 — rẻ nhất: phiên này có phải first mate không?
ofm_lock_matches "$session_id" || exit 0

# Cổng 2: có gì để chờ không? Home rỗng thì không tốn một lệnh orca nào.
runs=$(ofm_open_run_ids)
[ -n "$runs" ] || exit 0

# Chờ ngắn hơn timeout của hook một khoảng an toàn để hook luôn tự thoát
# có kiểm soát thay vì bị harness giết giữa chừng.
summary=$(printf '%s\n' "$runs" | ofm_wait_any_run "${OFM_WAIT_TIMEOUT_MS:-28500000}")

# FIX 2 — HẾT GIỜ PHẢI exit 2, KHÔNG PHẢI exit 0. Một phiên đang idle không tự
# sinh Stop event nào cả, nên im lặng ở đây là giám sát chết VĨNH VIỄN cho tới
# khi captain tự gõ gì đó — không phải "chờ thêm", mà là dừng hẳn. exit 2 với
# một dòng "re-arm" đánh thức phiên đủ để nó cắm lại đúng vòng chờ này ở lượt
# Stop kế tiếp. Đây KHÔNG phải vòng xoáy: mỗi vòng re-arm chờ tới tám tiếng,
# khác hẳn ca vô hạn của FIX 1 dưới đây (message không ack lặp lại mỗi lượt).
if [ -z "$summary" ]; then
  printf 'orca-firstmate: hết giờ chờ mailbox, re-arm lại vòng chờ ở lượt kế tiếp.\n' >&2
  exit 2
fi

# FIX 1 — TRẦN CHẶN VÒNG VÔ HẠN, theo DANH TÍNH MESSAGE, không theo cờ một
# mình. Hook dùng --peek nên một message chưa được first mate ack vẫn còn
# nguyên ở lượt sau; không có trần này thì MỖI lần tỉnh dậy vì message đó lại
# sinh ra một lần tỉnh nữa — vòng vô hạn, và đường ack (thuộc về first mate,
# không phải hook) nằm ở một plan sau, nên hôm nay đây là kết quả MẶC ĐỊNH của
# bất kỳ lần wake thành công nào nếu không chặn.
#
# Bản đầu chặn chỉ bằng `stop_hook_active`. Đo lại
# (docs/verification/2026-08-31-plugin-wake.md, mục "stop_hook_active xuyên
# chuỗi đánh thức") cho kết quả:
#   fire#1  stop_hook_active=false   <- sau lượt captain gõ thật
#   fire#2  stop_hook_active=true    <- sau lần đánh thức bởi exit 2
#   fire#3  stop_hook_active=true    <- sau lần đánh thức thứ hai
# Trần CÓ chạm — vòng vô hạn bị chặn thật. Nhưng cờ chỉ nói "lượt này do hook
# Stop trước đó gây ra", KHÔNG nói "ta đã báo đúng thứ này rồi". Sau BẤT KỲ
# exit 2 nào — kể cả nhánh hết giờ re-arm ở trên, hoàn toàn không liên quan
# tới message nào — mọi Stop kế tiếp trong chuỗi đều mang cờ true. Một cái
# chặn chỉ dựa vào cờ sẽ nuốt im lặng một message MỚI tới giữa một chuỗi
# re-arm — tệ hơn vòng lặp, vì vòng lặp còn ồn, cái này câm.
#
# Sửa: so DANH TÍNH, không so cờ một mình. Nhớ tóm tắt đã báo lần gần nhất ở
# "$(ofm_home)/last-wake"; chỉ im lặng (exit 0) khi cờ true VÀ tóm tắt lần
# này giống hệt byte-for-byte tóm tắt đã ghi — tức chắc chắn đây đúng là cùng
# một message chưa ack, không phải suy đoán từ việc lượt này do hook gây ra.
# Vẫn đọc `stop_hook_active` trước: thiếu nó thì báo cáo ĐẦU TIÊN (chưa từng
# có gì trong last-wake để so, hoặc lần đầu chạy) cũng bị so trùng nhầm với
# chính nó và bị nuốt — cờ là điều kiện để phép so identity có ý nghĩa, không
# phải điều kiện để bỏ qua nó.
stop_hook_active=$(printf '%s' "$payload" | jq -r '.stop_hook_active // false' 2>/dev/null)
last_wake_file="$(ofm_home)/last-wake"
last_wake=$(cat "$last_wake_file" 2>/dev/null)
if [ "$stop_hook_active" = "true" ] && [ "$summary" = "$last_wake" ]; then
  printf 'orca-firstmate: đã chạm trần đánh thức (message giống hệt lần trước, đối chiếu theo nội dung chứ không chỉ theo cờ stop_hook_active, và vẫn chưa được ack); dừng lại đây, không tỉnh thêm vòng nào nữa cho tới khi first mate ack hoặc captain tự gõ.\n' >&2
  exit 0
fi

# Ghi last-wake có thể thất bại (home mất quyền ghi, disk đầy, ...). Vẫn phải
# báo và exit 2 chứ không được chết ở đây: mất bản ghi nhiều nhất gây MỘT lần
# tỉnh trùng ở lượt sau (vô hại — lượt đó lại thử ghi lại), còn nuốt luôn
# message vì lỗi ghi file thì mất tín hiệu vĩnh viễn. Câm vì lỗi ghi luôn tệ
# hơn một lần báo lặp.
printf '%s' "$summary" > "$last_wake_file" 2>/dev/null

printf 'orca-firstmate: %s\n' "$summary" >&2
exit 2
