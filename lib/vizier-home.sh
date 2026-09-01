# shellcheck shell=bash
# Home path and the single first-mate lock. Sourced by the hook, the CLI, and tests.
#
# THE LOCK IS THE HOOK'S GATE. The hook runs after every turn of EVERY harness
# session on the machine, so vizier_lock_matches must be the cheapest possible
# operation (a single file read), and every uncertain branch must return "no match".
#
# LIVENESS IS NEVER GUESSED. A pid that fails to resolve is "not proven",
# not "dead": stealing the lock from a first mate that is still alive is a far
# worse failure than making the captain manually clear a stale lock.

vizier_home() { printf '%s' "${VIZIER_HOME:-$HOME/.vizier}"; }
vizier_lock_path() { printf '%s/lock' "$(vizier_home)"; }
vizier_requests_dir() { printf '%s/requests' "$(vizier_home)"; }

vizier_lock_get() {  # <key>
  local f
  f=$(vizier_lock_path)
  [ -f "$f" ] || return 0
  sed -n "s/^$1=//p" "$f" 2>/dev/null | head -1
}

vizier_harness_pid() {  # <harness> -- print the nearest matching ancestor pid, empty if none
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

vizier_lock_matches() {  # <session_id>
  local want=$1 have
  [ -n "$want" ] || return 1
  have=$(vizier_lock_get session_id)
  [ -n "$have" ] && [ "$have" = "$want" ]
}

_vizier_lock_write() {  # <session_id> <harness> <pid>
  local f tmp
  f=$(vizier_lock_path)
  mkdir -p "$(vizier_home)" || return 1
  # mktemp, NOT "$f.$$": in bash, `$$` inside a subshell is the PARENT shell's
  # pid, so multiple subshells with the same parent share one tmp name, overwrite
  # each other, and make `mv` fail. The race test is exactly that case, and it
  # once measured wrong because of this bug -- reporting "no one won the lock"
  # when it was really just a collision on the temp file's name.
  tmp=$(mktemp "$f.XXXXXX") || return 1
  printf 'session_id=%s\nharness=%s\npid=%s\nsince=%s\n' "$1" "$2" "$3" "$(date +%s)" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# Returns 0 only if WE created the file. No temp file, no read-back: the
# create IS the decision. `set -C` (noclobber) makes bash's `>` open with
# O_CREAT|O_EXCL, so of any number of processes racing this at once, the
# filesystem itself lets exactly one `>` succeed -- there is no window
# between "decide we should write" and "write" for a second racer to land
# in, because deciding and writing are the same syscall.
_vizier_lock_create_exclusive() {  # <session_id> <harness> <pid>
  local f
  f=$(vizier_lock_path)
  mkdir -p "$(vizier_home)" || return 1
  ( set -C
    printf 'session_id=%s\nharness=%s\npid=%s\nsince=%s\n' \
      "$1" "$2" "$3" "$(date +%s)" > "$f"
  ) 2>/dev/null
}

# Take the CURRENT lock file out of the way, but only if it is still byte-for
# -byte the file we inspected and judged dead. Prints nothing; rc 0 means the
# slot is now ours to create into. `mv` of one specific path succeeds for
# exactly one racer -- the losers find the file already gone -- so the move
# itself is the atomic step; the content comparison after it is what catches
# a third session that legitimately claimed the slot between our inspection
# and our move.
_vizier_lock_take_stale() {  # <snapshot>
  local f stale
  f=$(vizier_lock_path)
  stale="$f.stale.$$.$RANDOM"
  mv "$f" "$stale" 2>/dev/null || return 1
  if [ "$(cat "$stale" 2>/dev/null)" != "$1" ]; then
    # It changed between our inspection and our move: a third session claimed
    # it legitimately. Put it back if the slot is still free, and refuse.
    # Restoring through `set -C` matters -- an unguarded `>` here would
    # overwrite whoever took the slot in the meantime, which is the very theft
    # this function exists to prevent.
    ( set -C; cat "$stale" > "$f" ) 2>/dev/null
    rm -f "$stale"
    return 1
  fi
  rm -f "$stale"
  return 0
}

vizier_lock_claim() {  # <session_id> <harness> <pid>
  local sid=$1 harness=$2 pid=$3 owner owner_pid snapshot
  # The lock file is line-based key=value and read with sed, so a session_id
  # containing a newline would write a file that we ourselves cannot read back
  # -> a lone claimant gets refused for no obvious reason. Block it right at
  # the door, and say exactly why.
  case "$sid" in '') printf 'refused reason=empty_session_id\n'; return 1 ;; esac
  if [ "$(printf '%s' "$sid" | tr -cd '\n' | wc -c | tr -d ' ')" != "0" ]; then
    printf 'refused reason=session_id_has_newline\n'
    return 1
  fi
  owner=$(vizier_lock_get session_id)
  if [ -n "$owner" ]; then
    if [ "$owner" = "$sid" ]; then
      # Only one session can hold this session id, so there is no second
      # racer to lose to here -- the read-modify-write in _vizier_lock_write
      # is safe on this path alone.
      _vizier_lock_write "$sid" "$harness" "$pid" || return 1
      printf 'refreshed session_id=%s\n' "$sid"
      return 0
    fi
    owner_pid=$(vizier_lock_get pid)
    case "$owner_pid" in
      ''|*[!0-9]*)
        # Could not resolve the previous owner: refuse rather than steal.
        printf 'refused held_by=%s pid=unresolvable\n' "$owner"
        return 1
        ;;
    esac
    # ONLY liveness decides. A pid that is still alive never has its lock
    # stolen, even when `ps -o comm=` doesn't match the harness: a command-name
    # mismatch is weak evidence of "not that harness", not evidence of "dead".
    # Stealing the lock of a first mate that is still alive means two sessions
    # writing requests/.
    if kill -0 "$owner_pid" 2>/dev/null; then
      printf 'refused held_by=%s pid=%s\n' "$owner" "$owner_pid"
      return 1
    fi
    # Snapshot BEFORE acting: this is what _vizier_lock_take_stale compares
    # against after it moves the file out of the way, to detect a third
    # session that legitimately claimed the lock between our liveness check
    # and our move.
    snapshot=$(cat "$(vizier_lock_path)" 2>/dev/null)
    if ! _vizier_lock_take_stale "$snapshot"; then
      owner=$(vizier_lock_get session_id)
      printf 'refused held_by=%s pid=%s\n' "${owner:-unknown}" "$(vizier_lock_get pid)"
      return 1
    fi
    if ! _vizier_lock_create_exclusive "$sid" "$harness" "$pid"; then
      owner=$(vizier_lock_get session_id)
      printf 'refused held_by=%s pid=%s\n' "${owner:-unknown}" "$(vizier_lock_get pid)"
      return 1
    fi
    printf 'reclaimed from=%s dead_pid=%s\n' "$owner" "$owner_pid"
    return 0
  fi
  if ! _vizier_lock_create_exclusive "$sid" "$harness" "$pid"; then
    owner=$(vizier_lock_get session_id)
    printf 'refused held_by=%s pid=%s\n' "${owner:-unknown}" "$(vizier_lock_get pid)"
    return 1
  fi
  printf 'claimed session_id=%s\n' "$sid"
  return 0
}

vizier_lock_release() {  # <session_id> -- only the true owner can remove it
  vizier_lock_matches "$1" || { printf 'not_owner\n'; return 0; }
  rm -f "$(vizier_lock_path)"
  printf 'released\n'
}
