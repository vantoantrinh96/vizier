#!/usr/bin/env bash
# The whole coordination loop, end to end, with no app and no model:
# open -> route -> brief -> dispatch -> worker_done -> plan -> release -> close.
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-home.sh"
. "$VIZIER_TEST_REPO/lib/vizier-mailbox-lib.sh"
. "$VIZIER_TEST_REPO/lib/vizier-wake-lib.sh"
. "$VIZIER_TEST_REPO/lib/vizier-request-lib.sh"
. "$VIZIER_TEST_REPO/lib/vizier-routing-lib.sh"
. "$VIZIER_TEST_REPO/lib/vizier-brief-lib.sh"
. "$VIZIER_TEST_REPO/lib/vizier-supervise-lib.sh"

mkdir -p "$VIZIER_HOME/projects"
printf -- '---\ndelivery: direct-PR\n---\nTest with `make test`.\n' > "$VIZIER_HOME/projects/platform.md"

fake_orca_seed_host local "this machine" local
fake_orca_seed_host 0559ea68 "Mac mini" environment
fake_orca_set_status ""         ready true
fake_orca_set_status "Mac mini" ready true
fake_orca_seed_setup "github:acme/platform" local ready
fake_orca_seed_setup "github:acme/platform" 0559ea68 ready

# --- open -----------------------------------------------------------------
t=$(vizier_routing_table github:acme/platform)
assert_eq "$(printf '%s\n' "$t" | awk -F'\t' '$4=="yes"' | wc -l | tr -d ' ')" "2" "both hosts eligible"

run=$(orca orchestration run-create --objective "Add dark mode" --json | jq -r '.result.run.id')
slug=$(vizier_request_slug "Add dark mode")
# the captain picked the remote host
vizier_request_create "$slug" "$run" platform github:acme/platform "Mac mini" "Add dark mode"
assert_eq "$(vizier_open_run_ids)" "$run" "the hook would now wait on this Run"

# --- brief and dispatch ---------------------------------------------------
mode=$(vizier_project_mode platform)
assert_eq "$mode" "direct-PR" "mode from the project posture"
spec=$(vizier_brief_assemble platform "$mode" "Add a toggle in settings.")
task=$(orca orchestration task-create --spec "$spec" --run "$run" --json | jq -r '.result.task.id')
host=$(vizier_request_get "$slug" host)

# THE REPO SELECTOR IS DERIVED, NOT GUESSED -- brief §5. This spans four
# things and so belongs here rather than in a unit test: the request file's
# host, `host list` (which names hosts by id/name differently from `--on`),
# the setup record for that project on that host, and the dispatch call. The
# dispatch previously passed no --repo at all, which Orca's own worker-start
# note requires ("Use exact --repo on the selected server").
if [ "$host" = "local" ]; then
  host_id=local
else
  host_id=$(orca host list --json | jq -r --arg n "$host" \
    '.result.hosts[] | select(.name == $n) | .id' | head -1)
fi
assert_eq "$host_id" "0559ea68" "the request's host NAME resolves to the host ID setups is keyed by"
project_id=$(vizier_request_get "$slug" project_id)
assert_eq "$project_id" "github:acme/platform" "the request file really carries the project id the lookup keys on"
repo_path=$(orca project setups --project "$project_id" --host "$host_id" --json \
  | jq -r '.result.setups[0].path // empty')
# The two seeded hosts have DIFFERENT paths, so this can only be right if the
# host actually resolved -- with one shared path it would pass either way.
assert_eq "$repo_path" "/seeded/0559ea68" "the repo path comes from the setup record for THIS project on THIS host"

# TWO CALLS, NOT ONE. `worker-start` only ever selects a worktree that already
# exists -- measured, no `--worktree` value creates one -- so `worktree create`
# comes first and the dispatch selects what it made.
wt=$(orca worktree create --name dark-mode --repo "path:$repo_path" --setup run --json \
  | jq -r '.result.worktree.path')
assert_eq "$wt" "/tmp/fake-worktrees/dark-mode" "the worktree is created before the dispatch"
dispatch=$(orca orchestration worker-start --task "$task" --run "$run" \
  --agent claude --worktree "path:$wt" --on "$host" --json \
  | jq -r '.result.dispatchId')

# the host chosen at OPEN is the host used at DISPATCH -- the single rule that
# no unit test can check, because it spans two libraries and a file
assert_contains "$(fake_orca_calls)" "--on Mac mini" "dispatch inherited the request's host"
assert_contains "$(fake_orca_calls)" "--repo path:/seeded/0559ea68" "and the exact repo selector reached worktree create"
assert_contains "$(fake_orca_calls)" "--worktree path:/tmp/fake-worktrees/dark-mode" \
  "and the dispatch selected the worktree that call returned"
# The creation flags must NOT ride along on the dispatch -- Orca rejects them
# once the worktree exists.
assert_eq "$(fake_orca_calls | grep 'orchestration worker-start' | grep -c -- '--setup')" "0" \
  "no creation flags on the dispatch call"
# and the brief that reached Orca really had all four layers
assert_eq "$(grep -c '^## ' "$VIZIER_FAKE_ORCA_STATE/spec.$task")" "4" "the stored spec has four layers"
assert_contains "$(cat "$VIZIER_FAKE_ORCA_STATE/spec.$task")" "gh-axi" "invariants reached the worker"

# brief section 5 records the dispatch in the request file. Nothing downstream
# works without it, so the loop has to actually write it, not assume it.
vizier_request_note "$slug" "task $task -> dispatch $dispatch ($mode)"

# --- the wake arrives COLD: a run_id and nothing else ----------------------
# This is the join the whole supervise path hangs off, and it was the one link
# the loop test skipped -- it carried $slug forward in a variable, which no
# real wake ever does. supervise starts from an independent wake event with
# `run=<run_id>` in it and must translate that back to a request file before
# it can read the project, the mode map, or the host.
wake_slug=$(vizier_request_slug_for_run "$run")
assert_eq "$wake_slug" "$slug" "a cold wake translates run_id back to the request's slug"

# Everything from here uses ONLY what the wake could have known. The skill's
# map-building line references $slug, so it is rebound HERE from the cold-wake
# lookup -- deliberately not left holding the value this test carried forward,
# which is the whole point of the section above.
slug="$wake_slug"
map="$VIZIER_TEST_TMP/loop-mode-map"
# supervise's own map-building line, grepped out of the shipped skill rather
# than retyped -- same reason as tests/supervise-mode-map.test.sh. The
# anchored extraction it calls now lives in vizier_request_dispatch_notes,
# shared with activation's reconciliation; what the skill still owns is the
# projection down to the <dispatch>TAB<mode> map the plan joins on.
map_line=$(grep -m1 '^vizier_request_dispatch_notes ' "$VIZIER_TEST_REPO/skills/supervise/SKILL.md")
eval "$map_line"
assert_eq "$(cat "$map")" "$(printf '%s\t%s' "$dispatch" "$mode")" \
  "the mode map is built from the note brief wrote, keyed by the real dispatch id"

# supervise resolves the default mode through the request file it just found.
# This call is the reason supervise must source brief-lib: unsourced it is
# `command not found`, rc 127, swallowed by `|| default_mode=""`.
default_mode=$(vizier_project_mode "$(vizier_request_get "$wake_slug" project)") || default_mode=""
assert_eq "$default_mode" "direct-PR" "the cold wake recovers the project's delivery mode"

# --- a real batch: a terminal message AND the traffic around it ------------
# The loop used to process exactly one worker_done per batch, so no
# non-terminal type had ever been through it. That is what let a question be
# planned `none not-terminal` -- a heartbeat's disposition -- and then acked
# away with a captain decision owed and nobody holding it.
fake_orca_message "$run" d0 heartbeat "tick"
fake_orca_message "$run" d1 worker_done "PR https://x/1" "$(fake_orca_payload "$dispatch")"
fake_orca_message "$run" d2 question "ship it behind a flag?"
fake_orca_message "$run" d3 escalation "the pipeline wants a schema change"
# READ WITHOUT --peek. A peek returns the messages but forms no delivery, so
# a peeked batch has no ack handle and can never be acknowledged -- Orca
# replays it forever. This is the read the supervise skill makes.
orca orchestration run-use --id "$run" --json >/dev/null
plan=$(orca orchestration check --run "$run" --json | vizier_supervise_plan "$default_mode" "$map")
assert_contains "$plan" "PLAN d0 none not-terminal" "a heartbeat is not a terminal event"
assert_contains "$plan" "PLAN d1 release ok" "a successful worker_done plans a release"
assert_contains "$plan" "PLAN d2 reply question" "a question owes the captain an answer"
assert_contains "$plan" "PLAN d3 reply escalation" "so does an escalation"
assert_eq "$(printf '%s\n' "$plan" | grep -c '^ACK ')" "1" "one ACK line for the whole four-message batch"

# Only the terminal one releases. The negative matters more than the positive:
# a bug that treated a question as terminal would show up here and nowhere
# else in this file.
orca orchestration worker-release --dispatch "$dispatch" --json >/dev/null
assert_eq "$(fake_orca_calls | grep -c 'worker-release --dispatch')" "1" \
  "exactly one release for a four-message batch with one terminal in it"

printf '%s\n' "$plan" | sed -n 's/^ACK //p' | while IFS= read -r ack_id; do
  [ -n "$ack_id" ] || continue
  orca orchestration run-use --id "$run" --json >/dev/null
  orca orchestration check --run "$run" --ack "$ack_id" --json >/dev/null
done
assert_eq "$(orca orchestration check --run "$run" --peek --json | jq -r '.result.messages | length')" "0" "mailbox drained"

# --- close ----------------------------------------------------------------
vizier_request_close "$slug"
assert_eq "$(vizier_open_run_ids)" "" "the hook stops waiting once the request closes"

# --- the no-mistakes variant HOLDS instead of releasing -------------------
run2=$(orca orchestration run-create --objective "Ship it" --json | jq -r '.result.run.id')
vizier_request_create shipit "$run2" platform github:acme/platform local "Ship it"
fake_orca_message "$run2" e1 worker_done "all done" "$(fake_orca_payload dispatch-9)"
orca orchestration run-use --id "$run2" --json >/dev/null
plan=$(orca orchestration check --run "$run2" --json | vizier_supervise_plan no-mistakes)
assert_contains "$plan" "PLAN e1 hold no-axi-outcome" "no axi outcome -> hold"
# holding still acks: the message WAS processed, the terminal just stays put
assert_eq "$(printf '%s\n' "$plan" | grep -c '^ACK ')" "1" "a held message is still a processed message"
# and nothing was released
assert_eq "$(fake_orca_calls | grep -c 'worker-release --dispatch dispatch-9')" "0" "a held terminal is never released"

# --- a MULTI-message batch must drain the queue COMPLETELY ----------------
# ONE ack clears the WHOLE delivery, and the handle is the delivery's, not any
# message's. This test previously asserted the opposite -- two messages, two
# ACK lines, one `--ack` each -- and defended it as "correct either way".
# Against the real app every one of those acks is refused with
# `stale_delivery`, so the batch would have replayed forever: re-planning the
# release, re-running worker-release on an already-released dispatch, and
# re-reporting the same PR to the captain on every wake.
run3=$(orca orchestration run-create --objective "Two workers" --json | jq -r '.result.run.id')
vizier_request_create two-workers "$run3" platform github:acme/platform local "Two workers"
fake_orca_message "$run3" t1 worker_done "PR https://x/A" "$(fake_orca_payload dispatch-A)"
fake_orca_message "$run3" t2 worker_done "PR https://x/B" "$(fake_orca_payload dispatch-B)"
orca orchestration run-use --id "$run3" --json >/dev/null
plan=$(orca orchestration check --run "$run3" --json | vizier_supervise_plan direct-PR)
assert_eq "$(printf '%s\n' "$plan" | grep -c '^PLAN ')" "2" "a two-message batch plans two messages"
assert_eq "$(printf '%s\n' "$plan" | grep -c '^ACK ')" "1" "and exactly one ack, naming the delivery"

# Exactly what the skill tells the model to do.
printf '%s\n' "$plan" | sed -n 's/^ACK //p' | while IFS= read -r ack_id; do
  [ -n "$ack_id" ] || continue
  orca orchestration run-use --id "$run3" --json >/dev/null
  orca orchestration check --run "$run3" --ack "$ack_id" --json >/dev/null
done
assert_eq "$(orca orchestration check --run "$run3" --peek --json | jq -r '.result.messages | length')" "0" \
  "the whole delivery is drained -- nothing is left to be replayed"

# AND THE ACK REALLY WAS THE DELIVERY ID, not a message id that happened to
# work against a forgiving double. Acking a message id is refused outright.
fake_orca_message "$run3" t3 worker_done "PR https://x/C" "$(fake_orca_payload dispatch-C)"
orca orchestration run-use --id "$run3" --json >/dev/null
orca orchestration check --run "$run3" --json >/dev/null
orca orchestration run-use --id "$run3" --json >/dev/null
out=$(orca orchestration check --run "$run3" --ack t3 --json 2>&1); rc=$?
assert_rc "$rc" 1 "acking a MESSAGE id is refused"
assert_eq "$(printf '%s' "$out" | jq -r '.error.code')" "stale_delivery" "with stale_delivery"
assert_eq "$(orca orchestration check --run "$run3" --peek --json | jq -r '.result.messages | length')" "1" \
  "and the message is still queued, exactly as the real app leaves it"

vizier_test_teardown
vizier_test_report
