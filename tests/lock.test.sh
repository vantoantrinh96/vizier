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
# Contract note (review round 1, Important 3): on success, take-stale no
# longer removes its own backup file -- it prints the backup's path and
# leaves cleanup to the CALLER, so that rm can happen after the caller's
# own create_exclusive instead of before it, shortening the window where
# the true lock file does not exist on disk. vizier_lock_claim does this
# cleanup itself; this direct test of the bare primitive does the same here
# so it does not leak a lock.stale.* file for a later assertion to trip over.
printf 'session_id=old\nharness=claude\npid=1\nsince=1\n' > "$(vizier_lock_path)"
snap=$(cat "$(vizier_lock_path)")
stale=$(_vizier_lock_take_stale "$snap"); rc=$?
assert_rc "$rc" 0 "take-stale succeeds when the file is unchanged"
assert_eq "$(test -e "$(vizier_lock_path)" && echo present || echo gone)" "gone" \
  "and leaves the slot free to create into"
rm -f "$stale"

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

# --- the same rule, driven through vizier_lock_claim itself, not the bare
# primitives (review round 1, Important 2; seam relocated + made
# function-based in review round 2) ------------------------------------------
# A dead-pid lock is seeded; the seam fires immediately after the snapshot is
# taken and BEFORE owner/liveness are even derived from it -- review round 1
# placed this seam too late (after the liveness decision), which is
# downstream of the whole vulnerable region: a faithful revert of the
# snapshot-first ordering still passed the suite because the seam fired
# after the vulnerable code had already run. It must fire here to actually
# exercise that region. Also switched from an env-var `eval` to a plain
# function existence check (`command -v ... && ...`): an env-var-triggered
# `eval`, even behind `${VAR:-}`, is a code-execution surface in a file the
# wake hook sources after every turn of every session on the machine. A
# function can only exist here because code already running in THIS shell
# defined it, so no environment variable can ever reach it.
#
# The claim must refuse, naming the ACTUAL live owner (not the stale
# snapshot's), and that live owner's lock must survive untouched.
rm -f "$(vizier_lock_path)"
printf 'session_id=ghost\nharness=claude\npid=999999\nsince=1\n' > "$(vizier_lock_path)"
_vizier_test_lock_seam() {
  printf 'session_id=live-one\nharness=claude\npid=%s\nsince=2\n' $$ > "$(vizier_lock_path)"
}
out=$(vizier_lock_claim thief claude $$); rc=$?
unset -f _vizier_test_lock_seam
assert_rc "$rc" 1 "a mid-flight legitimate claim refuses the reclaimer (composed path)"
assert_contains "$out" "held_by=live-one" "names the actual live owner, not the stale snapshot's"
assert_eq "$(vizier_lock_get session_id)" "live-one" "the live owner survives the interleave"

# --- unifying refresh through the same compare-and-swap closes the
# refresh-vs-reclaim race too (review round 1, Important 4) -----------------
# The demonstrated bug: A refreshes its own (believed-current) lock at the
# same moment B legitimately reclaims it as dead, and -- on the old
# unconditional-write refresh -- BOTH print success though only one write
# survives. Simulate B's reclaim landing right after A's snapshot (before A
# even derives owner/liveness from it); A's refresh must now refuse rather
# than lie about holding it.
rm -f "$(vizier_lock_path)"
printf 'session_id=sess-a\nharness=claude\npid=999999\nsince=1\n' > "$(vizier_lock_path)"
_vizier_test_lock_seam() {
  printf 'session_id=sess-b\nharness=claude\npid=%s\nsince=2\n' $$ > "$(vizier_lock_path)"
}
out=$(vizier_lock_claim sess-a claude $$); rc=$?
unset -f _vizier_test_lock_seam
assert_rc "$rc" 1 "a refresh that loses a concurrent reclaim refuses instead of lying"
assert_eq "$(vizier_lock_get session_id)" "sess-b" "the reclaiming session's lock survives"

# --- mutation-detecting: the restore's `set -C` guard specifically (review
# round 1, minor; seam made function-based in review round 2 for the same
# code-execution-surface reason as the claim seam above) --------------------
# Simulate a legitimate third claimant landing in the vacated slot exactly
# between take_stale detecting the mismatch and attempting its restore
# write. The guard must refuse to clobber it. Without `set -C` on that
# restore line, this assertion fails (the restore would silently overwrite
# the third claimant's fresh, live lock).
rm -f "$(vizier_lock_path)"
printf 'session_id=old\nharness=claude\npid=1\nsince=1\n' > "$(vizier_lock_path)"
snap=$(cat "$(vizier_lock_path)")
printf 'session_id=changed\nharness=claude\npid=1\nsince=2\n' > "$(vizier_lock_path)"
_vizier_test_take_stale_seam() {
  printf 'session_id=third\nharness=claude\npid=%s\nsince=3\n' $$ > "$(vizier_lock_path)"
}
_vizier_lock_take_stale "$snap"; rc=$?
unset -f _vizier_test_take_stale_seam
assert_rc "$rc" 1 "take-stale still refuses when a legitimate claimant lands during its own restore"
assert_eq "$(vizier_lock_get session_id)" "third" \
  "and does not clobber that legitimate claimant's lock (set -C guards the restore)"

# --- restore-on-any-create-failure, not just reclaim (review round 2,
# Important 3) ----------------------------------------------------------------
# _vizier_lock_restore_stale is the primitive vizier_lock_claim's trap now
# calls unconditionally on EVERY create-failure path (not only refresh):
# restoring a dead owner's lock back is harmless (still reclaimable), but
# for a refresh the backup IS the caller's own live lock -- silently
# discarding it (the old behavior on a create failure unrelated to losing a
# race) used to unlock a live first mate. Test the primitive directly.
rm -f "$(vizier_lock_path)"
printf 'session_id=sess-a\nharness=claude\npid=%s\nsince=1\n' $$ > "$(vizier_lock_path)"
stale=$(_vizier_lock_take_stale "$(cat "$(vizier_lock_path)")")
_vizier_lock_restore_stale "$stale"
assert_eq "$(vizier_lock_get session_id)" "sess-a" \
  "restore-stale gives the backup back when the slot is still free"
assert_eq "$(ls "$(vizier_home)"/lock.stale.* 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "and leaves no orphaned backup behind"

# ... but must not clobber a legitimate new owner that claimed the freed
# slot before the restore is attempted (same set -C guard as take_stale's
# own restore, and the same reason).
rm -f "$(vizier_lock_path)"
printf 'session_id=sess-a\nharness=claude\npid=%s\nsince=1\n' $$ > "$(vizier_lock_path)"
stale=$(_vizier_lock_take_stale "$(cat "$(vizier_lock_path)")")
_vizier_lock_create_exclusive newcomer claude $$ >/dev/null  # a legitimate racer claims the freed slot
_vizier_lock_restore_stale "$stale"
assert_eq "$(vizier_lock_get session_id)" "newcomer" \
  "restore-stale does NOT clobber a legitimate new owner"
assert_eq "$(ls "$(vizier_home)"/lock.stale.* 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "and still leaves no orphaned backup, even when it refuses to restore"

# A no-op call (nothing was ever taken) must not blow up under set -u and
# must not create anything.
_vizier_lock_restore_stale ""
assert_rc "$?" 0 "restore-stale with no path is a harmless no-op"
_vizier_lock_restore_stale "$VIZIER_TEST_TMP/never-existed"
assert_rc "$?" 0 "restore-stale with a nonexistent path is a harmless no-op"

# --- a create that fails for a NON-competitive reason must not claim
# held_by= (review round 1, minor) -------------------------------------------
# bin/vizier-activate.sh matches the literal string "refused held_by=" to
# decide whether to print the `vizier unlock` hint. If create_exclusive
# fails because the home is unwritable (not because someone else won the
# race), there is no lock and no owner to name -- printing held_by=unknown
# here would send the captain to unlock a lock that was never written.
# Force a non-competitive failure universally (works even as root): put a
# plain FILE where a directory needs to be created, so mkdir -p fails with
# ENOTDIR regardless of permissions.
blocked="$VIZIER_TEST_TMP/blocked-home"
: > "$blocked"
out=$(VIZIER_HOME="$blocked/sub" vizier_lock_claim sess-g claude $$ 2>&1); rc=$?
assert_rc "$rc" 1 "a non-competitive create failure still refuses"
assert_contains "$out" "reason=create_failed" "and does not print held_by= for it"

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
