#!/usr/bin/env bash
# Stop hook của Claude Code — nửa Claude của cơ chế tự thức dậy.
#
# Đăng ký với "asyncRewake": true và "timeout": 28800. Đã kiểm chứng trên
# Claude Code 2.1.236 (docs/verification/2026-08-31-plugin-wake.md):
#   - asyncRewake được honor trong plugin hook: phiên không bị chặn.
#   - exit 2 đánh thức phiên đang IDLE, stderr vào context dạng system reminder.
#   - exit 0 câm tuyệt đối.
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
[ -n "$summary" ] || exit 0

printf 'orca-firstmate: %s\n' "$summary" >&2
exit 2
