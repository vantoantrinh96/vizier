#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
ofm_test_setup
. "$OFM_TEST_REPO/lib/ofm-home.sh"
CLI="$OFM_TEST_REPO/bin/orca-firstmate"
export OFM_SKIP_GH_AUTH=1

# doctor is clean when fake-orca reports ready and every tool is present
out=$(bash "$CLI" doctor 2>&1); rc=$?
assert_rc "$rc" 0 "a clean doctor gives rc 0"
assert_contains "$out" "orca" "doctor mentions orca"

# Orca not ready makes doctor fail and states clearly how to fix it
export OFM_FAKE_ORCA_STATUS='{"ok":true,"result":{"reachable":false,"state":"starting","capabilities":[]}}'
out=$(bash "$CLI" doctor 2>&1); rc=$?
assert_rc "$rc" 1 "Orca not ready gives rc 1"
assert_contains "$out" "NOT_READY" "reports NOT_READY"
assert_contains "$out" "orca open" "suggests the fix command"

# Missing a required capability also fails
export OFM_FAKE_ORCA_STATUS='{"ok":true,"result":{"reachable":true,"state":"ready","capabilities":["other.v1"]}}'
out=$(bash "$CLI" doctor 2>&1); rc=$?
assert_rc "$rc" 1 "missing capability gives rc 1"
assert_contains "$out" "orchestration.contract.v1" "names the exact missing capability"
unset OFM_FAKE_ORCA_STATUS

# install copies the payload into dist then calls the adapter
export OFM_CLAUDE_SKILLS_DIR="$OFM_TEST_TMP/claude-skills"
export OFM_CURSOR_HOOKS_JSON="$OFM_TEST_TMP/cursor-hooks.json"
out=$(bash "$CLI" install --harness claude 2>&1); rc=$?
assert_rc "$rc" 0 "install claude succeeds"
[ -f "$OFM_HOME/dist/hooks/wake-claude.sh" ]; assert_rc $? 0 "the payload is in dist"
[ -f "$OFM_CLAUDE_SKILLS_DIR/orca-firstmate/hooks/hooks.json" ]; assert_rc $? 0 "the claude adapter is installed"

# An unsupported harness says so plainly, does not stay silent
out=$(bash "$CLI" install --harness codex 2>&1); rc=$?
assert_rc "$rc" 1 "an unknown harness gives rc 1"
assert_contains "$out" "is not supported" "says plainly it's not supported"

# FIX 9 -- a BARE install (no --harness) must not touch Cursor. The Cursor
# target file must not exist/be modified at all after a bare install, even
# when cursor-agent is present on this test machine.
rm -rf "$OFM_HOME/dist" "$OFM_CLAUDE_SKILLS_DIR" "$OFM_CURSOR_HOOKS_JSON"
out=$(bash "$CLI" install 2>&1); rc=$?
assert_rc "$rc" 0 "a bare install succeeds (installing only Claude)"
[ -f "$OFM_CLAUDE_SKILLS_DIR/orca-firstmate/hooks/hooks.json" ]; assert_rc $? 0 "a bare install still installs Claude"
[ -e "$OFM_CURSOR_HOOKS_JSON" ]; assert_rc $? 1 "FIX 9: a bare install does NOT touch the Cursor target file"
assert_contains "$out" "skipping Cursor" "a bare install clearly states it skipped Cursor and how to ask for it"

# uninstall keeps state
mkdir -p "$OFM_HOME/requests"; printf 'x\n' > "$OFM_HOME/requests/keep.md"
bash "$CLI" uninstall >/dev/null 2>&1
[ -f "$OFM_HOME/requests/keep.md" ]; assert_rc $? 0 "uninstall does NOT delete requests"
[ -d "$OFM_CLAUDE_SKILLS_DIR/orca-firstmate" ]; assert_rc $? 1 "uninstall removes the adapter"

# uninstall must also clean up bootstrap's own traces
export OFM_BIN_DIR="$OFM_TEST_TMP/bin"; mkdir -p "$OFM_BIN_DIR" "$OFM_HOME/src"
ln -sf /usr/bin/true "$OFM_BIN_DIR/orca-firstmate"
bash "$CLI" uninstall >/dev/null 2>&1
[ -L "$OFM_BIN_DIR/orca-firstmate" ]; assert_rc $? 1 "uninstall removes the symlink on PATH"
[ -d "$OFM_HOME/src" ]; assert_rc $? 1 "uninstall removes the src clone when not running from it"

# install FROM INSIDE the installed copy must be refused, not self-destruct
bash "$CLI" install --harness claude >/dev/null 2>&1
out=$(bash "$OFM_HOME/dist/bin/orca-firstmate" install --harness claude 2>&1); rc=$?
assert_rc "$rc" 1 "install from inside dist is refused"
assert_contains "$out" "refused" "clearly states this is a refusal"
[ -f "$OFM_HOME/dist/bin/orca-firstmate" ]; assert_rc $? 0 "dist is not deleted after the refusal"

# uninstall run FROM INSIDE src does not delete src, only prints the command
mkdir -p "$OFM_HOME/src/bin" "$OFM_HOME/src/lib"
cp "$OFM_TEST_REPO/bin/orca-firstmate" "$OFM_HOME/src/bin/"
cp "$OFM_TEST_REPO/lib/ofm-home.sh" "$OFM_HOME/src/lib/"
out=$(bash "$OFM_HOME/src/bin/orca-firstmate" uninstall 2>&1)
[ -d "$OFM_HOME/src" ]; assert_rc $? 0 "does not self-delete the directory it's running from"
assert_contains "$out" "rm -rf" "prints the delete command for the captain"

# Called through a SYMLINK -- exactly how install.sh installs the CLI, and the only real invocation path.
LINKDIR="$OFM_TEST_TMP/pathbin"; mkdir -p "$LINKDIR"
ln -sf "$OFM_TEST_REPO/bin/orca-firstmate" "$LINKDIR/orca-firstmate"
DECOY="$OFM_TEST_TMP/decoy"; mkdir -p "$DECOY/dist" "$DECOY/src"
printf 'keep\n' > "$DECOY/dist/keep.txt"; printf 'keep\n' > "$DECOY/src/keep.txt"
( cd "$DECOY" && OFM_SKIP_GH_AUTH=1 "$LINKDIR/orca-firstmate" uninstall >/dev/null 2>&1 )
[ -f "$DECOY/dist/keep.txt" ]; assert_rc $? 0 "calling through a symlink does NOT delete the current directory's dist/"
[ -f "$DECOY/src/keep.txt" ]; assert_rc $? 0 "calling through a symlink does NOT delete the current directory's src/"
out=$( cd "$DECOY" && OFM_SKIP_GH_AUTH=1 "$LINKDIR/orca-firstmate" doctor 2>&1 ); rc=$?
assert_rc "$rc" 0 "doctor runs fine through a symlink"

# Capability must match EXACTLY, not as a substring
export OFM_FAKE_ORCA_STATUS='{"ok":true,"result":{"reachable":true,"state":"ready","capabilities":["orchestration.contract.v10"]}}'
out=$(bash "$CLI" doctor 2>&1); rc=$?
assert_rc "$rc" 1 "capability v10 must NOT count as v1"
assert_contains "$out" "orchestration.contract.v1" "names the still-missing capability"
unset OFM_FAKE_ORCA_STATUS

# A symlink chain deeper than the ceiling must REPORT AN ERROR, not silently use a half-resolved path
# Test: create ENOUGH symlinks to exceed the 16-hop ceiling while bash can still execute it
# Rationale: without the check, lib would be sourced from the wrong path and fail with "could not read lib"
DEEP="$OFM_TEST_TMP/deep"; rm -rf "$DEEP"
mkdir -p "$DEEP"
cp "$OFM_TEST_REPO/bin/orca-firstmate" "$DEEP/script"
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
out=$(OFM_SKIP_GH_AUTH=1 bash "$DEEP/d19/link" doctor 2>&1); rc=$?
assert_rc "$rc" 2 "a symlink chain that's too deep gives rc 2"
assert_contains "$out" "symlink" "clearly states the reason is a symlink chain"

# FIX 4 -- `unlock` is the explicit way out of a stuck-but-alive lock
# (CLAUDE_PID alive but the session id changed after /clear or a resume). No
# parameters needed: prints the current owner then clears it, for the
# captain to call themselves when they're sure the old session is done.
printf 'session_id=sess-stuck\nharness=claude\npid=999999\nsince=1\n' > "$(ofm_lock_path)"
out=$(bash "$CLI" unlock 2>&1); rc=$?
assert_rc "$rc" 0 "unlock succeeds"
assert_contains "$out" "sess-stuck" "unlock reports the correct held session_id"
assert_contains "$out" "999999" "unlock reports the correct held pid"
assert_eq "$(ofm_lock_get session_id)" "" "unlock actually clears the lock"
# Calling it again with no lock left: no crash, clearly reports nothing to clear
out=$(bash "$CLI" unlock 2>&1); rc=$?
assert_rc "$rc" 0 "unlock with no lock still gives rc 0"
assert_contains "$out" "no lock" "clearly states no lock is held"

ofm_test_teardown
ofm_test_report
