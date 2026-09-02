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
has $f "jq -r '.result.dispatchId'" "the dispatch id is read from the field Orca actually returns"
has $f "agent_prompt_blocked" "a dispatch that launches but cannot be prompted is named"
# THE WORKTREE IS MADE BY A SEPARATE COMMAND. `--worktree new-top-level` was
# measured failing twice, the second time with --name and a valid --repo both
# present, so no `--worktree` value creates anything.
has $f "orca worktree create --name" "the worktree is created by its own command"
has $f "It is two calls, not one" "and the skill says plainly that it is two calls"
has $f '--worktree "path:$wt"' "the dispatch then SELECTS the worktree it just made"
has $f "no creation flags at all" "and passes no creation flags, which are rejected once it exists"
has $f "--setup run" "setup runs"
# A dispatch that launches but never receives the task is a distinct failure
# with no CLI recovery; without this the model retries it forever.
has $f "agent_prompt_blocked" "the blocked-prompt failure is named"
# A LONG ANCHOR ON PURPOSE. "agent_prompt_blocked" alone appears in the code
# block too, so deleting the whole section that explains it leaves the short
# anchor green -- measured. This phrase occurs only in that section, and it is
# the load-bearing half: without it the model just retries the dispatch.
has $f "This latches, and no CLI call clears it" \
  "and that no CLI call recovers it, so the dispatch must not be retried"
has $f "trust is per exact path" "and the trap that trusting the repo root is not enough"
has $f "stage: input_accepted" "success means launched AND prompted, not just launched"
# --repo IS REQUIRED AND MUST BE EXACT (Orca's own note on worker-start), and
# it has to come from the request's own project/host setup record rather than
# the working directory. The dispatch shipped without it entirely.
has $f 'orca project setups --project "$project" --host "$host_id"' \
  "the repo selector is derived from the request's project and host"
has $f '--repo "path:$repo_path"' "and passed to worker-start as an exact selector"
# worker-start is one of exactly two commands that need a sender terminal; an
# ordinary editor session is not one, so the handle has to be discovered.
has $f "orca terminal list --json" "a live terminal handle is discovered"
has $f '--from "$from"' "and passed to worker-start"
has $f "An empty \`from\` **stops the dispatch**" "no live handle stops the dispatch rather than retrying"
has $f "An empty \`repo_path\` **stops the dispatch**" \
  "no ready setup on the named host stops the dispatch instead of falling back"
# selector_not_found carries no information at all -- no stage, no effects, no
# recovery command -- so the skill has to carry what is known INSTEAD.
has $f "selector_not_found" "the measured worktree-selector failure is named"
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
has $f "vizier-mailbox-lib.sh" "the mailbox shape library is sourced"
# WITHOUT run-use, `check` is fenced and reads nothing. The hook that woke
# this skill used `inbox`, which needs no binding and cannot ack -- so binding
# is this skill's job and its absence makes every later step unreachable.
has $f 'orca orchestration run-use --id "$run_id"' "the session binds to the Run before reading"
has $f "Do not rebind between here and the ack" \
  "and the rule that a rebind mid-delivery invalidates the ack"
# The rule is MEASURED, not reasoned; pin the observed error so a future
# rewrite cannot soften it back into a hedge.
has $f "fenced consumer generation" "with the exact error a fenced delivery gives"
has $f "never assume the old ack" "and the recovery, which is to re-plan from a fresh delivery"
# The rejection notice reads exactly like a completion and is not one; if this
# rule leaves the skill, the model has no reason to treat the hold as real.
has $f "hold lifecycle-rejection" "Orca's own rejection notice has its own named disposition"
has $f "--ack" "ack exists"
has $f "only after" "ack comes only after processing"
has $f '**`reply`**' "the reply disposition is named as its own decision"
has $f "answered or escalated before the batch is" \
  "a reply must be discharged BEFORE the ack, not after"
# ONE ACK FOR THE WHOLE BATCH, and the handle is the delivery's. Measured:
# `--ack` takes `result.deliveryId`, clears the entire delivery, and refuses a
# message id with `stale_delivery`. The skill previously told the model to
# issue one `--ack` per message, which against the real app is a call that
# always fails -- so the anchor pins the rule AND the reason.
has $f '`--ack` for the whole batch' "the ack names the delivery, not a message"
has $f 'stale_delivery' "and the skill says what happens if a message id is used instead"
# THE READ MUST NOT PEEK. A peek forms no delivery, so a peeked batch has no
# ack handle at all and replays forever. This is the one line whose loss would
# make the whole ack section unreachable in practice.
has $f '**No `--peek`, and no `--all`.**' "the batch is read as a delivery, never peeked"
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
has $f "assignee_handle" "terminal transfer reads the handle Orca actually returns"
has $f "recovery" "a release receipt is followed by its own recovery sentence"
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
