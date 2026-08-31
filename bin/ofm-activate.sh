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

# FIX 5 — MỘT PHIÊN CON/SUBAGENT KÍCH HOẠT LÀ HỎNG IM LẶNG TOÀN PHẦN. Claude
# Code đặt CLAUDE_CODE_CHILD_SESSION trong môi trường của một phiên con (task
# con, subagent) — session id của NÓ khác với session id mà hook Stop nhận
# được cho phiên đó (hoặc hook không fire cho phiên con theo cách first mate
# cần), nên lock ghi từ đây không bao giờ khớp lại được: cả wake hook lẫn
# PostCompact hook câm vĩnh viễn trong khi lock vẫn bị giữ, y hệt lớp lỗi mà
# quy tắc "session id từ môi trường, không từ model" ở trên đã chặn cho ca
# thiếu session id. Từ chối tường minh còn hơn để captain phát hiện ba ngày
# sau rằng first mate của họ chưa từng thức dậy lần nào.
if [ -n "${CLAUDE_CODE_CHILD_SESSION:-}" ]; then
  printf 'refused reason=child_session\n' >&2
  printf 'phiên này là con/subagent (CLAUDE_CODE_CHILD_SESSION đã đặt): session id của nó\n' >&2
  printf 'không khớp payload mà hook Stop của phiên CHA nhận, nên kích hoạt ở đây hỏng\n' >&2
  printf 'im lặng toàn phần. Gõ /firstmate ở đúng phiên cha, không phải ở đây.\n' >&2
  exit 2
fi

if [ -z "$session_id" ]; then
  printf 'refused reason=no_session_id\n' >&2
  printf 'không đọc được session id (CLAUDE_CODE_SESSION_ID rỗng): phiên này\n' >&2
  printf 'không chạy dưới Claude Code, hoặc harness chưa được hỗ trợ.\n' >&2
  exit 2
fi

LIB="$(cd "$(dirname "$0")/../lib" 2>/dev/null && pwd)" || { printf 'error: lib not found\n' >&2; exit 2; }
# shellcheck source=/dev/null
. "$LIB/ofm-home.sh"

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

# Chỉ tạo home SAU khi mọi phép từ chối đã qua: một lần kích hoạt bị từ chối
# không nên để lại thư mục nào mà lần kích hoạt thành công sau thấy lạ.
mkdir -p "$(ofm_home)/requests" "$(ofm_home)/projects" || { printf 'error: cannot create home\n' >&2; exit 2; }

claim_out=$(ofm_lock_claim "$session_id" "$harness" "$pid"); claim_rc=$?
printf '%s\n' "$claim_out"
# FIX 4 — chủ cũ có thể là một lock KẸT-NHƯNG-SỐNG: `CLAUDE_PID` là pid của
# tiến trình `claude`, không phải của phiên, nên sau `/clear` hoặc resume, pid
# đó còn sống nhưng session_id bên trong đã đổi — `ofm_lock_claim` từ chối
# vĩnh viễn vì liveness không bao giờ đoán chết (đúng thiết kế), và command
# brief cấm agent tự xoá file lock. Captain cần biết đường thoát TƯỜNG MINH
# ngay tại chỗ họ va phải nó, không phải đi lục docs.
case "$claim_out" in
  refused\ held_by=*)
    printf 'nếu bạn chắc phiên trên đã xong việc, gỡ lock bằng: orca-firstmate unlock\n' >&2
    ;;
esac
exit "$claim_rc"
