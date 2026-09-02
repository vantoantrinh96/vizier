#!/usr/bin/env bash
# EVERY WORKER ROW THE APP HAS ACTUALLY PRODUCED IS READ FROM A CAPTURED
# RESPONSE, never rebuilt. This repo has been burned once already by a test
# double written from an imagined shape: the mailbox parser read
# `.delivery_id`, `.dispatch_id` and `.outcome`, none of which has ever
# existed, every assertion fed it literals using those same invented names,
# all 574 passed, and supervision was completely inert against the real app
# (see the header of lib/vizier-mailbox-lib.sh).
#
# So the shapes here come from tests/fixtures/worker-list-*.json, captured
# from Orca on 2026-09-02, and the sharpest case of all -- the failed
# dispatch that was sitting unnoticed on the captain's machine with a
# retained terminal and a held worktree -- is read straight out of
# worker-list-failed-retained.json with no builder in between.
#
# The only two rows built by hand are `terminalState: active` and
# `terminalState: released`: the CLI enumerates six terminal states and those
# two cannot be captured on this machine (nothing is currently active, and no
# dispatch has ever reached `released`). They come from
# `fake_orca_worker_json` in tests/helpers.sh, which is pinned to the
# captured field set -- one builder, so no test can invent a shape by hand.
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-home.sh"
. "$VIZIER_TEST_REPO/lib/vizier-request-lib.sh"
. "$VIZIER_TEST_REPO/lib/vizier-mailbox-lib.sh"
. "$VIZIER_TEST_REPO/lib/vizier-reconcile-lib.sh"

FIXTURES="$VIZIER_TEST_REPO/tests/fixtures"

# The real capture: one dispatch, run_52f834f62a96.
REAL_FAILED=$(cat "$FIXTURES/worker-list-failed-retained.json")
# The real machine-wide capture: three dispatches across three Runs.
REAL_ALL=$(cat "$FIXTURES/worker-list-all.json")

# The dispatch note the request file really carried for that Run.
REAL_NOTE=$(printf 'task_f5a588ccf365\tctx_70061775b9ca\tdirect-PR')

class_of() {  # <report> <dispatch_id> -- the class word on that dispatch's line
  printf '%s\n' "$1" | awk -v d="$2" '$1 == "RECONCILE" && $3 == d { print $2; exit }'
}
field_of() {  # <report> <dispatch_id> <key>
  printf '%s\n' "$1" \
    | awk -v d="$2" '$1 == "RECONCILE" && $3 == d { print; exit }' \
    | sed -n "s/.*[[:space:]]$3=\([^[:space:]]*\).*/\1/p"
}
summary_of() {  # <report>
  printf '%s\n' "$1" | sed -n 's/^SUMMARY //p'
}

# --- THE LIBRARY MAKES NO orca CALL WHATSOEVER ----------------------------
# Not an assertion about intent: the whole point of the pure-library split is
# that reconciliation can be decided from captured output, so a call would be
# both a design break and untestable. fake-orca logs every invocation, so an
# empty log after a full run is proof.
: > "$VIZIER_FAKE_ORCA_STATE/calls.log"
report=$(vizier_reconcile_run run_52f834f62a96 "$REAL_NOTE" "$REAL_FAILED")
assert_eq "$(fake_orca_calls)" "" "vizier_reconcile_run invoked orca zero times"

# --- THE MEASURED CASE, END TO END ----------------------------------------
# `~/.vizier/requests/mit-license-demo-vizier.md` was status: open, named
# exactly this dispatch, and nothing in vizier ever mentioned that its worker
# had failed with a terminal and a worktree still held.
assert_eq "$(class_of "$report" ctx_70061775b9ca)" "failed" \
  "the real run_52f834f62a96 capture classifies as failed"
assert_eq "$(field_of "$report" ctx_70061775b9ca health)" "failed" \
  "and its health verdict is failed too, not merely its headline"
# THE REPORT MUST NAME THE RETAINED TERMINAL AND THE HELD WORKTREE. A
# classification the captain cannot act on is not worth printing: the whole
# decision here is what to do with those two resources.
assert_eq "$(field_of "$report" ctx_70061775b9ca terminal)" "retained" \
  "the retained terminal state is on the line"
assert_eq "$(field_of "$report" ctx_70061775b9ca reason)" "user_takeover" \
  "with the reason it is retained -- the captain may be the one holding it"
assert_eq "$(field_of "$report" ctx_70061775b9ca handle)" \
  "term_e2a3fc69-05f9-4726-b908-55fd94dd2120" \
  "and the terminal handle, by its real value from the capture"
assert_contains "$report" "worktree=/Users/toantv/orca/workspaces/demo-vizier/mit-license" \
  "and the held worktree PATH, split out of the real worktreeId"
# The worktreeId is `<repo uuid>::<path>`; reporting the uuid would be
# useless to a captain deciding whether to remove a worktree.
assert_eq "$(field_of "$report" ctx_70061775b9ca worktree)" \
  "/Users/toantv/orca/workspaces/demo-vizier/mit-license" \
  "the uuid prefix is stripped, so worktree= really is a path"
assert_eq "$(field_of "$report" ctx_70061775b9ca task)" "task_f5a588ccf365" \
  "the task id comes from the request file's own note"
assert_eq "$(field_of "$report" ctx_70061775b9ca mode)" "direct-PR" \
  "and the delivery mode the note recorded"
assert_eq "$(summary_of "$report")" \
  "total=1 running=0 settled=0 failed=1 retained=0 missing=0 unrecorded=0 unreadable=0 held=1 other_run=0" \
  "the summary counts one failed dispatch and one held resource"

# FAILED WINS OVER RETAINED, and that ordering is a decision, not an
# accident. This row is BOTH: workerState failed and terminalState retained.
# Leading with `retained` would bury the thing that actually went wrong.
assert_eq "$(field_of "$report" ctx_70061775b9ca terminal)" "retained" \
  "the row really is retained as well as failed -- so the precedence is exercised, not vacuous"

# --- a healthy running dispatch stays quiet -------------------------------
# `terminalState: active` cannot be captured on this machine, so this row is
# built from the captured field set (see the file header).
running_note=$(printf 'task_r\tctx_running\tdirect-PR')
running_raw=$(fake_orca_worker_list_json \
  "$(fake_orca_worker_json ctx_running run_live running running active "" /tmp/wt-live task_r)")
report=$(vizier_reconcile_run run_live "$running_note" "$running_raw")
assert_eq "$(class_of "$report" ctx_running)" "running" \
  "a live dispatch on an active terminal is running"
assert_eq "$(summary_of "$report")" \
  "total=1 running=1 settled=0 failed=0 retained=0 missing=0 unrecorded=0 unreadable=0 held=1 other_run=0" \
  "and the only non-zero counts are running and held"

# A SUCCEEDED WORKER STILL HOLDING A LIVE TERMINAL IS NOT RUNNING. This is
# the exact window a session that dies between processing a worker_done and
# calling worker-release leaves behind -- the sibling of the measured bug --
# and reporting it as `running` would hide it.
done_raw=$(fake_orca_worker_list_json \
  "$(fake_orca_worker_json ctx_done run_live succeeded completed active "" /tmp/wt-done task_r)")
report=$(vizier_reconcile_run run_live "$(printf 'task_r\tctx_done\tdirect-PR')" "$done_raw")
assert_eq "$(class_of "$report" ctx_done)" "retained" \
  "succeeded + active terminal is a HELD resource, never running"
assert_eq "$(field_of "$report" ctx_done worker)" "succeeded" \
  "and the line says the worker succeeded, so the report can explain itself"

# --- a released dispatch is settled, and settled is quiet ------------------
# The normal end state of every task: released by supervise, request not yet
# closed by the captain. If this were an anomaly the report would cry wolf on
# the healthy case, and a report nobody reads is worth nothing.
rel_raw=$(fake_orca_worker_list_json \
  "$(fake_orca_worker_json ctx_gone run_live succeeded completed released "" /tmp/wt-gone task_r)")
report=$(vizier_reconcile_run run_live "$(printf 'task_r\tctx_gone\tdirect-PR')" "$rel_raw")
assert_eq "$(class_of "$report" ctx_gone)" "settled" \
  "a released terminal is settled: finished, holding nothing"
assert_eq "$(summary_of "$report")" \
  "total=1 running=0 settled=1 failed=0 retained=0 missing=0 unrecorded=0 unreadable=0 held=0 other_run=0" \
  "and held=0 -- a released dispatch holds no resource"

# --- a RETAINED terminal on a dispatch that SUCCEEDED ---------------------
# Read from the real machine-wide capture, not built: ctx_ae9c346dbbee really
# did finish (`succeeded`/`completed`) and really is still holding a terminal
# under `user_takeover`.
note_ret=$(printf 'task_f42ab05a3525\tctx_ae9c346dbbee\tdirect-PR')
report=$(vizier_reconcile_run run_cbac83d07798 "$note_ret" "$REAL_ALL")
assert_eq "$(class_of "$report" ctx_ae9c346dbbee)" "retained" \
  "a succeeded dispatch whose terminal is retained is reported as retained"
assert_eq "$(field_of "$report" ctx_ae9c346dbbee worker)" "succeeded" \
  "the work really did succeed -- so the retained class is about the resource, not the outcome"
assert_eq "$(field_of "$report" ctx_ae9c346dbbee reason)" "user_takeover" \
  "and the retention reason is named"
assert_contains "$report" "worktree=/Users/toantv/tmp/vizier-smoke" \
  "with the path it is still holding"

# A `release_unknown` terminal on a FAILED dispatch -- also real, from the
# same capture. `release_unknown` is the receipt for "we asked, and cannot
# say whether it worked", so it is read as held, not as gone.
report_all=$(vizier_reconcile_run "" "$(printf 'task_6c411f536fd3\tctx_354ce874603e\tno-mistakes')" "$REAL_ALL")
assert_eq "$(class_of "$report_all" ctx_354ce874603e)" "failed" \
  "a failed dispatch whose release outcome is unknown leads with failed"
assert_eq "$(field_of "$report_all" ctx_354ce874603e terminal)" "release_unknown" \
  "and the line carries the exact terminal state, not a normalised one"

# --- a dispatch in the FILE but not in Orca -------------------------------
# `worker-list` on a Run it does not know returns ok:true with an EMPTY
# workers array -- measured, it is not an error. So "the file names a
# dispatch and Orca does not account for it" is a real, reachable state and
# not a shape this test invented.
empty_raw=$(cat "$FIXTURES/worker-list-empty.json")
assert_eq "$(printf '%s' "$empty_raw" | jq -r '.ok')" "true" \
  "the captured unknown-Run response really is ok:true, not an error"
report=$(vizier_reconcile_run run_52f834f62a96 "$REAL_NOTE" "$empty_raw")
assert_eq "$(class_of "$report" ctx_70061775b9ca)" "missing" \
  "a recorded dispatch Orca does not account for is missing"
assert_eq "$(field_of "$report" ctx_70061775b9ca task)" "task_f5a588ccf365" \
  "and the task and mode from the note are still reported -- they are all the captain has"
assert_eq "$(field_of "$report" ctx_70061775b9ca terminal)" "-" \
  "with every Orca-sourced field an explicit dash, never a guess"
assert_eq "$(summary_of "$report")" \
  "total=1 running=0 settled=0 failed=0 retained=0 missing=1 unrecorded=0 unreadable=0 held=0 other_run=0" \
  "one missing dispatch, and nothing claimed to be held"

# --- a dispatch in Orca but not in the FILE -------------------------------
# The session died between `worker-start` and `vizier_request_note`, so the
# dispatch exists and the ledger has never heard of it. Read from the real
# capture: no note is passed at all.
report=$(vizier_reconcile_run run_52f834f62a96 "" "$REAL_FAILED")
assert_eq "$(class_of "$report" ctx_70061775b9ca)" "unrecorded" \
  "a dispatch Orca knows and the file does not is unrecorded"
# BOTH FACTS, ON ONE LINE. The ledger being wrong and the dispatch having
# failed are two separate things the captain has to act on; a report that
# picked one word would drop the other.
assert_eq "$(field_of "$report" ctx_70061775b9ca health)" "failed" \
  "and its health is still reported as failed -- the join anomaly does not hide the failure"
assert_eq "$(field_of "$report" ctx_70061775b9ca terminal)" "retained" \
  "with the resource it holds"
assert_eq "$(field_of "$report" ctx_70061775b9ca mode)" "-" \
  "the delivery mode is a dash, not a guessed default: the note that would carry it is what is missing"
assert_eq "$(field_of "$report" ctx_70061775b9ca task)" "task_f5a588ccf365" \
  "the task id comes from Orca here, since there is no note to read it from"
assert_eq "$(summary_of "$report")" \
  "total=1 running=0 settled=0 failed=0 retained=0 missing=0 unrecorded=1 unreadable=0 held=1 other_run=0" \
  "counted once, as unrecorded, with the held resource still counted"

# --- an ok:false envelope is NOT an empty fleet ---------------------------
# A real one, captured: `worker-list --terminal-state bogus` -> ok:false,
# invalid_argument. The point is not that argument in particular -- it is
# that a failure envelope reaches this code and must never look like "no
# dispatches, all clear".
err_raw=$(cat "$FIXTURES/worker-list-error.json")
report=$(vizier_reconcile_run run_52f834f62a96 "$REAL_NOTE" "$err_raw")
assert_eq "$report" "UNREADABLE envelope invalid_argument" \
  "an ok:false envelope is reported by its real error code"
# NO SUMMARY LINE IS THE SIGNAL THAT NOTHING WAS RECONCILED. A summary of
# zeroes would be indistinguishable from a genuinely clean Run, which is the
# exact silence this whole library exists to end.
assert_eq "$(summary_of "$report")" "" \
  "and prints no SUMMARY, so a caller cannot mistake it for a clean Run"
assert_eq "$(printf '%s\n' "$report" | grep -c '^RECONCILE ')" "0" \
  "and classifies nothing at all"
# The same must hold for orca printing nothing, and for a non-JSON reply.
assert_eq "$(vizier_reconcile_run run_x "$REAL_NOTE" "")" "UNREADABLE envelope unreadable" \
  "orca printing NOTHING is a failure to read, not an empty fleet"
assert_eq "$(vizier_reconcile_run run_x "$REAL_NOTE" "not json at all")" \
  "UNREADABLE envelope unreadable" "so is a reply that is not JSON"
# An ok:true envelope whose result has no `workers` array at all is shape
# drift, and must fail closed the same way -- this is the half of
# vizier_envelope_ok that `.ok == true` alone would miss.
assert_eq "$(vizier_reconcile_run run_x "$REAL_NOTE" '{"ok":true,"result":{}}')" \
  "UNREADABLE envelope unreadable" \
  "an ok:true envelope with no workers array is drift, not an empty fleet"

# --- a row with no dispatch id cannot be joined, and says so --------------
noid=$(printf '%s' "$(fake_orca_worker_json ctx_x run_live running running active)" \
  | jq -c 'del(.dispatchId)')
report=$(vizier_reconcile_run run_live "" "$(fake_orca_worker_list_json "$noid")")
assert_contains "$report" "RECONCILE unreadable row-1 " \
  "a row with no dispatch id is unreadable, keyed by its position"
assert_eq "$(printf '%s\n' "$report" | grep -c '^RECONCILE unreadable ')" "1" \
  "exactly one such line"
assert_contains "$(summary_of "$report")" "unreadable=1" "and it is counted"

# An unrecognised terminalState fails closed to unreadable rather than to
# running. The workerState enumeration is NOT known (only `failed` and
# `succeeded` have ever been observed), so this file must not treat an
# unfamiliar state word as healthy.
odd=$(fake_orca_worker_list_json \
  "$(fake_orca_worker_json ctx_odd run_live something_new pending wedged)")
report=$(vizier_reconcile_run run_live "$(printf 'task_o\tctx_odd\tdirect-PR')" "$odd")
assert_eq "$(class_of "$report" ctx_odd)" "unreadable" \
  "an unrecognised terminalState is unreadable, never running"
assert_eq "$(field_of "$report" ctx_odd terminal)" "wedged" \
  "and the unrecognised word is reported VERBATIM, so the captain sees what Orca said"
assert_eq "$(field_of "$report" ctx_odd worker)" "something_new" \
  "as is an unrecognised workerState -- the documented residual is mitigated by printing it"

# --- a row that is not an object does not erase the good rows -------------
# The extraction's failure mode is EMPTY OUTPUT, and empty output is
# indistinguishable from an empty fleet -- so one drifted row must not be
# allowed to take every good row with it. It collapses to dashes, is reported
# as `unreadable`, and its healthy neighbour is still classified.
mixed=$(printf '%s' "$REAL_FAILED" | jq -c '.result.workers += ["not an object"]')
report=$(vizier_reconcile_run run_52f834f62a96 "$REAL_NOTE" "$mixed")
assert_eq "$(class_of "$report" ctx_70061775b9ca)" "failed" \
  "the real row beside a drifted one is still classified"
assert_contains "$report" "RECONCILE unreadable row-2 " "and the drifted row is reported as unreadable"
assert_contains "$(summary_of "$report")" "unreadable=1" "and counted"
# A `resource` that is not an object is the same class of drift, one level in.
badres=$(printf '%s' "$REAL_FAILED" | jq -c '.result.workers[0].resource = "gone"')
report=$(vizier_reconcile_run run_52f834f62a96 "$REAL_NOTE" "$badres")
assert_eq "$(class_of "$report" ctx_70061775b9ca)" "failed" \
  "a non-object resource does not stop the dispatch being classified from its own fields"
assert_eq "$(field_of "$report" ctx_70061775b9ca worktree)" "-" \
  "and the fields that lived inside it come out as dashes, never invented"

# IF THE EXTRACTION LOSES A ROW, THE WHOLE RUN IS UNREADABLE. A partial fleet
# reported as a whole one is the same lie as an empty one; the count is
# checked against the envelope's own array length.
# THE GUARD ITSELF, exercised by breaking its collaborator rather than by an
# input. No input the extraction is known to mishandle can reach it any more
# -- that is the point of the hardening above -- so the only honest way to
# prove the second layer works is to make the extraction lose a row on
# purpose. Restored immediately afterwards.
_vizier_reconcile_rows_real=$(declare -f _vizier_reconcile_rows)
_vizier_reconcile_rows() { printf ''; }
dropped=$(vizier_reconcile_run run_52f834f62a96 "$REAL_NOTE" "$REAL_FAILED")
assert_eq "$dropped" "UNREADABLE envelope rows-0-of-1" \
  "an extraction that loses a row makes the whole run unreadable, naming the counts"
assert_eq "$(summary_of "$dropped")" "" \
  "and prints no SUMMARY -- a partial fleet is never reported as a whole one"
eval "$_vizier_reconcile_rows_real"
assert_eq "$(class_of "$(vizier_reconcile_run run_52f834f62a96 "$REAL_NOTE" "$REAL_FAILED")" ctx_70061775b9ca)" \
  "failed" "and the real extraction is back in place for everything after this"

shapeless=$(vizier_reconcile_run run_x "" '{"ok":true,"result":{"workers":[{},{}]}}')
assert_eq "$(printf '%s\n' "$shapeless" | grep -c '^RECONCILE ')" "2" \
  "two shapeless-but-present rows produce two lines, not zero"
assert_eq "$(printf '%s\n' "$shapeless" | grep -c '^SUMMARY ')" "1" \
  "and a summary, so the run counts as reconciled rather than unread"
assert_contains "$shapeless" "unreadable=2" \
  "both reported as unreadable, neither silently dropped"

# --- a value carrying whitespace cannot split a key=value pair ------------
# Every state field is squeezed to `_` so the line stays parseable; only the
# worktree path, which is last, keeps its spaces.
spacey_state=$(printf '%s' "$REAL_FAILED" \
  | jq -c '.result.workers[0].terminalState = "re tained"')
report=$(vizier_reconcile_run run_52f834f62a96 "$REAL_NOTE" "$spacey_state")
assert_eq "$(field_of "$report" ctx_70061775b9ca terminal)" "re_tained" \
  "whitespace inside a state word is collapsed, so the fields after it still parse"
assert_eq "$(field_of "$report" ctx_70061775b9ca reason)" "user_takeover" \
  "and the field after it really is still readable"

# --- a CLEAN, EMPTY home reconciles to nothing at all ---------------------
# A Run with no dispatches and a request with no notes: total=0, every count
# zero. This is what "activation on a home with no open request stays quiet"
# rests on -- there is nothing for the caller to say.
report=$(vizier_reconcile_run run_none "" "$empty_raw")
assert_eq "$(printf '%s\n' "$report" | grep -c '^RECONCILE ')" "0" \
  "no dispatches, no RECONCILE lines"
assert_eq "$(summary_of "$report")" \
  "total=0 running=0 settled=0 failed=0 retained=0 missing=0 unrecorded=0 unreadable=0 held=0 other_run=0" \
  "and an all-zero summary, which is the caller's licence to stay quiet"

# --- the run filter keeps OTHER Runs out of this request's report ---------
# A caller that passes the machine-wide `worker-list --json` instead of the
# per-run one would otherwise have every other Run's dispatch reported as
# this request's `unrecorded` -- a pile of confident, wrong findings. The
# real machine-wide capture holds three dispatches across three Runs.
assert_eq "$(printf '%s' "$REAL_ALL" | jq -r '[.result.workers[].runId] | unique | length')" "3" \
  "the captured machine-wide response really does span three Runs"
report=$(vizier_reconcile_run run_52f834f62a96 "$REAL_NOTE" "$REAL_ALL")
assert_eq "$(printf '%s\n' "$report" | grep -c '^RECONCILE ')" "1" \
  "only this Run's dispatch is reported"
assert_eq "$(class_of "$report" ctx_70061775b9ca)" "failed" "and it is the right one"
# COUNTED, NOT SILENTLY DROPPED. Silence here would make the caller's mistake
# invisible, which is the failure mode this library is a response to.
assert_contains "$(summary_of "$report")" "other_run=2" \
  "the two foreign rows are counted, so the mistake is visible"
# With no run id given, nothing is filtered: the two foreign rows become
# unrecorded, which is the honest answer when the caller did not say which
# Run it was asking about.
report=$(vizier_reconcile_run "" "$REAL_NOTE" "$REAL_ALL")
assert_eq "$(printf '%s\n' "$report" | grep -c '^RECONCILE ')" "3" \
  "with no run id, every row is reported"
assert_contains "$(summary_of "$report")" "unrecorded=2" "the unnamed ones as unrecorded"
assert_contains "$(summary_of "$report")" "other_run=0" "and nothing filtered"

# --- a task id disagreement between the file and Orca is visible ----------
# The request file's note is the ledger's record of what a dispatch was for.
# If Orca says otherwise, trusting either side silently loses the other.
report=$(vizier_reconcile_run run_52f834f62a96 \
  "$(printf 'task_WRONG\tctx_70061775b9ca\tdirect-PR')" "$REAL_FAILED")
assert_eq "$(field_of "$report" ctx_70061775b9ca task)" "task_WRONG!=task_f5a588ccf365" \
  "a task id the file and Orca disagree on is reported as both, not silently reconciled"

# --- duplicate notes for one dispatch: the LAST one wins ------------------
# Same rule vizier_supervise_plan applies to the same notes, and for the same
# reason: a request file can legitimately carry a corrected note appended
# after a mistaken one, and one dispatch must produce one line.
dup=$(printf 'task_a\tctx_70061775b9ca\tno-mistakes\ntask_a\tctx_70061775b9ca\tdirect-PR')
report=$(vizier_reconcile_run run_52f834f62a96 "$dup" "$REAL_FAILED")
assert_eq "$(printf '%s\n' "$report" | grep -c '^RECONCILE ')" "1" \
  "two notes for one dispatch produce ONE line, not two"
assert_eq "$(field_of "$report" ctx_70061775b9ca mode)" "direct-PR" \
  "and the LAST note's mode is the one reported"

# --- the report is deterministic and ordered by the request file ----------
# The order IS the report: the captain reads it as the order their tasks were
# dispatched. Two identical calls must also print identical bytes.
notes3=$(printf 'task_1\tctx_ae9c346dbbee\tdirect-PR\ntask_2\tctx_70061775b9ca\tdirect-PR\ntask_3\tctx_354ce874603e\tno-mistakes')
r1=$(vizier_reconcile_run "" "$notes3" "$REAL_ALL")
r2=$(vizier_reconcile_run "" "$notes3" "$REAL_ALL")
assert_eq "$r1" "$r2" "the same inputs print the same bytes"
assert_eq "$(printf '%s\n' "$r1" | awk '$1 == "RECONCILE" { printf "%s ", $3 }')" \
  "ctx_ae9c346dbbee ctx_70061775b9ca ctx_354ce874603e " \
  "and the lines come out in the request file's own note order, not Orca's"

# --- the report has one line per dispatch, always the same field set ------
# The caller is a language model quoting these lines into a report, so the
# shape has to be stable enough to quote: every field present on every line,
# `-` where there is nothing to say, and `worktree=` last because it is the
# only value that can contain a space.
report=$(vizier_reconcile_run run_52f834f62a96 "$REAL_NOTE" "$REAL_FAILED")
for k in task mode health worker status terminal reason handle worktree; do
  assert_contains "$report" " $k=" "the report line carries a $k= field"
done
assert_eq "$(printf '%s\n' "$report" | sed -n '1s/.*[[:space:]]\(worktree=\)/\1/p' | cut -d= -f1)" \
  "worktree" "worktree= is the last field on the line"
# A worktree path WITH A SPACE still leaves the rest of the line parseable,
# which is the entire reason that field is last.
spacey=$(fake_orca_worker_list_json \
  "$(fake_orca_worker_json ctx_sp run_live failed failed retained user_takeover "/tmp/a dir/wt")")
report=$(vizier_reconcile_run run_live "$(printf 'task_s\tctx_sp\tdirect-PR')" "$spacey")
assert_eq "$(field_of "$report" ctx_sp terminal)" "retained" \
  "a space in the worktree path does not disturb the fields before it"
assert_contains "$report" "worktree=/tmp/a dir/wt" "and the path keeps its space"

# --- vizier_reconcile_health, exercised directly ---------------------------
# The precedence between "it failed" and "a resource is held" is a decision
# the report's whole usefulness rests on, so it is pinned on its own rather
# than only through the rows above.
assert_eq "$(vizier_reconcile_health failed failed retained)" "failed" \
  "failed beats retained"
assert_eq "$(vizier_reconcile_health succeeded failed active)" "failed" \
  "a failed dispatchStatus alone is enough to be failed"
assert_eq "$(vizier_reconcile_health failed completed released)" "failed" \
  "and a failed workerState alone is too, even on a released terminal"
assert_eq "$(vizier_reconcile_health succeeded completed released)" "settled" \
  "released and not failed is settled"
for ts in retained release_pending release_unknown reclaimable; do
  assert_eq "$(vizier_reconcile_health running running "$ts")" "retained" \
    "terminalState $ts means a resource is still held"
done
assert_eq "$(vizier_reconcile_health running running active)" "running" \
  "active and not settled is running"
assert_eq "$(vizier_reconcile_health succeeded completed active)" "retained" \
  "succeeded on an active terminal is held, not running"
assert_eq "$(vizier_reconcile_health - - -)" "unreadable" \
  "no state information at all is unreadable, never running"

# --- the shared, anchored note extraction ---------------------------------
# This is the pattern `supervise` builds its mode map from and the pattern
# reconciliation joins on. It lives in lib/vizier-request-lib.sh so there is
# ONE copy; these assertions are here because reconciliation is the second
# reader whose arrival made a shared owner necessary.
#
# The lookalike case is the one that matters: the notes are in the BODY, and
# the body holds the captain's own words verbatim.
vizier_request_create anchored run-anchor proj proj-id local \
  "Retry note from last time: it failed with -> dispatch d-1 (direct-PR)"
vizier_request_note anchored "task 7 -> dispatch d-1 (no-mistakes)"
assert_eq "$(vizier_request_dispatch_notes anchored)" "$(printf '7\td-1\tno-mistakes')" \
  "only the anchored note is extracted -- the unanchored prose, which comes FIRST, never enters"

# Real request files carry other lines that start with `task ` and are not
# dispatch notes. These three are copied from the captain's actual files.
vizier_request_create realish run-realish proj proj-id local "body"
vizier_request_note realish "task 1: mode=direct-PR chosen explicitly by the captain because the project has no knowledge file yet."
vizier_request_note realish "task 1: copyright holder fixed by captain = \"Lumin PDF Limited\", year 2026."
vizier_request_note realish "task task_8a5ccd5abe4e created (status=ready), spec assembled with mode=direct-PR."
vizier_request_note realish "task task_f5a588ccf365 -> dispatch ctx_70061775b9ca (direct-PR)"
assert_eq "$(vizier_request_dispatch_notes realish)" \
  "$(printf 'task_f5a588ccf365\tctx_70061775b9ca\tdirect-PR')" \
  "the three real non-note lines that start with 'task ' are not mistaken for dispatch notes"

# An empty task id or an empty dispatch id is not a note. The earlier
# in-skill pattern used `*` and would have matched these; reconciliation
# would then have reported an empty dispatch id as one Orca had lost.
vizier_request_create blanks run-blanks proj proj-id local "body"
vizier_request_note blanks "task  -> dispatch d-9 (direct-PR)"
vizier_request_note blanks "task 4 -> dispatch  (direct-PR)"
assert_eq "$(vizier_request_dispatch_notes blanks)" "" \
  "a note with a blank task or dispatch id is not a note"

# A MODE CARRYING A SPACE MUST NOT REACH THE REPORT LINE. The mode used to be
# captured with `.*`, so a hand-edited or pasted body line put a space inside
# a `key=value` pair and shifted `health=` and everything after it out of
# position -- the one field allowed to hold a space is `worktree=`, and only
# because it is last. Bounded at the reader, the line is not a note at all,
# which is loud in both directions: the dispatch reconciles as `unrecorded`
# rather than being reported under a corrupt shape.
vizier_request_create spacey-mode run_52f834f62a96 proj proj-id local "body"
vizier_request_note spacey-mode "task task_f5a588ccf365 -> dispatch ctx_70061775b9ca (direct-PR, retried by hand)"
assert_eq "$(vizier_request_dispatch_notes spacey-mode)" "" \
  "a note whose mode carries a space is not a dispatch note"
report=$(vizier_reconcile_run run_52f834f62a96 \
  "$(vizier_request_dispatch_notes spacey-mode)" "$REAL_FAILED")
assert_eq "$(field_of "$report" ctx_70061775b9ca health)" "failed" \
  "the dispatch is still reported, with health= at its contracted position"
assert_eq "$(field_of "$report" ctx_70061775b9ca mode)" "-" \
  "and no unknown mode is invented for it"
assert_eq "$(class_of "$report" ctx_70061775b9ca)" "unrecorded" \
  "the malformed ledger entry is named, not silently honoured"

# A slug with no file at all answers empty and rc 0 -- reconciliation runs
# over open requests, and a file that vanished mid-scan must not abort it.
assert_eq "$(vizier_request_dispatch_notes no-such-request)" "" \
  "an absent request file yields no notes"
assert_rc "$(vizier_request_dispatch_notes no-such-request >/dev/null; echo $?)" "0" \
  "and does not fail the caller"

# The two-column mode map `supervise` joins on is this output's `cut -f2,3`.
assert_eq "$(vizier_request_dispatch_notes realish | cut -f2,3)" \
  "$(printf 'ctx_70061775b9ca\tdirect-PR')" \
  "supervise's <dispatch>TAB<mode> map is a projection of the same extraction"

# --- end to end from a REAL request file ----------------------------------
# The file is written through the library, the notes are read back out of it,
# and the captured response is reconciled against them -- the whole path
# activation walks, with nothing hand-assembled in the middle.
vizier_request_create mit-demo run_52f834f62a96 demo-vizier github:x/demo-vizier local \
  "thêm 1 file cho MIT license cho repo hiện tại"
vizier_request_note mit-demo "task 1: mode=direct-PR chosen explicitly by the captain because the project has no knowledge file yet."
vizier_request_note mit-demo "task task_f5a588ccf365 -> dispatch ctx_70061775b9ca (direct-PR)"
assert_eq "$(vizier_request_get mit-demo status)" "open" "the request is open"
report=$(vizier_reconcile_run "$(vizier_request_get mit-demo run_id)" \
  "$(vizier_request_dispatch_notes mit-demo)" "$REAL_FAILED")
assert_eq "$(class_of "$report" ctx_70061775b9ca)" "failed" \
  "end to end: the request file the captain really had reconciles to failed"
assert_contains "$report" "worktree=/Users/toantv/orca/workspaces/demo-vizier/mit-license" \
  "and names the worktree that was still held"
assert_contains "$(summary_of "$report")" "held=1" "with the resource counted as held"

# NOTHING WAS WRITTEN OR RELEASED. Reconciliation reads and reports; the
# request file must come out of it byte for byte unchanged, and no orca call
# may have been made across this whole file.
before=$(shasum -a 256 "$(vizier_request_path mit-demo)" | awk '{print $1}')
vizier_reconcile_run run_52f834f62a96 "$(vizier_request_dispatch_notes mit-demo)" "$REAL_FAILED" >/dev/null
after=$(shasum -a 256 "$(vizier_request_path mit-demo)" | awk '{print $1}')
assert_eq "$after" "$before" "reconciling does not touch the request file"
assert_eq "$(vizier_request_get mit-demo status)" "open" \
  "and never closes a request on its own"
assert_eq "$(fake_orca_calls)" "" \
  "and across this entire file, not one orca call was made"

vizier_test_teardown
vizier_test_report
