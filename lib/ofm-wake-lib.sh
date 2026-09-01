# shellcheck shell=bash
# Scans open requests and waits on the mailbox of several Runs at once.
# Requires lib/ofm-home.sh to be sourced first.
#
# WHY WAIT IN PARALLEL: `orca orchestration check` is per-Run (`--run <id>`),
# and the spec allows several requests to be open at once. Waiting
# sequentially would let one silent Run block another Run's message for the
# whole timeout. We fork one background process per Run, whichever gets a
# message first wins, then we kill the rest.
#
# ALWAYS PASS --run: a first-mate session is not an Orca terminal, so there is
# no terminal-bound Run to fall back on.

OFM_WAKE_TYPES="${OFM_WAKE_TYPES:-worker_done,escalation,question}"

# Poll cadence. Production keeps it at 1000ms: at an eight-hour timeout that's
# 28,500 loops instead of 285,000, and the extra sub-second wake latency is not
# something a human notices. Tests lower it to 50ms for speed.
OFM_WAKE_POLL_MS="${OFM_WAKE_POLL_MS:-1000}"

# Return only the frontmatter: the block between the first `---` line and the
# second. A "status:" that happens to appear in the prose body must never get
# to decide anything, and `tr -d '\r'` keeps a CRLF file from silently being
# treated as not-open.
_ofm_frontmatter() {  # <file>
  awk '
    { gsub(/\r$/, "") }
    NR==1 && $0 != "---" { exit }
    /^---[[:space:]]*$/ { n++; if (n==2) exit; next }
    n==1 { print }
  ' "$1" 2>/dev/null | tr -d '\r'
}

ofm_open_run_ids() {
  local dir f fm status run
  dir=$(ofm_requests_dir)
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    fm=$(_ofm_frontmatter "$f")
    [ -n "$fm" ] || continue
    status=$(printf '%s\n' "$fm" | sed -n 's/^status:[[:space:]]*//p' | head -1)
    [ "$status" = "open" ] || continue
    run=$(printf '%s\n' "$fm" | sed -n 's/^run_id:[[:space:]]*//p' | head -1)
    [ -n "$run" ] && printf '%s\n' "$run"
  done
}

ofm_summarize() {  # <json_line>
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

# Read run ids from stdin, wait up to <timeout_ms>, print one summary line or
# empty.
ofm_wait_any_run() {  # <timeout_ms>
  # The whole function body lives in a subshell so `trap` belongs only to it,
  # not to the caller's shell.
  (
    local timeout_ms=$1 tmp run i=0 line poll_s deadline f
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/ofm-wake.XXXXXX") || return 0
    # TRAP BEFORE SPAWNING ANYTHING. If this process is killed from the
    # outside -- the harness cuts the hook, the captain closes the session, the
    # machine sleeps -- every child `orca --wait` must die with it. Without the
    # trap, EVERY TURN of EVERY session on the machine would leave behind an
    # orphaned process that can live for up to eight hours. The trap is also
    # the only cleanup path for all three normal exits, so there is nowhere
    # left where cleanup has to be remembered by hand.
    # TWO traps, not one. In bash, a SIGNAL trap runs its handler then
    # CONTINUES execution -- it does not end the process. A single trap
    # combined for both EXIT and INT/TERM would clean up but leave this shell
    # spinning through the poll loop to the original deadline (eight hours in
    # production), once per hook run: exactly the accumulation the trap exists
    # to block. The signal branch must therefore `exit` explicitly. Cleaning up
    # twice is harmless: kill against an already-dead pid and rm -rf against an
    # already-gone directory are both no-ops.
    trap '_ofm_wake_kill_all "$tmp"; rm -rf "$tmp"' EXIT
    trap '_ofm_wake_kill_all "$tmp"; rm -rf "$tmp"; exit 0' INT TERM HUP
    # NEVER `set -m` here. Bash does not create a new process group for a
    # background job, so every child `orca` stays in the process group the
    # HARNESS owns -- and that is exactly what lets the harness ending the hook
    # clean up the whole cluster
    # (firstmate/bin/fm-claude-stop-autoarm.sh:35-37: "Claude owns the process
    # group, so its timeout/session teardown kills arm and watcher together").
    # Turning on `set -m` would push the children into a NEW group and escape
    # that cleanup -- exactly the opposite of what we want. The trap above
    # covers the clean-exit path; the process group covers the cut-off path.
    while IFS= read -r run; do
      [ -n "$run" ] || continue
      i=$((i + 1))
      (
        # FIX 11 -- `</dev/null` IS MANDATORY. This `while read` loop reads run
        # ids from the function's OWN stdin (caller `printf ... |
        # ofm_wait_any_run`), and a background process doesn't get its own fd
        # 0 -- it INHERITS the loop's stdin whole unless explicitly redirected.
        # If `orca` (a real process, not a builtin) reads stdin for any reason
        # at all -- a bug, logging, or some future behavior we don't control --
        # it eats part of the pipe the `while read` loop still needs, and
        # every run id AFTER THAT is SILENTLY SWALLOWED, no error, no log: the
        # second request onward is never waited on. Close that path off
        # entirely by pointing the child's fd 0 at /dev/null, so it never
        # touches the loop's pipe by even one byte.
        orca orchestration check --wait --peek --run "$run" \
          --types "$OFM_WAKE_TYPES" --timeout-ms "$timeout_ms" --json \
          2>/dev/null > "$tmp/$i.out" < /dev/null
      ) &
      printf '%s\n' "$!" >> "$tmp/pids"
    done
    [ "$i" -gt 0 ] || return 0

    # Deadline by REAL wall-clock time, not a logical counter: a counter that
    # accumulates poll ticks drifts away from real time, since each iteration
    # also costs time running the loop body -- and it drifts further as the
    # file grows.
    poll_s=$(awk -v m="${OFM_WAKE_POLL_MS}" 'BEGIN{printf "%.3f", m/1000}')
    deadline=$(( $(date +%s) + (timeout_ms + 999) / 1000 ))
    while :; do
      for f in "$tmp"/*.out; do
        [ -s "$f" ] || continue
        # Cheap grep before jq: `--types` already guarantees every returned
        # message has a `type`, and Orca's keepalive goes to stderr and gets
        # dropped, so most loop iterations fork no jq at all.
        grep -q '"type"' "$f" 2>/dev/null || continue
        line=$(jq -rc 'select(._keepalive|not) | select(.type? != null)' "$f" 2>/dev/null | head -1)
        [ -n "$line" ] || continue
        ofm_summarize "$line"
        return 0
      done
      [ "$(date +%s)" -lt "$deadline" ] || return 0
      sleep "$poll_s"
    done
  )
}

_ofm_wake_kill_all() {  # <tmpdir>
  local p
  [ -f "$1/pids" ] || return 0
  while IFS= read -r p; do
    case "$p" in ''|*[!0-9]*) continue ;; esac
    kill "$p" 2>/dev/null || true
  done < "$1/pids"
  wait 2>/dev/null || true
}
