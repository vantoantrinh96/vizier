#!/usr/bin/env bash
# fake-orca must answer the whole Orca surface the orchestration loop uses,
# in the SHAPE the real app returns -- envelope included. Every expectation
# here was copied from a real 1.4.193 response, not invented.
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup

# --- envelope -------------------------------------------------------------
out=$(orca status --json)
assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "true" "status is enveloped ok"
assert_eq "$(printf '%s' "$out" | jq -r '.result.runtime.state')" "ready" "health lives under result.runtime"
assert_eq "$(printf '%s' "$out" | jq -r '.result.runtime.reachable')" "true" "reachable under result.runtime"

# --- hosts ----------------------------------------------------------------
fake_orca_seed_host local "this machine" local
fake_orca_seed_host 0559ea68 "Mac mini" environment
out=$(orca host list --json)
assert_eq "$(printf '%s' "$out" | jq -r '.result.hosts | length')" "2" "two hosts"
assert_eq "$(printf '%s' "$out" | jq -r '.result.hosts[0].selector')" "--host local" "local selector verbatim"
assert_eq "$(printf '%s' "$out" | jq -r '.result.hosts[1].selector')" "--environment Mac mini" "env selector verbatim"
assert_eq "$(printf '%s' "$out" | jq -r '.result.hosts[1].name')" "Mac mini" "env host name"

# --- per-host health ------------------------------------------------------
fake_orca_set_status "Mac mini" offline false
assert_eq "$(orca status --environment "Mac mini" --json | jq -r '.result.runtime.reachable')" "false" "remote host reports its own health"
assert_eq "$(orca status --json | jq -r '.result.runtime.reachable')" "true" "local host unaffected"

# --- project setups -------------------------------------------------------
fake_orca_seed_setup "github:acme/platform" local ready
fake_orca_seed_setup "github:acme/platform" 0559ea68 pending
assert_eq "$(orca project setups --project github:acme/platform --json | jq -r '.result.setups | length')" "2" "both setups listed"
assert_eq "$(orca project setups --project github:acme/platform --host local --json | jq -r '.result.setups[0].setupState')" "ready" "filter by host id"
assert_eq "$(orca project setups --project github:acme/platform --host 0559ea68 --json | jq -r '.result.setups[0].setupState')" "pending" "non-ready setup preserved"

# --- run / task / worker ids are deterministic ----------------------------
assert_eq "$(orca orchestration run-create --objective "first" --json | jq -r '.result.run.id')" "run-1" "first run id"
assert_eq "$(orca orchestration run-create --objective "second" --json | jq -r '.result.run.id')" "run-2" "second run id"
assert_eq "$(orca orchestration task-create --spec "s" --run run-1 --json | jq -r '.result.task.id')" "task-1" "first task id"
out=$(orca orchestration worker-start --task task-1 --run run-1 --agent claude --worktree new-top-level --setup run --json)
# `.result.dispatchId`, captured from a real successful dispatch. The
# `.result.dispatch.id` this used to assert does not exist in a real response.
assert_eq "$(printf '%s' "$out" | jq -r '.result.dispatchId')" "dispatch-1" "first dispatch id"
assert_eq "$(printf '%s' "$out" | jq -r '.result.dispatch.id // "absent"')" "absent" \
  "and the invented nested shape really is absent"
assert_eq "$(printf '%s' "$out" | jq -r '.result.state')" "ready" "a successful dispatch is ready"
assert_eq "$(printf '%s' "$out" | jq -r '.result.stage')" "input_accepted" "with the prompt accepted"
assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "true" "worker-start ok"

# --- worker-show carries the terminal handle ------------------------------
# `.result.dispatch.assignee_handle`, captured from a real dispatch. The
# invented `.result.worker.agent_terminal_handle` this used to assert appears
# nowhere in a real response -- the same failure as the mailbox fields, found
# the same way, by finally running the thing.
assert_eq "$(orca orchestration worker-show --dispatch dispatch-1 --json | jq -r '.result.dispatch.assignee_handle')" "term-1" "handle for dispatch-1"
assert_eq "$(orca orchestration worker-show --dispatch dispatch-1 --json | jq -r '.result.worker.agent_terminal_handle // "absent"')" "absent" \
  "and the invented field really is absent, so a stale reader fails loudly"
assert_eq "$(orca orchestration worker-show --dispatch dispatch-1 --json | jq -r '.result.dispatch.id')" "dispatch-1" "the id field is `id`, not `dispatch_id`"

# --- release: the receipt IS .result --------------------------------------
assert_eq "$(orca orchestration worker-release --dispatch dispatch-1 --json | jq -r '.result.state')" "released" "release settles"
assert_eq "$(orca orchestration worker-release --dispatch dispatch-1 --json | jq -r '.result.dispatchId')" "dispatch-1" "the receipt names the dispatch in camelCase"
assert_eq "$(orca orchestration worker-release --dispatch dispatch-1 --json | jq -r '.result.release.state // "absent"')" "absent" \
  "and there is no .result.release wrapper"

# --- check: the envelope, the delivery, and the ack -----------------------
# EVERY EXPECTATION BELOW IS A MEASURED ORCA BEHAVIOUR, not a convenience of
# the double. See docs/verification/2026-09-02-mailbox-delivery-contract.md.
fake_orca_message run-1 msg_1 worker_done "done" "$(fake_orca_payload dispatch-1)"
fake_orca_message run-1 msg_2 heartbeat "tick"

# THE FENCE, FIRST. Reading a Run's mailbox is done as that Run's bound
# coordinator terminal; unbound reads nothing. Measured against the real app,
# and modelled here so a caller that forgets `run-use` cannot go green.
out=$(orca orchestration check --run run-1 --peek --json 2>&1); rc=$?
assert_rc "$rc" 1 "an UNBOUND terminal cannot read a mailbox"
assert_eq "$(printf '%s' "$out" | jq -r '.error.code')" "consumer_fenced" "and says consumer_fenced"
assert_contains "$(printf '%s' "$out" | jq -r '.error.message')" "no longer bound" \
  "with the real wording for an unbound terminal"

orca orchestration run-use --id run-2 --json >/dev/null
out=$(orca orchestration check --run run-1 --peek --json 2>&1); rc=$?
assert_rc "$rc" 1 "a terminal bound to ANOTHER Run cannot read this one either"
assert_contains "$(printf '%s' "$out" | jq -r '.error.message')" "bound to run-2, not run-1" \
  "and the message names both Runs, as the real one does"

# run-use needs NO sender terminal -- measured 2026-09-02 from a plain shell.
out=$(orca orchestration run-use --id run-1 --json); rc=$?
assert_rc "$rc" 0 "run-use binds without a sender terminal"
assert_eq "$(printf '%s' "$out" | jq -r '.result.run.id')" "run-1" "and reports the Run it bound"
assert_eq "$(orca orchestration run-current --json | jq -r '.result.run.id')" "run-1" "run-current agrees"

# ONE ENVELOPE, PRETTY-PRINTED -- never one message per line. A caller reading
# this as newline-delimited JSON must get NOTHING, because that is exactly
# what it gets from the real app.
out=$(orca orchestration check --run run-1 --peek --json)
assert_eq "$(printf '%s' "$out" | jq -r '.result.messages | length')" "2" "peek returns both, inside the envelope"
# PRETTY-PRINTED, asserted directly. "Reading it as JSON lines yields nothing"
# is NOT enough on its own: a COMPACT envelope also yields nothing that way,
# because the top level of the envelope has no `.type` either. Only the line
# count separates the two, and only the pretty one reproduces the real
# failure, where a message's fields land on separate lines.
assert_eq "$( [ "$(printf '%s' "$out" | wc -l | tr -d ' ')" -gt 10 ] && printf 'yes' )" "yes" \
  "the envelope is pretty-printed across many lines, exactly like the real CLI"
assert_eq "$(printf '%s\n' "$out" | jq -rc 'select(.type? != null)' 2>/dev/null | grep -c . || true)" "0" \
  "and read as JSON lines it yields no messages at all"
assert_eq "$(printf '%s' "$out" | jq -r '.result.deliveryId // "none"')" "none" \
  "a PEEK creates no delivery, so a peeked batch has no ack handle"

assert_eq "$(orca orchestration check --run run-1 --peek --types worker_done --json | jq -r '.result.messages[0].type')" \
  "worker_done" "types filter"
assert_eq "$(orca orchestration check --run run-1 --peek --json | jq -r '.result.messages | length')" "2" "peek did not consume"

# A DEFAULT read forms a delivery over the batch and names it.
out=$(orca orchestration check --run run-1 --json)
delivery=$(printf '%s' "$out" | jq -r '.result.deliveryId')
assert_contains "$delivery" "delivery-" "a default read forms a delivery"
assert_eq "$(printf '%s' "$out" | jq -r '.result.replayed')" "false" "the first read is not a replay"

# REPLAY UNTIL ACK: same id, same messages, replayed:true.
out=$(orca orchestration check --run run-1 --json)
assert_eq "$(printf '%s' "$out" | jq -r '.result.deliveryId')" "$delivery" "reading again replays the SAME delivery"
assert_eq "$(printf '%s' "$out" | jq -r '.result.replayed')" "true" "and says it is a replay"
assert_eq "$(printf '%s' "$out" | jq -r '.result.messages | length')" "2" "with the same messages"

# ACKING A MESSAGE ID IS REFUSED. Measured verbatim against the real app --
# this is the behaviour that makes a per-message ack design impossible, and
# a double that quietly accepted it would hide that entirely.
out=$(orca orchestration check --run run-1 --ack msg_1 --json 2>&1); rc=$?
assert_rc "$rc" 1 "acking a message id fails"
assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "false" "and returns an error envelope"
assert_eq "$(printf '%s' "$out" | jq -r '.error.code')" "stale_delivery" "with the real error code"
assert_eq "$(orca orchestration check --run run-1 --peek --json | jq -r '.result.messages | length')" "2" \
  "and acks NOTHING -- both messages are still queued"

# A message that arrives AFTER the delivery was formed is not part of it and
# must survive the ack. A double that truncated the whole queue would hide
# exactly the bug the all-or-nothing ack rule exists to prevent.
fake_orca_message run-1 msg_late status "arrived after the delivery"
out=$(orca orchestration check --run run-1 --ack "$delivery" --json)
assert_eq "$(printf '%s' "$out" | jq -r '.result.acknowledged')" "$delivery" "the ack echoes the delivery it cleared"
assert_eq "$(orca orchestration check --run run-1 --peek --json | jq -r '[.result.messages[].id] | join(",")')" \
  "msg_late" "one ack clears the whole delivery, and only the delivery"

# --- inbox: the UNFENCED, cross-Run read the wake hook uses ---------------
# No binding, no delivery, no ack. This is the only read a hook is allowed to
# make, and the only one that can see more than one Run.
fake_orca_message run-9 msg_other question "a message on a Run we are not bound to"
out=$(orca orchestration inbox --json); rc=$?
assert_rc "$rc" 0 "inbox works with no binding at all"
assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "true" "and returns an ok envelope"
assert_contains "$(printf '%s' "$out" | jq -r '[.result.messages[].run_id] | unique | join(",")')" "run-9" \
  "and sees a Run this terminal is NOT bound to -- the whole point"
assert_eq "$(printf '%s' "$out" | jq -r '.result.deliveryId // "none"')" "none" \
  "inbox forms no delivery, so a hook using it can never consume a batch"
assert_eq "$(orca orchestration inbox --limit 1 --json | jq -r '.result.messages | length')" "1" \
  "--limit is honoured"

# `read` FLIPS WHEN A DELIVERY IS FORMED. The wake hook's "is this new" test
# is `read == 0`, so this flag is what stops it waking forever on messages
# somebody has already taken delivery of.
assert_eq "$(orca orchestration inbox --json | jq -r '[.result.messages[] | select(.id == "msg_other") | .read] | join("")')" "0" \
  "an undelivered message reads 0"
orca orchestration run-use --id run-9 --json >/dev/null
orca orchestration check --run run-9 --json >/dev/null
assert_eq "$(orca orchestration inbox --json | jq -r '[.result.messages[] | select(.id == "msg_other") | .read] | join("")')" "1" \
  "and 1 once a delivery has been formed over it"
orca orchestration run-use --id run-1 --json >/dev/null

# --- terminal list: where brief finds a --from handle ---------------------
fake_orca_seed_terminal term_fake_1 "~"
assert_eq "$(orca terminal list --json | jq -r '.result.terminals[0].handle')" "term_fake_1" \
  "terminal list gives the handle worker-start needs for --from"

# --- a --wait that finds nothing still ANSWERS ----------------------------
# Real Orca returns a normal ok envelope with `messages: []` and
# `timedOut: true`; it does not go silent. A double that printed nothing let a
# caller treat "orca produced no output" -- which means orca failed -- and "the
# mailbox is quiet" as the same thing.
orca orchestration run-use --id run-quiet --json >/dev/null
out=$(orca orchestration check --run run-quiet --wait --types worker_done --timeout-ms 200 --json)
assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "true" "a timed-out wait still returns an ok envelope, not silence"
assert_eq "$(printf '%s' "$out" | jq -r '.result.timedOut')" "true" "and says it timed out"
assert_eq "$(printf '%s' "$out" | jq -r '.result.messages | length')" "0" "with an empty messages array"
assert_eq "$(printf '%s' "$out" | jq -r '.result.deliveryId // "none"')" "none" "and nothing to ack"

# --- every call is logged -------------------------------------------------
assert_contains "$(fake_orca_calls)" "orchestration worker-release --dispatch dispatch-1" "release was logged"

# --- unknown command is loud, not silently ok -----------------------------
orca orchestration nonsense --json >/dev/null 2>&1
assert_eq "$?" "64" "unknown subcommand exits 64"

vizier_test_teardown
vizier_test_report
