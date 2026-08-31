# shellcheck shell=bash
# Đường dẫn home và lock first-mate duy nhất. Source từ hook, CLI và test.
#
# LOCK LÀ CỔNG CHẶN CỦA HOOK. Hook chạy sau mỗi lượt của MỌI phiên harness
# trên máy, nên ofm_lock_matches phải là thao tác rẻ nhất có thể (một lần đọc
# file) và mọi nhánh không chắc chắn phải trả "không khớp".
#
# LIVENESS KHÔNG BAO GIỜ ĐOÁN. Một pid không phân giải được là "chưa chứng
# minh được", không phải "đã chết": cướp lock của một first mate còn sống là
# hỏng nặng hơn nhiều so với việc bắt captain gỡ tay một lock cũ.

ofm_home() { printf '%s' "${OFM_HOME:-$HOME/.orca-firstmate}"; }
ofm_lock_path() { printf '%s/lock' "$(ofm_home)"; }
ofm_requests_dir() { printf '%s/requests' "$(ofm_home)"; }

ofm_lock_get() {  # <key>
  local f
  f=$(ofm_lock_path)
  [ -f "$f" ] || return 0
  sed -n "s/^$1=//p" "$f" 2>/dev/null | head -1
}

ofm_pid_is_harness() {  # <pid> <harness>
  local pid=$1 want=$2 comm
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  [ -n "$comm" ] || return 1
  case "$comm" in *"$want"*) return 0 ;; esac
  # Một pid sống nhưng tên lệnh khác là pid bị dùng lại; coi như đã chết.
  return 1
}

ofm_harness_pid() {  # <harness> — in pid tổ tiên gần nhất khớp, rỗng nếu không có
  local want=$1 pid=$$ hops=0 comm ppid
  while [ "$pid" != "1" ] && [ "$hops" -lt 20 ]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 0
    case "$comm" in *"$want"*) printf '%s' "$pid"; return 0 ;; esac
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$ppid" ] || return 0
    pid=$ppid
    hops=$((hops + 1))
  done
}

ofm_lock_matches() {  # <session_id>
  local want=$1 have
  [ -n "$want" ] || return 1
  have=$(ofm_lock_get session_id)
  [ -n "$have" ] && [ "$have" = "$want" ]
}

_ofm_lock_write() {  # <session_id> <harness> <pid>
  local f tmp
  f=$(ofm_lock_path)
  mkdir -p "$(ofm_home)" || return 1
  tmp="$f.$$"
  printf 'session_id=%s\nharness=%s\npid=%s\nsince=%s\n' "$1" "$2" "$3" "$(date +%s)" > "$tmp" || return 1
  mv "$tmp" "$f"
}

ofm_lock_claim() {  # <session_id> <harness> <pid>
  local sid=$1 harness=$2 pid=$3 owner owner_pid owner_harness
  owner=$(ofm_lock_get session_id)
  if [ -n "$owner" ]; then
    if [ "$owner" = "$sid" ]; then
      _ofm_lock_write "$sid" "$harness" "$pid" || return 1
      printf 'refreshed session_id=%s\n' "$sid"
      return 0
    fi
    owner_pid=$(ofm_lock_get pid)
    owner_harness=$(ofm_lock_get harness)
    if ofm_pid_is_harness "$owner_pid" "${owner_harness:-$harness}"; then
      printf 'refused held_by=%s pid=%s\n' "$owner" "$owner_pid"
      return 1
    fi
    case "$owner_pid" in
      ''|*[!0-9]*)
        # Không phân giải được chủ cũ: từ chối thay vì cướp.
        printf 'refused held_by=%s pid=unresolvable\n' "$owner"
        return 1
        ;;
    esac
    # ofm_pid_is_harness returned 1, but we need to verify if the process is actually dead
    # (vs just not matching the harness name). If it's alive, refuse to be conservative.
    if kill -0 "$owner_pid" 2>/dev/null; then
      printf 'refused held_by=%s pid=%s\n' "$owner" "$owner_pid"
      return 1
    fi
    _ofm_lock_write "$sid" "$harness" "$pid" || return 1
    printf 'reclaimed from=%s dead_pid=%s\n' "$owner" "$owner_pid"
    return 0
  fi
  _ofm_lock_write "$sid" "$harness" "$pid" || return 1
  printf 'claimed session_id=%s\n' "$sid"
}

ofm_lock_release() {  # <session_id> — chỉ đúng chủ mới xoá được
  ofm_lock_matches "$1" || { printf 'not_owner\n'; return 0; }
  rm -f "$(ofm_lock_path)"
  printf 'released\n'
}
