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

vizier_test_teardown
vizier_test_report
