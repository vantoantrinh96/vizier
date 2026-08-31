#!/usr/bin/env bash
# Adapter Claude Code: cài payload thành một plugin trong thư mục RIÊNG.
# Không đụng file config nào của người khác, nên gỡ chỉ là xoá thư mục.
set -u

action=${1:-}
case "$action" in
  detect)
    command -v claude >/dev/null 2>&1 || exit 1
    printf 'claude\n'; exit 0 ;;
  install)
    dist=${2:?usage: install <dist_dir> [target_root]}
    target=${3:-$HOME/.claude/skills}
    [ -d "$dist" ] || { printf 'error: dist not found: %s\n' "$dist" >&2; exit 1; }
    dest="$target/orca-firstmate"
    mkdir -p "$target" || exit 1
    # Chép sạch: xoá bản cũ trước để install là idempotent theo đúng nghĩa,
    # không để lại file của phiên bản trước.
    rm -rf "$dest"
    mkdir -p "$dest" || exit 1
    (cd "$dist" && tar cf - .) | (cd "$dest" && tar xf -) || exit 1
    printf 'installed claude adapter -> %s\n' "$dest"
    printf 'note: Claude Code có cơ chế đánh thức phiên idle đầy đủ (asyncRewake).\n'
    exit 0 ;;
  uninstall)
    target=${2:-$HOME/.claude/skills}
    rm -rf "$target/orca-firstmate"
    printf 'removed claude adapter\n'; exit 0 ;;
  *)
    printf 'usage: ofm-adapter-claude.sh detect|install <dist> [target]|uninstall [target]\n' >&2
    exit 2 ;;
esac
