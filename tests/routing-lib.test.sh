#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-home.sh"
. "$VIZIER_TEST_REPO/lib/vizier-routing-lib.sh"

fake_orca_seed_host local "this machine" local
fake_orca_seed_host 0559ea68 "Mac mini" environment
fake_orca_seed_host beef "Broken box" environment

assert_eq "$(vizier_hosts | wc -l | tr -d ' ')" "3" "three hosts discovered"
assert_eq "$(vizier_hosts | head -1)" "$(printf 'local\tthis machine\tlocal')" "TSV shape"

# --- health ---------------------------------------------------------------
fake_orca_set_status ""           ready   true
fake_orca_set_status "Mac mini"   ready   true
fake_orca_set_status "Broken box" ready   false

assert_eq "$(vizier_host_health "this machine" local)" "ready" "local is ready"
assert_eq "$(vizier_host_health "Mac mini" environment)" "ready" "remote ready"
assert_eq "$(vizier_host_health "Broken box" environment)" "unreachable" "reachable=false is not eligible"
vizier_host_health "Broken box" environment >/dev/null; assert_eq "$?" "1" "and returns rc 1"

fake_orca_set_status "Mac mini" starting true
assert_eq "$(vizier_host_health "Mac mini" environment)" "state=starting" "a non-ready state is named, not summarised"

# the local host must be probed with NO host flag at all
assert_contains "$(fake_orca_calls)" "status --json" "local health used no host flag"
assert_contains "$(fake_orca_calls)" "status --environment Mac mini --json" "remote health used the NAME"

# --- setups ---------------------------------------------------------------
fake_orca_seed_setup "github:acme/platform" local ready
fake_orca_seed_setup "github:acme/platform" 0559ea68 pending
assert_eq "$(vizier_host_setup_state github:acme/platform local)" "ready" "ready setup"
assert_eq "$(vizier_host_setup_state github:acme/platform 0559ea68)" "pending" "pending setup reported as-is"
assert_eq "$(vizier_host_setup_state github:acme/platform beef)" "none" "no setup at all"
assert_contains "$(fake_orca_calls)" "project setups --project github:acme/platform --host local --json" "setup lookup used the host ID"

# --- the table ------------------------------------------------------------
fake_orca_set_status "Mac mini" ready true
t=$(vizier_routing_table github:acme/platform)
assert_eq "$(printf '%s\n' "$t" | wc -l | tr -d ' ')" "3" "one row per host"
assert_eq "$(printf '%s\n' "$t" | awk -F'\t' '$1=="this machine"{print $4}')" "yes" "local eligible"
assert_eq "$(printf '%s\n' "$t" | awk -F'\t' '$1=="Mac mini"{print $4}')" "no" "healthy host with a pending setup is NOT eligible"
assert_eq "$(printf '%s\n' "$t" | awk -F'\t' '$1=="Broken box"{print $4}')" "no" "unreachable host is not eligible"
assert_eq "$(printf '%s\n' "$t" | awk -F'\t' '$1=="Mac mini"{print $3}')" "pending" "the reason survives into the table"

# --- an orca failure is never silently 'eligible' -------------------------
PATH="$VIZIER_TEST_TMP/nobin:$PATH" ; mkdir -p "$VIZIER_TEST_TMP/nobin"
printf '#!/bin/sh\nexit 3\n' > "$VIZIER_TEST_TMP/nobin/orca"; chmod +x "$VIZIER_TEST_TMP/nobin/orca"
assert_eq "$(vizier_host_health "this machine" local)" "error" "a failing orca is an error, not ready"
vizier_host_health "this machine" local >/dev/null; assert_eq "$?" "1" "and rc 1"

vizier_test_teardown
vizier_test_report
