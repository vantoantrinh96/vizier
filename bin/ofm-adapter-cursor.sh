#!/usr/bin/env bash
# Cursor adapter: surgical merge into ~/.cursor/hooks.json.
#
# WHY NOT A PLUGIN. Measured (docs/verification/2026-08-31-plugin-wake.md):
# the same hook placed in ~/.cursor/skills/<name>/ with .cursor-plugin/plugin.json
# declaring "hooks" NEVER fires, even when forced with --plugin-dir; placed
# in ~/.cursor/hooks.json it runs the full cycle. Cursor gives us no choice.
#
# THIS FILE HAS ANOTHER OWNER. Orca installs its own 8 entries into it. Every
# operation must:
#   - identify our entry by exactly one string in .command (the file name
#     wake-cursor.sh, independent of the install path);
#   - only add/remove that one entry, never rewrite the whole file from a
#     template;
#   - back up before writing;
#   - REFUSE when the JSON fails to parse, rather than "fixing" it by
#     overwriting.
set -u

MARKER="wake-cursor.sh"   # the file name is the marker: no other tool has a file with this name

# The decision rule for "was an update lost" lives in the lib, NOT here: a
# script with a `case` dispatch block can't be sourced for testing, and we
# don't invent a test-only branch inside the single riskiest file in the
# project.
LIB="$(cd "$(dirname "$0")/../lib" 2>/dev/null && pwd)" || { printf 'error: lib not found\n' >&2; exit 2; }
# shellcheck source=/dev/null
. "$LIB/ofm-merge-lib.sh"

_home() { printf '%s' "${OFM_HOME:-$HOME/.orca-firstmate}"; }
_default_hooks() { printf '%s/.cursor/hooks.json' "$HOME"; }

# Follow the symlink before writing. `mv tmp "$H"` onto a symlink would
# REPLACE the symlink itself with a plain file -- the content survives but
# the structure the captain set up is lost.
_resolve() {  # <path> -- walk the whole link chain, not just one hop
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

# Backup names must not collide. `date +%S` only resolves to the second, and
# three installs in a row can easily land inside the same second -- the later
# one would overwrite the earlier one and the in-between state would become
# unrecoverable.
_backup() {  # <hooks_json> -> prints the backup path
  local dir stamp n=0 f
  dir="$(_home)/backups"
  mkdir -p "$dir" || return 1
  stamp=$(date +%Y%m%d-%H%M%S)
  while [ -e "$dir/cursor-hooks.$stamp.$n.json" ]; do n=$((n + 1)); done
  f="$dir/cursor-hooks.$stamp.$n.json"
  cp "$1" "$f" 2>/dev/null || return 1
  printf '%s' "$f"
}

# Count entries that are NOT ours. Used both before and after writing to
# detect a lost update. An entry whose `.command` is not a string can't be
# ours, so it gets COUNTED and KEPT -- a foreign entry must never be allowed
# to break an install.
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

# Apply our entry onto the current file. Used for both the first merge and
# a retry.
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

# `.hooks.stop` must be an array, or not exist at all. If it's an object, jq
# would SILENTLY coerce it into an array and wipe out the key entirely --
# structural damage with no error reported, exactly the worst kind of harm
# on a file owned by another tool.
_assert_stop_shape() {  # <hooks_json>
  local t
  t=$(jq -r '(.hooks.stop // null) | type' "$1" 2>/dev/null) || return 1
  case "$t" in
    null|array) return 0 ;;
    *) printf 'refused: .hooks.stop is %s, not an array; not touching %s\n' "$t" "$1" >&2
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
        printf 'refused: %s is not valid JSON; fix it or move it aside, this tool will not overwrite it\n' "$H" >&2
        exit 1
      }
      _assert_stop_shape "$H" || exit 1
      backup=$(_backup "$H") || { printf 'refused: could not write a backup\n' >&2; exit 1; }
    else
      mkdir -p "$(dirname "$H")" || exit 1
      printf '{"version":1,"hooks":{}}\n' > "$H" || exit 1
      backup=""
    fi
    others_before=$(_count_others "$H")
    _merge_ours "$H" "$cmd" || { printf 'refused: merge failed\n' >&2; exit 1; }

    # READ BACK AFTER WRITING. macOS has no `flock`, so instead of preventing
    # the race we DETECT it. But NO auto-restore: the backup is a snapshot
    # from BEFORE our merge, so restoring it would wipe out whatever the
    # other writer wrote in between -- leaving the file older than either
    # side, worse than just leaving it alone. Instead: try re-merging ONCE
    # from the current state (which already contains their change), and if
    # it's still off, report loudly and point the captain at the backup to
    # decide for themselves.
    if ! ofm_no_lost_update "$others_before" "$(_count_others "$H")" "$(_count_mine "$H")"; then
      # FIX 3 -- THIS USED TO BE A COMPARISON WITH ITSELF. The old version
      # called `ofm_no_lost_update "$(_count_others "$H")" "$(_count_others "$H")" ...`
      # -- both `$(_count_others "$H")` calls read the file RIGHT AFTER the
      # re-merge had just finished writing, so they always produced the same
      # number: the check could never detect a lost update on the second
      # pass, no matter what had actually happened while `_merge_ours` was
      # running. The "before" number must be CAPTURED BEFORE the re-merge,
      # exactly the way `others_before` is captured before the first merge,
      # then compared against the number read back AFTER the re-merge
      # finishes.
      others_before_retry=$(_count_others "$H")
      _merge_ours "$H" "$cmd" || { printf 'refused: retry merge failed\n' >&2; exit 1; }
      if ! ofm_no_lost_update "$others_before_retry" "$(_count_others "$H")" "$(_count_mine "$H")"; then
        printf 'refused: another process wrote %s at the same time and we could not reconcile it.\n' "$H" >&2
        printf '  NOT auto-restoring, because the backup is older than their change. Backup at: %s\n' "${backup:-<none>}" >&2
        printf '  Please inspect the file and rerun install.\n' >&2
        exit 1
      fi
    fi
    printf 'installed cursor adapter -> %s\n' "$H"
    printf 'note: Cursor does NOT run hooks in headless `cursor-agent -p`; an interactive session is required.\n'
    printf 'note: Cursor requires trust per workspace directory, so every new directory needs one trust step.\n'
    # FIX 9 -- say it straight AT INSTALL TIME, don't let the captain discover
    # it three days later: Cursor's wake now runs the full cycle, but
    # ACTIVATION (`/firstmate`) does not yet. `ofm-activate.sh` reads
    # CLAUDE_CODE_SESSION_ID, a variable only Claude Code has; Cursor has no
    # equivalent way to get its own session id. Installing this entry only
    # gets the hook ready for when the activation path arrives, it is not
    # ready to use right now.
    printf 'note: Cursor has NO activation path yet -- /firstmate does not work on Cursor, this entry is just standing by.\n'
    exit 0 ;;

  uninstall)
    H=$(_resolve "${2:-$(_default_hooks)}")
    [ -f "$H" ] || { printf 'nothing to remove\n'; exit 0; }
    jq -e . "$H" >/dev/null 2>&1 || { printf 'refused: %s is not valid JSON\n' "$H" >&2; exit 1; }
    _assert_stop_shape "$H" || exit 1
    _backup "$H" >/dev/null || { printf 'refused: could not write a backup\n' >&2; exit 1; }
    others_before=$(_count_others "$H")
    tmp="$H.ofm.$$"
    jq --arg m "$MARKER" '
      .hooks.stop = ((.hooks.stop // []) | map(select(
         (((.command? | type) == "string") and (.command | contains($m))) | not)))
    ' "$H" > "$tmp" 2>/dev/null || { rm -f "$tmp"; exit 1; }
    jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; exit 1; }
    mv "$tmp" "$H" || { rm -f "$tmp"; exit 1; }
    [ "$(_count_others "$H")" = "$others_before" ] || {
      printf 'warn: the entry count for other tools changed while uninstalling\n' >&2; }
    printf 'removed cursor adapter entry from %s\n' "$H"
    exit 0 ;;

  verify)
    dist=${2:?usage: verify <dist_dir> [hooks_json]}
    H=$(_resolve "${3:-$(_default_hooks)}")
    [ -f "$H" ] || exit 1
    # Check the EXACT SHAPE, not just a count: a leftover stale entry with the
    # wrong timeout, or pointing at a previous install's dist, still "counts
    # as one" but is broken.
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
