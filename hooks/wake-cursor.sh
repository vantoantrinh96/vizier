#!/usr/bin/env bash
# stop hook của Cursor — nửa Cursor của cơ chế tự thức dậy.
#
# KHÔNG DÙNG LẠI ĐƯỢC CÔNG THỨC CỦA CLAUDE. Đã đo trên cursor-agent TUI
# 2026.08.25-3e8eec8 (docs/verification/2026-08-31-plugin-wake.md):
#   - Cursor chạy hook ĐỒNG BỘ và chờ nó: hook "park" giữ turn boundary mở.
#   - exit 2 là NO-OP IM LẶNG. Không bao giờ dựa vào nó.
#   - Kênh duy nhất là đúng một {"followup_message": "..."} trên STDOUT + exit 0.
#     Cursor nhận nó và chạy một lượt model mới.
#   - `loop_count` trong payload là bản Cursor của stop_hook_active.
#   - Hook này KHÔNG cài được dạng plugin; nó chỉ fire từ ~/.cursor/hooks.json.
#
# PARK-OWNER. Một tin captain gõ lúc hook đang park được nhận ngay và KHÔNG
# giết hook đang park. Nên hai park có thể cùng sống, cùng thấy một message
# (ta dùng --peek nên không ai ack), và cùng báo -> trùng. Mỗi lần chạy giành
# một số thứ tự tăng dần; trước khi emit phải xác nhận mình vẫn là số mới nhất.
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
loop_count=$(printf '%s' "$payload" | jq -r '.loop_count // 0' 2>/dev/null)

ofm_lock_matches "$session_id" || exit 0

# Trần tự chặn, đặt THẤP HƠN loop_limit đăng ký trong hooks.json, để bound của
# ta cắn trước và Cursor không lặng lẽ ngừng gọi hook ở trần của nó.
ceiling=${OFM_CURSOR_LOOP_CEILING:-5}
case "$loop_count" in ''|*[!0-9]*) loop_count=0 ;; esac
[ "$loop_count" -lt "$ceiling" ] || exit 0

runs=$(ofm_open_run_ids)
[ -n "$runs" ] || exit 0

# Giành quyền park trước khi chờ.
#
# HỢP ĐỒNG LÀ "AI GHI SAU CÙNG THÔI ĐƯ", không phải "số lớn hơn thì được
# nói". Bản trước đọc số cũ rồi cộng một rồi ghi — không nguyên tử, nên hai park
# cùng lúc chọn CÙNG một số và cả hai đều tưởng mình mới nhất: đúng cú báo trùng
# mà cơ chế này sinh ra để chặn. Thêm một mã duy nhất vào claim rồi ĐỌC LẠI
# trước khi phát thì kẻ ghi sau cùng thắng và mọi kẻ khác im, không cần nguyên
# tử ở đâu cả. Bất biến: KHÔNG BAO GIỜ có quá một park phát.
#
# Nó cũng sửa luôn hướng thất bại: file không đọc được thì `current` không khớp
# `my_claim` nên ta IM. Bản trước mặc định `current=$my_seq` khi file rác, tức
# mọi park đều tự nhận là chủ và tất cả đều phát — sai hướng, và tệ hơn cả race.
owner_file="$(ofm_home)/park-owner"
my_claim="${OFM_CURSOR_PARK_CLAIM:-$$.$(date +%s).${RANDOM:-0}}"
printf '%s\n' "$my_claim" > "$owner_file" 2>/dev/null || exit 0

summary=$(printf '%s\n' "$runs" | ofm_wait_any_run "${OFM_WAIT_TIMEOUT_MS:-28500000}")
[ -n "$summary" ] || exit 0

# Ta còn là kẻ ghi sau cùng không? Nếu không, đứng im: park mới sẽ thấy cùng
# message đó vì chưa ai ack.
current=$(cat "$owner_file" 2>/dev/null)
[ "$current" = "$my_claim" ] || exit 0

jq -cn --arg m "orca-firstmate: $summary" '{followup_message:$m}'
exit 0
