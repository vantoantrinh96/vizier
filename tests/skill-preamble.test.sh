#!/usr/bin/env bash
# EXECUTE each skill's source preamble, then prove every vizier_* function the
# skill's own text tells the model to call is actually defined by it.
#
# WHY THIS FILE EXISTS. Every other test sources the libraries the way a TEST
# finds convenient -- `. $VIZIER_TEST_REPO/lib/...`, all of them, in whatever
# order the test needs. No test had ever run the source block a SKILL ships.
# That gap let two defects through with the whole suite green:
#   - $VIZIER_DIST was defined nowhere in the repo, so all four skills sourced
#     an empty path and no library function was ever defined (47 assertions
#     green).
#   - `supervise` called vizier_project_mode without sourcing brief-lib, so
#     every dispatch missing from the mode map was held forever, with a bare
#     `command not found` in the captain's transcript (574 assertions green).
#
# Both are the same shape: two halves each correct, each tested, that do not
# fit. This closes the CLASS -- any skill that calls a function it does not
# source reddens here, whichever skill and whichever function.
#
# The identifier list is not maintained by hand: it is every `vizier_*` token
# the shipped Markdown mentions. A skill that starts naming a new function
# automatically starts requiring it.
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup

# The skills resolve VIZIER_DIST from VIZIER_HOME, which the harness points at
# the temp home -- so dist has to exist there, exactly as `vizier install`
# leaves it. Copying lib/ is the whole of what these preambles need.
mkdir -p "$VIZIER_HOME/dist"
cp -R "$VIZIER_TEST_REPO/lib" "$VIZIER_HOME/dist/lib"

# unresolved <skill_file> -- prints one line per vizier_* name the skill
# mentions that its OWN preamble fails to define. Runs in a subshell so one
# skill's sources never satisfy the next skill's requirements.
unresolved() {
  local skill="$1" preamble
  # The preamble is the VIZIER_DIST assignment plus every `. "..."` source
  # line, taken from the shipped Markdown -- never retyped here.
  #
  # LEADING WHITESPACE IS TOLERATED because commands/vizier.md's fences sit
  # inside a numbered list item and are therefore indented to stay inside it.
  # Anchoring at column 0 would have read that file as having no preamble at
  # all -- and "no preamble" is exactly the shape this test cannot let pass
  # silently, so it is asserted below rather than skipped.
  preamble=$(grep -E '^[[:space:]]*(VIZIER_DIST=|\. ")' "$skill")
  [ -n "$preamble" ] || { printf 'NO-PREAMBLE\n'; return 0; }
  (
    eval "$preamble" 2>/dev/null
    grep -o 'vizier_[a-z0-9_]*' "$skill" | sort -u | while IFS= read -r name; do
      [ -n "$name" ] || continue
      command -v "$name" >/dev/null 2>&1 || printf '%s\n' "$name"
    done
  )
}

# commands/vizier.md IS IN THIS LIST, not only the four skills. Activation's
# step 5 sources libraries and calls into them exactly the way a skill does,
# and it is the one place in the project whose whole job is to NOT be silent
# -- a `command not found` swallowed inside vizier_reconcile_run would leave
# activation reporting a clean fleet over a failed dispatch, which is the
# precise failure that step was added to end.
for f in \
  "$VIZIER_TEST_REPO/skills/request/SKILL.md" \
  "$VIZIER_TEST_REPO/skills/brief/SKILL.md" \
  "$VIZIER_TEST_REPO/skills/supervise/SKILL.md" \
  "$VIZIER_TEST_REPO/skills/delivery/SKILL.md" \
  "$VIZIER_TEST_REPO/commands/vizier.md" \
; do
  s=$(basename "$(dirname "$f")")/$(basename "$f")
  assert_eq "$(test -f "$f" && echo yes)" "yes" "$s exists"
  # A skill that mentions no vizier_* function at all would pass vacuously,
  # so require that each of the four really does call into the libraries.
  n=$(grep -o 'vizier_[a-z0-9_]*' "$f" | sort -u | grep -c . || true)
  assert_eq "$(test "$n" -gt 0 && echo yes)" "yes" "$s names at least one library function"
  assert_eq "$(unresolved "$f")" "" "$s: every library function it calls is defined by its own source block"
done

vizier_test_teardown
vizier_test_report
