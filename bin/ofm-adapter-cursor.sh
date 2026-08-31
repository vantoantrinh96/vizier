#!/usr/bin/env bash
# Adapter Cursor: merge phẫu thuật vào ~/.cursor/hooks.json.
#
# VÌ SAO KHÔNG PHẢI PLUGIN. Đã đo (docs/verification/2026-08-31-plugin-wake.md):
# cùng một hook đặt trong ~/.cursor/skills/<name>/ với .cursor-plugin/plugin.json
# khai "hooks" KHÔNG BAO GIỜ fire, kể cả ép bằng --plugin-dir; đặt trong
# ~/.cursor/hooks.json thì chạy đủ vòng. Cursor không cho ta lựa chọn.
#
# FILE NÀY CÓ CHỦ KHÁC. Orca tự cài 8 entry của nó vào đây. Mọi thao tác phải:
#   - nhận diện entry của ta bằng đúng một chuỗi trong .command (tên file
#     wake-cursor.sh, độc lập với đường dẫn cài);
#   - chỉ thêm/gỡ entry đó, không bao giờ viết lại cả file từ mẫu;
#   - sao lưu trước khi ghi;
#   - TỪ CHỐI khi JSON không parse được, thay vì "sửa" bằng cách ghi đè.
set -u

MARKER="wake-cursor.sh"   # tên file là marker: không tool nào khác có file tên này

_home() { printf '%s' "${OFM_HOME:-$HOME/.orca-firstmate}"; }
_default_hooks() { printf '%s/.cursor/hooks.json' "$HOME"; }

# Theo symlink trước khi ghi. `mv tmp "$H"` vào một symlink sẽ THAY THẾ chính
# symlink bằng một file thường — nội dung còn nhưng cấu trúc captain dựng thì mất.
_resolve() {  # <path> — đi hết chuỗi link, không chỉ một tầng
  local p=$1 t hops=0
  while [ -L "$p" ] && [ "$hops" -lt 16 ]; do
    t=$(readlink "$p") || break
    case "$t" in
      /*) p=$t ;;
      *)  p="$(dirname "$p")/$t" ;;
    esac
    hops=$((hops + 1))
  done
  printf '%s' "$p"
}

# Tên backup không được đụng nhau. `date +%S` chỉ phân giải tới giây, mà ba lần
# install liên tiếp nằm gọn trong một giây — bản sau sẽ đè bản trước và trạng
# thái ở giữa thành không khôi phục được.
_backup() {  # <hooks_json> -> in đường dẫn backup
  local dir stamp n=0 f
  dir="$(_home)/backups"
  mkdir -p "$dir" || return 1
  stamp=$(date +%Y%m%d-%H%M%S)
  while [ -e "$dir/cursor-hooks.$stamp.$n.json" ]; do n=$((n + 1)); done
  f="$dir/cursor-hooks.$stamp.$n.json"
  cp "$1" "$f" 2>/dev/null || return 1
  printf '%s' "$f"
}

# Đếm entry KHÔNG phải của ta. Dùng cả trước và sau khi ghi để phát hiện mất
# bản cập nhật. Entry có `.command` không phải chuỗi thì không phải của ta, nên
# được TÍNH và được GIỮ — không được để một entry lạ làm hỏng cả lần cài.
_count_others() {  # <hooks_json>
  jq --arg m "$MARKER" '
    [(.hooks.stop // [])[]
     | select(((.command? | type) != "string") or ((.command | contains($m)) | not))]
    | length' "$1" 2>/dev/null
}
_count_mine() {  # <hooks_json>
  jq --arg m "$MARKER" '
    [(.hooks.stop // [])[]
     | select(((.command? | type) == "string") and (.command | contains($m)))]
    | length' "$1" 2>/dev/null
}

# Quyết định "có mất bản cập nhật không". Tách ra thành hàm để test được bằng
# số dựng sẵn: bản thân cuộc đua thì không tái hiện được trong một unit test,
# nhưng LUẬT quyết định thì phải kiểm được. Một phép đếm rỗng (jq lỗi, file
# không đọc được) tính là LỆCH, không tính là bằng nhau.
_no_lost_update() {  # <others_before> <others_after> <mine_after>
  case "$1$2$3" in *[!0-9]*|'') return 1 ;; esac
  [ "$2" = "$1" ] && [ "$3" = "1" ]
}

# Áp entry của ta lên file hiện tại. Dùng cho cả lần merge đầu lẫn lần thử lại.
_merge_ours() {  # <hooks_json> <cmd>
  local H=$1 cmd=$2 tmp="$1.ofm.$$"
  jq --arg cmd "$cmd" --arg m "$MARKER" '
    .version = (.version // 1)
    | .hooks = (.hooks // {})
    | .hooks.stop = (
        ((.hooks.stop // []) | map(select(
           (((.command? | type) == "string") and (.command | contains($m))) | not)))
        + [{type:"command", command:$cmd, timeout:28800, loop_limit:200}]
      )
  ' "$H" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$H" || { rm -f "$tmp"; return 1; }
}

# `.hooks.stop` phải là mảng, hoặc không tồn tại. Nếu nó là object thì jq sẽ
# ÂM THẦM ép thành mảng và làm mất sạch khoá — hỏng cấu trúc mà không báo lỗi,
# đúng loại thiệt hại tệ nhất trên một file thuộc về tool khác.
_assert_stop_shape() {  # <hooks_json>
  local t
  t=$(jq -r '(.hooks.stop // null) | type' "$1" 2>/dev/null) || return 1
  case "$t" in
    null|array) return 0 ;;
    *) printf 'refused: .hooks.stop là %s chứ không phải mảng; không đụng vào %s\n' "$t" "$1" >&2
       return 1 ;;
  esac
}

action=${1:-}
case "$action" in
  detect)
    command -v cursor-agent >/dev/null 2>&1 || exit 1
    printf 'cursor\n'; exit 0 ;;

  install)
    dist=${2:?usage: install <dist_dir> [hooks_json]}
    H=$(_resolve "${3:-$(_default_hooks)}")
    cmd="$dist/hooks/wake-cursor.sh"
    if [ -f "$H" ]; then
      jq -e . "$H" >/dev/null 2>&1 || {
        printf 'refused: %s không phải JSON hợp lệ; sửa hoặc dời nó đi, tool này không ghi đè\n' "$H" >&2
        exit 1
      }
      _assert_stop_shape "$H" || exit 1
      backup=$(_backup "$H") || { printf 'refused: không ghi được backup\n' >&2; exit 1; }
    else
      mkdir -p "$(dirname "$H")" || exit 1
      printf '{"version":1,"hooks":{}}\n' > "$H" || exit 1
      backup=""
    fi
    others_before=$(_count_others "$H")
    _merge_ours "$H" "$cmd" || { printf 'refused: merge thất bại\n' >&2; exit 1; }

    # ĐỌC LẠI SAU KHI GHI. macOS không có `flock`, nên thay vì ngăn race ta PHÁT
    # HIỆN nó. Nhưng KHÔNG auto-restore: backup là ảnh chụp TRƯỚC merge của ta,
    # nên khôi phục nó sẽ xoá luôn thay đổi của writer đã ghi xen vào — đưa file
    # về trạng thái cũ hơn cả hai bên, tệ hơn là cứ để yên. Thay vào đó: thử
    # merge lại MỘT lần từ trạng thái hiện tại (đã chứa thay đổi của họ), rồi
    # nếu vẫn lệch thì báo thật to và chỉ chỗ backup cho captain tự quyết.
    if ! _no_lost_update "$others_before" "$(_count_others "$H")" "$(_count_mine "$H")"; then
      _merge_ours "$H" "$cmd" || { printf 'refused: merge lại thất bại\n' >&2; exit 1; }
      if ! _no_lost_update "$(_count_others "$H")" "$(_count_others "$H")" "$(_count_mine "$H")"; then
        printf 'refused: có tiến trình khác ghi %s cùng lúc và ta không hoà giải được.\n' "$H" >&2
        printf '  KHÔNG tự khôi phục vì backup cũ hơn thay đổi của họ. Backup ở: %s\n' "${backup:-<không có>}" >&2
        printf '  Hãy kiểm tra file rồi chạy lại install.\n' >&2
        exit 1
      fi
    fi
    printf 'installed cursor adapter -> %s\n' "$H"
    printf 'note: Cursor KHÔNG chạy hook ở headless `cursor-agent -p`; phải dùng phiên tương tác.\n'
    printf 'note: Cursor đòi trust theo từng thư mục workspace, nên mỗi thư mục mới cần một lần trust.\n'
    exit 0 ;;

  uninstall)
    H=$(_resolve "${2:-$(_default_hooks)}")
    [ -f "$H" ] || { printf 'nothing to remove\n'; exit 0; }
    jq -e . "$H" >/dev/null 2>&1 || { printf 'refused: %s không phải JSON hợp lệ\n' "$H" >&2; exit 1; }
    _assert_stop_shape "$H" || exit 1
    _backup "$H" >/dev/null || { printf 'refused: không ghi được backup\n' >&2; exit 1; }
    others_before=$(_count_others "$H")
    tmp="$H.ofm.$$"
    jq --arg m "$MARKER" '
      .hooks.stop = ((.hooks.stop // []) | map(select(
         (((.command? | type) == "string") and (.command | contains($m))) | not)))
    ' "$H" > "$tmp" 2>/dev/null || { rm -f "$tmp"; exit 1; }
    jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; exit 1; }
    mv "$tmp" "$H" || { rm -f "$tmp"; exit 1; }
    [ "$(_count_others "$H")" = "$others_before" ] || {
      printf 'warn: số entry của tool khác đổi trong lúc gỡ\n' >&2; }
    printf 'removed cursor adapter entry from %s\n' "$H"
    exit 0 ;;

  verify)
    dist=${2:?usage: verify <dist_dir> [hooks_json]}
    H=$(_resolve "${3:-$(_default_hooks)}")
    [ -f "$H" ] || exit 1
    # Kiểm ĐÚNG HÌNH DẠNG, không chỉ đếm: một entry cũ còn sót với timeout sai
    # hoặc trỏ vào dist của bản cài trước vẫn "đếm được một" nhưng đã hỏng.
    jq -e --arg cmd "$dist/hooks/wake-cursor.sh" --arg m "$MARKER" '
      [(.hooks.stop // [])[]
       | select(((.command? | type) == "string") and (.command | contains($m)))] as $mine
      | ($mine | length) == 1
        and $mine[0].command == $cmd
        and $mine[0].timeout == 28800
        and $mine[0].loop_limit == 200
    ' "$H" >/dev/null 2>&1 || exit 1
    exit 0 ;;

  *)
    printf 'usage: ofm-adapter-cursor.sh detect|install <dist> [hooks_json]|uninstall [hooks_json]|verify <dist> [hooks_json]\n' >&2
    exit 2 ;;
esac
