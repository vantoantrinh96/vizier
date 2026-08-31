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

ofm_open_run_ids() {
  local dir f status run
  dir=$(ofm_requests_dir)
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    status=$(sed -n 's/^status:[[:space:]]*//p' "$f" | head -1)
    [ "$status" = "open" ] || continue
    run=$(sed -n 's/^run_id:[[:space:]]*//p' "$f" | head -1)
    [ -n "$run" ] && printf '%s\n' "$run"
  done
}

ofm_summarize() {  # <json_line>
  local line=$1 type run detail
  type=$(printf '%s' "$line" | jq -r '.type // "message"' 2>/dev/null)
  run=$(printf '%s' "$line" | jq -r '.run_id // ""' 2>/dev/null)
  detail=$(printf '%s' "$line" | jq -r '.outcome // .body // ""' 2>/dev/null | tr '\n' ' ' | cut -c1-120)
  printf '%s run=%s %s' "${type:-message}" "${run:-?}" "${detail}" | sed 's/[[:space:]]*$//'
}

# Đọc run id từ stdin, chờ tối đa <timeout_ms>, in một dòng tóm tắt hoặc rỗng.
ofm_wait_any_run() {  # <timeout_ms>
  local timeout_ms=$1 tmp run i=0 waited=0 step=100 line
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/ofm-wake.XXXXXX") || return 0
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
  if [ "$i" -eq 0 ]; then rm -rf "$tmp"; return 0; fi

  while [ "$waited" -le "$timeout_ms" ]; do
    for f in "$tmp"/*.out; do
      [ -s "$f" ] || continue
      # Bỏ keepalive; lấy dòng JSON thật đầu tiên.
      line=$(jq -rc 'select(._keepalive|not) | select(.type? != null or .body? != null)' "$f" 2>/dev/null | head -1)
      [ -n "$line" ] || continue
      _ofm_wake_kill_all "$tmp"
      ofm_summarize "$line"
      rm -rf "$tmp"
      return 0
    done
    sleep 0.1
    waited=$((waited + step))
  done
  _ofm_wake_kill_all "$tmp"
  rm -rf "$tmp"
  return 0
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
