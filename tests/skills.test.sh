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
has $f 'VIZIER_DIST="${VIZIER_HOME:-$HOME/.vizier}/dist"' "VIZIER_DIST is defined, not assumed"
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
has $f 'VIZIER_DIST="${VIZIER_HOME:-$HOME/.vizier}/dist"' "VIZIER_DIST is defined, not assumed"
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
has $f "this is not a question" "exactly one open request needs no question"
has $f "which request this task belongs to" "more than one open request asks the captain"
has $f "route the captain to the request skill" "no open request routes to request, not a guess"
has $f "never authority" "the working directory is not used to choose the request"

# --- supervise --------------------------------------------------------
f=skills/supervise/SKILL.md
assert_eq "$(test -f "$R/$f" && echo yes)" "yes" "supervise skill exists"
has $f 'VIZIER_DIST="${VIZIER_HOME:-$HOME/.vizier}/dist"' "VIZIER_DIST is defined, not assumed"
has $f "vizier_supervise_plan" "dispositions come from the library"
# vizier_request_slug_for_run returns rc 0 with EMPTY output when no open
# request names the Run, so an unguarded skill runs the rest of its steps
# against vizier_request_path "" and the only symptom is a bare
# `sed: .../requests/.md: No such file` on stderr -- fails closed, but
# unexplained, which in a wake hook is indistinguishable from not firing.
has $f "no OPEN request names that Run" "an unresolvable run_id is named, not left to a sed error"
has $f "**An empty \`slug\` stops this skill.**" "and it stops the skill rather than continuing"
has $f "orca orchestration check" "the mailbox is read with check"
has $f "--ack" "ack exists"
has $f "only after" "ack comes only after processing"
has $f '**`reply`**' "the reply disposition is named as its own decision"
has $f "answered or escalated before the batch is" \
  "a reply must be discharged BEFORE the ack, not after"
has $f 'one `--ack` per `ACK` line' "every delivery in the batch is acked, not just the last"
# PRESENCE IS NOT ENOUGH HERE. "discharge a reply before the ack" and "the
# single consolidated report is what actually reaches the captain" are both
# rules a model follows IN SECTION ORDER, so if the ack section sits above
# the report section the skill instructs the exact failure the `reply`
# disposition was added to prevent: ack the question, then raise it, with the
# replay safety net already thrown away. Both halves were anchored by text
# and the contradiction still passed. Pin the ORDER, by section title rather
# than by section number, so renumbering while swapping does not hide it.
line_of() {  # <file> <basic-regex> -- first matching line number, or empty
  grep -n -- "$2" "$R/$1" 2>/dev/null | head -1 | cut -d: -f1
}
ack_at=$(line_of $f '^## [0-9]*\. Ack last')
report_at=$(line_of $f '^## [0-9]*\. Report once')
ack_after_report=no
[ -n "$ack_at" ] && [ -n "$report_at" ] && [ "$ack_at" -gt "$report_at" ] && ack_after_report=yes
assert_eq "$ack_after_report" "yes" \
  "the ack step comes after the report that puts an escalation in front of the captain"
has $f "puts an escalation in front of the captain" \
  "and the skill says so, so the order is a stated rule and not an accident"
has $f "agent_terminal_handle" "terminal transfer reads the handle"
has $f "--terminal" "transfer reuses the terminal"
has $f "worker-release --dispatch" "release is by dispatch"
has $f "release_pending" "pending release receipts are handled"
has $f "terminal close" "the forbidden substitution is named"
# THESE THREE ANCHORS ARE DELIBERATELY LONG. They used to read "one",
# "delivery" and "worker-read", and every one of them matched English prose
# from somewhere else in the file: "one" matched "worker_done" and "none",
# "delivery" matched `PLAN <delivery_id>`, "worker-read" matched §2's
# diagnosis line. Proof they were worthless: the reviewer deleted the whole
# "Report once" section -- the one-consolidated-report rule, the ask-user
# routing, and the worker-read diagnosis rule -- replaced it with "Say
# whatever, whenever, as many times as you like", and all 55 assertions
# stayed green. Each anchor below is a phrase that occurs ONLY in the section
# it is meant to pin.
has $f '**One** consolidated message for the whole wake' "the captain gets one consolidated report"
has $f 'the `delivery` skill'"'"'s policy first.' "an ask-user question routes through the delivery policy"
has $f "A worker gone unusually quiet" "a quiet worker is diagnosed, not guessed at"

# --- delivery -----------------------------------------------------------
f=skills/delivery/SKILL.md
assert_eq "$(test -f "$R/$f" && echo yes)" "yes" "delivery skill exists"
has $f 'VIZIER_DIST="${VIZIER_HOME:-$HOME/.vizier}/dist"' "VIZIER_DIST is defined, not assumed"
has $f "never call" "the first mate never drives a worker's run"
has $f "axi respond" "the command it must not run is named"
has $f "One precise decision" "the reply is a single decision"
has $f "expand the contract" "the escalation test is stated"
has $f "not authority" "a reviewer label is evidence, not authority"
# Not the bare word "security": it also appears in "security-sensitive
# choices" elsewhere and in any prose that mentions security at all. Pin the
# escalation criterion itself.
has $f "destructive, irreversible, or security-sensitive" "security-sensitive findings escalate"
has $f "orca orchestration reply --id" "the exact reply command"
has $f "smallest option" "escalations offer the smallest non-expanding option"
has $f "daemon" "the shared-daemon rule is restated"

vizier_test_teardown
vizier_test_report
