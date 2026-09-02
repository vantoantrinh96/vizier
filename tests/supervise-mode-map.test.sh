#!/usr/bin/env bash
# Exercises the mode-map extraction sed command that skills/supervise/SKILL.md
# tells the model to run against the request file (Task 6-9 review round 4).
#
# WHY THE SED IS PULLED OUT OF THE SKILL FILE INSTEAD OF RETYPED HERE. The
# extraction lives in skill prose, not a library function -- so the only way
# to test what actually SHIPS, rather than a copy that can silently drift
# from it, is to grep the literal line out of the skill and run it. If the
# skill's sed ever changes, this test exercises whatever is really there.
#
# THE BUG THIS GUARDS AGAINST: an unanchored `.*-> dispatch <id> (<mode>)`
# search matches ANYWHERE in the request file, including the captain's own
# verbatim body. A captain who pastes a previous run's notes into a new
# request reproduces a `-> dispatch <id> (<mode>)`-shaped line by accident,
# with nobody needing to predict a dispatch id or exploit anything. The
# review's own repro: prose containing that shape, ahead of the genuine
# `task N -> dispatch <id> (<mode>)` note for the same id, and the prose
# line won -- resolving a no-mistakes dispatch to direct-PR and releasing a
# terminal whose pipeline may still own the branch.
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-home.sh"
. "$VIZIER_TEST_REPO/lib/vizier-request-lib.sh"
. "$VIZIER_TEST_REPO/lib/vizier-mailbox-lib.sh"
. "$VIZIER_TEST_REPO/lib/vizier-supervise-lib.sh"

SKILL="$VIZIER_TEST_REPO/skills/supervise/SKILL.md"

# The one line in the skill's bash fence that builds the map. Captured by
# its fixed prefix, not retyped -- see the file header.
sed_line=$(grep -m1 "^sed -n '" "$SKILL")
assert_eq "$(test -n "$sed_line" && echo yes)" "yes" "the mode-map sed command is present in the skill"

# build_map <request_file> -- runs the SKILL'S OWN sed line (not a copy) by
# setting the exact shell variables it references ($f, $map) and letting it
# expand them itself, then prints the resulting map file's content.
build_map() {
  local f="$1" map
  map="$VIZIER_TEST_TMP/mode-map-$$-$RANDOM"
  eval "$sed_line"
  cat "$map" 2>/dev/null
  rm -f "$map"
}

# --- Test 1: a prose lookalike PRECEDES the genuine note for the same id --
# The genuine note must win, not the prose. Mirrors the review's own repro:
# the captain's verbatim body (written first, at request-create time) holds
# a line shaped like a dispatch note; brief's real note for that dispatch
# is appended later, after it.
vizier_request_create lookalike-wins run-1 proj proj-id local \
  "Retry note from last time: it failed with -> dispatch d-1 (direct-PR)"
vizier_request_note lookalike-wins "task 3 -> dispatch d-1 (no-mistakes)"
f=$(vizier_request_path lookalike-wins)
map=$(build_map "$f")
assert_eq "$map" "$(printf 'd-1\tno-mistakes')" "the map holds ONLY the genuine note's mode -- the unanchored prose (which came first) never enters it at all"

# End-to-end: with this map, a no-mistakes-shaped worker_done for d-1 with
# no axi_outcome line must HOLD, not release -- proving the resolved mode
# really is no-mistakes, not direct-PR.
map_file="$VIZIER_TEST_TMP/lookalike-map"
printf '%s' "$map" > "$map_file"
# The batch goes through fake-orca so the plan reads a REAL envelope, and the
# dispatch id is where Orca actually puts it -- inside the payload STRING.
# With the old top-level `.dispatch_id` read, every map lookup missed and this
# assertion passed for the wrong reason: the fallback happened to be strict.
fake_orca_message run-e1 e1 worker_done "still running, no outcome yet" "$(fake_orca_payload d-1)"
orca orchestration run-use --id "run-e1" --json >/dev/null
plan=$(orca orchestration check --run run-e1 --json | vizier_supervise_plan direct-PR "$map_file")
assert_contains "$plan" "PLAN e1 hold no-axi-outcome" "end-to-end: the lookalike-prose case resolves to no-mistakes and holds, not direct-PR-and-release"

# --- Test 2: a prose lookalike with NO genuine note for that id at all ----
# The lookup must find nothing (not the prose's mode) and fall back to
# whatever default the caller passed -- which, if the caller passed nothing
# usable, is the strict path (see vizier_msg_disposition).
vizier_request_create lookalike-only run-2 proj proj-id local \
  "For context, last time -> dispatch d-2 (direct-PR)"
f=$(vizier_request_path lookalike-only)
map=$(build_map "$f")
assert_eq "$map" "" "a lookalike line with no genuine note produces an EMPTY map, not a direct-PR entry"

map_file="$VIZIER_TEST_TMP/lookalike-only-map"
printf '%s' "$map" > "$map_file"
fake_orca_message run-e2 e2 worker_done "still running, no outcome yet" "$(fake_orca_payload d-2)"
orca orchestration run-use --id "run-e2" --json >/dev/null
plan=$(orca orchestration check --run run-e2 --json | vizier_supervise_plan no-mistakes "$map_file")
assert_contains "$plan" "PLAN e2 hold no-axi-outcome" "no genuine note for d-2 -> falls back to the given default (strict), never the prose's direct-PR"

vizier_test_teardown
vizier_test_report
