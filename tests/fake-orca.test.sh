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
assert_eq "$(printf '%s' "$out" | jq -r '.result.dispatch.id')" "dispatch-1" "first dispatch id"
assert_eq "$(printf '%s' "$out" | jq -r '.ok')" "true" "worker-start ok"

# --- worker-show carries the terminal handle ------------------------------
assert_eq "$(orca orchestration worker-show --dispatch dispatch-1 --json | jq -r '.result.worker.agent_terminal_handle')" "term-1" "handle for dispatch-1"

# --- release --------------------------------------------------------------
assert_eq "$(orca orchestration worker-release --dispatch dispatch-1 --json | jq -r '.result.release.state')" "released" "release settles"

# --- check: queue, types filter, ack --------------------------------------
fake_orca_queue run-1 '{"delivery_id":"d1","type":"worker_done","dispatch_id":"dispatch-1","body":"done","outcome":"succeeded"}'
fake_orca_queue run-1 '{"delivery_id":"d2","type":"heartbeat","body":"tick"}'
assert_eq "$(orca orchestration check --run run-1 --peek --json | wc -l | tr -d ' ')" "2" "peek returns both"
assert_eq "$(orca orchestration check --run run-1 --peek --types worker_done --json | jq -r '.type')" "worker_done" "types filter"
# peek must NOT consume
assert_eq "$(orca orchestration check --run run-1 --peek --json | wc -l | tr -d ' ')" "2" "peek did not consume"
orca orchestration check --run run-1 --ack d1 --json >/dev/null
assert_eq "$(orca orchestration check --run run-1 --peek --json | wc -l | tr -d ' ')" "1" "ack removed exactly one"

# --- every call is logged -------------------------------------------------
assert_contains "$(fake_orca_calls)" "orchestration worker-release --dispatch dispatch-1" "release was logged"

# --- unknown command is loud, not silently ok -----------------------------
orca orchestration nonsense --json >/dev/null 2>&1
assert_eq "$?" "64" "unknown subcommand exits 64"

vizier_test_teardown
vizier_test_report
