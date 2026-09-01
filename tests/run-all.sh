#!/usr/bin/env bash
# Runs every tests/*.test.sh, reports a combined result. Exits non-zero if any file fails.
set -u
cd "$(dirname "$0")" || exit 1

# GUARD: this suite must never touch the captain's REAL installed state.
# It once did -- an earlier version of cli.test.sh ran `uninstall` before
# it exported VIZIER_BIN_DIR, and cmd_uninstall fell back to the real
# $HOME/.local/bin/vizier and deleted the captain's actual symlink. The
# fix in tests/helpers.sh is meant to make that impossible, but a guard
# that only asserts the fix's INTENT is worth nothing next to a guard
# that would have actually caught the incident. This snapshots the three
# real locations bin/vizier can fall back to before the suite runs, and
# fails loudly if any of them changed after. Read-only: it must never
# create, touch, or repair any of these paths, and must not fail merely
# because one of them does not exist on this machine.
REAL_BIN_LINK="$HOME/.local/bin/vizier"
REAL_CLAUDE_SKILL="$HOME/.claude/skills/vizier"
REAL_CURSOR_HOOKS="$HOME/.cursor/hooks.json"

snapshot_real_state() {
  # bin link: whether it exists, whether it's a symlink, and what it points at
  if [ -L "$REAL_BIN_LINK" ]; then
    printf 'bin=symlink:%s\n' "$(readlink "$REAL_BIN_LINK")"
  elif [ -e "$REAL_BIN_LINK" ]; then
    printf 'bin=present-not-symlink\n'
  else
    printf 'bin=absent\n'
  fi
  # claude skill dir: presence only
  if [ -e "$REAL_CLAUDE_SKILL" ]; then
    printf 'claude_skill=present\n'
  else
    printf 'claude_skill=absent\n'
  fi
  # cursor hooks file: presence and content hash (this file is also
  # maintained by the Orca app itself, so a hash change matters even if
  # the file never disappears)
  if [ -e "$REAL_CURSOR_HOOKS" ]; then
    printf 'cursor_hooks=present:%s\n' "$(shasum -a 256 "$REAL_CURSOR_HOOKS" | awk '{print $1}')"
  else
    printf 'cursor_hooks=absent\n'
  fi
}

before_state=$(snapshot_real_state)

failed=0
for t in *.test.sh; do
  if bash "$t"; then :; else failed=$((failed+1)); fi
done

after_state=$(snapshot_real_state)

real_state_ok=1
if [ "$before_state" != "$after_state" ]; then
  real_state_ok=0
  printf '\nREAL INSTALLED STATE WAS TOUCHED BY THE TEST SUITE:\n' >&2
  before_bin=$(printf '%s\n' "$before_state" | sed -n 's/^bin=//p')
  after_bin=$(printf '%s\n' "$after_state" | sed -n 's/^bin=//p')
  [ "$before_bin" = "$after_bin" ] || printf '  %s: %s -> %s\n' "$REAL_BIN_LINK" "$before_bin" "$after_bin" >&2
  before_skill=$(printf '%s\n' "$before_state" | sed -n 's/^claude_skill=//p')
  after_skill=$(printf '%s\n' "$after_state" | sed -n 's/^claude_skill=//p')
  [ "$before_skill" = "$after_skill" ] || printf '  %s: %s -> %s\n' "$REAL_CLAUDE_SKILL" "$before_skill" "$after_skill" >&2
  before_hooks=$(printf '%s\n' "$before_state" | sed -n 's/^cursor_hooks=//p')
  after_hooks=$(printf '%s\n' "$after_state" | sed -n 's/^cursor_hooks=//p')
  [ "$before_hooks" = "$after_hooks" ] || printf '  %s: %s -> %s\n' "$REAL_CURSOR_HOOKS" "$before_hooks" "$after_hooks" >&2
fi

if [ "$failed" -eq 0 ] && [ "$real_state_ok" -eq 1 ]; then
  printf '\nALL TEST FILES PASSED\n'; exit 0
fi
[ "$failed" -eq 0 ] || printf '\n%s TEST FILE(S) FAILED\n' "$failed" >&2
[ "$real_state_ok" -eq 1 ] || printf '\nREAL STATE GUARD FAILED\n' >&2
exit 1
