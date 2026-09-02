#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-home.sh"
. "$VIZIER_TEST_REPO/lib/vizier-brief-lib.sh"

mkdir -p "$VIZIER_HOME/projects"
cat > "$VIZIER_HOME/projects/platform.md" <<'EOF'
---
delivery: direct-PR
---
Build with `make build`. Test with `make test`.
PRs target `develop`, never `main`.
EOF

# --- project file ---------------------------------------------------------
assert_eq "$(vizier_project_mode platform)" "direct-PR" "mode read from frontmatter"
assert_contains "$(vizier_brief_project platform)" "make test" "body is layer 2"
assert_eq "$(vizier_brief_project platform | grep -c 'delivery:')" "0" \
  "frontmatter never leaks into the brief"

# a project with NO knowledge file must not silently get a default mode
vizier_project_mode unknown-project >/dev/null 2>&1
assert_eq "$?" "1" "no knowledge file -> rc 1 so the skill asks the captain"

# --- a trailing space on a fence is an ordinary hand-editing accident -------
# docs/project-file-format.md tells the captain to write these files by hand,
# so `--- ` instead of `---` is a typo anyone makes. Under an exact `$0=="---"`
# match it was silent AND catastrophic: vizier_brief_project returned empty
# with rc 0, so vizier_brief_assemble's `(no project knowledge file yet)`
# fallback never fired and the ENTIRE project layer -- build, test,
# conventions, pitfalls -- vanished from every brief for that project.
printf -- '--- \ndelivery: no-mistakes\n--- \nBuild with `make loose`.\n' \
  > "$VIZIER_HOME/projects/loose-fence.md"
assert_eq "$(vizier_project_mode loose-fence)" "no-mistakes" \
  "a trailing space on a fence does not hide the delivery mode"
assert_contains "$(vizier_brief_project loose-fence)" "make loose" \
  "a trailing space on a fence does not empty brief layer 2"
assert_eq "$(vizier_brief_project loose-fence | grep -c 'delivery:')" "0" \
  "and the frontmatter still does not leak into the body"
assert_contains "$(vizier_brief_assemble loose-fence direct-PR 'Task.')" "make loose" \
  "the assembled brief really carries the project layer, not the fallback"

# The closing fence alone is the worst version, and the one that motivated
# this fix: the opening fence matches, so `inside` is set and never cleared,
# and vizier_brief_project prints NOTHING while returning rc 0 -- which is
# why the `(no project knowledge file yet)` fallback could not fire either.
printf -- '---\ndelivery: direct-PR\n--- \nBuild with `make closer`.\n' \
  > "$VIZIER_HOME/projects/loose-close.md"
body=$(vizier_brief_project loose-close); rc=$?
assert_rc "$rc" 0 "a readable project file still returns rc 0"
assert_contains "$body" "make closer" \
  "a trailing space on the CLOSING fence must not silently return an empty body"
assert_contains "$(vizier_brief_assemble loose-close direct-PR 'Task.')" "make closer" \
  "and the assembled brief is not silently missing its project layer"

# --- layer 1 invariants ---------------------------------------------------
inv=$(vizier_brief_invariant)
assert_contains "$inv" "orchestration send --type worker_done" "exact done syntax"
assert_contains "$inv" "--outcome succeeded|failed" "failure goes in --outcome, not prose"
assert_contains "$inv" "orchestration ask" "stuck -> ask"
assert_contains "$inv" "Never self-merge" "no self-merge"
assert_contains "$inv" "no-mistakes daemon" "daemon rule present"
# the wrapper ban must name the tools: a worker that has never read the spec
# will not recognise "canonical CLI" as excluding something it just found
assert_contains "$inv" "gh-axi" "the banned wrapper is named"

# --- layer 3: direct-PR ---------------------------------------------------
d=$(vizier_brief_delivery direct-PR)
assert_eq "$(printf '%s\n' "$d" | head -1)" "Delivery contract: mode=direct-PR" "fixed opening line"
assert_contains "$d" "gh" "PR is opened with gh"
assert_contains "$d" "https://" "the URL must be reported in full"
assert_contains "$d" "Never push the default branch" "default branch protected"

# --- layer 3: no-mistakes -------------------------------------------------
n=$(vizier_brief_delivery no-mistakes)
assert_eq "$(printf '%s\n' "$n" | head -1)" "Delivery contract: mode=no-mistakes" "fixed opening line"
assert_contains "$n" "no-mistakes doctor" "doctor first"
assert_contains "$n" "no-mistakes init" "init when uninitialised"
assert_contains "$n" "axi run --intent" "the run command"
assert_contains "$n" "axi_outcome:" "the exact outcome syntax is mandated"
assert_contains "$n" "checks-passed" "terminal values listed"
assert_contains "$n" "cancelled" "all four terminal values listed"
assert_contains "$n" "never answer" "worker must not answer its own finding"
assert_contains "$n" "never quote it earlier as an example" "worker told not to quote the outcome line as an example"
# The OTHER half of that sentence, and the half that actually narrows the
# residual gap in _vizier_axi_outcome: the matcher cannot tell one real report
# from one quoted example, so "exactly once, at the END, and nowhere else" is
# the only thing that makes a single anchored line unambiguous. Pinning only
# the "never quote it as an example" clause would let the positional rule be
# dropped while this test stayed green.
assert_contains "$n" "as the LAST line of the body" "worker told WHERE the outcome line goes, not just where it must not appear"
assert_contains "$n" "exactly once" "worker told the outcome line appears exactly once"

# an unknown mode is a hard error, not a silent default
vizier_brief_delivery local-only >/dev/null 2>&1
assert_eq "$?" "2" "an out-of-scope mode is refused"

# --- assembly: exactly four layers, in order ------------------------------
b=$(vizier_brief_assemble platform direct-PR "Add a dark mode toggle to settings.")
assert_eq "$(printf '%s\n' "$b" | grep -c '^## ')" "4" "exactly four layers"
assert_eq "$(printf '%s\n' "$b" | grep '^## ' | tr '\n' '|')" \
  "## 1. Invariants|## 2. Project|## 3. Delivery|## 4. Task|" "layers in spec order"
assert_contains "$b" "Add a dark mode toggle" "the captain's task is layer 4"
assert_contains "$b" "make test" "the project layer is included"
assert_contains "$b" "Delivery contract: mode=direct-PR" "the delivery layer is included"

# the mode passed to assemble WINS over the project posture: the spec lets the
# captain override per task, and the override is what must reach the worker
b2=$(vizier_brief_assemble platform no-mistakes "Same task.")
assert_contains "$b2" "Delivery contract: mode=no-mistakes" "per-task override reaches the brief"
assert_eq "$(printf '%s\n' "$b2" | grep -c 'mode=direct-PR')" "0" "the project posture does not also appear"

vizier_test_teardown
vizier_test_report
