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

vizier_test_teardown
vizier_test_report
