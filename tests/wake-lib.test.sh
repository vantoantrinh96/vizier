#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-home.sh"
. "$VIZIER_TEST_REPO/lib/vizier-wake-lib.sh"

# Production's poll cadence is 1000ms; the test lowers it to run fast.
export VIZIER_WAKE_POLL_MS=50

mk_request() {  # <slug> <run_id> <status>
  printf -- '---\nrun_id: %s\nproject: demo\nhost: local\nstatus: %s\nopened: 2026-08-31\n---\noriginal request\n' \
    "$2" "$3" > "$(vizier_requests_dir)/$1.md"
}

assert_eq "$(vizier_open_run_ids)" "" "no requests means no runs"

mk_request one run_a open
mk_request two run_b closed
assert_eq "$(vizier_open_run_ids)" "run_a" "only picks up open requests"

mk_request three run_c open
got=$(vizier_open_run_ids | sort | tr '\n' ',')
assert_eq "$got" "run_a,run_c," "picks up multiple open runs"

# A timeout with no message prints empty, rc is still 0
out=$(vizier_open_run_ids | vizier_wait_any_run 200); rc=$?
assert_rc "$rc" 0 "a timeout still gives rc 0"
assert_eq "$out" "" "a timeout prints nothing"

# A message on the second run is still caught: waiting in parallel, not sequentially
fake_orca_queue run_c '{"type":"worker_done","run_id":"run_c","outcome":"succeeded","body":"PR https://x/1"}'
out=$(vizier_open_run_ids | vizier_wait_any_run 3000)
assert_contains "$out" "worker_done" "catches the second run's message"
assert_contains "$out" "run_c" "the summary names the run id"

# The summary is always wrapped into one line
lines=$(printf '%s' "$out" | wc -l | tr -d ' ')
assert_eq "$lines" "0" "the summary is exactly one line, no trailing newline"

# Frontmatter is the only source of truth: "status: open" in the prose body does not count
printf -- '---\nrun_id: run_body\nstatus: closed\n---\nstatus: open\n' > "$(vizier_requests_dir)/body.md"
assert_eq "$(vizier_open_run_ids | grep -c run_body || true)" "0" "status in the prose body does not count"
# A file not opened with `---` is skipped entirely
printf 'a preamble\n---\nrun_id: run_late\nstatus: open\n---\n' > "$(vizier_requests_dir)/late.md"
assert_eq "$(vizier_open_run_ids | grep -c run_late || true)" "0" "frontmatter not at the start of the file is skipped"
rm -f "$(vizier_requests_dir)/body.md" "$(vizier_requests_dir)/late.md"

# A trailing space on either fence is a hand-editing typo, not a different
# file format. The closing fence already tolerated it; the NR==1 opening check
# did not, so `--- ` on line 1 made the hook silently stop waiting on a live
# Run -- indistinguishable from "no open requests".
printf -- '--- \nrun_id: run_space\nstatus: open\n--- \nstatus: closed\n' \
  > "$(vizier_requests_dir)/space.md"
assert_eq "$(vizier_open_run_ids | grep -c run_space || true)" "1" \
  "a trailing space on the fences still reads as an open request"
rm -f "$(vizier_requests_dir)/space.md"

# CRLF must not silently turn an open request into a not-open one
printf -- '---\r\nrun_id: run_crlf\r\nstatus: open\r\n---\r\n' > "$(vizier_requests_dir)/crlf.md"
assert_eq "$(vizier_open_run_ids | grep -c run_crlf || true)" "1" "CRLF frontmatter is still read correctly"
rm -f "$(vizier_requests_dir)/crlf.md"

# vizier_summarize: a newline slipping through .type or .run_id must also get wrapped into one line
s=$(vizier_summarize '{"type":"worker\ndone","run_id":"r\n1","body":"a\nb"}')
assert_eq "$(printf '%s' "$s" | grep -c . )" "1" "the summary is always exactly one line even when every field has a newline"

# Kill the WHOLE PROCESS GROUP -- exactly how the real harness ends a hook.
# Killing only the outer subshell's pid does NOT propagate to the inner
# subshell (measured: leaked=1), so that measurement wouldn't reflect
# production. `set -m` HERE, in the test, makes the background job its own
# group leader; the library must absolutely never turn it on.
#
# BOTH WAITS AROUND THE KILL ARE BOUNDED POLLS, NOT SLEEPS, and neither may be
# replaced by a longer sleep. This probe used to `sleep 0.8`, kill, `sleep
# 0.8`, count -- and it failed 2 runs in 10 of the full suite under 8-way CPU
# load (`got: 1 want: 0`), 0 in 10 idle. Under load the child `orca` had
# sometimes not spawned yet when the kill landed, appeared afterwards, and got
# counted. That race has a nastier second half: on exactly those runs the
# probe never tested what it claims, because killing a group before the child
# exists proves nothing about cleaning the child up. So the wait BEFORE the
# kill is asserted, not just waited -- if the child never appears the probe is
# vacuous and must say so. And a longer sleep AFTER the kill would hide a real
# leak exactly as well as it hides the race, whereas a poll with a deadline
# still fails when cleanup never happens; it only stops failing when cleanup
# merely happened late.
#
# WHAT THIS PROBE ACTUALLY MEASURES, for whoever next mutates the library to
# check the probe still bites: it is the PROCESS GROUP, not the trap, that
# does the cleanup on this path -- `kill -TERM -<pgid>` reaches the child
# `orca` directly. Deleting either trap from `vizier_wait_any_run`, or both,
# therefore leaves this probe green (measured), because the traps cover the
# clean-exit path that a different assertion would have to cover. The
# mutation that genuinely leaks here is `set -m` inside the library (children
# escape the harness's group) together with no trap to reap them; against
# that, this probe reports `leaked: 1` and fails inside its deadline.
count_orphanprobe() { pgrep -f 'run_orphanprobe' 2>/dev/null | wc -l | tr -d ' '; }
count_in_group() { pgrep -g "$1" 2>/dev/null | wc -l | tr -d ' '; }

# Ceilings are in 10ms ticks rather than wall-clock, so the budget stretches
# with the load that slows the polls down -- generous when the machine is
# busy, still finite when the condition is simply never going to be true. The
# spawn ceiling is the larger one because spawn latency under load is the
# thing that was actually measured going long; the kill takes effect at once
# or not at all.
wait_until_count() {  # <test-op> <n> <max_ticks> <cmd...>
  local op=$1 n=$2 max=$3; shift 3
  local i=0
  while [ "$i" -lt "$max" ]; do
    [ "$("$@")" "$op" "$n" ] && return 0
    i=$((i + 1))
    sleep 0.01
  done
  return 1
}

printf -- '---\nrun_id: run_orphanprobe\nstatus: open\n---\nx\n' > "$(vizier_requests_dir)/orphan.md"
set -m
( printf 'run_orphanprobe\n' | vizier_wait_any_run 30000 >/dev/null 2>&1 ) & waiter=$!
set +m
wait_until_count -gt 0 500 count_orphanprobe; spawned=$?
assert_rc "$spawned" 0 "the child orca is running before the kill (or this probe proves nothing)"
kill -TERM -"$waiter" 2>/dev/null || kill -TERM "$waiter" 2>/dev/null || true
wait_until_count -eq 0 300 count_orphanprobe || true
leaked=$(count_orphanprobe)
assert_eq "$leaked" "0" "killing the process group leaves no orphaned orca"
# `pgrep -f run_orphanprobe` ONLY matches the child orca's argv, so it used to
# report 0 while the wrapping shell was still alive and spinning its poll
# loop. Counting the whole process group is what actually catches it:
# $waiter is the pgid because this block runs under `set -m`.
wait_until_count -eq 0 300 count_in_group "$waiter" || true
remaining=$(count_in_group "$waiter")
assert_eq "$remaining" "0" "the whole process group is gone, not just the child orca"
pkill -f 'run_orphanprobe' 2>/dev/null || true
rm -f "$(vizier_requests_dir)/orphan.md"

# A keepalive line is dropped, not treated as a message
fake_orca_queue run_a '{"_keepalive":true}'
out=$(printf 'run_a\n' | vizier_wait_any_run 300)
assert_eq "$out" "" "a keepalive does not count as a message"

vizier_test_teardown
vizier_test_report
