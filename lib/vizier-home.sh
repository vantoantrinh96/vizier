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
# fork does not sit inside the missing-lock window (see the comment on that
# path) -- callers that just want to claim an empty lock (or the brief's
# direct tests of this primitive) can omit it.
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
# now ours to create into, and prints the path holding the old bytes -- the
# CALLER removes it (or restores it), and only after its own
# create_exclusive has finished, so that fork sits outside the missing-lock
# window (see vizier_lock_claim). `mv` of one specific path succeeds for
# exactly one racer -- the losers find the file already gone -- so the move
# itself is the atomic step; the content comparison after it is what catches
# a third session that legitimately claimed the slot between our inspection
# and our move.
#
# <stale_path> is optional. vizier_lock_claim's composed path precomputes
# and passes one, BEFORE calling this function, so that its own trap (set up
# before this call) already knows the exact name to restore even if a signal
# lands while this function is still running -- there would otherwise be a
# gap between this function's internal `mv` succeeding and the caller
# learning the resulting path back from us. Direct callers (and the brief's
# own tests of this primitive) can omit it and get the original self-named
# behavior.
_vizier_lock_take_stale() {  # <snapshot> [stale_path]
  local f stale
  f=$(vizier_lock_path)
  stale=${2:-"$f.stale.$$.$RANDOM"}
  mv "$f" "$stale" 2>/dev/null || return 1
  if [ "$(cat "$stale" 2>/dev/null)" != "$1" ]; then
    # Test-only seam: lets tests/lock.test.sh simulate a legitimate
    # claimant landing in the vacated slot during the restore attempt
    # below, so the `set -C` guard on that restore has a real
    # mutation-detecting test instead of only a lint-shaped one. A plain
    # function check, not an env-var `eval` -- this file is sourced by the
    # wake hook after every turn of every session on the machine, and an
    # env-var-triggered `eval` there is a code-execution surface even when
    # guarded by `${VAR:-}`. A function can only exist here because code
    # already running in THIS shell defined it, so no environment variable
    # can ever reach it.
    command -v _vizier_test_take_stale_seam >/dev/null 2>&1 && _vizier_test_take_stale_seam
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

# Restore a backup _vizier_lock_take_stale produced, guarded by `set -C` for
# the same reason its own restore is: a legitimate new owner may already
# occupy the slot by the time this runs, and an unguarded write would
# silently steal it from them. A no-op if nothing was actually taken (the
# path does not exist), which is what makes it safe to call unconditionally
# from a trap that may fire before any `mv` ever happened. Used by
# vizier_lock_claim on EVERY create-failure path, not only refresh: for a
# reclaim the old owner was already dead so restoring it back is harmless
# (it just stays reclaimable), but for a refresh the backup IS the caller's
# own live lock -- discarding it unconditionally on a create failure that
# had nothing to do with losing a race used to silently unlock a live first
# mate.
_vizier_lock_restore_stale() {  # <stale_path>
  local stale=$1
  [ -n "$stale" ] && [ -e "$stale" ] || return 0
  ( set -C; cat "$stale" > "$(vizier_lock_path)" ) 2>/dev/null
  rm -f "$stale"
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
  local sid=$1 harness=$2 pid=$3 owner owner_pid snapshot since verb detail
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
  # Test-only seam, placed HERE deliberately: review round 1 shipped this
  # seam further down (after the liveness decision), which is downstream of
  # the entire vulnerable region and made the composed-path test unable to
  # see the bug it was written for -- a faithful revert of the snapshot
  # ordering still passed the suite. It must fire before owner/liveness are
  # even derived, so a test can simulate the interleave landing anywhere in
  # that region. A plain function check, not an env-var `eval` -- see the
  # matching comment on _vizier_lock_take_stale for why.
  command -v _vizier_test_lock_seam >/dev/null 2>&1 && _vizier_test_lock_seam

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
    # entered from the refresh side instead of the reclaim side. The cost
    # of that protection is real and is spelled out in the RESIDUAL WINDOW
    # comment below: unifying refresh into this sequence means an ALIVE
    # owner's own refresh now unlinks its lock for the width of that
    # window too, where it previously never did (mktemp+mv was a single
    # atomic replace with no missing-file window at all).
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
  # us" and silently skips the turn. This now applies to REFRESH as well as
  # reclaim (see the comment above): review round 1 measured 150 refreshes
  # by a live owner against a concurrent different-sid thief hammering
  # vizier_lock_claim and found 0/0 successful steals on the pre-unification
  # library (4ab6d86) versus 1/2 on this one (51ec567) -- unifying refresh
  # into this sequence made the window newly reachable by the very session
  # that legitimately owns the lock, not just by a reclaimer. The trade-off
  # is judged net-positive (a wrong owner is worse than a skipped hook
  # turn), not reverted; this comment exists so that judgment is visible,
  # not assumed.
  #
  # Narrowed twice: round 1 hoisted `mkdir` behind a builtin `-d` test,
  # precomputed `date` (see `since` below), and deferred
  # _vizier_lock_take_stale's cleanup `rm` past this create. Round 2 closed
  # an orphaning gap: a signal landing between take_stale's `mv` and this
  # create used to leave a `lock.stale.*` backup on disk and NO lock at
  # all, permanently, because nothing was there to restore it -- the trap
  # below now does that unconditionally on every exit from this section.
  #
  # What is left: the `mv` and `cat` inside _vizier_lock_take_stale (both
  # external execs the compare-and-swap genuinely needs) and the `set -C`
  # subshell in create_exclusive. This is not proven to be the floor --
  # a `mktemp` + `mv`-into-place swap in place of the `set -C` subshell
  # would shave one more fork -- but going further than that (closing the
  # window to zero) needs a second file (a mutex), which this task's brief
  # explicitly rules out. Measured max (8 busy-loop processes, `perl
  # Time::HiRes` polling the file's existence): see task-2b-report.md. A
  # fresh claimant that lands IN whatever window remains sees an empty lock
  # and is free to claim it -- that claimant would then dispossess the true
  # (about to be restored) owner. That is the residual risk this fix
  # accepts, not a case this fix misses.
  since=$(date +%s)

  # The take-stale -> create-or-restore sequence lives in its own subshell
  # so ITS trap belongs only to it, not to vizier_lock_claim's caller --
  # same reason lib/vizier-wake-lib.sh's vizier_wait_any_run scopes its
  # trap to a subshell (a bare `trap - ...` afterward would otherwise erase
  # any trap the caller had already installed for itself). TWO traps, not
  # one, for the same reason recorded there too: a bash SIGNAL trap runs
  # its handler and then CONTINUES execution -- it does NOT end the
  # process -- so a cleanup-only EXIT trap is not enough by itself; the
  # INT/TERM/HUP trap must `exit` explicitly, and it repeats the same
  # cleanup call rather than relying on that `exit` re-triggering the EXIT
  # trap, matching the belt-and-suspenders style already established there.
  # `stale_target` is computed HERE, before the `mv` inside take_stale even
  # runs, specifically so the trap already knows the exact path to restore
  # even if the signal lands while take_stale is still executing --
  # _vizier_lock_restore_stale itself is a safe no-op if that path does not
  # exist yet (signal arrived before the `mv`) or no longer exists (we
  # already succeeded and cleaned it up).
  (
    stale_target="$(vizier_lock_path).stale.$$.$RANDOM"
    success=""
    # `[ -n "$success" ] ||` guards both traps: once create_exclusive has
    # actually succeeded, the backup must NEVER be restored over the fresh
    # lock it just wrote, even if a signal lands in the sliver between that
    # success and our own explicit `rm -f` two lines down.
    trap '[ -n "$success" ] || _vizier_lock_restore_stale "$stale_target"' EXIT
    trap '[ -n "$success" ] || _vizier_lock_restore_stale "$stale_target"; exit 1' INT TERM HUP

    if ! _vizier_lock_take_stale "$snapshot" "$stale_target" >/dev/null; then
      _vizier_lock_refuse_current
      exit 1
    fi
    if _vizier_lock_create_exclusive "$sid" "$harness" "$pid" "$since"; then
      success=1
      rm -f "$stale_target"
      printf '%s %s\n' "$verb" "$detail"
      exit 0
    fi
    # Create failed for ANY reason -- lost race, or something else entirely
    # (e.g. the home going unwritable between the take and the create).
    # The EXIT trap above restores $stale_target unconditionally; nothing
    # further to do here except report why.
    _vizier_lock_refuse_current
    exit 1
  )
  return $?
}

vizier_lock_release() {  # <session_id> -- only the true owner can remove it
  vizier_lock_matches "$1" || { printf 'not_owner\n'; return 0; }
  rm -f "$(vizier_lock_path)"
  printf 'released\n'
}
