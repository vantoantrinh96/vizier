# shellcheck shell=bash
# Decides what a mailbox batch means. Pure: never calls orca, never releases
# anything. The `supervise` skill executes what this plans.
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
  local body="$1"
  printf '%s\n' "$body" \
    | sed -n 's/^[[:space:]]*axi_outcome:[[:space:]]*\([A-Za-z-][A-Za-z-]*\).*/\1/p' \
    | sort -u
}

vizier_msg_disposition() {  # <mode> <json_line> -- "<release|hold|none> <reason>"
  # Three separate jq reads rather than one @tsv row: a body legitimately
  # contains newlines (the axi_outcome line is on its own line), and @tsv
  # would escape them into the middle of a single field.
  local mode="$1" line="$2"
  local type dispatch body
  local values value_count outcome
  type=$(printf '%s' "$line" | jq -r '.type // ""' 2>/dev/null)
  dispatch=$(printf '%s' "$line" | jq -r '.dispatch_id // ""' 2>/dev/null)
  body=$(printf '%s' "$line" | jq -r '.body // ""' 2>/dev/null)

  [ -n "$type" ] || { printf 'none unparseable'; return 0; }
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

vizier_supervise_plan() {  # <mode> -- batch JSON lines on stdin
  local mode="$1"
  local plan="" last="" bad=0
  local line id
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # ASSUMES ORCA NEVER REPEATS A delivery_id WITHIN ONE BATCH. This is
    # not re-checked here: a duplicate would print two PLAN lines for the
    # same id and then ACK whichever came last, which is silently wrong
    # rather than loud. Orca's mailbox contract guarantees unique ids, so
    # this is a documented reliance on that guarantee, not a gap this
    # function closes.
    id=$(printf '%s' "$line" | jq -r '.delivery_id // empty' 2>/dev/null)
    if [ -z "$id" ]; then
      plan="${plan}UNPARSEABLE
"
      bad=1
      continue
    fi
    plan="${plan}PLAN $id $(vizier_msg_disposition "$mode" "$line")
"
    last=$id
  done
  printf '%s' "$plan"
  # No ACK when anything in the batch failed to classify. Orca replays an
  # unacked batch, so withholding the ack loses nothing and re-delivers
  # everything; acking a batch we did not fully understand loses a message
  # for good.
  if [ "$bad" -eq 0 ] && [ -n "$last" ]; then
    printf 'ACK %s\n' "$last"
  fi
  return 0
}
