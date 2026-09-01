#!/usr/bin/env bash
# Claude Code adapter: installs the payload as a plugin in its OWN directory.
# Touches no one else's config file, so uninstalling is just deleting the
# directory.
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
    # Copy clean: delete the old copy first so install is idempotent in the
    # real sense, leaving no file behind from a previous version.
    rm -rf "$dest"
    mkdir -p "$dest" || exit 1
    (cd "$dist" && tar cf - .) | (cd "$dest" && tar xf -) || exit 1
    printf 'installed claude adapter -> %s\n' "$dest"
    printf 'note: Claude Code has a full idle-session wake mechanism (asyncRewake).\n'
    exit 0 ;;
  uninstall)
    target=${2:-$HOME/.claude/skills}
    rm -rf "$target/orca-firstmate"
    printf 'removed claude adapter\n'; exit 0 ;;
  *)
    printf 'usage: ofm-adapter-claude.sh detect|install <dist> [target]|uninstall [target]\n' >&2
    exit 2 ;;
esac
