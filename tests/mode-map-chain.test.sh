#!/usr/bin/env bash
# Proves the mode-map note format `brief` writes and the sed `supervise`
# reads are the SAME text, not two independently pinned strings.
#
# tests/skills.test.sh pins the note format `brief` writes; that file is
# UNCHANGED and untouched by this test. tests/supervise-mode-map.test.sh
# pins the real sed pulled out of `skills/supervise/SKILL.md` -- but it
# fabricates the note by hand instead of taking it from `brief`. Both ends
# were correct in isolation and nothing asserted they agree with each
# other. This is the third time that exact coupling shape has appeared in
# this plan; the other two both shipped broken:
#   - the `axi_outcome:` contract (brief writes it, supervise-lib parses it)
#   - $VIZIER_DIST (four skills sourced a variable nothing defined, and 47
#     green assertions never noticed)
#
# BOTH SIDES COME FROM THE SHIPPED SKILL TEXT, not from strings retyped
# here: the note template is grepped out of skills/brief/SKILL.md, real
# values are substituted into THAT template (not a hand-typed one), the
# result is appended to a real request file with the real
# vizier_request_note, and then the sed grepped out of
# skills/supervise/SKILL.md is run over that same file. If either skill's
# wording drifts from the other, this reddens; a copy retyped into a test
# would not have.
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-home.sh"
. "$VIZIER_TEST_REPO/lib/vizier-request-lib.sh"
. "$VIZIER_TEST_REPO/lib/vizier-supervise-lib.sh"

BRIEF_SKILL="$VIZIER_TEST_REPO/skills/brief/SKILL.md"
SUPERVISE_SKILL="$VIZIER_TEST_REPO/skills/supervise/SKILL.md"

# --- side A: the note template brief actually ships ------------------------
# The literal placeholder text of brief's own instruction -- not retyped.
note_tpl=$(grep -o 'task <id> -> dispatch <id> (<mode>)' "$BRIEF_SKILL" | head -1)
assert_eq "$(test -n "$note_tpl" && echo yes)" "yes" "brief's dispatch-note template is present in the skill"

# --- side B: the sed supervise actually ships -------------------------------
sed_line=$(grep -m1 "^sed -n '" "$SUPERVISE_SKILL")
assert_eq "$(test -n "$sed_line" && echo yes)" "yes" "supervise's mode-map sed command is present in the skill"

# --- drive the chain: real template -> real note -> real request file ------
vizier_request_create chain-run run-1 proj proj-id local "Add dark mode"
slug=chain-run

task_id=task-7
dispatch_a=d-100
mode_a=direct-PR
dispatch_b=d-200
mode_b=no-mistakes

# Substitute real values into BRIEF'S OWN template text. ${v/pat/rep} in
# bash replaces only the first match, so two successive substitutions land
# on the task's <id> first, then the dispatch's <id> -- the same order the
# template names them in.
note_a=${note_tpl/<id>/$task_id}
note_a=${note_a/<id>/$dispatch_a}
note_a=${note_a/<mode>/$mode_a}
note_b=${note_tpl/<id>/$task_id}
note_b=${note_b/<id>/$dispatch_b}
note_b=${note_b/<mode>/$mode_b}

# Recorded through the REAL library call brief's instruction names --
# vizier_request_note -- never appended by hand.
vizier_request_note "$slug" "$note_a"
vizier_request_note "$slug" "$note_b"

# --- run supervise's OWN sed line over that same file -----------------------
# Variable names ($f, $map) match exactly what the skill's sed line
# references, so `eval` expands it unmodified -- this is the skill's
# command, not a copy of it.
f=$(vizier_request_path "$slug")
map="$VIZIER_TEST_TMP/mode-map-$$-$RANDOM"
eval "$sed_line"
map_content=$(cat "$map" 2>/dev/null)
rm -f "$map"

assert_contains "$map_content" "$(printf '%s\t%s' "$dispatch_a" "$mode_a")" "the chain resolves brief's note for dispatch A to the right mode"
assert_contains "$map_content" "$(printf '%s\t%s' "$dispatch_b" "$mode_b")" "the chain resolves brief's note for dispatch B to the right mode"

# --- feed the derived map into vizier_supervise_plan, one batch, one call --
map_file="$VIZIER_TEST_TMP/chain-map"
printf '%s\n' "$map_content" > "$map_file"

batch=$(printf '%s\n%s\n' \
  "{\"delivery_id\":\"c1\",\"type\":\"worker_done\",\"dispatch_id\":\"$dispatch_a\",\"outcome\":\"succeeded\",\"body\":\"PR https://x/1\"}" \
  "{\"delivery_id\":\"c2\",\"type\":\"worker_done\",\"dispatch_id\":\"$dispatch_b\",\"outcome\":\"succeeded\",\"body\":\"still running, no outcome yet\"}")
plan=$(printf '%s\n' "$batch" | vizier_supervise_plan direct-PR "$map_file")

assert_contains "$plan" "PLAN c1 release ok" "the direct-PR-mapped dispatch releases"
assert_contains "$plan" "PLAN c2 hold no-axi-outcome" "the no-mistakes-mapped dispatch holds, in the SAME call"
assert_eq "$(printf '%s\n' "$plan" | tail -1)" "ACK c2" "the mixed batch is still ackable as a whole"

vizier_test_teardown
vizier_test_report
