#!/usr/bin/env bash
# PostCompact hook: after context compaction, the first mate forgets who it
# is but is still holding the lock and still being woken up. Reprint identity
# to stderr for the session that actually holds the lock, stay silent for
# every other session.
set -u
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)" || exit 0
[ -r "$LIB/vizier-home.sh" ] || exit 0
# shellcheck source=/dev/null
. "$LIB/vizier-home.sh"
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null || true)
session_id=$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null) || exit 0
vizier_lock_matches "$session_id" || exit 0

SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills/identity" 2>/dev/null && pwd)/SKILL.md"
if [ -r "$SKILL" ]; then
  printf 'vizier: this session is still the first mate. Reprinting identity:\n' >&2
  cat "$SKILL" >&2
else
  printf 'vizier: this session is still the first mate but the identity skill could not be read.\n' >&2
fi
exit 0
