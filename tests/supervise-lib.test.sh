#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-home.sh"
. "$VIZIER_TEST_REPO/lib/vizier-supervise-lib.sh"

d() { vizier_msg_disposition "$1" "$2"; }

# --- nothing but a processed worker_done ever releases --------------------
for t in heartbeat status question escalation timeout worker_progress; do
  got=$(d direct-PR "{\"delivery_id\":\"d\",\"type\":\"$t\",\"dispatch_id\":\"dispatch-1\"}")
  assert_eq "${got%% *}" "none" "$t never releases"
done

# --- direct-PR ------------------------------------------------------------
assert_eq "$(d direct-PR '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","outcome":"succeeded","body":"PR https://x/1"}')" \
  "release ok" "successful worker_done releases"
assert_eq "$(d direct-PR '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","outcome":"failed","body":"broke"}')" \
  "release ok" "a FAILED worker_done still releases -- the work is over either way"
assert_eq "$(d direct-PR '{"delivery_id":"d","type":"worker_done","outcome":"succeeded"}')" \
  "none stale-no-dispatch" "no dispatch id -> stale, never release"
assert_eq "$(d direct-PR '{"delivery_id":"d","type":"worker_done","dispatch_id":"","outcome":"succeeded"}')" \
  "none stale-no-dispatch" "an explicit empty-string dispatch id is stale too"
assert_eq "$(d direct-PR '{"delivery_id":"d","type":"worker_done","dispatch_id":"   ","outcome":"succeeded"}')" \
  "none stale-no-dispatch" "a whitespace-only dispatch id is as stale as a missing one"

# --- no-mistakes ----------------------------------------------------------
assert_eq "$(d no-mistakes '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","body":"axi_outcome: passed\nPR https://x/1"}')" \
  "release axi-outcome=passed" "terminal outcome releases"
for v in checks-passed failed cancelled; do
  assert_eq "$(d no-mistakes "{\"delivery_id\":\"d\",\"type\":\"worker_done\",\"dispatch_id\":\"dispatch-1\",\"body\":\"axi_outcome: $v\"}")" \
    "release axi-outcome=$v" "$v is terminal"
done
assert_eq "$(d no-mistakes '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","outcome":"succeeded","body":"all good, shipped it"}')" \
  "hold no-axi-outcome" "no outcome line -> HOLD, do not release"
assert_eq "$(d no-mistakes '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","body":"axi_outcome: running"}')" \
  "hold axi-outcome=running" "a non-terminal outcome -> hold"
# a whitespace-only dispatch id must not slip past the stale check even
# when the body otherwise looks terminal
assert_eq "$(d no-mistakes '{"delivery_id":"d","type":"worker_done","dispatch_id":"   ","body":"axi_outcome: passed"}')" \
  "none stale-no-dispatch" "blank dispatch id is stale even with a terminal-looking body"

# --- ambiguous bodies must hold, never pick a winner ----------------------
# two genuine, distinct axi_outcome lines: first-match-wins would release on
# the stale first value, which is exactly the bug this guards against
assert_eq "$(d no-mistakes '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","body":"axi_outcome: passed\naxi_outcome: running"}')" \
  "hold axi-outcome=ambiguous" "two distinct outcome lines must hold, not pick the first"
# the same value repeated is not ambiguous -- only DISTINCT values are
assert_eq "$(d no-mistakes '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","body":"axi_outcome: passed\naxi_outcome: passed"}')" \
  "release axi-outcome=passed" "a repeated identical outcome line is not ambiguous"

# DOCUMENTED RESIDUAL: a body that quotes the required syntax once as an
# example/instruction and only contradicts it in prose still has exactly one
# anchored axi_outcome line, so the ambiguity check cannot catch it. This is
# the case vizier_brief_delivery no-mistakes's new "never quote it earlier as
# an example" sentence exists to prevent at the source; the matcher alone
# cannot close it. Asserted here so a future change to this behavior is
# noticed rather than silent.
assert_eq "$(d no-mistakes '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","body":"Format reminder: report status as\naxi_outcome: passed\nwhen done. Currently still executing tests."}')" \
  "release axi-outcome=passed" "residual: a single quoted example line still releases -- the brief text is the mitigation, not this matcher"

# --- the anchor is load-bearing, not incidental ----------------------------
# the false-positive test above uses a body with NO axi_outcome key at all,
# so it cannot tell an anchored matcher from an unanchored one. This body
# embeds the exact key mid-sentence, so only line-anchoring saves it.
assert_eq "$(d no-mistakes '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","body":"please confirm the axi_outcome: passed field is set"}')" \
  "hold no-axi-outcome" "the key must start the line, not merely appear in it"

# THE FALSE POSITIVE THE EXACT SYNTAX EXISTS TO PREVENT
assert_eq "$(d no-mistakes '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","body":"the tests have not passed yet"}')" \
  "hold no-axi-outcome" "prose containing the word passed must NOT read as an outcome"
assert_eq "$(d no-mistakes '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","body":"  axi_outcome:   passed  "}')" \
  "release axi-outcome=passed" "surrounding whitespace tolerated"
# a multi-line body must still be searched line-anchored, not as one blob
assert_eq "$(d no-mistakes '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","body":"summary line\naxi_outcome: passed\ntrailer"}')" \
  "release axi-outcome=passed" "the outcome line is found anywhere in the body"

# a direct-PR task is not subject to the axi rule at all
assert_eq "$(d direct-PR '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","body":"no axi here"}')" \
  "release ok" "direct-PR needs no axi outcome"

# --- unrecognised mode strings fail closed to the strict check ------------
# an EMPTY mode is what supervise sees before a per-dispatch mode has been
# established (e.g. a mixed-mode batch, or a caller that didn't resolve it) --
# it must NOT be read as "not no-mistakes, so release ok".
assert_eq "$(d "" '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","body":"no axi here"}')" \
  "hold no-axi-outcome" "an empty mode still requires the outcome line"
assert_eq "$(d "" '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","body":"axi_outcome: passed"}')" \
  "release axi-outcome=passed" "an empty mode still releases on a genuine terminal outcome"
# a garbage/typo'd mode is not direct-PR either -- only the exact string is
assert_eq "$(d direct-pr '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","body":"no axi here"}')" \
  "hold no-axi-outcome" "a mistyped mode (wrong case) still requires the outcome line"
assert_eq "$(d bogus-mode '{"delivery_id":"d","type":"worker_done","dispatch_id":"dispatch-1","body":"no axi here"}')" \
  "hold no-axi-outcome" "an unrecognised mode string still requires the outcome line"

# --- the batch plan: ack comes last, and only if all were processed -------
batch='{"delivery_id":"d1","type":"heartbeat"}
{"delivery_id":"d2","type":"worker_done","dispatch_id":"dispatch-1","outcome":"succeeded"}
{"delivery_id":"d3","type":"question","body":"which option?"}'
plan=$(printf '%s\n' "$batch" | vizier_supervise_plan direct-PR)
assert_eq "$(printf '%s\n' "$plan" | grep -c '^PLAN ')" "3" "one plan line per message"
assert_eq "$(printf '%s\n' "$plan" | tail -1)" "ACK d3" "ack is last and names the last delivery"
assert_eq "$(printf '%s\n' "$plan" | grep -n '^ACK ' | cut -d: -f1)" "4" "ack never precedes a plan line"
assert_contains "$plan" "PLAN d2 release ok" "the worker_done in the middle is planned"

# a message that cannot be parsed must block the ACK for the WHOLE batch
bad='{"delivery_id":"d1","type":"worker_done","dispatch_id":"dispatch-1"}
this is not json'
plan=$(printf '%s\n' "$bad" | vizier_supervise_plan direct-PR)
assert_eq "$(printf '%s\n' "$plan" | grep -c '^ACK ')" "0" "one unparseable message withholds the batch ack"
assert_contains "$plan" "UNPARSEABLE" "and says so"

# an empty batch acks nothing
assert_eq "$(printf '' | vizier_supervise_plan direct-PR | wc -l | tr -d ' ')" "0" "empty batch, empty plan"

# --- per-dispatch mode map: one call, one batch, one ack --------------------
# The map is <dispatch_id><TAB><mode>, exactly what the supervise skill
# builds from the request file's `task <id> -> dispatch <id> (<mode>)` notes.
map="$VIZIER_TEST_TMP/mode-map"
printf 'dispatch-A\tdirect-PR\ndispatch-B\tno-mistakes\n' > "$map"

# A batch mixing a direct-PR dispatch and a no-mistakes dispatch, resolved
# correctly IN THE SAME vizier_supervise_plan call -- this is exactly what
# splitting into one call per message could not do (see the library comment).
mixed='{"delivery_id":"m1","type":"worker_done","dispatch_id":"dispatch-A","body":"no axi needed"}
{"delivery_id":"m2","type":"worker_done","dispatch_id":"dispatch-B","body":"still running"}'
plan=$(printf '%s\n' "$mixed" | vizier_supervise_plan no-mistakes "$map")
assert_contains "$plan" "PLAN m1 release ok" "a direct-PR dispatch in the map releases even though the default mode is strict"
assert_contains "$plan" "PLAN m2 hold no-axi-outcome" "a no-mistakes dispatch in the same call still holds, unaffected by the other dispatch's mode"
assert_eq "$(printf '%s\n' "$plan" | tail -1)" "ACK m2" "one batch, one ack, even with mixed per-dispatch modes"

# a dispatch absent from the map falls back to the DEFAULT_MODE ARGUMENT,
# not to empty/strict by accident -- default_mode=direct-PR here, so a bug
# that dropped the fallback (defaulting to "" instead) would show up as a
# wrong hold instead of the expected release.
missing='{"delivery_id":"m3","type":"worker_done","dispatch_id":"dispatch-not-in-map","body":"no axi here"}'
plan=$(printf '%s\n' "$missing" | vizier_supervise_plan direct-PR "$map")
assert_eq "$(printf '%s\n' "$plan" | grep -c '^PLAN ')" "1" "one plan line"
assert_contains "$plan" "PLAN m3 release ok" "a dispatch missing from the map falls back to the given default mode"

# an unparseable message anywhere in a mixed-mode batch still withholds the
# WHOLE batch's ack -- the exact invariant the per-message-call approach broke
bad_mixed='{"delivery_id":"m4","type":"worker_done","dispatch_id":"dispatch-A","body":"no axi needed"}
this is not json'
plan=$(printf '%s\n' "$bad_mixed" | vizier_supervise_plan no-mistakes "$map")
assert_eq "$(printf '%s\n' "$plan" | grep -c '^ACK ')" "0" "an unparseable message withholds the ack even with a mode map in play"
assert_contains "$plan" "PLAN m4 release ok" "the good message before it is still planned correctly"

vizier_test_teardown
vizier_test_report
