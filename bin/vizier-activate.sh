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

# NO CLAUDE_CODE_CHILD_SESSION GUARD HERE, ON PURPOSE. A reviewer claimed a
# subagent session sets CLAUDE_CODE_CHILD_SESSION and carries a DIFFERENT
# session id than its parent, so activating from inside a subagent would
# write a lock the parent's Stop hook could never match -- a silent total
# failure. That claim was accepted without measuring it, and a refusal was
# added here on that basis. It was then measured directly on the captain's
# machine: in an ordinary top-level interactive session, CLAUDE_CODE_CHILD_SESSION=1,
# CLAUDE_CODE_SESSION_ID=fddb6e1c-322f-...; in a subagent dispatched from that
# same session, CLAUDE_CODE_CHILD_SESSION=1 and CLAUDE_CODE_SESSION_ID is the
# SAME fddb6e1c-322f-... -- identical in both. The variable does not
# distinguish a subagent from its parent (it appears to mark the shell as a
# child of the session, which is true for every tool-run command), and a
# subagent shares the parent's session id, so a lock claimed from a subagent
# matches the parent session's hook payload exactly. There is no case where
# this variable being set causes the failure the removed guard was written to
# prevent. Do not reintroduce a refusal on CLAUDE_CODE_CHILD_SESSION without
# first measuring session ids across a real parent/subagent pair yourself.

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
