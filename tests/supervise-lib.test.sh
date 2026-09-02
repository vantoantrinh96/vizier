#!/usr/bin/env bash
# EVERY MESSAGE IN THIS FILE IS BUILT FROM THE CAPTURED SHAPE, never
# hand-written. The bug this suite missed was not a logic error: the parser
# read `.delivery_id`, `.dispatch_id` and `.outcome`, none of which has ever
# existed in an Orca message, and every assertion here fed it literals using
# those same invented names. Both halves agreed, all 574 assertions passed,
# and supervision was completely inert against the real app.
#
# So: messages come from `fake_orca_message_json` (tests/helpers.sh, pinned to
# tests/fixtures/check-delivery.json), batches come out of fake-orca as real
# envelopes, and the sharpest case of all -- Orca's own rejection notice -- is
# read straight out of the captured fixture with no builder in between.
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-home.sh"
. "$VIZIER_TEST_REPO/lib/vizier-mailbox-lib.sh"
. "$VIZIER_TEST_REPO/lib/vizier-supervise-lib.sh"

FIXTURES="$VIZIER_TEST_REPO/tests/fixtures"

# <type> [<body>] [<dispatch_id>] [<outcome>] -- one message, captured shape
m() {
  local type="$1" body="${2:-}" dispatch="${3:-}" outcome="${4:-succeeded}"
  local payload=""
  [ -z "$dispatch" ] || payload=$(fake_orca_payload "$dispatch" "$outcome")
  fake_orca_message_json run-1 msg_test "$type" "$body" "$payload"
}
d() { vizier_msg_disposition "$1" "$2"; }

# "yes" unless the disposition is a release. A helper, not an inline `case`
# inside "$(...)": the `)` of a case pattern closes the command substitution.
not_release() {  # <disposition>
  case "$1" in release*) printf 'no' ;; *) printf 'yes' ;; esac
}

# --- nothing but a processed worker_done ever releases --------------------
for t in heartbeat status question escalation timeout worker_progress; do
  got=$(d direct-PR "$(m "$t" "" dispatch-1)")
  assert_eq "$(not_release "$got")" "yes" "$t never releases"
done

# --- ORCA'S OWN REJECTION NOTICE IS NEVER A COMPLETION --------------------
# Read from the real captured response, not rebuilt: this message is the
# reason the gate exists and a builder could quietly soften it. Orca accepts a
# worker_done naming an unknown dispatch, rewrites it into a rejection, keeps
# `type: worker_done`, keeps the original `dispatchId` in the payload -- so
# the stale-dispatch guard does not bite -- and quotes the original body
# verbatim, terminal `axi_outcome: passed` line and all.
rejection=$(vizier_mailbox_messages "$(cat "$FIXTURES/check-delivery.json")" \
  | jq -c 'select(.type == "worker_done")')
assert_contains "$rejection" '_orcaLifecycleRejection' "the captured fixture really is a rejection notice"
assert_contains "$rejection" 'axi_outcome: passed' "and it really does quote a terminal outcome line"
assert_eq "$(printf '%s' "$rejection" | jq -r '.type')" "worker_done" \
  "and it really does still call itself a worker_done"
assert_eq "$(vizier_mailbox_payload_field "$rejection" dispatchId)" "dispatch-probe" \
  "and its dispatch id is present, so staleness cannot be what saves us"
assert_eq "$(d no-mistakes "$rejection")" "hold lifecycle-rejection" \
  "a real rejection notice HOLDS under the strict mode -- without the gate it releases axi-outcome=passed"
assert_eq "$(d direct-PR "$rejection")" "hold lifecycle-rejection" \
  "and under direct-PR too, where nothing reads the body at all"
# The gate keys on the payload marker, not on the subject text or the type.
assert_eq "$(d direct-PR "$(m worker_done "clean report" dispatch-1)")" "release ok" \
  "an ordinary worker_done is untouched by the rejection gate"

# --- a question or an escalation owes the captain an ANSWER ----------------
# These used to plan `none not-terminal`, the same disposition a heartbeat
# gets, and were then acked away. The vocabulary could not express "a human
# owes a reply", so the only thing preventing a dropped captain decision was
# the model remembering to re-read the raw JSON. `reply` says it in the plan.
for t in question escalation; do
  assert_eq "$(d direct-PR "$(m "$t" "which option?")")" "reply $t" \
    "type $t plans a reply, not the heartbeat disposition"
done
# ...and never a release, whatever the mode or the body says. A question is
# not a terminal event even if it happens to quote a terminal outcome line.
assert_eq "$(d direct-PR "$(m question "axi_outcome: passed" dispatch-1)")" \
  "reply question" "a question carrying a terminal-looking body is still a reply, never a release"
assert_eq "$(d no-mistakes "$(m escalation "axi_outcome: passed" dispatch-1)")" \
  "reply escalation" "an escalation is a reply under the strict mode too"
# A type nobody has a rule for is still `none` -- `reply` is for exactly the
# two types the spec names, not a catch-all for "not worker_done".
assert_eq "$(d direct-PR "$(m heartbeat "" dispatch-1)")" \
  "none not-terminal" "a heartbeat keeps the plain not-terminal disposition"
# A message with no type at all cannot be classified.
assert_eq "$(d direct-PR '{"id":"msg_x","body":"no type here"}')" \
  "none unparseable" "a message with no type is unparseable, never terminal"

# --- direct-PR ------------------------------------------------------------
assert_eq "$(d direct-PR "$(m worker_done "PR https://x/1" dispatch-1)")" \
  "release ok" "successful worker_done releases"
assert_eq "$(d direct-PR "$(m worker_done "broke" dispatch-1 failed)")" \
  "release ok" "a FAILED worker_done still releases -- the work is over either way"
# THE DISPATCH ID LIVES IN THE PAYLOAD STRING. A worker_done with no payload
# at all is exactly what every real message looked like to the old parser,
# which read a top-level `.dispatch_id` that has never existed.
assert_eq "$(d direct-PR "$(m worker_done "done")")" \
  "none stale-no-dispatch" "no payload at all -> stale, never release"
assert_eq "$(d direct-PR "$(m worker_done "done" "")")" \
  "none stale-no-dispatch" "an empty dispatch id is stale too"
assert_eq "$(d direct-PR "$(m worker_done "done" "   ")")" \
  "none stale-no-dispatch" "a whitespace-only dispatch id is as stale as a missing one"
# A payload that is not JSON must not be readable as a dispatch id either.
assert_eq "$(d direct-PR "$(fake_orca_message_json run-1 msg_test worker_done "done" "not json at all")")" \
  "none stale-no-dispatch" "an unparseable payload yields no dispatch id, so the message is stale"

# --- no-mistakes ----------------------------------------------------------
assert_eq "$(d no-mistakes "$(m worker_done "axi_outcome: passed
PR https://x/1" dispatch-1)")" \
  "release axi-outcome=passed" "terminal outcome releases"
for v in checks-passed failed cancelled; do
  assert_eq "$(d no-mistakes "$(m worker_done "axi_outcome: $v" dispatch-1)")" \
    "release axi-outcome=$v" "$v is terminal"
done
assert_eq "$(d no-mistakes "$(m worker_done "all good, shipped it" dispatch-1)")" \
  "hold no-axi-outcome" "no outcome line -> HOLD, do not release"
assert_eq "$(d no-mistakes "$(m worker_done "axi_outcome: running" dispatch-1)")" \
  "hold axi-outcome=running" "a non-terminal outcome -> hold"
# a whitespace-only dispatch id must not slip past the stale check even
# when the body otherwise looks terminal
assert_eq "$(d no-mistakes "$(m worker_done "axi_outcome: passed" "   ")")" \
  "none stale-no-dispatch" "blank dispatch id is stale even with a terminal-looking body"

# --- ambiguous bodies must hold, never pick a winner ----------------------
# two genuine, distinct axi_outcome lines: first-match-wins would release on
# the stale first value, which is exactly the bug this guards against
assert_eq "$(d no-mistakes "$(m worker_done "axi_outcome: passed
axi_outcome: running" dispatch-1)")" \
  "hold axi-outcome=ambiguous" "two distinct outcome lines must hold, not pick the first"
# the same value repeated is not ambiguous -- only DISTINCT values are
assert_eq "$(d no-mistakes "$(m worker_done "axi_outcome: passed
axi_outcome: passed" dispatch-1)")" \
  "release axi-outcome=passed" "a repeated identical outcome line is not ambiguous"

# DOCUMENTED RESIDUAL: a body that quotes the required syntax once as an
# example/instruction and only contradicts it in prose still has exactly one
# anchored axi_outcome line, so the ambiguity check cannot catch it. This is
# the case vizier_brief_delivery no-mistakes's new "never quote it earlier as
# an example" sentence exists to prevent at the source; the matcher alone
# cannot close it. Asserted here so a future change to this behavior is
# noticed rather than silent.
#
# NOTE the one instance of this residual that IS closed: Orca's rejection
# notice quotes the original body the same way, and is caught structurally
# above, before the body is read at all.
assert_eq "$(d no-mistakes "$(m worker_done "Format reminder: report status as
axi_outcome: passed
when done. Currently still executing tests." dispatch-1)")" \
  "release axi-outcome=passed" "residual: a single quoted example line still releases -- the brief text is the mitigation, not this matcher"

# --- the anchor is load-bearing, not incidental ----------------------------
# the false-positive test above uses a body with NO axi_outcome key at all,
# so it cannot tell an anchored matcher from an unanchored one. This body
# embeds the exact key mid-sentence, so only line-anchoring saves it.
assert_eq "$(d no-mistakes "$(m worker_done "please confirm the axi_outcome: passed field is set" dispatch-1)")" \
  "hold no-axi-outcome" "the key must start the line, not merely appear in it"

# THE FALSE POSITIVE THE EXACT SYNTAX EXISTS TO PREVENT
assert_eq "$(d no-mistakes "$(m worker_done "the tests have not passed yet" dispatch-1)")" \
  "hold no-axi-outcome" "prose containing the word passed must NOT read as an outcome"
assert_eq "$(d no-mistakes "$(m worker_done "  axi_outcome:   passed  " dispatch-1)")" \
  "release axi-outcome=passed" "surrounding whitespace tolerated"
# a multi-line body must still be searched line-anchored, not as one blob
assert_eq "$(d no-mistakes "$(m worker_done "summary line
axi_outcome: passed
trailer" dispatch-1)")" \
  "release axi-outcome=passed" "the outcome line is found anywhere in the body"

# a direct-PR task is not subject to the axi rule at all
assert_eq "$(d direct-PR "$(m worker_done "no axi here" dispatch-1)")" \
  "release ok" "direct-PR needs no axi outcome"

# --- unrecognised mode strings fail closed to the strict check ------------
# an EMPTY mode is what supervise sees before a per-dispatch mode has been
# established (e.g. a mixed-mode batch, or a caller that didn't resolve it) --
# it must NOT be read as "not no-mistakes, so release ok".
assert_eq "$(d "" "$(m worker_done "no axi here" dispatch-1)")" \
  "hold no-axi-outcome" "an empty mode still requires the outcome line"
assert_eq "$(d "" "$(m worker_done "axi_outcome: passed" dispatch-1)")" \
  "release axi-outcome=passed" "an empty mode still releases on a genuine terminal outcome"
# a garbage/typo'd mode is not direct-PR either -- only the exact string is
assert_eq "$(d direct-pr "$(m worker_done "no axi here" dispatch-1)")" \
  "hold no-axi-outcome" "a mistyped mode (wrong case) still requires the outcome line"
assert_eq "$(d bogus-mode "$(m worker_done "no axi here" dispatch-1)")" \
  "hold no-axi-outcome" "an unrecognised mode string still requires the outcome line"

# --- the batch plan reads a REAL ENVELOPE, not JSON lines -----------------
# THE ORIGINAL BUG, pinned. `check --json` pretty-prints ONE envelope, in
# --wait mode as much as out of it, so the old JSON-lines reader turned this
# 3-message capture into 77 UNPARSEABLE lines, no plan, and no ack.
real=$(cat "$FIXTURES/check-delivery.json")
# Pinned by BEHAVIOUR, not by a line count that would drift: read the captured
# response the way the old parser did -- one JSON object per line -- and it
# yields no messages whatsoever, because pretty-printing puts one FIELD on a
# line. That is the entire original bug in one assertion.
as_json_lines=$(printf '%s\n' "$real" | jq -rc 'select(.type? != null)' 2>/dev/null | grep -c . || true)
assert_eq "$as_json_lines" "0" \
  "read as JSON lines, the captured response yields ZERO messages -- pretty-printed, one field per line"
assert_eq "$( [ "$(printf '%s' "$real" | wc -l | tr -d ' ')" -gt 3 ] && printf 'yes' )" "yes" \
  "and it really is spread over many more lines than it has messages"
plan=$(printf '%s' "$real" | vizier_supervise_plan direct-PR)
assert_eq "$(printf '%s\n' "$plan" | grep -c '^PLAN ')" "3" \
  "three messages in the captured envelope, three plan lines"
assert_eq "$(printf '%s\n' "$plan" | grep -c '^UNPARSEABLE')" "0" \
  "and none of them is unparseable"
assert_contains "$plan" "PLAN msg_c3fc501363f5 hold lifecycle-rejection" \
  "the captured rejection notice is held, by its real message id"
assert_eq "$(printf '%s\n' "$plan" | tail -1)" "ACK delivery_aad01f2a4ab7" \
  "the ack names the batch's REAL deliveryId, read from the captured response"

# ONE ACK FOR THE WHOLE BATCH, NOT ONE PER MESSAGE. Measured: `--ack` takes
# `result.deliveryId` and clears the entire delivery; `--ack <a message id>`
# is refused outright with `stale_delivery`. The previous design printed one
# ACK line per message and defended it as "correct either way" -- every one
# of those acks would have been rejected and the batch would have replayed
# forever.
assert_eq "$(printf '%s\n' "$plan" | grep -c '^ACK ')" "1" \
  "one ACK line for the batch, whatever the message count"
assert_eq "$(printf '%s\n' "$plan" | grep -n '^ACK ' | cut -d: -f1)" "4" \
  "no ack precedes any plan line"

# --- an unreadable envelope is NOT an empty mailbox -----------------------
# A real one: the coordinator terminal is bound to another Run.
err_plan=$(cat "$FIXTURES/check-error.json" | vizier_supervise_plan direct-PR)
assert_eq "$err_plan" "UNPARSEABLE envelope consumer_fenced" \
  "an ok:false envelope is reported by its real error code, never read as no traffic"
assert_eq "$(printf '%s\n' "$err_plan" | grep -c '^ACK ')" "0" "and nothing is acked"
assert_eq "$(printf '' | vizier_supervise_plan direct-PR)" "UNPARSEABLE envelope unreadable" \
  "orca printing NOTHING is a failure to read, not an empty mailbox"
assert_eq "$(printf 'not json at all' | vizier_supervise_plan direct-PR)" "UNPARSEABLE envelope unreadable" \
  "so is a response that is not JSON"

# --- an empty mailbox IS empty, and acks nothing --------------------------
# A wait that timed out and a mailbox already drained are both healthy.
for fx in check-timeout check-peek-empty; do
  assert_eq "$(cat "$FIXTURES/$fx.json" | vizier_supervise_plan direct-PR)" "" \
    "$fx plans nothing and acks nothing"
done

# --- a peeked batch cannot be acked, and says so --------------------------
# `--peek` and `--all` never create a delivery, so there is no ack handle.
# Silence here would be indistinguishable from a batch withheld because a
# message failed to classify.
fake_orca_message run-p p1 worker_done "PR https://x/1" "$(fake_orca_payload dispatch-1)"
orca orchestration run-use --id "run-p" --json >/dev/null
peeked=$(orca orchestration check --run run-p --peek --json | vizier_supervise_plan direct-PR)
assert_contains "$peeked" "PLAN p1 release ok" "a peeked message is still planned"
assert_contains "$peeked" "UNACKABLE no-delivery-id" "but the batch says out loud that it cannot be acked"
assert_eq "$(printf '%s\n' "$peeked" | grep -c '^ACK ')" "0" "and prints no ACK line"

# --- the batch plan over a real fake-orca delivery ------------------------
fake_orca_message run-b d1 heartbeat "tick"
fake_orca_message run-b d2 worker_done "PR https://x/1" "$(fake_orca_payload dispatch-1)"
fake_orca_message run-b d3 question "which option?"
orca orchestration run-use --id "run-b" --json >/dev/null
plan=$(orca orchestration check --run run-b --json | vizier_supervise_plan direct-PR)
assert_eq "$(printf '%s\n' "$plan" | grep -c '^PLAN ')" "3" "one plan line per message"
assert_contains "$plan" "PLAN d2 release ok" "the worker_done in the middle is planned"
assert_eq "$(printf '%s\n' "$plan" | tail -1)" "ACK delivery-1" "the batch's delivery id is the ack handle"

# a message that cannot be parsed must block the ACK for the WHOLE batch.
# The queue is raw here on purpose: this is the one case that cannot be
# expressed through the captured-shape builder.
fake_orca_message run-bad b1 worker_done "done" "$(fake_orca_payload dispatch-1)"
fake_orca_queue run-bad '{"run_id":"run-bad","type":"worker_done","body":"no id at all"}'
orca orchestration run-use --id "run-bad" --json >/dev/null
plan=$(orca orchestration check --run run-bad --json | vizier_supervise_plan direct-PR)
assert_eq "$(printf '%s\n' "$plan" | grep -c '^ACK ')" "0" "one unparseable message withholds the batch ack"
assert_contains "$plan" "UNPARSEABLE" "and says so"
assert_contains "$plan" "PLAN b1 release ok" "the good message before it is still planned correctly"

# --- per-dispatch mode map: one call, one batch, one ack --------------------
# The map is <dispatch_id><TAB><mode>, exactly what the supervise skill
# builds from the request file's `task <id> -> dispatch <id> (<mode>)` notes.
map="$VIZIER_TEST_TMP/mode-map"
printf 'dispatch-A\tdirect-PR\ndispatch-B\tno-mistakes\n' > "$map"

# A batch mixing a direct-PR dispatch and a no-mistakes dispatch, resolved
# correctly IN THE SAME vizier_supervise_plan call -- this is exactly what
# splitting into one call per message could not do (see the library comment).
# THE MAP IS KEYED ON A DISPATCH ID THAT ONLY EXISTS INSIDE THE PAYLOAD
# STRING: with the old top-level read, every lookup missed and every message
# silently fell back to the default mode.
fake_orca_message run-m m1 worker_done "no axi needed" "$(fake_orca_payload dispatch-A)"
fake_orca_message run-m m2 worker_done "still running" "$(fake_orca_payload dispatch-B)"
orca orchestration run-use --id "run-m" --json >/dev/null
plan=$(orca orchestration check --run run-m --json | vizier_supervise_plan no-mistakes "$map")
assert_contains "$plan" "PLAN m1 release ok" "a direct-PR dispatch in the map releases even though the default mode is strict"
assert_contains "$plan" "PLAN m2 hold no-axi-outcome" "a no-mistakes dispatch in the same call still holds, unaffected by the other dispatch's mode"
assert_eq "$(printf '%s\n' "$plan" | grep -c '^ACK ')" "1" "one batch, one ack, even with mixed per-dispatch modes"

# a dispatch absent from the map falls back to the DEFAULT_MODE ARGUMENT,
# not to empty/strict by accident -- default_mode=direct-PR here, so a bug
# that dropped the fallback (defaulting to "" instead) would show up as a
# wrong hold instead of the expected release.
fake_orca_message run-f m3 worker_done "no axi here" "$(fake_orca_payload dispatch-not-in-map)"
orca orchestration run-use --id "run-f" --json >/dev/null
plan=$(orca orchestration check --run run-f --json | vizier_supervise_plan direct-PR "$map")
assert_eq "$(printf '%s\n' "$plan" | grep -c '^PLAN ')" "1" "one plan line"
assert_contains "$plan" "PLAN m3 release ok" "a dispatch missing from the map falls back to the given default mode"

vizier_test_teardown
vizier_test_report
