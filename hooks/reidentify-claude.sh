#!/usr/bin/env bash
# PostCompact hook: sau khi nén context, first mate quên mình là ai nhưng vẫn
# đang giữ lock và vẫn bị đánh thức. In lại identity ra stderr cho đúng phiên
# đang giữ lock, câm với mọi phiên khác.
set -u
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)" || exit 0
[ -r "$LIB/ofm-home.sh" ] || exit 0
# shellcheck source=/dev/null
. "$LIB/ofm-home.sh"
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null || true)
session_id=$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null) || exit 0
ofm_lock_matches "$session_id" || exit 0

SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills/identity" 2>/dev/null && pwd)/SKILL.md"
if [ -r "$SKILL" ]; then
  printf 'orca-firstmate: phiên này vẫn là first mate. Đọc lại identity:\n' >&2
  cat "$SKILL" >&2
else
  printf 'orca-firstmate: phiên này vẫn là first mate nhưng không đọc được skill identity.\n' >&2
fi
exit 0
