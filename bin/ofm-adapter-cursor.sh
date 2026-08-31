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

_backup() {  # <hooks_json>
  local dir stamp
  dir="$(_home)/backups"
  mkdir -p "$dir" || return 1
  stamp=$(date +%Y%m%d-%H%M%S)
  cp "$1" "$dir/cursor-hooks.$stamp.json" 2>/dev/null || return 1
  printf '%s/cursor-hooks.%s.json' "$dir" "$stamp"
}

action=${1:-}
case "$action" in
  detect)
    command -v cursor-agent >/dev/null 2>&1 || exit 1
    printf 'cursor\n'; exit 0 ;;

  install)
    dist=${2:?usage: install <dist_dir> [hooks_json]}
    H=${3:-$(_default_hooks)}
    cmd="$dist/hooks/wake-cursor.sh"
    if [ -f "$H" ]; then
      jq -e . "$H" >/dev/null 2>&1 || {
        printf 'refused: %s is not valid JSON; fix or move it, this tool will not overwrite it\n' "$H" >&2
        exit 1
      }
      _backup "$H" >/dev/null || { printf 'refused: cannot write backup\n' >&2; exit 1; }
    else
      mkdir -p "$(dirname "$H")" || exit 1
      printf '{"version":1,"hooks":{}}\n' > "$H" || exit 1
    fi
    tmp="$H.ofm.$$"
    jq --arg cmd "$cmd" --arg marker "$MARKER" '
      .version = (.version // 1)
      | .hooks = (.hooks // {})
      | .hooks.stop = (
          ((.hooks.stop // []) | map(select(((.command // "") | contains($marker)) | not)))
          + [{type:"command", command:$cmd, timeout:28800, loop_limit:200}]
        )
    ' "$H" > "$tmp" 2>/dev/null || { rm -f "$tmp"; printf 'refused: merge failed\n' >&2; exit 1; }
    jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; printf 'refused: merge produced invalid JSON\n' >&2; exit 1; }
    mv "$tmp" "$H" || exit 1
    printf 'installed cursor adapter -> %s\n' "$H"
    printf 'note: Cursor KHÔNG chạy hook ở headless `cursor-agent -p`; phải dùng phiên tương tác.\n'
    printf 'note: Cursor đòi trust theo từng thư mục workspace, nên mỗi thư mục mới cần một lần trust.\n'
    exit 0 ;;

  uninstall)
    H=${2:-$(_default_hooks)}
    [ -f "$H" ] || { printf 'nothing to remove\n'; exit 0; }
    jq -e . "$H" >/dev/null 2>&1 || { printf 'refused: %s is not valid JSON\n' "$H" >&2; exit 1; }
    _backup "$H" >/dev/null || { printf 'refused: cannot write backup\n' >&2; exit 1; }
    tmp="$H.ofm.$$"
    jq --arg marker "$MARKER" '
      .hooks.stop = ((.hooks.stop // []) | map(select(((.command // "") | contains($marker)) | not)))
    ' "$H" > "$tmp" 2>/dev/null || { rm -f "$tmp"; exit 1; }
    jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; exit 1; }
    mv "$tmp" "$H" || exit 1
    printf 'removed cursor adapter entry from %s\n' "$H"
    exit 0 ;;

  verify)
    H=${2:-$(_default_hooks)}
    [ -f "$H" ] || exit 1
    n=$(jq --arg marker "$MARKER" '[(.hooks.stop // [])[] | select((.command // "") | contains($marker))] | length' "$H" 2>/dev/null)
    [ "$n" = "1" ] || exit 1
    exit 0 ;;

  *)
    printf 'usage: ofm-adapter-cursor.sh detect|install <dist> [hooks_json]|uninstall [hooks_json]|verify [hooks_json]\n' >&2
    exit 2 ;;
esac
