# shellcheck shell=bash
# Decides what Orca's worker accounting means for one open Request. Pure:
# never calls orca, never releases anything, never edits a request file. The
# activation step in commands/vizier.md captures the output and REPORTS it.
#
# REQUIRES lib/vizier-mailbox-lib.sh to be sourced first -- it owns the
# envelope every `orca orchestration ... --json` reply is wrapped in, and
# `vizier_envelope_ok`/`vizier_mailbox_error_code` are the readers used here.
# Nothing in this file opens an envelope by hand; that split is the same one
# that produced vizier-supervise-lib.sh, and for the same reason.
#
# WHY THIS FILE EXISTS -- MEASURED ON THE CAPTAIN'S MACHINE, 2026-09-02.
# `~/.vizier/requests/mit-license-demo-vizier.md` was `status: open`,
# `run_id: run_52f834f62a96`, and named exactly one dispatch:
#
#   task task_f5a588ccf365 -> dispatch ctx_70061775b9ca (direct-PR)
#
# `worker-list --run run_52f834f62a96 --json` answered (captured verbatim in
# tests/fixtures/worker-list-failed-retained.json):
#
#   workerState: failed, dispatchStatus: failed, terminalState: retained,
#   retainedReason: user_takeover,
#   worktreeId: 5d217a28-…::/Users/toantv/orca/workspaces/demo-vizier/mit-license
#
# That Run had NO message at all in `orca orchestration inbox`, and the
# session that held the first-mate lock (pid 22985) was dead. So: a failed
# worker, a retained terminal, a worktree still held -- and not one thing in
# vizier would ever have mentioned it. Activation counted files with
# `status: open` and stopped there; the wake hook only ever fires on a
# message, and there was none. A dispatch that dies quietly costs nothing to
# notice and everything to miss, which is the whole argument for reconciling
# from durable state at every activation instead of from what a session
# happens to remember.
#
# READS AND REPORTS, NOTHING ELSE. Every class below is a sentence for the
# captain, never an action: releasing a terminal, removing a worktree,
# acking, or closing a request are all decisions that require the captain to
# say so (identity hard rule 2), and a `retained` terminal is retained
# because somebody -- possibly the captain, `retainedReason: user_takeover`
# says exactly that -- wanted it kept. An automatic cleanup here would throw
# away the debugging state the retention exists to preserve.
#
# EVERY UNCERTAIN CASE IS REPORTED, NEVER SWALLOWED. `unreadable` is not a
# fallback for tidiness; it is what a row or an envelope this file does not
# understand MUST come out as, because the alternative -- letting an
# unrecognised shape default to "healthy" -- is precisely how the original
# hole stayed invisible. A false alarm costs the captain one line of report;
# a missed failed dispatch costs a held worktree nobody is looking for.

# --- the class vocabulary -------------------------------------------------
#
# Two independent questions are asked of every dispatch, and the answers are
# reported separately because conflating them loses one of them:
#
#   health  -- what Orca's own accounting says about the dispatch:
#              running | settled | failed | retained | unreadable
#   class   -- the one word the report leads with. It is the health verdict,
#              EXCEPT where the join between the request file and Orca is
#              itself the anomaly, in which case it names that:
#              missing | unrecorded
#
# So a failed dispatch the request file never recorded prints
# `class=unrecorded health=failed`: the captain has to hear both "the ledger
# does not know this" and "it failed and is holding a worktree", and a
# single word cannot say both. Everything else prints class == health.
#
#   running     the dispatch exists and is healthy: not failed, terminal live
#   settled     finished and holding nothing -- terminal `released`. ADDED to
#               the vocabulary the task named, because neither `running` nor
#               `retained` is true of it: a released dispatch is not alive,
#               and it holds no resource. Without it the normal end state of
#               every task -- released by `supervise`, request not yet closed
#               by the captain -- would have to be reported as an anomaly,
#               and a report that cries wolf on the healthy case is a report
#               nobody reads. This is the one class besides `running` that a
#               clean fleet is allowed to be quiet about.
#   failed      workerState or dispatchStatus is `failed`. Checked FIRST, so
#               the measured case above comes out `failed` and not
#               `retained` -- the failure is the headline, and the retained
#               terminal and held worktree ride along on the same line
#               because the captain needs all three to decide anything.
#   retained    not failed, but a resource is still held
#   missing      the request file names a dispatch `worker-list` does not
#               return at all
#   unrecorded   `worker-list` returns a dispatch the request file never
#                recorded -- a dispatch that happened and whose note was
#                never written, e.g. a session that died between
#                `worker-start` and `vizier_request_note`
#   unreadable   the envelope, or one row in it, could not be read into a
#                decision
#
# RESIDUAL, AND IT IS A REAL ONE: the `workerState` enumeration is NOT known.
# Only two values have ever been observed on this machine -- `failed` and
# `succeeded` -- so `running` cannot be defined as "workerState is one of the
# live values"; there is no measured list of those. It is defined as the
# leftover: terminal `active`, and workerState neither `failed` nor
# `succeeded`. An unmeasured settled-ish state (a `cancelled`, say) sitting on
# a live terminal would therefore read `running`. The mitigation is that the
# line carries `worker=<the raw value>` verbatim, so the report names the word
# Orca actually used and the captain sees it even when this file has no rule
# for it. Inventing the enumeration instead is the exact mistake that shipped
# supervision inert -- see the header of lib/vizier-mailbox-lib.sh.
#
# `terminalState` IS enumerated, by the CLI itself: `worker-list
# --terminal-state` rejects anything outside
# `active|reclaimable|retained|release_pending|release_unknown|released`
# (measured, the error message lists them). Of those, `retained`,
# `release_pending` and `release_unknown` are read as "held" -- and so is
# `reclaimable`, which is UNMEASURED and read as held on purpose: a terminal
# eligible to be reclaimed is a resource that has not been released, and
# guessing that direction costs a line of report while guessing the other way
# costs a resource nobody is looking for.

_vizier_reconcile_rows() {  # <raw> -- one TSV row per worker, fixed field order
  # FIELD ORDER IS THE CONTRACT between this and the loops below:
  # dispatchId, taskId, workerState, dispatchStatus, terminalState,
  # retainedReason, terminal handle, worktree path, runId.
  #
  # camelCase, and `resource` is a nested OBJECT (not a JSON string the way a
  # mailbox message's `payload` is). Both facts are captured, not assumed --
  # see tests/fixtures/worker-list-*.json. Note the real CLI is internally
  # inconsistent here: `worker-show` is snake_case for the same concepts.
  #
  # `@tsv` escapes an embedded tab or newline inside a value rather than
  # emitting it, so a `while IFS=$'\t' read` over this output cannot lose
  # column alignment even if a future field carries one.
  #
  # `w` (whitespace collapsed to `_`) is used for every state-word field
  # because those become `key=value` pairs on a single reported line, and a
  # space inside one would split the pair. The worktree path uses `f`, keeps
  # its spaces, and is emitted LAST on the line for exactly that reason.
  #
  # An empty string is normalised to `-` alongside null: a field present but
  # blank is not a value, and letting `terminal=` print empty would make the
  # report's own grammar ambiguous.
  #
  # `-` IS A SENTINEL AND COULD IN PRINCIPLE COLLIDE with a real value of
  # exactly that text. It cannot in practice: every field it stands in for is
  # an Orca identifier (`ctx_…`, `task_…`, `term_…`), an enumerated state
  # word, or an absolute path, and none of those is a lone dash. Said out loud
  # rather than left as a silent assumption, because the one place it would
  # matter is the dispatch-id test in pass 2, which reads `-` as "this row
  # cannot be joined".
  #
  # EVERY FIELD ACCESS IS MADE SAFE AGAINST A NON-OBJECT, and that is not
  # defensive padding. `.result.workers` being an array is all
  # vizier_envelope_ok establishes; a row that is not an object, or a
  # `resource` that is not one, would abort the whole jq program, and this
  # function's failure mode is EMPTY OUTPUT -- which the caller would read as
  # "no dispatches". Rather than let one drifted row erase every good one,
  # the non-object collapses to `{}`, its fields come out as `-`, and it is
  # reported as `unreadable`. The row-count check in vizier_reconcile_run is
  # the second layer, for the case jq fails outright anyway.
  printf '%s' "$1" | jq -r '
    def f: if . == null then "-"
           elif (tostring | length) == 0 then "-"
           else tostring end;
    def w: f | gsub("[[:space:]]+"; "_");
    .result.workers[]?
    | (if type == "object" then . else {} end) as $k
    | (($k.resource | objects) // {}) as $r
    | [ ($k.dispatchId | w),
        ($k.taskId | w),
        ($k.workerState | w),
        ($k.dispatchStatus | w),
        ($k.terminalState | w),
        ($r.retainedReason | w),
        (($k.agentTerminalHandle // $r.terminalHandle) | w),
        # `worktreeId` is `<repo uuid>::<absolute path>` -- measured. The uuid
        # holds no colon, so stripping through the FIRST `::` yields the path
        # even if the path itself contained one. A value with no `::` at all
        # is passed through untouched rather than blanked: printing whatever
        # Orca gave is honest, printing nothing hides a shape change.
        ($r.worktreeId | if type == "string" then sub("^[^:]*::"; "") else . end | f),
        ($k.runId | w)
      ] | @tsv
  ' 2>/dev/null
}

_vizier_reconcile_notes() {  # dispatch notes on stdin -- deduped, ordered
  # LAST NOTE FOR A DISPATCH WINS, ORDERED BY FIRST APPEARANCE. Identical to
  # the rule vizier_supervise_plan applies to the same notes, and for the
  # same reason: a request file can legitimately carry more than one note for
  # one dispatch (a corrected note appended after a mistaken one), and "the
  # most recent note about this dispatch is the one that's true" is the only
  # reading that matches how the file is written. Deterministic order matters
  # here in a way it does not there -- this output IS the report's order.
  #
  # A row with an empty dispatch column is dropped: the anchored extraction
  # in vizier_request_dispatch_notes cannot produce one, so anything that
  # gets here is a caller passing something else, and a blank dispatch id
  # would otherwise be reported as a `missing` dispatch that never existed.
  awk -F'\t' '
    $2 == "" { next }
    { if (!($2 in seen)) { seen[$2] = 1; order[++n] = $2 }
      last[$2] = $0 }
    END { for (i = 1; i <= n; i++) print last[order[i]] }
  '
}

vizier_reconcile_health() {  # <workerState> <dispatchStatus> <terminalState>
  # The health verdict from Orca's fields alone. See the vocabulary block
  # above for why each branch reads the way it does; the ORDER is the part
  # that carries a decision:
  #
  #   failed is tested BEFORE any terminal state, so the measured case --
  #   failed worker, retained terminal -- reports as `failed`. A retained
  #   terminal on a failed dispatch is a consequence of the failure, not a
  #   separate finding, and leading with `retained` would bury the thing
  #   that actually went wrong.
  #
  #   released is tested BEFORE the held set so a normal, finished,
  #   released dispatch cannot be swept into `retained` by a future
  #   addition to that list.
  local ws="$1" ds="$2" ts="$3"
  if [ "$ws" = "failed" ] || [ "$ds" = "failed" ]; then
    printf 'failed'
    return 0
  fi
  case "$ts" in
    released)
      printf 'settled' ;;
    retained|release_pending|release_unknown|reclaimable)
      printf 'retained' ;;
    active)
      # A SUCCEEDED WORKER ON A LIVE TERMINAL IS A HELD RESOURCE, not a
      # running one. This is the sibling of the measured bug: it is exactly
      # what a session that died between processing a `worker_done` and
      # calling `worker-release` leaves behind, and reporting it as
      # `running` would hide the one window this whole file exists to cover.
      if [ "$ws" = "succeeded" ]; then printf 'retained'; else printf 'running'; fi ;;
    *)
      # An absent or unrecognised terminalState is not health information.
      # It fails closed to `unreadable` rather than to `running`: this file
      # would rather say "I do not understand this row" than say "fine".
      printf 'unreadable' ;;
  esac
  return 0
}

_vizier_reconcile_line() {  # <class> <dispatch> <task> <mode> <health> <worker> <status> <terminal> <reason> <handle> <worktree>
  # ONE LINE PER DISPATCH, FIXED FIELD ORDER, EVERY FIELD ALWAYS PRESENT --
  # `-` where there is nothing to say. A report that omits absent fields
  # cannot be read by position or by a fixed `sed`, and the caller is a
  # language model reading prose: a stable shape it can quote verbatim beats
  # a compact one it has to reformat.
  #
  # `worktree=` IS LAST, always. It is the only field whose value can contain
  # a space, so it has to be the tail of the line for the rest to stay
  # parseable as `key=value` pairs.
  printf 'RECONCILE %s %s task=%s mode=%s health=%s worker=%s status=%s terminal=%s reason=%s handle=%s worktree=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}"
}

vizier_reconcile_run() {  # <run_id> <dispatch_notes> <worker_list_raw> -- the report
  # <dispatch_notes> is the output of vizier_request_dispatch_notes:
  # `<task_id><TAB><dispatch_id><TAB><mode>` lines, extracted from the
  # request file ANCHORED TO THE START OF THE LINE. That anchoring lives in
  # lib/vizier-request-lib.sh, which owns the request file's shape, and is
  # shared with supervise's mode map so the two cannot drift -- see the
  # comment on vizier_request_dispatch_notes for the accident it prevents.
  #
  # <worker_list_raw> is the raw stdout of
  # `orca orchestration worker-list --run <id> --json`. THIS FUNCTION DOES
  # NOT RUN THAT COMMAND. That is what makes it testable against captured
  # output, and it is the established convention here: the library decides,
  # the skill executes.
  #
  # <run_id> is optional-by-empty and exists as a fail-LOUD guard. A caller
  # that passes the machine-wide `worker-list --json` instead of the
  # per-run one would otherwise have every OTHER Run's dispatch reported as
  # `unrecorded` against this request -- a pile of confident, wrong findings.
  # Rows naming a different Run are excluded from the join and COUNTED as
  # `other_run=<n>` in the summary, because silently dropping them would
  # make the mistake invisible, which is the failure mode this whole file is
  # a response to.
  local run_id="$1" notes="$2" raw="$3"
  local rows dedup code want got
  local task dispatch mode row shown
  local d t ws ds ts rr handle wt rid
  local health class
  local idx=0
  local out=""
  local n_running=0 n_settled=0 n_failed=0 n_retained=0
  local n_missing=0 n_unrecorded=0 n_unreadable=0 n_other=0 n_held=0 total=0

  # AN UNREADABLE ENVELOPE IS NOT AN EMPTY FLEET. `ok:false` (a real one:
  # `invalid_argument`, captured), orca printing nothing at all, or any
  # future shape drift all land here -- and NO SUMMARY line is printed, which
  # is the caller's signal that nothing was reconciled for this Run. Treating
  # an unreadable answer as "no dispatches, all clear" is the exact silence
  # that let the measured case sit unnoticed.
  if ! vizier_envelope_ok "$raw" workers; then
    code=$(vizier_mailbox_error_code "$raw")
    printf 'UNREADABLE envelope %s\n' "${code:-unreadable}"
    return 0
  fi
  rows=$(_vizier_reconcile_rows "$raw")
  # ONE ROW OUT FOR EVERY ROW IN, OR THE WHOLE THING IS UNREADABLE. The
  # extraction above answers a failure with EMPTY OUTPUT, which is
  # indistinguishable from an empty fleet -- the one confusion this library
  # exists to end. So the count is checked against the envelope's own array
  # length: if jq dropped anything, say so and reconcile nothing, rather than
  # report a partial fleet as if it were the whole one.
  #
  # It is a SECOND LAYER, and after the hardening above no known input reaches
  # it -- which is why tests/reconcile-lib.test.sh reaches it by stubbing
  # _vizier_reconcile_rows rather than by an input. It is here for the case a
  # future jq, or a jq that is not there at all, makes the extraction fail
  # wholesale.
  want=$(printf '%s' "$raw" | jq -r '.result.workers | length' 2>/dev/null)
  got=$(printf '%s\n' "$rows" | sed '/^$/d' | wc -l | tr -d ' ')
  if [ "${want:-x}" != "$got" ]; then
    printf 'UNREADABLE envelope rows-%s-of-%s\n' "$got" "${want:-unreadable}"
    return 0
  fi
  # Deduped ONCE, not per row: pass 2 asks "is this dispatch in the notes?"
  # for every row, and re-running the dedupe inside that loop would make the
  # cost quadratic in a function that runs on every activation.
  dedup=$(printf '%s\n' "$notes" | _vizier_reconcile_notes)

  # --- pass 1: every dispatch the request file recorded -------------------
  # In the request file's own order, so the report reads in the order the
  # captain's tasks were dispatched.
  #
  # The join is on the dispatch id ALONE, with no run filter: a dispatch id
  # is globally unique, so a recorded dispatch found under a different Run is
  # a real fact about that dispatch and gets reported with its real state,
  # not hidden behind `missing`. The run filter belongs to pass 2, where its
  # job is to keep OTHER Runs' dispatches from being reported as this
  # request's `unrecorded` ones.
  while IFS=$'\t' read -r task dispatch mode; do
    [ -n "${dispatch:-}" ] || continue
    total=$((total + 1))
    row=$(printf '%s\n' "$rows" | awk -F'\t' -v d="$dispatch" '$1 == d { print; exit }')
    if [ -z "$row" ]; then
      # THE FILE NAMES A DISPATCH ORCA DOES NOT ACCOUNT FOR. Reported, and
      # deliberately not explained away. RESIDUAL, stated because it changes
      # what the captain should do about it: it is NOT known whether a
      # released dispatch stays in `worker-list`. The CLI accepts
      # `--terminal-state released` as a filter, which is strong evidence
      # released rows are kept (a filter that could never match anything
      # would be odd), but no dispatch on this machine has ever reached
      # `released` -- a real `worker-release` on a healthy dispatch returned
      # `retained`, and one on a dead terminal returned `release_unknown`
      # (docs/verification/2026-09-02-smoke-real-loop.md). So `missing` means
      # "worker-list does not account for it", and `worker-show --dispatch
      # <id>` is the call that tells the captain which of the two it is.
      # This file must not pretend to know.
      n_missing=$((n_missing + 1))
      out="${out}$(_vizier_reconcile_line missing "$dispatch" "$task" "$mode" - - - - - - -)
"
      continue
    fi
    IFS=$'\t' read -r d t ws ds ts rr handle wt rid <<EOF
$row
EOF
    health=$(vizier_reconcile_health "$ws" "$ds" "$ts")
    class="$health"
    case "$health" in
      running)    n_running=$((n_running + 1)) ;;
      settled)    n_settled=$((n_settled + 1)) ;;
      failed)     n_failed=$((n_failed + 1)) ;;
      retained)   n_retained=$((n_retained + 1)) ;;
      *)          n_unreadable=$((n_unreadable + 1)) ;;
    esac
    case "$ts" in -|released) : ;; *) n_held=$((n_held + 1)) ;; esac
    # THE TASK COLUMN CARRIES BOTH TASK IDS WHEN THEY DISAGREE, as
    # `<note>!=<orca>`. Normally they are the same id and the field prints it
    # once. When they are not, the request file's own record of what this
    # dispatch was for is wrong -- which is the same class of ledger drift as
    # `missing` and `unrecorded`, and just as invisible if the report simply
    # trusts one side. One token, no whitespace, so the line stays parseable.
    shown="$task"
    [ "$t" = "$task" ] || [ "$t" = "-" ] || shown="$task!=$t"
    out="${out}$(_vizier_reconcile_line "$class" "$d" "$shown" "$mode" \
      "$health" "$ws" "$ds" "$ts" "$rr" "$handle" "$wt")
"
  done < <(printf '%s\n' "$dedup")

  # --- pass 2: every dispatch Orca knows and the request file does not ----
  while IFS=$'\t' read -r d t ws ds ts rr handle wt rid; do
    [ -n "${d:-}" ] || continue
    idx=$((idx + 1))
    # A ROW WITH NO DISPATCH ID CANNOT BE JOINED IN EITHER DIRECTION, and it
    # is not "one fewer thing to worry about" -- it is a row nothing here
    # understands. Reported as `unreadable`, keyed by `row-<n>` so two such
    # rows are distinguishable and neither can be mistaken for a real
    # `ctx_...` dispatch id. Checked before the run filter: a row with no
    # dispatch id may well have no run id either, and dropping it as
    # "another Run's problem" would be a guess.
    if [ "$d" = "-" ]; then
      total=$((total + 1))
      n_unreadable=$((n_unreadable + 1))
      out="${out}$(_vizier_reconcile_line unreadable "row-$idx" "$t" - \
        unreadable "$ws" "$ds" "$ts" "$rr" "$handle" "$wt")
"
      continue
    fi
    # Already reported by pass 1, with the mode the note gave it.
    printf '%s\n' "$dedup" \
      | awk -F'\t' -v d="$d" '$2 == d { found = 1 } END { exit !found }' && continue
    if [ -n "$run_id" ] && [ "$rid" != "$run_id" ]; then
      n_other=$((n_other + 1))
      continue
    fi
    total=$((total + 1))
    n_unrecorded=$((n_unrecorded + 1))
    health=$(vizier_reconcile_health "$ws" "$ds" "$ts")
    case "$ts" in -|released) : ;; *) n_held=$((n_held + 1)) ;; esac
    # class=unrecorded, health=whatever Orca says. Both, on one line: the
    # ledger being wrong and the dispatch having failed are two separate
    # things the captain has to act on, and a report that picked one of them
    # would drop the other. `mode` is `-`, not a guessed default: the note
    # that would have carried the delivery mode is the very thing missing.
    out="${out}$(_vizier_reconcile_line unrecorded "$d" "$t" - \
      "$health" "$ws" "$ds" "$ts" "$rr" "$handle" "$wt")
"
  done < <(printf '%s\n' "$rows")

  printf '%s' "$out"
  # THE SUMMARY IS WHAT LETS A CLEAN FLEET BE QUIET. `running` and `settled`
  # are the only two classes a caller may stay silent about; any other
  # non-zero count, and any `UNREADABLE` line above, is something the captain
  # has to be told in the same breath as the thing it names. `held` counts
  # every dispatch Orca still accounts a terminal for -- the resource
  # question, asked separately from the health question, because a healthy
  # dispatch holds a terminal too and the captain's decision is about the
  # resource either way.
  printf 'SUMMARY total=%s running=%s settled=%s failed=%s retained=%s missing=%s unrecorded=%s unreadable=%s held=%s other_run=%s\n' \
    "$total" "$n_running" "$n_settled" "$n_failed" "$n_retained" \
    "$n_missing" "$n_unrecorded" "$n_unreadable" "$n_held" "$n_other"
  return 0
}
