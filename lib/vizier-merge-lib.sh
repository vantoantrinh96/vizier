# shellcheck shell=bash
# Decision rule for merging into a file owned by another tool.
#
# Lives in lib rather than in the adapter, because the adapter has a dispatch
# `case` block that runs the moment it's sourced -- it can't be tested without
# inventing a test-only branch inside the single riskiest file in the project.
# A lib exists precisely to be sourced.
#
# The write race itself can't be reproduced in a unit test, but the decision
# RULE must be testable, and this is it.

# 0 when there is no sign of a lost update.
# An EMPTY count (jq failed, file unreadable) counts as a MISMATCH, not as
# equal: two empty strings compared to each other are "equal", and that is how
# a real failure disguises itself as healthy state.
#
# Check EACH argument separately, never concatenate then check the whole:
# concatenating "" + "" + "1" gives "1" -- all digits, not empty -- so a combined
# check misses exactly the case where the first two arguments are both empty.
# Checking each argument on its own means two empty ones can never be masked
# by one non-empty one.
vizier_no_lost_update() {  # <others_before> <others_after> <mine_after>
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  case "$2" in ''|*[!0-9]*) return 1 ;; esac
  case "$3" in ''|*[!0-9]*) return 1 ;; esac
  [ "$2" = "$1" ] && [ "$3" = "1" ]
}
