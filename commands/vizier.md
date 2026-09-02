---
description: Turns this session into the first mate -- the liaison coordinating crew agents through Orca
---

Activate this session as the first mate.

1. Run exactly this command through Bash, **with no extra arguments**:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/vizier-activate.sh" claude
   ```

   The script reads the session id itself from `CLAUDE_CODE_SESSION_ID` in the environment.
   **Do not guess or fill in a session id yourself** -- you have no way to know it, and a made-up
   value would keep the lock from ever matching the hook's payload, permanently silencing both
   the wake mechanism and the reidentify mechanism while the lock stays held.

   Handle it according to the exact return code:

   - **rc 0**, printing `claimed` / `reclaimed` / `refreshed` -> this session is now the first
     mate, proceed.
   - **rc 1**, printing `refused held_by=<id>` -> **STOP.** Another session is already the first
     mate. Tell the captain which session holds it, then ask whether they want to close that
     session or keep working there. **Never steal the lock yourself, never delete the lock file
     yourself, never rerun the script hoping for a different outcome.** If the captain confirms
     the old session is dead (for example after `/clear` or a resume -- the pid is still alive
     but the session id inside it has changed, so the lock can never match again on its own),
     the correct way out is running `vizier unlock` (prints the current owner then clears
     the lock, no arguments needed) -- NEVER delete the lock file by hand.
   - **rc 2**, printing `no_session_id` or `no_harness_pid` -> **STOP** and report the exact
     reason line to the captain. This is an environment where the session cannot be identified,
     not something to retry.

2. Read `${CLAUDE_PLUGIN_ROOT}/skills/identity/SKILL.md` and follow it for the rest of the session.

3. Run `"${CLAUDE_PLUGIN_ROOT}/bin/vizier" doctor`. If any line fails, report it to the
   captain along with the printed fix command and **stop** -- don't take on a request with a
   broken toolchain.

4. If the cwd is inside a git repo, read `git remote get-url origin` and **suggest** it as the
   project for the first request. It's only a suggestion: it counts only once the captain
   confirms it. cwd is never the authority.

5. **Reconcile every open request against Orca before saying anything.**

   A restart reconciles from **durable state** -- the request files plus Orca -- never from
   what a session remembers. Counting files with `status: open` and stopping there is what let
   this happen, measured on the captain's machine on 2026-09-02: `mit-license-demo-vizier.md`
   was `status: open` with `run_id: run_52f834f62a96`, its one dispatch `ctx_70061775b9ca` had
   `workerState: failed` with a **retained terminal** and a **worktree still held**, the Run had
   no mailbox message at all -- so the wake hook, which only ever fires on a message, could
   never have said a word -- and the session that held the lock was dead. Nothing in vizier
   would ever have mentioned it.

   `worker-list` is one of the commands that works from a plain shell: no `run-use`, no bound
   Run, no sender terminal. That is why this step is possible here at all, unlike `check`, which
   needs a binding.

   ```bash
   # CLAUDE_PLUGIN_ROOT first, and deliberately: step 3 ran `doctor` out of that same copy, and
   # `~/.vizier/dist` can legitimately disagree with it (that disagreement is exactly what
   # `vizier version` exists to report). Reconciling with one version's library while having
   # doctored another is the kind of split this project keeps paying for.
   VIZIER_DIST="${CLAUDE_PLUGIN_ROOT:-${VIZIER_HOME:-$HOME/.vizier}/dist}"
   . "$VIZIER_DIST/lib/vizier-home.sh"
   . "$VIZIER_DIST/lib/vizier-request-lib.sh"
   . "$VIZIER_DIST/lib/vizier-mailbox-lib.sh"
   . "$VIZIER_DIST/lib/vizier-reconcile-lib.sh"

   for slug in $(vizier_request_open_slugs); do
     run_id=$(vizier_request_get "$slug" run_id)
     printf 'REQUEST %s run=%s\n' "$slug" "${run_id:-NONE}"
     [ -n "$run_id" ] || continue
     vizier_reconcile_run "$run_id" \
       "$(vizier_request_dispatch_notes "$slug")" \
       "$(orca orchestration worker-list --run "$run_id" --json)"
   done
   ```

   `mailbox-lib` owns the envelope shape and must be sourced **before** `reconcile-lib`, which
   reads it through `vizier_envelope_ok`. Without it every response is a `command not found`
   swallowed inside the library and nothing is reconciled -- silently, which is the one outcome
   this step exists to prevent.

   An open request whose file carries **no `run_id`** prints `run=NONE` and is skipped: there is
   nothing to reconcile against, and that itself is a broken request file the captain has to hear
   about.

   ### Read the output

   `vizier_reconcile_run` prints one `RECONCILE <class> <dispatch_id> …` line per dispatch and
   one `SUMMARY …` line per request. Every line carries the same fields, `-` where there is
   nothing to say, and `worktree=` last.

   - **`running`** and **`settled`** are the only quiet classes: no line of their own. One
     exception, and it is the reason the class exists at all. `running` is a **leftover**, not a
     measured state -- Orca's `workerState` enumeration is unknown, so anything that is neither
     `failed` nor `succeeded` on a live terminal lands here (see the RESIDUAL in
     `lib/vizier-reconcile-lib.sh`). So carry the raw `worker=` value of every `running` line
     into the one summary sentence below, verbatim. A `worker=cancelled`, or a `worker=-`, on a
     live terminal is not a healthy dispatch, and that sentence is the only place the word ever
     gets spoken.
   - **`failed`** -- the worker failed. Name the dispatch, the terminal in `handle=` with its
     `terminal=`/`reason=` state, and the worktree path in `worktree=`. The captain decides what
     happens to those two resources.
   - **`retained`** -- a terminal, and usually a worktree, is still held. `reason=user_takeover`
     means somebody took the terminal over deliberately, possibly the captain: say so, and do
     not treat it as a fault.
   - **`missing`** -- the request file names a dispatch `worker-list` does not account for.
     `orca orchestration worker-show --dispatch <id> --json` is the next call, and it is the
     captain's to authorise, not yours to run as cleanup.
   - **`unrecorded`** -- a dispatch exists that the ledger never recorded, so `health=` is the
     only thing known about it and no delivery mode is known at all. Report both: the ledger is
     wrong *and* whatever `health=` says.
   - **`unreadable`**, or an `UNREADABLE envelope <code>` line -- the response, or one row of
     it, could not be read. Report it verbatim.
     **A request with no `SUMMARY` line was not reconciled at all**; never report it as clean.
   - `held=<n>` in the summary counts every dispatch Orca still accounts a terminal for, and
     `other_run=<n>` should always be `0` here -- anything else means the wrong command was run.

   ### Then report, once

   **A clean fleet stays quiet.** If every request summarises to `failed=0 retained=0 missing=0
   unrecorded=0 unreadable=0` and there was no `UNREADABLE` line, say **one sentence**: that you
   are now the first mate, where home is, how many requests are open, and how many dispatches are
   running -- naming the raw `worker=` value of each of those running dispatches inside it, e.g.
   "3 dispatches running (worker=running, running, cancelled)". Still one sentence: not a report,
   not a table, not a per-request rundown.

   Otherwise, that same sentence plus one line per thing that is not `running`/`settled`, each
   naming the concrete thing the captain has to decide -- the dispatch id, the terminal handle,
   and the worktree path, in full.

   ### Reconciliation reads and reports. Nothing else.

   It must **not** release a terminal, remove or prune a worktree,
   ack a mailbox delivery, close a request, or edit a request file
   -- not even when the answer looks obvious.

   A retained terminal is retained because somebody wanted it kept, and its worktree is the
   debugging state that retention exists to preserve; throwing either away is the captain's call
   to make explicitly (identity hard rule 2). Releasing a terminal is `supervise`'s job, and only
   after a real `worker_done` has been processed (hard rule 4).
