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
printf -- '---\nrun_id: run_orphanprobe\nstatus: open\n---\nx\n' > "$(vizier_requests_dir)/orphan.md"
set -m
( printf 'run_orphanprobe\n' | vizier_wait_any_run 30000 >/dev/null 2>&1 ) & waiter=$!
set +m
sleep 0.8
kill -TERM -"$waiter" 2>/dev/null || kill -TERM "$waiter" 2>/dev/null || true
sleep 0.8
leaked=$(pgrep -f 'run_orphanprobe' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$leaked" "0" "killing the process group leaves no orphaned orca"
# `pgrep -f run_orphanprobe` ONLY matches the child orca's argv, so it used to
# report 0 while the wrapping shell was still alive and spinning its poll
# loop. Counting the whole process group is what actually catches it:
# $waiter is the pgid because this block runs under `set -m`.
remaining=$(pgrep -g "$waiter" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$remaining" "0" "the whole process group is gone, not just the child orca"
pkill -f 'run_orphanprobe' 2>/dev/null || true
rm -f "$(vizier_requests_dir)/orphan.md"

# A keepalive line is dropped, not treated as a message
fake_orca_queue run_a '{"_keepalive":true}'
out=$(printf 'run_a\n' | vizier_wait_any_run 300)
assert_eq "$out" "" "a keepalive does not count as a message"

vizier_test_teardown
vizier_test_report
