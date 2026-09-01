#!/usr/bin/env bash
# Runs every tests/*.test.sh, reports a combined result. Exits non-zero if any file fails.
set -u
cd "$(dirname "$0")" || exit 1
failed=0
for t in *.test.sh; do
  if bash "$t"; then :; else failed=$((failed+1)); fi
done
if [ "$failed" -eq 0 ]; then
  printf '\nALL TEST FILES PASSED\n'; exit 0
fi
printf '\n%s TEST FILE(S) FAILED\n' "$failed" >&2; exit 1
