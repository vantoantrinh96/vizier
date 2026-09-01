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

# Same extraction as vizier_lock_get, but against an in-memory snapshot
# string instead of the file on disk. Used by vizier_lock_claim so that
# "who is the owner" and "is the owner alive" are answered from the exact
# bytes we are about to hand to _vizier_lock_take_stale, never from a fresh
# read of a file that may have changed under us since the snapshot was taken.
_vizier_lock_field() {  # <key> <snapshot>
  printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -1
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

# Returns 0 only if WE created the file. No temp file, no read-back: the
# create IS the decision. `set -C` (noclobber) makes bash's `>` open with
# O_CREAT|O_EXCL, so of any number of processes racing this at once, the
# filesystem itself lets exactly one `>` succeed -- there is no window
# between "decide we should write" and "write" for a second racer to land
# in, because deciding and writing are the same syscall.
#
# <since> is optional and defaults to "now". vizier_lock_claim's composed
# reclaim/refresh path always passes it precomputed, so that the `date`
# fork does not sit inside the window (see the comment on that path) --
# callers that just want to claim an empty lock (or the brief's direct
# tests of this primitive) can omit it.
_vizier_lock_create_exclusive() {  # <session_id> <harness> <pid> [since]
  local f since
  f=$(vizier_lock_path)
  since=${4:-$(date +%s)}
  # `[ -d ]` first: a plain test is a shell builtin (no fork), so on the
  # composed reclaim/refresh path -- where the directory necessarily
  # already exists, because a lock file was just living in it -- this
  # costs nothing. Only the very first claim ever (no ~/.vizier yet) pays
  # for the `mkdir` fork, and that path has no missing-lock window to widen.
  [ -d "$(vizier_home)" ] || mkdir -p "$(vizier_home)" || return 1
  ( set -C
    printf 'session_id=%s\nharness=%s\npid=%s\nsince=%s\n' \
      "$1" "$2" "$3" "$since" > "$f"
  ) 2>/dev/null
}

# Take the CURRENT lock file out of the way, but only if it is still byte-for
# -byte the file we inspected and judged dead (or, on the refresh path,
# byte-for-byte what we last knew ourselves to hold). Rc 0 means the slot is
# now ours to create into, and prints the temp path holding the old bytes --
# the CALLER removes it, and only after its own create_exclusive has
# finished, so that fork sits outside the missing-lock window (see
# vizier_lock_claim). `mv` of one specific path succeeds for exactly one
# racer -- the losers find the file already gone -- so the move itself is
# the atomic step; the content comparison after it is what catches a third
# session that legitimately claimed the slot between our inspection and our
# move.
_vizier_lock_take_stale() {  # <snapshot>
  local f stale
  f=$(vizier_lock_path)
  stale="$f.stale.$$.$RANDOM"
  mv "$f" "$stale" 2>/dev/null || return 1
  if [ "$(cat "$stale" 2>/dev/null)" != "$1" ]; then
    # Test-only seam: lets tests/lock.test.sh simulate a legitimate
    # claimant landing in the vacated slot during the restore attempt
    # below, so the `set -C` guard on that restore has a real
    # mutation-detecting test instead of only a lint-shaped one. Inert
    # unless a test sets this variable.
    [ -n "${VIZIER_TEST_TAKE_STALE_RESTORE_INJECT:-}" ] && eval "$VIZIER_TEST_TAKE_STALE_RESTORE_INJECT"
    # It changed between our inspection and our move: a third session claimed
    # it legitimately. Put it back if the slot is still free, and refuse.
    # Restoring through `set -C` matters -- an unguarded `>` here would
    # overwrite whoever took the slot in the meantime, which is the very theft
    # this function exists to prevent.
    ( set -C; cat "$stale" > "$f" ) 2>/dev/null
    rm -f "$stale"
    return 1
  fi
  printf '%s' "$stale"
  return 0
}

# Shared refusal for "we did not end up holding the lock". Prints
# `held_by=` ONLY when a lock file genuinely exists to name -- if create
# failed for a non-competitive reason (an unwritable home, say), there is no
# owner to report and no lock to unlock. That distinction matters because
# bin/vizier-activate.sh matches on the literal string `refused held_by=` to
# decide whether to print the `vizier unlock` hint; printing it here for a
# non-race failure would send the captain to run `vizier unlock` on a lock
# that was never written.
_vizier_lock_refuse_current() {
  local owner
  if [ -f "$(vizier_lock_path)" ]; then
    owner=$(vizier_lock_get session_id)
    printf 'refused held_by=%s pid=%s\n' "${owner:-unknown}" "$(vizier_lock_get pid)"
  else
    printf 'refused reason=create_failed\n'
  fi
}

vizier_lock_claim() {  # <session_id> <harness> <pid>
  local sid=$1 harness=$2 pid=$3 owner owner_pid snapshot since stale take_rc verb detail
  # The lock file is line-based key=value and read with sed, so a session_id
  # containing a newline would write a file that we ourselves cannot read back
  # -> a lone claimant gets refused for no obvious reason. Block it right at
  # the door, and say exactly why.
  case "$sid" in '') printf 'refused reason=empty_session_id\n'; return 1 ;; esac
  if [ "$(printf '%s' "$sid" | tr -cd '\n' | wc -c | tr -d ' ')" != "0" ]; then
    printf 'refused reason=session_id_has_newline\n'
    return 1
  fi

  # Snapshot ONCE, before any decision, and answer every question below
  # ("who owns it", "are they alive") from these exact bytes -- never from a
  # fresh read of the file, which can change under us at any point after
  # this line. This is what makes _vizier_lock_take_stale's byte comparison
  # cover the WHOLE decision: if the file changes between this snapshot and
  # our take_stale call, the comparison catches it and we refuse, no matter
  # which of our own checks (owner, liveness) ran on the old bytes in the
  # meantime.
  snapshot=$(cat "$(vizier_lock_path)" 2>/dev/null)

  if [ -z "$snapshot" ]; then
    if ! _vizier_lock_create_exclusive "$sid" "$harness" "$pid"; then
      _vizier_lock_refuse_current
      return 1
    fi
    printf 'claimed session_id=%s\n' "$sid"
    return 0
  fi

  owner=$(_vizier_lock_field session_id "$snapshot")
  owner_pid=$(_vizier_lock_field pid "$snapshot")

  if [ "$owner" = "$sid" ]; then
    # Refreshing our own lock still goes through the same
    # snapshot -> take_stale -> create_exclusive sequence as a reclaim.
    # It looks unnecessary ("only we hold our own session id, what is there
    # to race?") but it is not: a second session can conclude OUR lock is
    # dead (if the pid on file is stale, e.g. after a resume changed it)
    # and reclaim it in between our snapshot and our write. Without going
    # through take_stale, both sides would print success and only one
    # write survives -- exactly the bug this task exists to close, just
    # entered from the refresh side instead of the reclaim side.
    verb=refreshed
    detail="session_id=$sid"
  else
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
    verb=reclaimed
    detail="from=$owner dead_pid=$owner_pid"
  fi

  # RESIDUAL WINDOW: from here until _vizier_lock_create_exclusive's `>`
  # below succeeds, the lock file does not exist, and vizier_lock_matches
  # returns false for the TRUE owner -- the wake hook reads that as "not
  # us" and silently skips the turn. Measured after narrowing (mkdir
  # hoisted out via the builtin `[ -d ]` test above, `date` precomputed
  # here instead of inside create_exclusive, and the stale file's cleanup
  # `rm` deferred past the create below): see task-2b-report.md for the
  # real numbers. What remains is the `mv` and `cat` inside
  # _vizier_lock_take_stale (both external execs the compare-and-swap
  # genuinely needs) plus the `set -C` subshell in create_exclusive. This
  # window cannot be closed further without a second file (a mutex), which
  # this task's brief explicitly rules out. A fresh claimant that lands
  # IN this window sees an empty lock and is free to claim it -- that
  # claimant would then dispossess the true (about to be restored) owner.
  # That is the residual risk this fix accepts, not a case this fix misses.
  since=$(date +%s)
  # Test-only seam: lets tests/lock.test.sh simulate a legitimate claimant
  # landing between our snapshot/liveness decision and our take_stale call
  # -- the exact interleave that used to dispossess a live owner. Inert
  # unless a test sets this variable.
  [ -n "${VIZIER_TEST_LOCK_CLAIM_INJECT:-}" ] && eval "$VIZIER_TEST_LOCK_CLAIM_INJECT"

  stale=$(_vizier_lock_take_stale "$snapshot"); take_rc=$?
  if [ "$take_rc" -ne 0 ]; then
    _vizier_lock_refuse_current
    return 1
  fi
  if ! _vizier_lock_create_exclusive "$sid" "$harness" "$pid" "$since"; then
    rm -f "$stale"
    _vizier_lock_refuse_current
    return 1
  fi
  rm -f "$stale"
  printf '%s %s\n' "$verb" "$detail"
  return 0
}

vizier_lock_release() {  # <session_id> -- only the true owner can remove it
  vizier_lock_matches "$1" || { printf 'not_owner\n'; return 0; }
  rm -f "$(vizier_lock_path)"
  printf 'released\n'
}
