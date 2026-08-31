# shellcheck shell=bash
# Quét request đang mở và chờ mailbox nhiều Run cùng lúc.
# Cần source lib/ofm-home.sh trước.
#
# VÌ SAO CHỜ SONG PARALLEL: `orca orchestration check` là per-Run (`--run <id>`),
# và spec cho phép nhiều request mở cùng lúc. Chờ tuần tự thì một Run im lặng
# sẽ chặn message của Run khác suốt cả timeout. Ta bung mỗi Run một tiến trình
# nền, ai có tin trước thì thắng, rồi giết phần còn lại.
#
# LUÔN TRUYỀN --run: phiên first mate không phải terminal Orca nên không có
# Run nào bound theo terminal để dựa vào.

OFM_WAKE_TYPES="${OFM_WAKE_TYPES:-worker_done,escalation,question}"

# Nhịp poll. Production để 1000ms: ở timeout tám tiếng thì đó là 28.500 vòng
# thay vì 285.000, mà độ trễ đánh thức thêm dưới một giây thì con người không
# nhận ra. Test hạ xuống 50ms cho nhanh.
OFM_WAKE_POLL_MS="${OFM_WAKE_POLL_MS:-1000}"

# Chỉ trả về phần frontmatter: khối giữa dòng `---` thứ nhất và `---` thứ hai.
# Một chữ "status:" nằm trong phần văn xuôi không được phép quyết định gì, và
# `tr -d '\r'` để một file CRLF không âm thầm bị coi là không-mở.
_ofm_frontmatter() {  # <file>
  awk '
    { gsub(/\r$/, "") }
    NR==1 && $0 != "---" { exit }
    /^---[[:space:]]*$/ { n++; if (n==2) exit; next }
    n==1 { print }
  ' "$1" 2>/dev/null | tr -d '\r'
}

ofm_open_run_ids() {
  local dir f fm status run
  dir=$(ofm_requests_dir)
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    fm=$(_ofm_frontmatter "$f")
    [ -n "$fm" ] || continue
    status=$(printf '%s\n' "$fm" | sed -n 's/^status:[[:space:]]*//p' | head -1)
    [ "$status" = "open" ] || continue
    run=$(printf '%s\n' "$fm" | sed -n 's/^run_id:[[:space:]]*//p' | head -1)
    [ -n "$run" ] && printf '%s\n' "$run"
  done
}

ofm_summarize() {  # <json_line>
  local line=$1 type run detail
  type=$(printf '%s' "$line" | jq -r '.type // "message"' 2>/dev/null)
  run=$(printf '%s' "$line" | jq -r '.run_id // ""' 2>/dev/null)
  detail=$(printf '%s' "$line" | jq -r '.outcome // .body // ""' 2>/dev/null | tr '\n\r\t' '   ' | cut -c1-120)
  # MỌI trường đi qua tr, không chỉ detail: caller dựa vào "đúng một dòng", và
  # một newline lọt qua .type hay .run_id phá hợp đồng đó y như trong .body.
  printf '%s run=%s %s' "${type:-message}" "${run:-?}" "${detail}" \
    | tr '\n\r\t' '   ' | sed 's/[[:space:]]*$//'
}

# Đọc run id từ stdin, chờ tối đa <timeout_ms>, in một dòng tóm tắt hoặc rỗng.
ofm_wait_any_run() {  # <timeout_ms>
  # Cả thân hàm nằm trong một subshell để `trap` chỉ thuộc về nó, không dính
  # vào shell của caller.
  (
    local timeout_ms=$1 tmp run i=0 line poll_s deadline f
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/ofm-wake.XXXXXX") || return 0
    # TRAP TRƯỚC KHI SPAWN BẤT CỨ GÌ. Nếu tiến trình này bị giết từ ngoài —
    # harness cắt hook, captain đóng phiên, máy sleep — thì mọi `orca --wait`
    # con phải chết theo. Không có trap thì MỖI LƯỢT của MỖI phiên trên máy để
    # lại một tiến trình mồ côi có thể sống tới tám tiếng. Trap cũng là đường
    # dọn duy nhất cho cả ba lối ra bình thường, nên không còn chỗ nào phải
    # nhớ gọi cleanup bằng tay.
    trap '_ofm_wake_kill_all "$tmp"; rm -rf "$tmp"' EXIT INT TERM HUP
    while IFS= read -r run; do
      [ -n "$run" ] || continue
      i=$((i + 1))
      (
        orca orchestration check --wait --peek --run "$run" \
          --types "$OFM_WAKE_TYPES" --timeout-ms "$timeout_ms" --json \
          2>/dev/null > "$tmp/$i.out"
      ) &
      printf '%s\n' "$!" >> "$tmp/pids"
    done
    [ "$i" -gt 0 ] || return 0

    # Deadline theo giờ THẬT, không theo bộ đếm logic: bộ đếm cộng dồn nhịp
    # poll rồi trôi khỏi thời gian thực, vì mỗi vòng còn tốn thời gian chạy
    # thân vòng — và càng trôi khi file lớn dần.
    poll_s=$(awk -v m="${OFM_WAKE_POLL_MS}" 'BEGIN{printf "%.3f", m/1000}')
    deadline=$(( $(date +%s) + (timeout_ms + 999) / 1000 ))
    while :; do
      for f in "$tmp"/*.out; do
        [ -s "$f" ] || continue
        # grep rẻ đứng trước jq: `--types` đã bảo đảm mọi message trả về đều
        # có `type`, còn keepalive của Orca đi ra stderr và bị bỏ, nên hầu hết
        # vòng lặp không phải fork jq nào.
        grep -q '"type"' "$f" 2>/dev/null || continue
        line=$(jq -rc 'select(._keepalive|not) | select(.type? != null)' "$f" 2>/dev/null | head -1)
        [ -n "$line" ] || continue
        ofm_summarize "$line"
        return 0
      done
      [ "$(date +%s)" -lt "$deadline" ] || return 0
      sleep "$poll_s"
    done
  )
}

_ofm_wake_kill_all() {  # <tmpdir>
  local p
  [ -f "$1/pids" ] || return 0
  while IFS= read -r p; do
    case "$p" in ''|*[!0-9]*) continue ;; esac
    kill "$p" 2>/dev/null || true
  done < "$1/pids"
  wait 2>/dev/null || true
}
