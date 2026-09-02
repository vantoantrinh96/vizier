# shellcheck shell=bash
# Scans open requests and waits on the mailbox of several Runs at once.
# Requires lib/vizier-home.sh to be sourced first.
#
# WHY inbox AND NOT `check --wait`: measured 2026-09-02, reading a Run's
# mailbox with `check` is done as that Run's BOUND coordinator terminal. The
# binding is 1:1, a terminal bound to one Run is fenced off every other
# (`consumer_fenced`), and an unbound terminal reads nothing at all. So the
# design this file used to have -- one session, one `check --wait` per open
# Run, all in parallel -- could never have worked against the real app: at
# most one of those waits can succeed.
#
# `orca orchestration inbox` is the read that has none of those constraints:
# no binding, every Run, every row carrying `run_id` and a `read` flag. It
# also has no `--ack` and no delivery, which is not a gap -- it is exactly the
# split this project already committed to. THE HOOK NEVER ACKS. Forming the
# delivery, and acknowledging it, belongs to `supervise`, which binds with
# `run-use` first. See docs/decisions/2026-09-02-sender-terminal.md.
#
# THE COST OF THE SWAP IS POLLING. `inbox` has no `--wait`, so this is a poll
# loop where it used to be a long block, and every tick is a real call into
# the app rather than a read of a local file. That is why the default cadence
# below is seconds, not the one second the old file-polling loop could afford.
#
# ALWAYS FILTER BY THE OPEN RUNS. `inbox` shows messages across every Run on
# the machine, including Runs this vizier does not own. Waking on one of those
# would put a first mate to work on someone else's Run.
#
# REQUIRES lib/vizier-mailbox-lib.sh to be sourced first (after
# lib/vizier-home.sh). It owns the shape of the response -- and `inbox`
# returns the same `.result.messages[]` envelope `check` does, which is the
# whole reason that library exists as its own owner.

VIZIER_WAKE_TYPES="${VIZIER_WAKE_TYPES:-worker_done,escalation,question}"

# Poll cadence. EVERY TICK IS NOW A REAL CALL INTO THE APP, not a stat of a
# local file the way it was when background `orca --wait` children did the
# blocking -- so the old 1000ms would mean ~28,500 CLI invocations across an
# eight-hour hook. 3000ms costs ~9,500 and adds at most three seconds of wake
# latency, which is not something a human supervising a fleet notices. Tests
# lower it to 50ms for speed.
VIZIER_WAKE_POLL_MS="${VIZIER_WAKE_POLL_MS:-3000}"

# `inbox` returns newest-first (observed) and takes `--limit`. An explicit
# limit is passed rather than relying on whatever the default is, because an
# unknown default is exactly the kind of thing that silently truncates the one
# message that mattered once a mailbox gets busy.
VIZIER_WAKE_INBOX_LIMIT="${VIZIER_WAKE_INBOX_LIMIT:-100}"

# Return only the frontmatter: the block between the first `---` line and the
# second. A "status:" that happens to appear in the prose body must never get
# to decide anything, and `tr -d '\r'` keeps a CRLF file from silently being
# treated as not-open.
_vizier_frontmatter() {  # <file>
  awk '
    { gsub(/\r$/, "") }
    NR==1 && $0 !~ /^---[[:space:]]*$/ { exit }
    /^---[[:space:]]*$/ { n++; if (n==2) exit; next }
    n==1 { print }
  ' "$1" 2>/dev/null | tr -d '\r'
}

vizier_open_run_ids() {
  local dir f fm status run
  dir=$(vizier_requests_dir)
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    fm=$(_vizier_frontmatter "$f")
    [ -n "$fm" ] || continue
    status=$(printf '%s\n' "$fm" | sed -n 's/^status:[[:space:]]*//p' | head -1)
    [ "$status" = "open" ] || continue
    run=$(printf '%s\n' "$fm" | sed -n 's/^run_id:[[:space:]]*//p' | head -1)
    [ -n "$run" ] && printf '%s\n' "$run"
  done
}

vizier_summarize() {  # <json_line>
  local line=$1 type run detail
  type=$(printf '%s' "$line" | jq -r '.type // "message"' 2>/dev/null)
  run=$(printf '%s' "$line" | jq -r '.run_id // ""' 2>/dev/null)
  detail=$(printf '%s' "$line" | jq -r '.outcome // .body // ""' 2>/dev/null | tr '\n\r\t' '   ' | cut -c1-120)
  # EVERY field goes through tr, not just detail: the caller relies on "exactly
  # one line", and a newline slipping through .type or .run_id breaks that
  # contract exactly as badly as one slipping through .body.
  printf '%s run=%s %s' "${type:-message}" "${run:-?}" "${detail}" \
    | tr '\n\r\t' '   ' | sed 's/[[:space:]]*$//'
}

_vizier_wake_pick() {  # <raw_inbox_json> <run_ids one per line> -- one message, or empty
  # THREE FILTERS, ALL LOAD-BEARING:
  #   read == 0   -- `read` flips to 1 when a delivery is formed, so this is
  #                  "nobody has taken delivery of this yet". It is the same
  #                  boundary the old `--peek` wait had, not a new one.
  #   run_id      -- only Runs this vizier has an OPEN request for.
  #   type        -- VIZIER_WAKE_TYPES, applied here because `inbox` has no
  #                  `--types` of its own.
  # THE NEWEST MATCH IS NAMED, and it is chosen by an explicit sort rather
  # than by trusting the order `inbox` happens to return. `inbox` was observed
  # newest-first, but that was one measurement over one Run, and the choice
  # is not cosmetic: the Claude hook compares each summary against the last
  # one it reported and stays silent on a repeat, so naming a stale message
  # while a fresh one waits would suppress the wake entirely. Sorting here
  # makes that independent of an ordering nobody has pinned.
  local raw="$1" runs="$2"
  vizier_mailbox_ok "$raw" || return 0
  printf '%s' "$raw" | jq -c --arg types "$VIZIER_WAKE_TYPES" --arg runs "$runs" '
      ($types | split(",")) as $t
    | ($runs | split("\n") | map(select(length > 0))) as $r
    | [ .result.messages[]?
        | select(.read == 0)
        | select(.run_id as $x | $r | index($x))
        | select(.type  as $y | $t | index($y)) ]
    | sort_by([.created_at, .sequence])
    | last // empty
  ' 2>/dev/null
}

# Read run ids from stdin, poll up to <timeout_ms>, print one summary line or
# empty.
vizier_wait_any_run() {  # <timeout_ms>
  # NO BACKGROUND CHILDREN, AND SO NO TRAPS. The previous version forked one
  # `orca --wait` per Run and needed two traps plus a pid file to guarantee
  # none of them outlived the hook -- an orphan could live eight hours, once
  # per turn per session. Polling a single short-lived call removes that whole
  # class of failure rather than managing it: there is nothing left to leak.
  # The harness still owns the process group, so cutting the hook still ends
  # everything here; `set -m` must never appear in this file, for the same
  # reason it never could.
  local timeout_ms=$1 runs="" run poll_s deadline raw line
  while IFS= read -r run; do
    [ -n "$run" ] || continue
    runs="${runs}${run}
"
  done
  [ -n "$runs" ] || return 0

  # Deadline by REAL wall-clock time, not a logical counter: a counter that
  # accumulates poll ticks drifts away from real time, since each iteration
  # also costs time running the loop body.
  poll_s=$(awk -v m="${VIZIER_WAKE_POLL_MS}" 'BEGIN{printf "%.3f", m/1000}')
  deadline=$(( $(date +%s) + (timeout_ms + 999) / 1000 ))
  while :; do
    # `</dev/null` is kept from the old fan-out for the same reason it was
    # added there: `orca` is a real process, and nothing about this loop
    # should depend on what it does or does not read from an inherited stdin.
    raw=$(orca orchestration inbox --limit "$VIZIER_WAKE_INBOX_LIMIT" --json \
            2>/dev/null </dev/null)
    line=$(_vizier_wake_pick "$raw" "$runs")
    if [ -n "$line" ]; then
      vizier_summarize "$line"
      return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] || return 0
    sleep "$poll_s"
  done
}
