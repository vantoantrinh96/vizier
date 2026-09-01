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

_vizier_axi_outcome() {  # <body> -- prints the value of the axi_outcome line
  # Anchored to a line that STARTS with the exact key (after optional
  # whitespace). Free-text matching is not acceptable: a body reading "the
  # tests have not passed" contains the token `passed`, and releasing on that
  # would defeat the whole rule. The brief mandates this exact syntax -- see
  # vizier_brief_delivery no-mistakes -- so requiring it is not a guess.
  local body="$1"
  printf '%s\n' "$body" \
    | sed -n 's/^[[:space:]]*axi_outcome:[[:space:]]*\([A-Za-z-][A-Za-z-]*\).*/\1/p' \
    | head -n 1
}

vizier_msg_disposition() {  # <mode> <json_line> -- "<release|hold|none> <reason>"
  # Three separate jq reads rather than one @tsv row: a body legitimately
  # contains newlines (the axi_outcome line is on its own line), and @tsv
  # would escape them into the middle of a single field.
  local mode="$1" line="$2"
  local type dispatch body out
  type=$(printf '%s' "$line" | jq -r '.type // ""' 2>/dev/null)
  dispatch=$(printf '%s' "$line" | jq -r '.dispatch_id // ""' 2>/dev/null)
  body=$(printf '%s' "$line" | jq -r '.body // ""' 2>/dev/null)

  [ -n "$type" ] || { printf 'none unparseable'; return 0; }
  [ "$type" = "worker_done" ] || { printf 'none not-terminal'; return 0; }
  [ -n "$dispatch" ] || { printf 'none stale-no-dispatch'; return 0; }

  if [ "$mode" = "no-mistakes" ]; then
    out=$(_vizier_axi_outcome "$body")
    case "$out" in
      passed|checks-passed|failed|cancelled) printf 'release axi-outcome=%s' "$out" ;;
      "")                                    printf 'hold no-axi-outcome' ;;
      *)                                     printf 'hold axi-outcome=%s' "$out" ;;
    esac
    return 0
  fi

  printf 'release ok'
}

vizier_supervise_plan() {  # <mode> -- batch JSON lines on stdin
  local mode="$1"
  local plan="" last="" bad=0
  local line id
  while IFS= read -r line; do
    [ -n "$line" ] || continue
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
