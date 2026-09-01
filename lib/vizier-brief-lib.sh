# shellcheck shell=bash
# Assembles the four brief layers into the --spec string for task-create.
# Requires lib/vizier-home.sh to be sourced first.
#
# THE WORKER HAS NEVER READ THE SPEC. Everything a worker must not do has to
# be said here, in words -- including naming the banned tools, because "use
# the canonical CLI" does not stop an agent that has never heard of gh-axi
# from installing it the moment it looks convenient.
#
# LAYER 3 IS PARSED LATER. lib/vizier-supervise-lib.sh decides whether to
# release a terminal by looking for the exact `axi_outcome:` line this layer
# mandates. Loosen the wording here and a worker can satisfy the brief while
# producing a body the supervisor cannot read. That fails closed -- no
# release, captain gets a report -- but it still stalls the request.

vizier_projects_dir() { printf '%s/projects' "$(vizier_home)"; }
vizier_project_path() { printf '%s/%s.md' "$(vizier_projects_dir)" "$1"; }

_vizier_project_frontmatter() {  # <project>
  local f
  f=$(vizier_project_path "$1")
  [ -r "$f" ] || return 1
  tr -d '\r' < "$f" | awk 'NR==1 && $0=="---" {inside=1; next} inside && $0=="---" {exit} inside'
}

vizier_project_field() {  # <project> <key>
  _vizier_project_frontmatter "$1" 2>/dev/null | sed -n "s/^$2: *//p" | head -n 1
}

vizier_project_mode() {  # <project> -- rc 1 when there is no knowledge file
  local m
  [ -r "$(vizier_project_path "$1")" ] || return 1
  m=$(vizier_project_field "$1" delivery)
  [ -n "$m" ] || return 1
  printf '%s' "$m"
}

vizier_brief_project() {  # <project> -- the body, frontmatter stripped
  local f
  f=$(vizier_project_path "$1")
  [ -r "$f" ] || return 1
  tr -d '\r' < "$f" | awk '
    NR==1 && $0=="---" { inside=1; next }
    inside && $0=="---" { inside=0; body=1; next }
    !inside { print }
  '
}

vizier_brief_invariant() {
  cat <<'EOF'
You are a crew agent working one task inside one Orca worktree.

- Report completion with exactly:
  `orca orchestration send --type worker_done --outcome succeeded|failed ...`
  A failure goes in `--outcome`, never only in prose. A body that describes a
  failure while `--outcome` says succeeded will be read as success.
- Stuck, blocked, or facing a decision that is not yours: run
  `orca orchestration ask` and wait. Never guess.
- Never self-merge. The captain merges every PR.
- Never leave the worktree you were assigned.
- Use the canonical CLI: `git` and `gh`. Do NOT install or use `gh-axi`,
  `tasks-axi`, `lavish-axi`, `chrome-devtools-axi`, or `quota-axi`, even if
  one looks more convenient, unless this project's section below names a
  different tool for that job.
- Never stop, restart, or update the no-mistakes daemon. One instance is
  shared across every worktree and every host, and restarting it kills
  someone else's running pipeline. A daemon error means: escalate, then stop.
EOF
}

vizier_brief_delivery() {  # <mode>
  case "$1" in
    direct-PR)
      cat <<'EOF'
Delivery contract: mode=direct-PR

- Implement the task, then push your own branch.
- Open the PR with `gh`. Never push the default branch. Never self-merge.
- Report done with the full `https://...` PR URL in the body and
  `--outcome succeeded`.
EOF
      ;;
    no-mistakes)
      cat <<'EOF'
Delivery contract: mode=no-mistakes

- Run `no-mistakes doctor` first. If this worktree's repo is not initialised
  yet, run `no-mistakes init`.
- Implement the task and commit. Then run
  `no-mistakes axi run --intent "<the captain's intent>"`.
- Keep driving every `axi run` / `axi respond` the pipeline asks for until it
  returns a terminal outcome.
- A finding that needs a human decision is NOT yours to answer: never answer
  your own finding. Call `orca orchestration ask` with the finding ID, the
  step, the choices, and your recommendation, then apply the single decision
  that comes back.
- Send `worker_done` only once axi has returned a terminal outcome, and put
  that outcome in the body as this exact line, on its own:
      axi_outcome: <passed|checks-passed|failed|cancelled>
  Include the PR URL in the body as well. Without that exact line your
  terminal will be held rather than released, because a pipeline run may
  still own the branch.
- Write that line exactly once, as the LAST line of the body, and nowhere
  else -- never quote it earlier as an example, a format reminder, or a
  restatement of this instruction. The supervisor cannot tell your one real
  report apart from a quoted example; only you writing it once, at the end,
  makes it unambiguous.
EOF
      ;;
    *)
      printf 'vizier_brief_delivery: unsupported mode: %s\n' "$1" >&2
      return 2
      ;;
  esac
}

vizier_brief_assemble() {  # <project> <mode> <task_text>
  local d
  d=$(vizier_brief_delivery "$2") || return 2
  printf '## 1. Invariants\n\n%s\n' "$(vizier_brief_invariant)"
  printf '\n## 2. Project\n\n%s\n' "$(vizier_brief_project "$1" 2>/dev/null || printf '(no project knowledge file yet)')"
  printf '\n## 3. Delivery\n\n%s\n' "$d"
  printf '\n## 4. Task\n\n%s\n' "$3"
}
