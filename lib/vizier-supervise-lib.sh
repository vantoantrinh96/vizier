# shellcheck shell=bash
# Decides what a mailbox batch means. Pure: never calls orca, never releases
# anything. The `supervise` skill executes what this plans.
#
# REQUIRES lib/vizier-mailbox-lib.sh to be sourced first -- it owns every fact
# about the shape of an `orca orchestration check --json` response. Nothing in
# this file may reach into that shape directly; that split is the whole point
# of the fix that produced it.
#
# WHY A PLAN AND NOT AN EXECUTOR. The spec's rule is "ack only after every
# message in the batch is processed". Acking early loses messages
# permanently -- replay-until-ack is the only reason a hook that dies
# mid-flight is safe. As prose in a skill that rule is forgettable; here the
# ACK line simply is not printed unless every message was classified, so the
# rule holds even when the model is in a hurry.
#
# EVERY UNCERTAIN CASE FAILS CLOSED. `none` and `hold` cost the captain a
# report and a manual release. Releasing a terminal whose pipeline still owns
# the branch costs the branch.

_vizier_axi_outcome() {  # <body> -- prints each DISTINCT axi_outcome value found, one per line
  # Anchored to a line that STARTS with the exact key (after optional
  # whitespace). Free-text matching is not acceptable: a body reading "the
  # tests have not passed" contains the token `passed`, and releasing on that
  # would defeat the whole rule. The brief mandates this exact syntax -- see
  # vizier_brief_delivery no-mistakes -- so requiring it is not a guess.
  #
  # Every matching line is collected, not just the first. A body can
  # legitimately (rewritten drafts left in) or accidentally (a stale line
  # plus a fresh one) carry more than one; picking the first with `head -n 1`
  # would release on whichever happened to come first, which is an accident
  # of line order, not a decision. The caller (vizier_msg_disposition) holds
  # rather than releases when more than one distinct value shows up.
  #
  # RESIDUAL GAP: this still cannot tell an instruction from a report. A body
  # that quotes the required syntax once as an example and then contradicts
  # it only in prose -- e.g. "report status as\naxi_outcome: passed\nwhen
  # done. Currently still executing tests." -- has exactly one anchored
  # line, so it releases. Nothing textual distinguishes an example from a
  # real report of that one line; closing this requires the brief itself to
  # tell the worker never to write the line except as its one real, final
  # report (see vizier_brief_delivery no-mistakes), which is the actual
  # mitigation for this case, not this matcher.
  #
  # ONE REAL CASE OF THAT GAP IS NOT LEFT TO THE BRIEF: Orca's own rejection
  # notice quotes the rejected message's body verbatim, terminal outcome line
  # and all. That one is caught structurally in vizier_msg_disposition,
  # BEFORE the body is ever read -- see the rejection gate there.
  local body="$1"
  printf '%s\n' "$body" \
    | sed -n 's/^[[:space:]]*axi_outcome:[[:space:]]*\([A-Za-z-][A-Za-z-]*\).*/\1/p' \
    | sort -u
}

vizier_msg_disposition() {  # <mode> <message_json> -- "<release|hold|reply|none> <reason>"
  # Separate jq reads rather than one @tsv row: a body legitimately contains
  # newlines (the axi_outcome line is on its own line), and @tsv would escape
  # them into the middle of a single field.
  local mode="$1" line="$2"
  local type dispatch body rejection
  local values value_count outcome
  type=$(printf '%s' "$line" | jq -r '.type // ""' 2>/dev/null)
  body=$(printf '%s' "$line" | jq -r '.body // ""' 2>/dev/null)
  # THE DISPATCH ID LIVES INSIDE `.payload`, WHICH IS A JSON STRING. There is
  # no top-level `.dispatch_id` and there never was; reading one is what made
  # every real worker_done look stale.
  dispatch=$(vizier_mailbox_payload_field "$line" dispatchId)
  rejection=$(vizier_mailbox_payload_field "$line" _orcaLifecycleRejection)

  [ -n "$type" ] || { printf 'none unparseable'; return 0; }

  # ORCA'S OWN REJECTION NOTICE IS NOT A COMPLETION REPORT -- and it is the
  # single most dangerous message in the mailbox, because it is disguised as
  # one. Send a `worker_done` naming a dispatch Orca does not know and the
  # call does not fail: Orca ACCEPTS it and rewrites it into a notice that
  # still carries `type: worker_done`, still carries the original
  # `dispatchId` in its payload (so the stale-dispatch guard does not bite),
  # and QUOTES THE ORIGINAL BODY VERBATIM under an "Original body:" heading --
  # terminal `axi_outcome:` line included.
  #
  # Measured against the real captured notice (tests/fixtures/check-delivery
  # .json): with the field access fixed and this gate removed, it plans
  # `release axi-outcome=passed` under the strict mode and `release ok` under
  # direct-PR. That is a terminal released on the strength of a message whose
  # entire content is Orca saying the terminal event never happened.
  #
  # Checked BEFORE the type switch, not inside the worker_done branch: what
  # makes a rejection unsafe is that it is a lifecycle notice wearing another
  # message's clothes, and nothing guarantees `worker_done` is the only set
  # of clothes it can wear. `hold`, not `none`: something is genuinely wrong
  # with a dispatch and the captain needs to hear about it, and `none` is
  # acked away in silence.
  if [ -n "$rejection" ]; then
    printf 'hold lifecycle-rejection'
    return 0
  fi

  # `reply` EXISTS SO THE PLAN CAN SAY "A HUMAN OWES AN ANSWER". Before it,
  # a question got `none not-terminal` -- the same disposition as a
  # heartbeat -- and was then acked away with nothing owed to anyone. The
  # vocabulary could not express the difference, so the only thing standing
  # between a captain's decision and silence was the model remembering to
  # re-read the raw JSON after the plan had already told it there was
  # nothing to do. The spec requires escalation and question to be turned
  # into a question with context, and an ask-user finding to be routed
  # through `delivery`; neither is expressible as `none`.
  #
  # `reply` is NEVER a release. It is checked before the dispatch-id and
  # mode logic on purpose: a question is not a terminal event no matter
  # what its body says or which delivery mode the dispatch runs under.
  #
  # Exactly these two types, not a catch-all for "not worker_done": a
  # heartbeat owes nobody anything and must stay `none`.
  case "$type" in
    question|escalation) printf 'reply %s' "$type"; return 0 ;;
  esac

  [ "$type" = "worker_done" ] || { printf 'none not-terminal'; return 0; }
  # A dispatch id of only whitespace is exactly as stale as no dispatch id
  # at all -- `-n` only rejects the empty string, so a JSON producer that
  # sends `"   "` instead of omitting the field would have slipped past a
  # plain `-n` check. Match on the presence of a non-whitespace character.
  case "$dispatch" in
    *[![:space:]]*) : ;;
    *) printf 'none stale-no-dispatch'; return 0 ;;
  esac

  # FAIL CLOSED ON THE MODE STRING ITSELF, not only on the body. The caller
  # can pass a mode that is empty (nothing established yet) or garbage (a
  # typo, a stale value), and a mixed-mode batch can genuinely mix a
  # no-mistakes dispatch in among direct-PR ones. Treating anything other
  # than the exact string `direct-PR` as "needs the strict check" means an
  # unrecognised mode gets the safer of the two behaviors -- a wrongly held
  # terminal costs the captain a report, a wrongly released one can lose a
  # branch a pipeline still owns. `direct-PR` is the only value that ever
  # skips the axi_outcome check, and it must be spelled exactly.
  if [ "$mode" = "direct-PR" ]; then
    printf 'release ok'
    return 0
  fi

  values=$(_vizier_axi_outcome "$body")
  value_count=$(printf '%s\n' "$values" | sed '/^$/d' | wc -l | tr -d ' ')
  if [ "$value_count" -eq 0 ]; then
    printf 'hold no-axi-outcome'
  elif [ "$value_count" -gt 1 ]; then
    # More than one distinct value is ambiguous, not decidable -- see the
    # RESIDUAL GAP note on _vizier_axi_outcome for why first-match-wins
    # was wrong here.
    printf 'hold axi-outcome=ambiguous'
  else
    outcome="$values"
    case "$outcome" in
      passed|checks-passed|failed|cancelled) printf 'release axi-outcome=%s' "$outcome" ;;
      *)                                     printf 'hold axi-outcome=%s' "$outcome" ;;
    esac
  fi
  return 0
}

vizier_supervise_plan() {  # <default_mode> [<mode_map_file>] -- RAW check --json output on stdin
  # STDIN IS THE RAW ENVELOPE, exactly as `orca orchestration check --json`
  # printed it. It is NOT newline-delimited JSON and never was: the real
  # command pretty-prints one envelope, in `--wait` mode as much as out of
  # it, so a 3-message batch fed to the old JSON-lines reader produced 77
  # `UNPARSEABLE` lines, no plan, and no ack -- supervision was inert
  # against the real app while its own tests were green, because the test
  # double had been built from the same invented shape as the parser.
  #
  # WHY THE BATCH STAYS WHOLE, EVEN THOUGH THE MODE IS RESOLVED PER MESSAGE.
  # An earlier version of the calling skill called this once PER MESSAGE, to
  # get a per-dispatch mode -- that broke the ACK invariant below: an
  # unparseable message in one call could no longer suppress the ACK a
  # different call still printed, because "did anything fail to classify"
  # was computed per call instead of over the one true batch. So the mode
  # varies per line, but the loop, the UNPARSEABLE/bad tracking, and the
  # all-or-nothing ACK decision all stay batch-wide, exactly as before.
  #
  # <mode_map_file>, if given, is lines of `<dispatch_id><TAB><mode>` --
  # the caller builds it from the request file's own
  # `task <id> -> dispatch <id> (<mode>)` notes (written by the `brief`
  # skill), which is keyed by dispatch id, unlike the per-task override
  # note that isn't. A dispatch missing from the map, or no map at all,
  # falls back to <default_mode> -- which itself already fails closed to
  # the strict check unless it is the exact string `direct-PR` (see
  # vizier_msg_disposition above).
  #
  # THE LAST MATCHING LINE FOR A GIVEN DISPATCH WINS, NOT THE FIRST. The
  # map file can legitimately (or, per review round 4, accidentally -- a
  # captain who pastes a previous run's notes into a new request's body
  # reproduces this without trying) contain more than one line for the
  # same dispatch id: the request file's extraction pattern is anchored to
  # a genuine `task ... -> dispatch ...` note (see the supervise skill),
  # but nothing stops the file from holding TWO genuine-looking lines for
  # one id -- an old one quoted in prose that happens to satisfy the
  # anchor, or a corrected note appended after a mistaken one. Reading the
  # LAST one matches the intuition "the most recent note about this
  # dispatch is the one that's true," and fails toward the strict path
  # exactly as often as it fails toward the lenient one -- it does not
  # itself make either direction safer, unlike the mode-string default in
  # vizier_msg_disposition, which deliberately fails toward strict. What
  # makes this safe in practice is the skill's anchored extraction pattern
  # keeping stray prose out of the map in the first place; this rule is the
  # second layer, for on the rare case a lookalike line still gets in.
  #
  # ONE `ACK <delivery_id>` LINE FOR THE WHOLE BATCH, and the id is the
  # batch's, not any message's. MEASURED, not assumed: a batch read without
  # `--peek`/`--all` is a *delivery*, named by `result.deliveryId`; reading
  # again before acking replays the same delivery id with `replayed: true`;
  # `--ack <that id>` clears the whole batch and echoes it back in
  # `acknowledged`. Acking a MESSAGE id is refused outright with
  # `stale_delivery` -- so the previous design here, which printed one ACK
  # line per message and defended that as "correct either way", was not
  # correct either way. It was correct in neither: every one of those acks
  # would have been rejected, and the batch would have replayed forever.
  #
  # The all-or-nothing rule is unchanged: the ACK line is not printed if any
  # message in the batch failed to classify.
  local default_mode="$1" map_file="${2:-}"
  local raw plan="" bad=0 seen=0 delivery code
  local line id dispatch mode looked
  raw=$(cat)

  # AN UNREADABLE ENVELOPE IS NOT AN EMPTY MAILBOX. `ok:false` (a real one:
  # `consumer_fenced`, when this coordinator terminal is bound to a different
  # Run), a truncated read, orca printing nothing at all, or any future shape
  # drift all land here -- and all of them are reported, never silently
  # treated as "no traffic". Silence is precisely how the original bug hid.
  if ! vizier_mailbox_ok "$raw"; then
    code=$(vizier_mailbox_error_code "$raw")
    printf 'UNPARSEABLE envelope %s\n' "${code:-unreadable}"
    return 0
  fi
  delivery=$(vizier_mailbox_delivery_id "$raw")

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    seen=$((seen + 1))
    # ASSUMES ORCA NEVER REPEATS A MESSAGE id WITHIN ONE BATCH. This is
    # not re-checked here: a duplicate would print two PLAN lines for the
    # same id, which is silently redundant rather than loud. Orca's mailbox
    # contract guarantees unique ids, so this is a documented reliance on
    # that guarantee, not a gap this function closes.
    id=$(printf '%s' "$line" | jq -r '.id // empty' 2>/dev/null)
    if [ -z "$id" ]; then
      plan="${plan}UNPARSEABLE
"
      bad=1
      continue
    fi
    mode="$default_mode"
    if [ -n "$map_file" ] && [ -r "$map_file" ]; then
      dispatch=$(vizier_mailbox_payload_field "$line" dispatchId)
      if [ -n "$dispatch" ]; then
        # END-block accumulation, not `{print;exit}` on first match: see
        # the LAST MATCHING LINE WINS comment above vizier_supervise_plan.
        looked=$(awk -F'\t' -v d="$dispatch" '$1==d{v=$2} END{print v}' "$map_file")
        [ -n "$looked" ] && mode="$looked"
      fi
    fi
    plan="${plan}PLAN $id $(vizier_msg_disposition "$mode" "$line")
"
  done < <(vizier_mailbox_messages "$raw")

  printf '%s' "$plan"

  # An empty batch is a real, healthy answer -- a wait that timed out, or a
  # mailbox already drained. Nothing to plan and nothing to ack.
  [ "$seen" -gt 0 ] || return 0
  # No ACK at all when anything in the batch failed to classify. Orca replays
  # an unacked delivery, so withholding the ack loses nothing and re-delivers
  # everything; acking a batch we did not fully understand loses all of it for
  # good, because one ack clears the whole delivery.
  [ "$bad" -eq 0 ] || return 0
  if [ -n "$delivery" ]; then
    printf 'ACK %s\n' "$delivery"
  else
    # A BATCH THAT CANNOT BE ACKED SAYS SO. Only a default read creates a
    # delivery; `--peek` and `--all` do not, so a caller that peeks has
    # messages it has fully processed and no handle to acknowledge them
    # with. Orca will replay them forever. Printing nothing here would make
    # that indistinguishable from a batch withheld for a classification
    # failure -- the same silence the rest of this file exists to prevent.
    printf 'UNACKABLE no-delivery-id\n'
  fi
  return 0
}
