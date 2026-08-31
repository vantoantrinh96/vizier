#!/usr/bin/env bash
# Kích hoạt phiên này thành first mate. /firstmate gọi đúng script này.
# In một dòng kết quả; rc 0 = phiên này là first mate, rc 1 = bị từ chối.
set -u

# SESSION ID LẤY TỪ MÔI TRƯỜNG, KHÔNG TỪ MODEL. Đã đo trên máy captain: Claude
# Code đặt CLAUDE_CODE_SESSION_ID (UUID 36 ký tự, trùng tên file transcript của
# phiên) trong môi trường mọi lệnh shell — còn model thì KHÔNG có đường nào biết
# session id của chính nó. Nếu để model tự điền, nó sẽ bịa một giá trị không bao
# giờ khớp `session_id` trong payload mà hook nhận, và khi đó CẢ wake hook LẪN
# PostCompact hook câm vĩnh viễn trong khi lock vẫn bị giữ — hỏng toàn bộ sản
# phẩm, im lặng. Thà từ chối kích hoạt.
# Usage: ofm-activate.sh [harness] [session_id_override]
harness=${1:-claude}
session_id=${2:-${CLAUDE_CODE_SESSION_ID:-}}
if [ -z "$session_id" ]; then
  printf 'refused reason=no_session_id\n' >&2
  printf 'không đọc được session id (CLAUDE_CODE_SESSION_ID rỗng): phiên này\n' >&2
  printf 'không chạy dưới Claude Code, hoặc harness chưa được hỗ trợ.\n' >&2
  exit 2
fi

LIB="$(cd "$(dirname "$0")/../lib" 2>/dev/null && pwd)" || { printf 'error: lib not found\n' >&2; exit 2; }
# shellcheck source=/dev/null
. "$LIB/ofm-home.sh"

mkdir -p "$(ofm_home)/requests" "$(ofm_home)/projects" || { printf 'error: cannot create home\n' >&2; exit 2; }

# PID phải là tiến trình HARNESS sống lâu, không phải shell tạm đang gọi script.
# $PPID là shell của Bash tool và có thể chết ngay sau đó, khiến `kill -0` coi
# một first mate đang sống là đã chết và cho phiên khác cướp lock — đúng hỏng
# hóc mà quy tắc liveness gọi là tệ hơn một lock kẹt. Đã đo: CLAUDE_PID và
# ofm_harness_pid cho cùng một pid, nên ưu tiên biến môi trường rồi mới đi bộ
# cây tiến trình, và KHÔNG có đường lùi nào khác.
pid=${CLAUDE_PID:-}
case "$pid" in ''|*[!0-9]*) pid=$(ofm_harness_pid "$harness") ;; esac
case "$pid" in
  ''|*[!0-9]*)
    printf 'refused reason=no_harness_pid harness=%s\n' "$harness" >&2
    exit 2 ;;
esac

ofm_lock_claim "$session_id" "$harness" "$pid"
