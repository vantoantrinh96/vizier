#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-home.sh"

assert_eq "$(vizier_home)" "$VIZIER_HOME" "vizier_home respects VIZIER_HOME"
assert_eq "$(vizier_lock_path)" "$VIZIER_HOME/lock" "the lock path"

# With no lock, no session matches
vizier_lock_matches "sess-a"; assert_rc $? 1 "no lock means no match"

# Claim the lock for the first time
out=$(vizier_lock_claim "sess-a" claude $$); assert_rc $? 0 "claims an empty lock"
assert_contains "$out" "claimed" "reports claimed"
assert_eq "$(vizier_lock_get session_id)" "sess-a" "writes session_id"
assert_eq "$(vizier_lock_get harness)" "claude" "writes harness"
vizier_lock_matches "sess-a"; assert_rc $? 0 "the owner matches"
vizier_lock_matches "sess-b"; assert_rc $? 1 "a different session does not match"

# While the owner is alive, a different session is refused
out=$(vizier_lock_claim "sess-b" claude $$); assert_rc $? 1 "refused while the owner is alive"
assert_contains "$out" "held_by=sess-a" "names the current owner"
assert_eq "$(vizier_lock_get session_id)" "sess-a" "the lock's owner does not change"

# The same owner calling again just refreshes, no refusal
vizier_lock_claim "sess-a" claude $$ >/dev/null; assert_rc $? 0 "the same owner calling again is ok"

# A dead owner can be reclaimed
printf 'session_id=sess-dead\nharness=claude\npid=999999\nsince=1\n' > "$(vizier_lock_path)"
out=$(vizier_lock_claim "sess-c" claude $$); assert_rc $? 0 "a dead lock can be reclaimed"
assert_contains "$out" "reclaimed" "reports reclaimed"
assert_eq "$(vizier_lock_get session_id)" "sess-c" "the new owner was written"

# A non-numeric pid counts as unproven, DOES NOT get reclaimed carelessly
printf 'session_id=sess-x\nharness=claude\npid=abc\nsince=1\n' > "$(vizier_lock_path)"
vizier_lock_claim "sess-d" claude $$ >/dev/null; assert_rc $? 1 "a garbage pid does not let the lock be stolen"

# vizier_harness_pid: finds bash (the test shell itself) as an ancestor, and never makes up a pid
hp=$(vizier_harness_pid bash)
case "$hp" in ''|*[!0-9]*) assert_eq "$hp" "<numeric pid>" "finds bash's ancestor pid" ;; esac
kill -0 "${hp:-0}" 2>/dev/null; assert_rc $? 0 "the returned ancestor pid is alive"
assert_eq "$(vizier_harness_pid definitely-not-a-real-harness-xyz)" "" "returns empty when nothing is found"

# --- exclusive create ------------------------------------------------------
rm -f "$(vizier_lock_path)"
_vizier_lock_create_exclusive sess-x claude $$
assert_rc "$?" 0 "exclusive create succeeds into an empty slot"
assert_eq "$(vizier_lock_get session_id)" "sess-x" "and writes our session"

before=$(shasum -a 256 "$(vizier_lock_path)" | awk '{print $1}')
_vizier_lock_create_exclusive sess-y claude $$
assert_rc "$?" 1 "exclusive create REFUSES when the slot is taken"
after=$(shasum -a 256 "$(vizier_lock_path)" | awk '{print $1}')
assert_eq "$after" "$before" "and leaves the existing lock byte-identical"

# --- take-stale: the file we take must be the file we judged ---------------
printf 'session_id=old\nharness=claude\npid=1\nsince=1\n' > "$(vizier_lock_path)"
snap=$(cat "$(vizier_lock_path)")
_vizier_lock_take_stale "$snap"
assert_rc "$?" 0 "take-stale succeeds when the file is unchanged"
assert_eq "$(test -e "$(vizier_lock_path)" && echo present || echo gone)" "gone" \
  "and leaves the slot free to create into"

# the case that prevents stealing from a live owner
printf 'session_id=old\nharness=claude\npid=1\nsince=1\n' > "$(vizier_lock_path)"
snap=$(cat "$(vizier_lock_path)")
printf 'session_id=newcomer\nharness=claude\npid=%s\nsince=2\n' $$ > "$(vizier_lock_path)"
_vizier_lock_take_stale "$snap"
assert_rc "$?" 1 "take-stale REFUSES when the file changed under it"
assert_eq "$(vizier_lock_get session_id)" "newcomer" \
  "and restores the newcomer's lock rather than stealing it"
assert_eq "$(ls "$(vizier_home)"/lock.stale.* 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "and leaves no stale file behind"

# --- the end-to-end rule the whole fix exists to enforce -------------------
# A claimant that saw a dead owner must NOT overwrite a lock a third session
# has since legitimately taken. This is the bug that mattered most: the
# previous design overwrote unconditionally.
rm -f "$(vizier_lock_path)"
printf 'session_id=ghost\nharness=claude\npid=1\nsince=1\n' > "$(vizier_lock_path)"
snap=$(cat "$(vizier_lock_path)")
# simulate the interleaving: a live session takes the lock after our snapshot
printf 'session_id=live-one\nharness=claude\npid=%s\nsince=2\n' $$ > "$(vizier_lock_path)"
out=$(_vizier_lock_take_stale "$snap" && _vizier_lock_create_exclusive thief claude $$ && echo stole || echo refused)
assert_eq "$out" "refused" "a stale snapshot never dispossesses a live owner"
assert_eq "$(vizier_lock_get session_id)" "live-one" "the live owner still holds it"

# Anti-race invariant, run 20 times: many sessions claiming an empty lock at
# once must produce EXACTLY ONE winner, every time. This now holds because
# the create is atomic (`set -C` / O_CREAT|O_EXCL) -- at most one process's
# create can succeed into a given empty slot, so at most one can print
# "claimed", and the empty-lock branch only prints "claimed" on a create it
# won. One trial passes even with the old bug on an idle machine; twenty
# trials under load is what turns a 1-in-4 flake into a near-certain detector.
race_trial=1
while [ "$race_trial" -le 20 ]; do
  rm -f "$(vizier_lock_path)"
  race="$VIZIER_TEST_TMP/race-$race_trial"; mkdir -p "$race"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ( vizier_lock_claim "race-$i" claude $$ > "$race/$i.out" 2>&1 ) &
  done
  wait
  wins=$(grep -l '^claimed' "$race"/*.out 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "$wins" "1" "trial $race_trial: exactly one session wins the empty lock"
  losers=$(grep -l '^refused' "$race"/*.out 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "$losers" "9" "trial $race_trial: the other nine sessions are all refused, none errors while writing"
  race_trial=$((race_trial + 1))
done

# A session_id containing a newline would corrupt the lock file, so it must be blocked right at the door
rm -f "$(vizier_lock_path)"
out=$(vizier_lock_claim "$(printf 'a\nb')" claude $$); rc=$?
assert_rc "$rc" 1 "a session_id containing a newline is refused"
assert_contains "$out" "newline" "clearly states the reason"
assert_eq "$(vizier_lock_get session_id)" "" "no lock is written for a bad session_id"
out=$(vizier_lock_claim "" claude $$); rc=$?
assert_rc "$rc" 1 "an empty session_id is refused"

# Release only works for the true owner
printf 'session_id=sess-e\nharness=claude\npid=%s\nsince=1\n' $$ > "$(vizier_lock_path)"
vizier_lock_release "sess-other" >/dev/null
assert_eq "$(vizier_lock_get session_id)" "sess-e" "a stranger cannot release it"
vizier_lock_release "sess-e" >/dev/null
assert_eq "$(vizier_lock_get session_id)" "" "the true owner can release it"

vizier_test_teardown
vizier_test_report
