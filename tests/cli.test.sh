#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
. "$VIZIER_TEST_REPO/lib/vizier-home.sh"
CLI="$VIZIER_TEST_REPO/bin/vizier"
export VIZIER_SKIP_GH_AUTH=1

# doctor is clean when fake-orca reports ready and every tool is present
out=$(bash "$CLI" doctor 2>&1); rc=$?
assert_rc "$rc" 0 "a clean doctor gives rc 0"
assert_contains "$out" "orca" "doctor mentions orca"

# Orca not ready makes doctor fail and states clearly how to fix it
# NOTE: fake-orca wraps the envelope itself (id/ok/_meta); the override hook
# only supplies the .result body, so only that much is set here.
export VIZIER_FAKE_ORCA_STATUS_RESULT='{"runtime":{"reachable":false,"state":"starting","capabilities":[]}}'
out=$(bash "$CLI" doctor 2>&1); rc=$?
assert_rc "$rc" 1 "Orca not ready gives rc 1"
assert_contains "$out" "NOT_READY" "reports NOT_READY"
assert_contains "$out" "orca open" "suggests the fix command"

# Missing a required capability also fails
export VIZIER_FAKE_ORCA_STATUS_RESULT='{"runtime":{"reachable":true,"state":"ready","capabilities":["other.v1"]}}'
out=$(bash "$CLI" doctor 2>&1); rc=$?
assert_rc "$rc" 1 "missing capability gives rc 1"
assert_contains "$out" "orchestration.contract.v1" "names the exact missing capability"
unset VIZIER_FAKE_ORCA_STATUS_RESULT

# install copies the payload into dist then calls the adapter
out=$(bash "$CLI" install --harness claude 2>&1); rc=$?
assert_rc "$rc" 0 "install claude succeeds"
[ -f "$VIZIER_HOME/dist/hooks/wake-claude.sh" ]; assert_rc $? 0 "the payload is in dist"
[ -f "$VIZIER_CLAUDE_SKILLS_DIR/vizier/hooks/hooks.json" ]; assert_rc $? 0 "the claude adapter is installed"

# A skill added to the repo must reach dist with no manifest edit. If
# _sync_dist ever switches to an explicit file list, install still succeeds
# and the skill silently never appears -- so assert the payload, not the
# exit code.
for s in request brief supervise delivery identity; do
  assert_eq "$(test -f "$VIZIER_HOME/dist/skills/$s/SKILL.md" && echo yes)" "yes" \
    "skill $s reached dist"
done
for l in vizier-home vizier-request-lib vizier-routing-lib vizier-brief-lib vizier-supervise-lib vizier-wake-lib; do
  assert_eq "$(test -f "$VIZIER_HOME/dist/lib/$l.sh" && echo yes)" "yes" \
    "library $l reached dist"
done

# An unsupported harness says so plainly, does not stay silent
out=$(bash "$CLI" install --harness codex 2>&1); rc=$?
assert_rc "$rc" 1 "an unknown harness gives rc 1"
assert_contains "$out" "is not supported" "says plainly it's not supported"

# FIX 9 -- a BARE install (no --harness) must not touch Cursor. The Cursor
# target file must not exist/be modified at all after a bare install, even
# when cursor-agent is present on this test machine.
rm -rf "$VIZIER_HOME/dist" "$VIZIER_CLAUDE_SKILLS_DIR" "$VIZIER_CURSOR_HOOKS_JSON"
out=$(bash "$CLI" install 2>&1); rc=$?
assert_rc "$rc" 0 "a bare install succeeds (installing only Claude)"
[ -f "$VIZIER_CLAUDE_SKILLS_DIR/vizier/hooks/hooks.json" ]; assert_rc $? 0 "a bare install still installs Claude"
[ -e "$VIZIER_CURSOR_HOOKS_JSON" ]; assert_rc $? 1 "FIX 9: a bare install does NOT touch the Cursor target file"
assert_contains "$out" "skipping Cursor" "a bare install clearly states it skipped Cursor and how to ask for it"

# uninstall keeps state
mkdir -p "$VIZIER_HOME/requests"; printf 'x\n' > "$VIZIER_HOME/requests/keep.md"
bash "$CLI" uninstall >/dev/null 2>&1
[ -f "$VIZIER_HOME/requests/keep.md" ]; assert_rc $? 0 "uninstall does NOT delete requests"
[ -d "$VIZIER_CLAUDE_SKILLS_DIR/vizier" ]; assert_rc $? 1 "uninstall removes the adapter"

# uninstall must also clean up bootstrap's own traces
mkdir -p "$VIZIER_HOME/src"
ln -sf /usr/bin/true "$VIZIER_BIN_DIR/vizier"
bash "$CLI" uninstall >/dev/null 2>&1
[ -L "$VIZIER_BIN_DIR/vizier" ]; assert_rc $? 1 "uninstall removes the symlink on PATH"
[ -d "$VIZIER_HOME/src" ]; assert_rc $? 1 "uninstall removes the src clone when not running from it"

# install FROM INSIDE the installed copy must be refused, not self-destruct
bash "$CLI" install --harness claude >/dev/null 2>&1
out=$(bash "$VIZIER_HOME/dist/bin/vizier" install --harness claude 2>&1); rc=$?
assert_rc "$rc" 1 "install from inside dist is refused"
assert_contains "$out" "refused" "clearly states this is a refusal"
[ -f "$VIZIER_HOME/dist/bin/vizier" ]; assert_rc $? 0 "dist is not deleted after the refusal"

# uninstall run FROM INSIDE src does not delete src, only prints the command
mkdir -p "$VIZIER_HOME/src/bin" "$VIZIER_HOME/src/lib"
cp "$VIZIER_TEST_REPO/bin/vizier" "$VIZIER_HOME/src/bin/"
cp "$VIZIER_TEST_REPO/lib/vizier-home.sh" "$VIZIER_HOME/src/lib/"
out=$(bash "$VIZIER_HOME/src/bin/vizier" uninstall 2>&1)
[ -d "$VIZIER_HOME/src" ]; assert_rc $? 0 "does not self-delete the directory it's running from"
assert_contains "$out" "rm -rf" "prints the delete command for the captain"

# Called through a SYMLINK -- exactly how install.sh installs the CLI, and the only real invocation path.
LINKDIR="$VIZIER_TEST_TMP/pathbin"; mkdir -p "$LINKDIR"
ln -sf "$VIZIER_TEST_REPO/bin/vizier" "$LINKDIR/vizier"
DECOY="$VIZIER_TEST_TMP/decoy"; mkdir -p "$DECOY/dist" "$DECOY/src"
printf 'keep\n' > "$DECOY/dist/keep.txt"; printf 'keep\n' > "$DECOY/src/keep.txt"
( cd "$DECOY" && VIZIER_SKIP_GH_AUTH=1 "$LINKDIR/vizier" uninstall >/dev/null 2>&1 )
[ -f "$DECOY/dist/keep.txt" ]; assert_rc $? 0 "calling through a symlink does NOT delete the current directory's dist/"
[ -f "$DECOY/src/keep.txt" ]; assert_rc $? 0 "calling through a symlink does NOT delete the current directory's src/"
out=$( cd "$DECOY" && VIZIER_SKIP_GH_AUTH=1 "$LINKDIR/vizier" doctor 2>&1 ); rc=$?
assert_rc "$rc" 0 "doctor runs fine through a symlink"

# Capability must match EXACTLY, not as a substring
export VIZIER_FAKE_ORCA_STATUS_RESULT='{"runtime":{"reachable":true,"state":"ready","capabilities":["orchestration.contract.v10"]}}'
out=$(bash "$CLI" doctor 2>&1); rc=$?
assert_rc "$rc" 1 "capability v10 must NOT count as v1"
assert_contains "$out" "orchestration.contract.v1" "names the still-missing capability"
unset VIZIER_FAKE_ORCA_STATUS_RESULT

# REGRESSION: the real orca app nests reachable/state/capabilities under
# result.runtime, not directly under result. A status document in the OLD
# flat shape (the one the parser used to read, and the fixture used to
# emit) must now be treated as not-ready, proving doctor actually reads the
# nested path and no longer accepts the shape it used to wrongly accept.
export VIZIER_FAKE_ORCA_STATUS_RESULT='{"reachable":true,"state":"ready","capabilities":["orchestration.contract.v1"]}'
out=$(bash "$CLI" doctor 2>&1); rc=$?
assert_rc "$rc" 1 "doctor rejects the OLD flat status shape (reachable/state/capabilities directly under result)"
assert_contains "$out" "NOT_READY" "the old flat shape is reported NOT_READY, not silently accepted as ready"
unset VIZIER_FAKE_ORCA_STATUS_RESULT

# A symlink chain deeper than the ceiling must REPORT AN ERROR, not silently use a half-resolved path
# Test: create ENOUGH symlinks to exceed the 16-hop ceiling while bash can still execute it
# Rationale: without the check, lib would be sourced from the wrong path and fail with "could not read lib"
DEEP="$VIZIER_TEST_TMP/deep"; rm -rf "$DEEP"
mkdir -p "$DEEP"
cp "$VIZIER_TEST_REPO/bin/vizier" "$DEEP/script"
# Build a symlink chain: d0/link -> script, d1/link -> ../d0/link, d2/link -> ../d1/link, ...
# Each level adds one hop that readlink must walk through sequentially
i=0
while [ "$i" -lt 20 ]; do
  mkdir -p "$DEEP/d$i"
  if [ "$i" -eq 0 ]; then
    ln -sf ../script "$DEEP/d$i/link"
  else
    ln -sf "../d$((i-1))/link" "$DEEP/d$i/link"
  fi
  i=$((i + 1))
done
# d19/link -> d18/link -> ... -> d0/link -> script (20 hops)
out=$(VIZIER_SKIP_GH_AUTH=1 bash "$DEEP/d19/link" doctor 2>&1); rc=$?
assert_rc "$rc" 2 "a symlink chain that's too deep gives rc 2"
assert_contains "$out" "symlink" "clearly states the reason is a symlink chain"

# FIX 4 -- `unlock` is the explicit way out of a stuck-but-alive lock
# (CLAUDE_PID alive but the session id changed after /clear or a resume). No
# parameters needed: prints the current owner then clears it, for the
# captain to call themselves when they're sure the old session is done.
printf 'session_id=sess-stuck\nharness=claude\npid=999999\nsince=1\n' > "$(vizier_lock_path)"
out=$(bash "$CLI" unlock 2>&1); rc=$?
assert_rc "$rc" 0 "unlock succeeds"
assert_contains "$out" "sess-stuck" "unlock reports the correct held session_id"
assert_contains "$out" "999999" "unlock reports the correct held pid"
assert_eq "$(vizier_lock_get session_id)" "" "unlock actually clears the lock"
# Calling it again with no lock left: no crash, clearly reports nothing to clear
out=$(bash "$CLI" unlock 2>&1); rc=$?
assert_rc "$rc" 0 "unlock with no lock still gives rc 0"
assert_contains "$out" "no lock" "clearly states no lock is held"

# --- version: reports source, payload match, and manifest ---

# A FRESH INSTALL: src is a real git checkout of the payload, and dist is
# synced FROM that exact tree by running the CLI through its own copy
# inside src -- the same trick install.sh's real bootstrap relies on. `git
# log` alone could never prove dist matches this commit; version must.
rm -rf "$VIZIER_HOME/dist" "$VIZIER_HOME/src"
mkdir -p "$VIZIER_HOME/src"
for item in lib hooks skills commands bin .claude-plugin; do
  [ -e "$VIZIER_TEST_REPO/$item" ] && cp -R "$VIZIER_TEST_REPO/$item" "$VIZIER_HOME/src/"
done
git -C "$VIZIER_HOME/src" init --quiet
git -C "$VIZIER_HOME/src" add -A
git -C "$VIZIER_HOME/src" -c user.email=t@t -c user.name=t commit --quiet -m seed
bash "$VIZIER_HOME/src/bin/vizier" install --harness claude >/dev/null 2>&1
short_sha=$(git -C "$VIZIER_HOME/src" log -1 --format=%h)

out=$(bash "$CLI" version 2>&1); rc=$?
assert_rc "$rc" 0 "a fresh install: version exits 0"
assert_contains "$out" "$short_sha" "version names the source commit"
assert_contains "$out" "dist matches src" "a fresh install reports dist matching src"

# NO PAYLOAD INSTALLED: dist was never synced. "not installed" and
# "mismatched" are two different problems with two different fixes, so
# version must say the first plainly and must NOT claim the second.
rm -rf "$VIZIER_HOME/dist"
out=$(bash "$CLI" version 2>&1); rc=$?
assert_rc "$rc" 0 "no payload installed: version exits 0"
assert_contains "$out" "not installed" "no payload installed: version says so"
case "$out" in *"DOES NOT MATCH"*) claimed=1 ;; *) claimed=0 ;; esac
assert_rc "$claimed" 0 "no payload installed: version must not claim a mismatch"

# A TAMPERED PAYLOAD: reinstall clean, then edit one file under dist by
# hand -- exactly what a half-finished install, or someone poking at dist
# directly, produces. This is the whole point of the command: catch it and
# exit non-zero.
bash "$VIZIER_HOME/src/bin/vizier" install --harness claude >/dev/null 2>&1
printf '# tampered\n' >> "$VIZIER_HOME/dist/lib/vizier-home.sh"
out=$(bash "$CLI" version 2>&1); rc=$?
assert_rc "$rc" 1 "a tampered payload: version exits non-zero"
assert_contains "$out" "DOES NOT MATCH" "a tampered payload: version reports the mismatch"

# SRC ABSENT, NO PAYLOAD EITHER: reported plainly, no crash, rc 0 since
# there is nothing installed to disagree with anything.
rm -rf "$VIZIER_HOME/dist" "$VIZIER_HOME/src"
out=$(bash "$CLI" version 2>&1); rc=$?
assert_rc "$rc" 0 "src absent, no payload: version exits 0"
assert_contains "$out" "not a git repository" "src absent: version reports it plainly"

# SRC EXISTS BUT ISN'T A GIT REPO: same plain report, still no crash.
mkdir -p "$VIZIER_HOME/src"; printf 'junk\n' > "$VIZIER_HOME/src/junk"
out=$(bash "$CLI" version 2>&1); rc=$?
assert_rc "$rc" 0 "src not a git repo: version exits 0"
assert_contains "$out" "not a git repository" "src not a git repo: version reports it plainly"

vizier_test_teardown
vizier_test_report
