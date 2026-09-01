#!/usr/bin/env bash
# Skills are prompts, so what is testable is that the exact strings a skill
# MUST contain are present: the commands it tells the model to run, and the
# refusals it must not soften. A skill that quietly loses its hard rule is
# the failure mode this file exists to catch.
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
R="$VIZIER_TEST_REPO"

has() {  # <file> <needle> <label>
  assert_contains "$(cat "$R/$1" 2>/dev/null)" "$2" "$3"
}

# --- request --------------------------------------------------------------
f=skills/request/SKILL.md
assert_eq "$(test -f "$R/$f" && echo yes)" "yes" "request skill exists"
assert_eq "$(head -1 "$R/$f")" "---" "frontmatter present"
has $f "name: request" "skill is named"
has $f "orca orchestration run-create --objective" "the exact run-create call"
has $f "vizier_routing_table" "routing comes from the library"
has $f "exactly once" "the host is asked exactly once"
has $f "Never silently" "no silent host substitution"
has $f "orca project setup-clone" "setup-clone is proposed, not run"
has $f "vizier_request_create" "the request file is written through the library"
has $f "vizier_request_close" "closing goes through the library"
has $f "worker-release" "closing releases remaining dispatches"

# --- brief ------------------------------------------------------------
f=skills/brief/SKILL.md
assert_eq "$(test -f "$R/$f" && echo yes)" "yes" "brief skill exists"
has $f "vizier_brief_assemble" "the spec comes from the library, never hand-written"
has $f "orca orchestration task-create --spec" "exact task-create"
has $f "orca orchestration worker-start" "exact worker-start"
has $f "--worktree new-top-level" "isolation default"
has $f "--setup run" "setup runs"
has $f "--on" "the host is passed through"
has $f "inherits the request's host" "host inheritance is stated"
has $f "Ask the captain" "an unknown delivery mode is asked, never guessed"
has $f "--effort" "model hints are applied"
has $f "requires --model" "effort depends on model"
has $f "--retry-of" "retries chain"
has $f "never retry blind" "receipts are read"

# --- supervise --------------------------------------------------------
f=skills/supervise/SKILL.md
assert_eq "$(test -f "$R/$f" && echo yes)" "yes" "supervise skill exists"
has $f "vizier_supervise_plan" "dispositions come from the library"
has $f "orca orchestration check" "the mailbox is read with check"
has $f "--ack" "ack exists"
has $f "only after" "ack comes only after processing"
has $f "agent_terminal_handle" "terminal transfer reads the handle"
has $f "--terminal" "transfer reuses the terminal"
has $f "worker-release --dispatch" "release is by dispatch"
has $f "release_pending" "pending release receipts are handled"
has $f "terminal close" "the forbidden substitution is named"
has $f "one" "the captain gets one consolidated report"
has $f "delivery" "questions route through the delivery policy"
has $f "worker-read" "a quiet worker is diagnosed, not guessed at"

# --- delivery -----------------------------------------------------------
f=skills/delivery/SKILL.md
assert_eq "$(test -f "$R/$f" && echo yes)" "yes" "delivery skill exists"
has $f "never call" "the first mate never drives a worker's run"
has $f "axi respond" "the command it must not run is named"
has $f "One precise decision" "the reply is a single decision"
has $f "expand the contract" "the escalation test is stated"
has $f "not authority" "a reviewer label is evidence, not authority"
has $f "security" "security-sensitive findings escalate"
has $f "orca orchestration reply --id" "the exact reply command"
has $f "smallest option" "escalations offer the smallest non-expanding option"
has $f "daemon" "the shared-daemon rule is restated"

vizier_test_teardown
vizier_test_report
