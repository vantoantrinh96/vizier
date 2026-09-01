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
