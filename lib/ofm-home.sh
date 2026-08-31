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

# Đọc LẠI lock sau khi ghi, và chỉ báo thành công khi ta thực sự là chủ.
# Vì sao cần: chuỗi đọc-quyết-ghi trong ofm_lock_claim không nguyên tử, nên hai
# phiên cùng thấy lock trống (hoặc cùng thấy một chủ đã chết) đều ghi và đều
# tưởng mình thắng — đúng hỏng hóc tệ nhất của thiết kế này: hai phiên cùng ghi
# requests/. Đọc lại biến bất biến thành "KHÔNG BAO GIỜ có quá một phiên tin
# mình giữ lock", không cần thêm file mutex nào và không sinh trạng thái mutex cũ.
_ofm_lock_confirm() {  # <session_id> <verb> <detail>
  local sid=$1 verb=$2 detail=$3 winner
  if ofm_lock_matches "$sid"; then
    printf '%s %s\n' "$verb" "$detail"
    return 0
  fi
  winner=$(ofm_lock_get session_id)
  printf 'refused held_by=%s pid=%s\n' "${winner:-unknown}" "$(ofm_lock_get pid)"
  return 1
}

ofm_lock_claim() {  # <session_id> <harness> <pid>
  local sid=$1 harness=$2 pid=$3 owner owner_pid
  owner=$(ofm_lock_get session_id)
  if [ -n "$owner" ]; then
    if [ "$owner" = "$sid" ]; then
      _ofm_lock_write "$sid" "$harness" "$pid" || return 1
      printf 'refreshed session_id=%s\n' "$sid"
      return 0
    fi
    owner_pid=$(ofm_lock_get pid)
    case "$owner_pid" in
      ''|*[!0-9]*)
        # Không phân giải được chủ cũ: từ chối thay vì cướp.
        printf 'refused held_by=%s pid=unresolvable\n' "$owner"
        return 1
        ;;
    esac
    # CHỈ liveness quyết định. Một pid còn sống không bao giờ bị cướp lock, kể
    # cả khi `ps -o comm=` không khớp harness: tên lệnh không khớp là bằng chứng
    # yếu về "không phải harness đó", không phải bằng chứng về "đã chết". Cướp
    # lock của một first mate còn sống thì hai phiên cùng ghi requests/.
    if kill -0 "$owner_pid" 2>/dev/null; then
      printf 'refused held_by=%s pid=%s\n' "$owner" "$owner_pid"
      return 1
    fi
    _ofm_lock_write "$sid" "$harness" "$pid" || return 1
    _ofm_lock_confirm "$sid" reclaimed "from=$owner dead_pid=$owner_pid"
    return $?
  fi
  _ofm_lock_write "$sid" "$harness" "$pid" || return 1
  _ofm_lock_confirm "$sid" claimed "session_id=$sid"
}

ofm_lock_release() {  # <session_id> — chỉ đúng chủ mới xoá được
  ofm_lock_matches "$1" || { printf 'not_owner\n'; return 0; }
  rm -f "$(ofm_lock_path)"
  printf 'released\n'
}
