#!/usr/bin/env bash
# Exercises the mode-map extraction that skills/supervise/SKILL.md tells the
# model to run against the request file (Task 6-9 review round 4).
#
# WHY THE MAP-BUILDING LINE IS PULLED OUT OF THE SKILL FILE INSTEAD OF
# RETYPED HERE. The only way to test what actually SHIPS, rather than a copy
# that can silently drift from it, is to grep the literal line out of the
# skill and run it. If the skill's line ever changes, this test exercises
# whatever is really there.
#
# THE ANCHORED PATTERN ITSELF NO LONGER LIVES IN SKILL PROSE. It moved into
# vizier_request_dispatch_notes (lib/vizier-request-lib.sh) when activation's
# reconciliation became its second reader -- two copies of one anchored
# pattern in two files is two chances for one of them to drift open. What the
# skill still owns, and what this file therefore still greps out of it, is
# the projection down to the `<dispatch>TAB<mode>` map that
# vizier_supervise_plan joins on. Both halves are exercised: the line from
# the skill, running against the library the skill names.
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
map_line=$(grep -m1 '^vizier_request_dispatch_notes ' "$SKILL")
assert_eq "$(test -n "$map_line" && echo yes)" "yes" "the mode-map command is present in the skill"
assert_contains "$map_line" 'cut -f2,3' \
  "and it projects the shared extraction down to <dispatch>TAB<mode>, which is what the plan joins on"

# build_map <slug> -- runs the SKILL'S OWN map-building line (not a copy) by
# setting the exact shell variables it references ($slug, $map) and letting it
# expand them itself, then prints the resulting map file's content.
build_map() {
  # `slug` looks unused and is not: the skill's line references it and is
  # reached only through `eval`, which shellcheck cannot see into.
  # shellcheck disable=SC2034
  local slug="$1" map
  map="$VIZIER_TEST_TMP/mode-map-$$-$RANDOM"
  eval "$map_line"
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
map=$(build_map lookalike-wins)
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
map=$(build_map lookalike-only)
assert_eq "$map" "" "a lookalike line with no genuine note produces an EMPTY map, not a direct-PR entry"

map_file="$VIZIER_TEST_TMP/lookalike-only-map"
printf '%s' "$map" > "$map_file"
fake_orca_message run-e2 e2 worker_done "still running, no outcome yet" "$(fake_orca_payload d-2)"
orca orchestration run-use --id "run-e2" --json >/dev/null
plan=$(orca orchestration check --run run-e2 --json | vizier_supervise_plan no-mistakes "$map_file")
assert_contains "$plan" "PLAN e2 hold no-axi-outcome" "no genuine note for d-2 -> falls back to the given default (strict), never the prose's direct-PR"

# --- Test 3: A NOTE WHOSE MODE CARRIES A SPACE MUST STILL BE IN THE MAP ---
# A DROPPED NOTE IS NOT THE STRICT PATH, and that is the whole reason the
# mode capture in vizier_request_dispatch_notes stays greedy. On a map miss
# vizier_supervise_plan falls back to `$default_mode`, which is the PROJECT's
# `delivery:` field and can be exactly `direct-PR` -- the one value that
# skips the axi_outcome check. So a reader that tidies an odd mode away
# releases a terminal a pipeline may still own.
#
# Measured, same request file, both directions: with the mode captured
# greedily this plans `hold no-axi-outcome`; with it bounded to
# `[^[:space:]]\{1,\}` the note vanished and the identical input planned
# `release ok`. The default below is deliberately `direct-PR` -- with any
# other default this assertion would pass for the wrong reason.
vizier_request_create spacey-mode run-3 proj proj-id local "body"
vizier_request_note spacey-mode "task task_9 -> dispatch d-3 (no-mistakes per captain)"
map=$(build_map spacey-mode)
assert_eq "$map" "$(printf 'd-3\tno-mistakes per captain')" \
  "the odd mode reaches the map whole and unrecognised, rather than being dropped"

map_file="$VIZIER_TEST_TMP/spacey-map"
printf '%s\n' "$map" > "$map_file"
fake_orca_message run-e3 e3 worker_done "done, no outcome line" "$(fake_orca_payload d-3)"
orca orchestration run-use --id "run-e3" --json >/dev/null
plan=$(orca orchestration check --run run-e3 --json | vizier_supervise_plan direct-PR "$map_file")
assert_contains "$plan" "PLAN e3 hold no-axi-outcome" \
  "end-to-end: an unrecognised mode HOLDS even when the project default is direct-PR"

# The same, via a tab rather than a space: the note reader's output is
# tab-separated, so a captured tab would split the mode into a fourth column
# and `cut -f2,3` would hand the map exactly `direct-PR`, promoting an
# unrecognised mode into the only one that releases without the check.
vizier_request_create tabby-mode run-4 proj proj-id local "body"
vizier_request_note tabby-mode "$(printf 'task task_10 -> dispatch d-4 (direct-PR\tretried by hand)')"
map=$(build_map tabby-mode)
assert_eq "$map" "$(printf 'd-4\tdirect-PR retried by hand')" \
  "a tab in the mode is folded, never allowed to truncate the value into direct-PR"

map_file="$VIZIER_TEST_TMP/tabby-map"
printf '%s\n' "$map" > "$map_file"
fake_orca_message run-e4 e4 worker_done "done, no outcome line" "$(fake_orca_payload d-4)"
orca orchestration run-use --id "run-e4" --json >/dev/null
plan=$(orca orchestration check --run run-e4 --json | vizier_supervise_plan direct-PR "$map_file")
assert_contains "$plan" "PLAN e4 hold no-axi-outcome" \
  "so it holds too, instead of being read as a bare direct-PR and released"

# --- Test 5: A TAB-PREFIXED LOOKALIKE MUST NOT SATISFY THE ANCHOR ---------
# `^task ` means a SPACE after `task`, and this is the case that proves it.
# Every other lookalike in this file separates them with a space, which is
# why a fix round could fold every tab in the file to a space BEFORE the
# anchored match and pass the whole suite: `task<TAB>` became `task<SPACE>`,
# the lookalike matched, and it was appended AFTER the genuine note, so
# last-match-wins handed supervise `direct-PR` and released a terminal a
# no-mistakes pipeline may still have owned. Measured on this exact file:
# `hold no-axi-outcome` with the anchor intact, `release ok` with the fold
# placed ahead of it.
#
# The default is deliberately `direct-PR` so a dropped-note fallback cannot
# make this pass for the wrong reason -- if the genuine note were lost too,
# the miss would resolve to direct-PR and release.
vizier_request_create tab-lookalike run-5 proj proj-id local "body"
vizier_request_note tab-lookalike "task task_9 -> dispatch d-5 (no-mistakes)"
vizier_request_note tab-lookalike "$(printf 'task\t9 -> dispatch d-5 (direct-PR)')"
map=$(build_map tab-lookalike)
assert_eq "$map" "$(printf 'd-5\tno-mistakes')" \
  "the tab-prefixed lookalike never enters the map -- only a real space after 'task' satisfies the anchor"

map_file="$VIZIER_TEST_TMP/tab-lookalike-map"
printf '%s\n' "$map" > "$map_file"
fake_orca_message run-e5 e5 worker_done "done, no outcome line" "$(fake_orca_payload d-5)"
orca orchestration run-use --id "run-e5" --json >/dev/null
plan=$(orca orchestration check --run run-e5 --json | vizier_supervise_plan direct-PR "$map_file")
assert_contains "$plan" "PLAN e5 hold no-axi-outcome" \
  "end-to-end: the lookalike cannot flip the genuine no-mistakes note into a release"

# --- Test 6: AN EMPTY PARENTHESISED MODE MUST NOT READ AS A MAP MISS ------
# `()` matches on purpose -- requiring a non-empty mode would drop the note,
# and a dropped note is a miss, which falls back to the project default.
# But an empty mode column is ALSO a miss, because the lookup is guarded by
# `[ -n "$looked" ]`. Measured before the sentinel: `PLAN mb release ok` on a
# direct-PR project. So the reader substitutes `-`, which is non-empty and is
# not a mode vizier_brief_delivery recognises, and the strict path holds.
vizier_request_create empty-mode run-6 proj proj-id local "body"
vizier_request_note empty-mode "task task_9 -> dispatch d-6 ()"
map=$(build_map empty-mode)
assert_eq "$map" "$(printf 'd-6\t-')" \
  "an empty mode becomes the - sentinel, so the map row cannot be read as no row at all"

map_file="$VIZIER_TEST_TMP/empty-mode-map"
printf '%s\n' "$map" > "$map_file"
fake_orca_message run-e6 e6 worker_done "done, no outcome line" "$(fake_orca_payload d-6)"
orca orchestration run-use --id "run-e6" --json >/dev/null
plan=$(orca orchestration check --run run-e6 --json | vizier_supervise_plan direct-PR "$map_file")
assert_contains "$plan" "PLAN e6 hold no-axi-outcome" \
  "end-to-end: an empty mode holds instead of inheriting the project's direct-PR default"

vizier_test_teardown
vizier_test_report
