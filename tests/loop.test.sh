#!/usr/bin/env bash
# The whole coordination loop, end to end, with no app and no model:
# open -> route -> brief -> dispatch -> worker_done -> plan -> release -> close.
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-home.sh"
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
dispatch=$(orca orchestration worker-start --task "$task" --run "$run" \
  --agent claude --worktree new-top-level --setup run --on "$host" --json \
  | jq -r '.result.dispatch.id')

# the host chosen at OPEN is the host used at DISPATCH -- the single rule that
# no unit test can check, because it spans two libraries and a file
assert_contains "$(fake_orca_calls)" "--on Mac mini" "dispatch inherited the request's host"
# and the brief that reached Orca really had all four layers
assert_eq "$(grep -c '^## ' "$VIZIER_FAKE_ORCA_STATE/spec.$task")" "4" "the stored spec has four layers"
assert_contains "$(cat "$VIZIER_FAKE_ORCA_STATE/spec.$task")" "gh-axi" "invariants reached the worker"

# --- worker reports done --------------------------------------------------
fake_orca_queue "$run" "{\"delivery_id\":\"d1\",\"type\":\"worker_done\",\"dispatch_id\":\"$dispatch\",\"outcome\":\"succeeded\",\"body\":\"PR https://x/1\"}"
plan=$(orca orchestration check --run "$run" --peek --json | vizier_supervise_plan "$mode")
assert_contains "$plan" "PLAN d1 release ok" "a successful worker_done plans a release"
assert_eq "$(printf '%s\n' "$plan" | tail -1)" "ACK d1" "and the batch is ackable"

orca orchestration worker-release --dispatch "$dispatch" --json >/dev/null
orca orchestration check --run "$run" --ack d1 --json >/dev/null
assert_eq "$(orca orchestration check --run "$run" --peek --json | wc -l | tr -d ' ')" "0" "mailbox drained"

# --- close ----------------------------------------------------------------
vizier_request_close "$slug"
assert_eq "$(vizier_open_run_ids)" "" "the hook stops waiting once the request closes"

# --- the no-mistakes variant HOLDS instead of releasing -------------------
run2=$(orca orchestration run-create --objective "Ship it" --json | jq -r '.result.run.id')
vizier_request_create shipit "$run2" platform github:acme/platform local "Ship it"
fake_orca_queue "$run2" '{"delivery_id":"e1","type":"worker_done","dispatch_id":"dispatch-9","outcome":"succeeded","body":"all done"}'
plan=$(orca orchestration check --run "$run2" --peek --json | vizier_supervise_plan no-mistakes)
assert_contains "$plan" "PLAN e1 hold no-axi-outcome" "no axi outcome -> hold"
# holding still acks: the message WAS processed, the terminal just stays put
assert_eq "$(printf '%s\n' "$plan" | tail -1)" "ACK e1" "a held message is still a processed message"
# and nothing was released
assert_eq "$(fake_orca_calls | grep -c 'worker-release --dispatch dispatch-9')" "0" "a held terminal is never released"

# --- a MULTI-message batch must drain the queue COMPLETELY ----------------
# The single `ACK <last id>` this plan used to print was issued as a single
# `--ack`, and an ack removes exactly one delivery. So a two-message batch
# left the first message queued: the next wake replayed it, re-planned a
# release, re-ran worker-release on an already-released dispatch, and
# re-reported the same PR to the captain. Nothing in a unit test could see
# that -- it only shows up against a real queue, acked the way the skill says.
run3=$(orca orchestration run-create --objective "Two workers" --json | jq -r '.result.run.id')
vizier_request_create two-workers "$run3" platform github:acme/platform local "Two workers"
fake_orca_queue "$run3" '{"delivery_id":"t1","type":"worker_done","dispatch_id":"dispatch-A","outcome":"succeeded","body":"PR https://x/A"}'
fake_orca_queue "$run3" '{"delivery_id":"t2","type":"worker_done","dispatch_id":"dispatch-B","outcome":"succeeded","body":"PR https://x/B"}'
plan=$(orca orchestration check --run "$run3" --peek --json | vizier_supervise_plan direct-PR)
assert_eq "$(printf '%s\n' "$plan" | grep -c '^ACK ')" "2" "a two-message batch plans two acks"

# Exactly what the skill tells the model to do: one `--ack` per ACK line.
printf '%s\n' "$plan" | sed -n 's/^ACK //p' | while IFS= read -r ack_id; do
  [ -n "$ack_id" ] || continue
  orca orchestration check --run "$run3" --ack "$ack_id" --json >/dev/null
done
assert_eq "$(orca orchestration check --run "$run3" --peek --json | wc -l | tr -d ' ')" "0" \
  "every delivery in the batch is drained -- nothing is left to be replayed"

vizier_test_teardown
vizier_test_report
