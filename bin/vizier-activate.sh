#!/usr/bin/env bash
# Activates this session as the first mate. /vizier calls exactly this
# script. Prints one result line; rc 0 = this session is the first mate,
# rc 1 = refused.
set -u

# SESSION ID COMES FROM THE ENVIRONMENT, NOT FROM THE MODEL. Measured on the
# captain's machine: Claude Code sets CLAUDE_CODE_SESSION_ID (a 36-character
# UUID, matching the session's transcript file name) in the environment of
# every shell command -- while the model has NO way at all to know its own
# session id. If the model were left to fill it in, it would make up a value
# that never matches the `session_id` in the payload the hook receives, and
# then BOTH the wake hook AND the PostCompact hook would go silent forever
# while the lock stayed held -- the whole product broken, silently. Better to
# refuse activation.
# Usage: vizier-activate.sh [harness] [session_id_override]
harness=${1:-claude}
session_id=${2:-${CLAUDE_CODE_SESSION_ID:-}}

# FIX 5 -- A CHILD SESSION/SUBAGENT ACTIVATING IS A TOTAL SILENT BREAKAGE.
# Claude Code sets CLAUDE_CODE_CHILD_SESSION in the environment of a child
# session (a subtask, a subagent) -- ITS session id differs from the session
# id the Stop hook receives for that session (or the hook doesn't fire for
# the child session in the way the first mate needs), so a lock written from
# here could never match again: both the wake hook and the PostCompact hook
# would go silent forever while the lock stayed held, exactly the same class
# of bug that the "session id from the environment, not from the model" rule
# above already blocks for the missing-session-id case. An explicit refusal
# beats letting the captain discover three days later that their first mate
# never once woke up.
if [ -n "${CLAUDE_CODE_CHILD_SESSION:-}" ]; then
  printf 'refused reason=child_session\n' >&2
  printf 'this session is a child/subagent (CLAUDE_CODE_CHILD_SESSION is set): its session id\n' >&2
  printf 'does not match the payload received by the PARENT session Stop hook, so activating\n' >&2
  printf 'here breaks completely, silently. Type /vizier in the actual parent session, not here.\n' >&2
  exit 2
fi

if [ -z "$session_id" ]; then
  printf 'refused reason=no_session_id\n' >&2
  printf 'could not read a session id (CLAUDE_CODE_SESSION_ID is empty): this session\n' >&2
  printf 'is not running under Claude Code, or the harness is not supported yet.\n' >&2
  exit 2
fi

LIB="$(cd "$(dirname "$0")/../lib" 2>/dev/null && pwd)" || { printf 'error: lib not found\n' >&2; exit 2; }
# shellcheck source=/dev/null
. "$LIB/vizier-home.sh"

# PID must be the long-lived HARNESS process, not the transient shell calling
# this script. $PPID is the Bash tool's shell and can die right afterward,
# which would make `kill -0` treat a first mate that's still alive as dead
# and let another session steal the lock -- exactly the failure the liveness
# rule calls worse than a stuck lock. Measured: CLAUDE_PID and
# vizier_harness_pid give the same pid, so prefer the environment variable and
# only then walk the process tree, and there is NO other fallback.
pid=${CLAUDE_PID:-}
case "$pid" in ''|*[!0-9]*) pid=$(vizier_harness_pid "$harness") ;; esac
case "$pid" in
  ''|*[!0-9]*)
    printf 'refused reason=no_harness_pid harness=%s\n' "$harness" >&2
    exit 2 ;;
esac

# Only create the home AFTER every refusal check has passed: a refused
# activation should not leave behind any directory that a later, successful
# activation would find unfamiliar.
mkdir -p "$(vizier_home)/requests" "$(vizier_home)/projects" || { printf 'error: cannot create home\n' >&2; exit 2; }

claim_out=$(vizier_lock_claim "$session_id" "$harness" "$pid"); claim_rc=$?
printf '%s\n' "$claim_out"
# FIX 4 -- the previous owner might be a STUCK-BUT-ALIVE lock: `CLAUDE_PID`
# is the pid of the `claude` process, not of the session, so after `/clear`
# or a resume that pid is still alive but the session_id inside it has
# changed -- `vizier_lock_claim` refuses forever because liveness never guesses
# dead (by design), and the command brief forbids the agent from deleting
# the lock file itself. The captain needs to know the EXPLICIT way out right
# where they run into it, not have to go dig through docs.
case "$claim_out" in
  refused\ held_by=*)
    printf 'if you are sure the session above is done, remove the lock with: vizier unlock\n' >&2
    ;;
esac
exit "$claim_rc"
