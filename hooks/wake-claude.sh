#!/usr/bin/env bash
# Claude Code's Stop hook -- the Claude half of the self-wake mechanism.
#
# Registered with "asyncRewake": true and "timeout": 28800. Verified on
# Claude Code 2.1.236 (docs/verification/2026-08-31-plugin-wake.md):
#   - asyncRewake IS honored in a plugin hook: the session is not blocked.
#   - exit 2 wakes an IDLE session, stderr enters context as a system reminder.
#   - exit 0 is absolutely silent.
#
# THE TWO exit 2 BRANCHES HAVE COMPLETELY DIFFERENT INTENT, read carefully
# before touching them:
#   - mailbox wait timed out -> "re-arm" exit 2 (FIX 2): nothing new to
#     report, this just re-arms the wait for the next turn. Not a spin loop,
#     because each wait runs up to eight hours.
#   - a real message arrived -> exit 2 with a summary: this is a message that
#     has NEVER been reported before (different from "last-wake", or there is
#     no "last-wake" yet).
# And an exit 0 branch is no longer "absolutely silent" in the old sense: the
# ceiling branch keyed on message identity (FIX 1, compared against
# "$(ofm_home)/last-wake") still prints one line to stderr before exiting 0,
# so the captain sees that the loop stopped on purpose rather than the hook
# dying silently.
#
# THIS HOOK RUNS AFTER EVERY TURN OF EVERY CLAUDE CODE SESSION ON THE MACHINE,
# with no dedup. So the gate ordering is mandatory, cheap checks before
# expensive ones, and every uncertain branch exits 0.
#
# THE HOOK NEVER ACKS. Acking belongs to the first mate, once it has finished
# processing the batch; thanks to Orca's replay-to-ack, the hook dying midway
# never loses a message.
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)" || exit 0
[ -r "$LIB/ofm-home.sh" ] || exit 0
# shellcheck source=/dev/null
. "$LIB/ofm-home.sh"
# shellcheck source=/dev/null
. "$LIB/ofm-wake-lib.sh"

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null || true)
session_id=$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null) || exit 0

# Gate 1 -- cheapest: is this session the first mate?
ofm_lock_matches "$session_id" || exit 0

# Gate 2: is there anything to wait on? An empty home costs zero orca calls.
runs=$(ofm_open_run_ids)
[ -n "$runs" ] || exit 0

# Wait for less than the hook's own timeout by a safety margin, so the hook
# always exits under its own control rather than being killed mid-flight by
# the harness.
summary=$(printf '%s\n' "$runs" | ofm_wait_any_run "${OFM_WAIT_TIMEOUT_MS:-28500000}")

# FIX 2 -- A TIMEOUT MUST exit 2, NOT exit 0. An idle session never generates
# a Stop event on its own, so staying silent here means supervision dies
# PERMANENTLY until the captain happens to type something -- not "wait a bit
# more", but a full stop. exit 2 with a "re-arm" line wakes the session just
# enough for it to re-arm this same wait on the next Stop turn. This is NOT a
# spin loop: each re-arm cycle waits up to eight hours, unlike the infinite
# case FIX 1 guards against below (an unacked message repeating every turn).
if [ -z "$summary" ]; then
  printf 'orca-firstmate: mailbox wait timed out, re-arming the wait for the next turn.\n' >&2
  exit 2
fi

# FIX 1 -- THE CEILING THAT STOPS THE INFINITE LOOP, KEYED ON MESSAGE
# IDENTITY, not on the flag alone. The hook uses --peek, so a message the
# first mate hasn't acked yet is still there on the next turn; without this
# ceiling, EVERY wake caused by that message would produce another wake --
# an infinite loop -- and the ack path (owned by the first mate, not the
# hook) lives in a later plan, so today this is the DEFAULT outcome of any
# successful wake if left unguarded.
#
# The first version gated on `stop_hook_active` alone. Re-measuring
# (docs/verification/2026-08-31-plugin-wake.md, section "stop_hook_active
# across a wake chain") gave:
#   fire#1  stop_hook_active=false   <- after a real captain turn
#   fire#2  stop_hook_active=true    <- after being woken by exit 2
#   fire#3  stop_hook_active=true    <- after a second wake
# The ceiling DOES engage -- the infinite loop really is blocked. But the
# flag only says "this turn was caused by a previous hook Stop", NOT "we
# already reported exactly this thing". After ANY exit 2 -- including the
# timeout re-arm branch above, which has nothing to do with any message --
# every subsequent Stop in the chain carries the flag true. A gate based on
# the flag alone would silently swallow a NEW message arriving in the middle
# of a re-arm chain -- worse than a loop, because a loop is at least noisy,
# and this would be silent.
#
# Fix: compare IDENTITY, not the flag alone. Remember the summary last
# reported at "$(ofm_home)/last-wake"; stay silent (exit 0) only when the
# flag is true AND this turn's summary is byte-for-byte identical to the one
# recorded -- i.e. we are certain this is truly the same unacked message, not
# a guess based on this turn having been hook-caused. Still read
# `stop_hook_active` first: without it, the FIRST report (nothing yet in
# last-wake to compare against, or a first run) would also get wrongly
# compared against itself and swallowed -- the flag is the condition that
# makes the identity comparison meaningful, not a condition to skip it.
stop_hook_active=$(printf '%s' "$payload" | jq -r '.stop_hook_active // false' 2>/dev/null)
last_wake_file="$(ofm_home)/last-wake"
last_wake=$(cat "$last_wake_file" 2>/dev/null)
if [ "$stop_hook_active" = "true" ] && [ "$summary" = "$last_wake" ]; then
  printf 'orca-firstmate: hit the wake ceiling (message is identical to the previous one, matched by content rather than just the stop_hook_active flag, and it is still not acked); stopping here, no more wake-ups until the first mate acks it or the captain types something.\n' >&2
  exit 0
fi

# Writing last-wake can fail (home not writable, disk full, ...). Still must
# report and exit 2 rather than die here: losing the record causes at most
# ONE duplicate wake on the next turn (harmless -- that turn just tries to
# write it again), whereas swallowing the message because of a write error
# would lose the signal permanently. Staying silent because of a write error
# is always worse than one duplicate report.
printf '%s' "$summary" > "$last_wake_file" 2>/dev/null

printf 'orca-firstmate: %s\n' "$summary" >&2
exit 2
