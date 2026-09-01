#!/usr/bin/env bash
# Cursor's stop hook -- the Cursor half of the self-wake mechanism.
#
# CANNOT REUSE CLAUDE'S RECIPE. Measured on cursor-agent TUI 2026.08.25-3e8eec8
# (docs/verification/2026-08-31-plugin-wake.md):
#   - Cursor runs the hook SYNCHRONOUSLY and waits for it: the hook "parks"
#     and keeps the turn boundary open.
#   - exit 2 is a SILENT NO-OP. Never rely on it.
#   - The only channel is exactly one {"followup_message": "..."} on STDOUT
#     plus exit 0. Cursor receives it and runs a new model turn.
#   - `loop_count` in the payload is Cursor's version of stop_hook_active.
#   - This hook CANNOT be installed as a plugin; it only fires from
#     ~/.cursor/hooks.json.
#
# PARK-OWNER. A message the captain types while a hook is parked is received
# immediately and does NOT kill the parked hook. So two parks can be alive at
# once, both see the same message (we use --peek, so neither acks it), and
# both report -> a duplicate. Each run claims an increasing sequence number;
# before emitting, it must confirm it is still the most recent one.
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)" || exit 0
[ -r "$LIB/vizier-home.sh" ] || exit 0
# shellcheck source=/dev/null
. "$LIB/vizier-home.sh"
# shellcheck source=/dev/null
. "$LIB/vizier-wake-lib.sh"

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null || true)
session_id=$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null) || exit 0
loop_count=$(printf '%s' "$payload" | jq -r '.loop_count // 0' 2>/dev/null)

vizier_lock_matches "$session_id" || exit 0

# Self-imposed ceiling, set LOWER than the loop_limit registered in
# hooks.json, so our bound bites first and Cursor never silently stops
# calling the hook at its own ceiling.
ceiling=${VIZIER_CURSOR_LOOP_CEILING:-5}
case "$loop_count" in ''|*[!0-9]*) loop_count=0 ;; esac

# FIX 8 -- THE CEILING MUST STILL SAY ONE SENTENCE, IT MUST NOT GO SILENT.
# The old version only had `[ "$loop_count" -lt "$ceiling" ] || exit 0`:
# exactly when the ceiling was hit, the hook went absolutely silent -- the
# captain would see Cursor sitting idle with no explanation, unable to tell
# whether WE deliberately stopped it (nowhere near Cursor's own loop_limit of
# 200) or a real error occurred. Split into two cases:
#   - loop_count == ceiling: this is EXACTLY the turn that hits the ceiling ->
#     emit ONE followup_message saying so clearly, then exit 0. This is the
#     first and ONLY turn allowed to say it.
#   - loop_count > ceiling: already reported on a previous turn -> stay
#     silent, same as before.
# Use "==" rather than ">=" for the reporting case: the followup_message we
# emit here itself makes Cursor run one more turn, and that turn's Stop hits
# the hook again with loop_count == ceiling+1 -- if we used ">=" we would
# report again on THAT SAME turn, then the next turn would report again too
# -- an infinite report loop, the exact opposite of what the ceiling is for.
if [ "$loop_count" -gt "$ceiling" ]; then
  exit 0
fi
if [ "$loop_count" -eq "$ceiling" ]; then
  jq -cn --arg m "vizier: hit the self-wake ceiling ($ceiling turns in a row); stopping here, type something to resume supervision." '{followup_message:$m}'
  exit 0
fi

runs=$(vizier_open_run_ids)
[ -n "$runs" ] || exit 0

# Claim park ownership before waiting.
#
# THE CONTRACT IS "WHOEVER WRITES LAST WINS", not "the bigger number gets to
# speak". The previous version read the old number, added one, and wrote it
# back -- not atomic, so two parks running at the same time could pick the
# SAME number and both believe they were the newest: exactly the duplicate
# report this mechanism exists to block. Adding a unique token to the claim
# and READING IT BACK before emitting means the last writer wins and everyone
# else stays silent, with no atomicity needed anywhere. Invariant: NEVER more
# than one park emits.
#
# It also fixes the failure direction: if the file can't be read, `current`
# won't match `my_claim`, so we STAY SILENT. The previous version defaulted
# `current=$my_seq` when the file was garbage, meaning every park believed
# itself the owner and all of them emitted -- the wrong direction, and worse
# than the race itself.
owner_file="$(vizier_home)/park-owner"
my_claim="${VIZIER_CURSOR_PARK_CLAIM:-$$.$(date +%s).${RANDOM:-0}}"
printf '%s\n' "$my_claim" > "$owner_file" 2>/dev/null || exit 0

summary=$(printf '%s\n' "$runs" | vizier_wait_any_run "${VIZIER_WAIT_TIMEOUT_MS:-28500000}")
[ -n "$summary" ] || exit 0

# Are we still the last writer? If not, stay quiet: the new park will see the
# same message anyway, since no one has acked it.
current=$(cat "$owner_file" 2>/dev/null)
[ "$current" = "$my_claim" ] || exit 0

jq -cn --arg m "vizier: $summary" '{followup_message:$m}'
exit 0
