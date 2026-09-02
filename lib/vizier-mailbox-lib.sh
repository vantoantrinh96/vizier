# shellcheck shell=bash
# The ONE owner of "what `orca orchestration check --json` actually returns".
#
# WHY THIS FILE EXISTS. Two callers -- the wake hook (vizier-wake-lib.sh) and
# the supervision plan (vizier-supervise-lib.sh) -- each open-coded their own
# reader for this one response, and both were written from an imagined shape
# instead of a captured one. Both were individually tested; both were green;
# and against the real app the wake never fired at all while every real message
# classified as unparseable. A shape with two private readers and no captured
# fixture is a shape nobody owns. It has one reader now, and that reader is
# pinned to real responses in tests/fixtures/.
#
# THE CAPTURED CONTRACT -- Orca 1.4.193, measured 2026-09-02, every claim
# reproduced in docs/verification/2026-09-02-mailbox-delivery-contract.md:
#
#   stdout is ALWAYS ONE PRETTY-PRINTED ENVELOPE. Never newline-delimited
#   JSON, and this holds in `--wait` mode exactly as it does out of it:
#     {"id":…,"ok":true,"result":{…},"_meta":{…}}
#   Reading it as JSON lines is the original bug: a 3-message batch parses as
#   77 unparseable lines, because pretty-printing puts one FIELD on a line.
#
#   result.messages[]   the messages. snake_case fields, and `payload` is a
#                       JSON *string*, not an object -- it has to be parsed.
#   result.deliveryId   the ACK HANDLE, and it names the WHOLE BATCH. Present
#                       only on a default read; `--peek` and `--all` omit it.
#   result.count, .replayed, .timedOut, .cancelled, .connectionLost
#
#   A failure is {"ok":false,"error":{"code":…}} with rc 1 -- e.g.
#   `consumer_fenced` when the coordinator terminal is bound to another Run.
#   An error envelope has NO .result.messages, which is what
#   vizier_mailbox_ok tests for: "no messages" and "could not read this at
#   all" must never look alike to a caller that is deciding whether to ack.
#
#   `--wait` keepalives go to STDERR (documented in `check --help`), so
#   `_keepalive` never reaches stdout. The filter below is kept anyway, for
#   the caller that merges the two streams.
#
# Requires jq. Sourced, never executed.

vizier_envelope_ok() {  # <raw> <result_array_key> -- rc 0 only for a READABLE SUCCESS envelope
  # THE ENVELOPE IS SHARED ACROSS EVERY ORCHESTRATION COMMAND; only the
  # `result` payload inside it is per-command. Measured 2026-09-02 against
  # `check` and `worker-list` alike: both answer `{id, ok, result, _meta}`,
  # and both answer a failure as `{"ok":false,"error":{"code":…}}` with rc 1
  # (`consumer_fenced` for one, `invalid_argument` for the other). So the
  # envelope test is written once, parameterised by the one array key the
  # caller expects in `result`, and lib/vizier-reconcile-lib.sh reuses it for
  # `workers` rather than opening a second reader of its own. A shape with two
  # private readers is a shape nobody owns -- see the header of this file for
  # what that cost the last time.
  #
  # Both halves matter. `.ok == true` alone would accept a success envelope
  # whose result is some future shape with no such array; the array test
  # alone would accept a malformed one that happens to carry the key. An
  # envelope that fails this is never "an empty mailbox" or "an empty fleet"
  # -- it is a response nothing here understands, and the caller must fail
  # closed on it.
  #
  # rc is normalised to 0/1 rather than passed through from jq, which answers
  # "false" with 1 but "could not parse the input" with 4 and "no output" with
  # 5. A caller that reads `rc=$?` and compares it to 1 would be told an
  # unreadable response is somehow a different KIND of not-ok. It is not:
  # every one of these means the same thing here, and it must mean it in one
  # value.
  if printf '%s' "$1" | jq -e --arg k "$2" '(.ok == true) and (.result[$k] | type == "array")' \
       >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

vizier_mailbox_ok() {  # <raw> -- rc 0 only for a READABLE SUCCESS envelope
  # Kept as its own name because every caller of it is asking about a
  # MAILBOX, and `vizier_envelope_ok "$raw" messages` at each of those call
  # sites would let one of them quietly ask for the wrong key.
  vizier_envelope_ok "$1" messages
}

vizier_mailbox_messages() {  # <raw> -- one COMPACT message per line
  # `-c` is load-bearing, not a style choice: every caller reads these back
  # with `while IFS= read -r line`, and the input they came from is
  # pretty-printed. Dropping `-c` reintroduces the original bug one layer
  # further in.
  printf '%s' "$1" | jq -c '.result.messages[]? | select(._keepalive | not)' 2>/dev/null
}

vizier_mailbox_delivery_id() {  # <raw> -- the batch's ack handle, or empty
  # EMPTY IS A REAL, EXPECTED ANSWER, not an error: `--peek` and `--all` never
  # create a delivery, so a peeked batch has no ack handle and CANNOT be
  # acked. Measured: `--ack <a message id>` is refused with `stale_delivery`;
  # only this value is accepted. A caller that peeks and then tries to ack is
  # not doing something inefficient, it is doing something impossible -- which
  # is why vizier_supervise_plan says so out loud instead of silently acking
  # nothing.
  printf '%s' "$1" | jq -r '.result.deliveryId // empty' 2>/dev/null
}

vizier_mailbox_error_code() {  # <raw> -- the error code of a failed envelope
  printf '%s' "$1" | jq -r '.error.code // empty' 2>/dev/null
}

vizier_mailbox_payload_field() {  # <message_json> <key> -- payload's <key>, or empty
  # `.payload` IS A JSON STRING. This is the field the original parser missed
  # entirely: it read `.dispatch_id` at the top level, which has never
  # existed, so every real worker_done looked stale.
  #
  # An object value is re-serialised rather than dropped, so a caller can test
  # PRESENCE of a nested object (`_orcaLifecycleRejection`) with the same
  # "is the output non-empty" test it uses for a plain string.
  #
  # Every failure mode collapses to empty output: payload null (a status
  # message has none), payload a string that is not JSON, payload parsed to a
  # non-object, key absent, key explicitly null. None of them may look like a
  # value, and none may abort the caller under `set -u`.
  printf '%s' "$1" | jq -r --arg k "$2" '
      (.payload // empty)
    | (if type == "string" then (fromjson? // empty) else . end)
    | objects
    | .[$k]
    | if . == null then empty
      elif type == "string" then .
      else tojson end
  ' 2>/dev/null
}
