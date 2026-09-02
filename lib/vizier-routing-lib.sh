# shellcheck shell=bash
# Host discovery and eligibility. Requires lib/vizier-home.sh to be sourced.
#
# THIS LIBRARY DECIDES NOTHING. It reports which hosts are eligible; the
# captain picks. The spec's hard rule is that an unavailable route never
# silently becomes a local one, and the surest way to keep that rule is to
# leave no code path that can choose a host at all.
#
# THREE DIFFERENT FLAGS NAME THE SAME HOST -- verified against Orca 1.4.193:
#   health   : orca status [--environment <NAME>]     (local: no flag)
#   setups   : orca project setups --host <ID>
#   dispatch : worker-start --on <NAME>               (not this library)
# `orca host list` also returns a `selector` field ("--host local",
# "--environment Mac mini"). It is a ready-made flag PAIR and is not
# interchangeable with any of the three above. Do not pass it to --on.

vizier_hosts() {
  orca host list --json 2>/dev/null \
    | jq -r '.result.hosts[]? | [.id, .name, .kind] | @tsv'
}

vizier_host_health() {  # <name> <kind> -- prints ready|unreachable|state=<x>|error
  local name=$1 kind=$2 out reachable state
  if [ "$kind" = "local" ]; then
    out=$(orca status --json 2>/dev/null) || { printf 'error'; return 1; }
  else
    out=$(orca status --environment "$name" --json 2>/dev/null) || { printf 'error'; return 1; }
  fi
  [ -n "$out" ] || { printf 'error'; return 1; }
  # One jq pass, so a malformed document fails once rather than per-field.
  read -r reachable state <<EOF
$(printf '%s' "$out" | jq -r '[.result.runtime.reachable, .result.runtime.state] | @tsv' 2>/dev/null)
EOF
  case "$reachable" in
    true) ;;
    *) printf 'unreachable'; return 1 ;;
  esac
  if [ "$state" != "ready" ]; then printf 'state=%s' "${state:-unknown}"; return 1; fi
  printf 'ready'
}

vizier_host_setup_state() {  # <project_id> <host_id> -- prints setupState or "none"
  local project_id=$1 host_id=$2 s
  s=$(orca project setups --project "$project_id" --host "$host_id" --json 2>/dev/null \
      | jq -r '.result.setups[0].setupState // empty' 2>/dev/null)
  printf '%s' "${s:-none}"
}

vizier_routing_table() {  # <project_id> -- name TAB health TAB setup TAB eligible
  local project_id=$1
  vizier_hosts | while IFS="$(printf '\t')" read -r id name kind; do
    local health setup eligible
    [ -n "$id" ] || continue
    health=$(vizier_host_health "$name" "$kind") || :
    setup=$(vizier_host_setup_state "$project_id" "$id")
    if [ "$health" = "ready" ] && [ "$setup" = "ready" ]; then eligible=yes; else eligible=no; fi
    printf '%s\t%s\t%s\t%s\n' "$name" "$health" "$setup" "$eligible"
  done
}
