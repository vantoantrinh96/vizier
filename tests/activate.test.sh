#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-home.sh"
ACT="$VIZIER_TEST_REPO/bin/vizier-activate.sh"

out=$(bash "$ACT" claude sess-a); rc=$?
assert_rc "$rc" 0 "the first activation succeeds"
assert_contains "$out" "claimed" "reports claimed"
assert_eq "$(vizier_lock_get session_id)" "sess-a" "the lock records the right session"

# The home is fully created on the very first activation
[ -d "$VIZIER_HOME/requests" ]; assert_rc $? 0 "creates requests/"
[ -d "$VIZIER_HOME/projects" ]; assert_rc $? 0 "creates projects/"

# A second session is refused while the owner is still alive
out=$(bash "$ACT" claude sess-b); rc=$?
assert_rc "$rc" 1 "the second session is refused"
assert_contains "$out" "held_by=sess-a" "clearly states who holds it"

# FIX 4 -- a held_by= refusal must include a hint toward the
# `vizier unlock` escape hatch, so the captain doesn't have to dig
# through docs when they run into a stuck-but-alive lock.
err=$(bash "$ACT" claude sess-b 2>&1 >/dev/null)
assert_contains "$err" "vizier unlock" "suggests the unlock command in a held_by= refusal"

# CLAUDE_CODE_CHILD_SESSION is set on every subagent invocation AND on every
# ordinary top-level interactive session (measured: both carry the SAME
# session id), so activation must succeed with it set -- that is the normal
# case, not an edge case. A previous version of this script refused here on
# an unmeasured claim that a subagent's session id differs from its parent's;
# it does not, so there must be no refusal on this variable.
rm -f "$(vizier_lock_path)"
out=$(CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CODE_SESSION_ID=sess-child bash "$ACT" claude 2>&1); rc=$?
assert_rc "$rc" 0 "activation succeeds when CLAUDE_CODE_CHILD_SESSION is set"
assert_contains "$out" "claimed" "reports claimed"
assert_eq "$(vizier_lock_get session_id)" "sess-child" "the lock records the session id"

# No session id from the environment: REFUSE, never make up a value
rm -f "$(vizier_lock_path)"
out=$(env -u CLAUDE_CODE_SESSION_ID bash "$ACT" claude 2>&1); rc=$?
assert_rc "$rc" 2 "no CLAUDE_CODE_SESSION_ID gives rc 2"
assert_contains "$out" "no_session_id" "clearly states the reason"
assert_eq "$(vizier_lock_get session_id)" "" "no lock is written when the session id is missing"
# When the environment variable is present, use it -- the model fills in nothing
out=$(CLAUDE_CODE_SESSION_ID=from-env bash "$ACT" claude); rc=$?
assert_rc "$rc" 0 "the session id is taken from the environment"
assert_eq "$(vizier_lock_get session_id)" "from-env" "the lock records the environment's session id"

# Failing to determine the harness pid: REFUSE. This branch previously had NO
# test reaching it at all, because every call read the test environment's
# real CLAUDE_PID. Remove CLAUDE_PID and give a harness name that cannot
# possibly exist in the process tree.
rm -f "$(vizier_lock_path)"
out=$(env -u CLAUDE_PID bash "$ACT" no-such-harness-xyz 2>&1); rc=$?
assert_rc "$rc" 2 "failing to find the harness pid gives rc 2"
assert_contains "$out" "no_harness_pid" "clearly states the reason"
assert_eq "$(vizier_lock_get session_id)" "" "no lock is written when the harness pid is missing"

# PostCompact: a matching lock reprints identity to stderr, a mismatch stays silent
rm -f "$(vizier_lock_path)"
CLAUDE_CODE_SESSION_ID=sess-a bash "$ACT" claude sess-a > /dev/null
HOOK="$VIZIER_TEST_REPO/hooks/reidentify-claude.sh"
err=$(printf '{"session_id":"sess-a"}' | bash "$HOOK" 2>&1 >/dev/null); rc=$?
assert_rc "$rc" 0 "reidentify always exits 0"
assert_contains "$err" "first mate" "reprints identity"
err=$(printf '{"session_id":"sess-zzz"}' | bash "$HOOK" 2>&1 >/dev/null)
assert_eq "$err" "" "a different session stays silent"

vizier_test_teardown
vizier_test_report
