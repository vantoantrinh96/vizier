#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup

# A local bare repo stands in for the remote: the test runs offline, with no dependency on the published repo.
ORIGIN="$VIZIER_TEST_TMP/origin.git"
WORK="$VIZIER_TEST_TMP/work"
git init --quiet --bare "$ORIGIN"
git clone --quiet "$ORIGIN" "$WORK"
mkdir -p "$WORK/bin"
printf '#!/usr/bin/env bash\necho stub-cli\n' > "$WORK/bin/vizier"
chmod +x "$WORK/bin/vizier"
cp "$VIZIER_TEST_REPO/install.sh" "$WORK/install.sh"
git -C "$WORK" add -A
git -C "$WORK" -c user.email=t@t -c user.name=t commit --quiet -m init
git -C "$WORK" push --quiet origin HEAD:refs/heads/main
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main

export VIZIER_REPO_URL="file://$ORIGIN"
export VIZIER_BIN_DIR="$VIZIER_TEST_TMP/bin"

out=$(sh "$VIZIER_TEST_REPO/install.sh" 2>&1); rc=$?
assert_rc "$rc" 0 "bootstrap succeeds"
[ -d "$VIZIER_HOME/src/.git" ]; assert_rc $? 0 "clones into src/"
[ -L "$VIZIER_BIN_DIR/vizier" ]; assert_rc $? 0 "creates the symlink"
assert_eq "$("$VIZIER_BIN_DIR/vizier")" "stub-cli" "the symlink runs the right CLI"
assert_contains "$out" "vizier install" "prints the next step"

# MUST NOT auto-install into a harness: that's a separate decision, it edits someone else's file
assert_eq "$(ls "$VIZIER_HOME/dist" 2>/dev/null)" "" "bootstrap does not run install on its own"

# Running it again is an update, not a breakage
printf '#!/usr/bin/env bash\necho stub-v2\n' > "$WORK/bin/vizier"
git -C "$WORK" -c user.email=t@t -c user.name=t commit --quiet -am v2
git -C "$WORK" push --quiet origin HEAD:refs/heads/main
sh "$VIZIER_TEST_REPO/install.sh" >/dev/null 2>&1; assert_rc $? 0 "rerunning succeeds"
assert_eq "$("$VIZIER_BIN_DIR/vizier")" "stub-v2" "rerunning updates to the new version"

# Local changes inside src get overwritten, without getting bootstrap stuck
printf 'junk\n' > "$VIZIER_HOME/src/bin/vizier"
sh "$VIZIER_TEST_REPO/install.sh" >/dev/null 2>&1; assert_rc $? 0 "a dirty src still updates"
assert_eq "$("$VIZIER_BIN_DIR/vizier")" "stub-v2" "a dirty src gets restored"

# The default must be a real URL, not a placeholder. This test is what
# catches "forgot to fill it in" instead of letting it reach a user's machine.
grep -q 'OWNER_PLACEHOLDER' "$VIZIER_TEST_REPO/install.sh"; assert_rc $? 1 "no owner placeholder remains"
default_url=$(sed -n 's/^REPO_URL="\${VIZIER_REPO_URL:-\(.*\)}"$/\1/p' "$VIZIER_TEST_REPO/install.sh")
assert_contains "$default_url" "github.com" "the default points at GitHub"
assert_contains "$default_url" "orca-firstmate" "the default points at the right repo"
# `github.com` alone does NOT distinguish: the SSH string
# `git@github.com:...` also contains it. Must catch the actual SSH marker.
case "$default_url" in *git@*) assert_eq "ssh" "https" "the default must NOT be in SSH form" ;; esac

# Target on PATH is already a DIRECTORY: must be REFUSED, must not report success
export VIZIER_REPO_URL="file://$ORIGIN"
rm -rf "$VIZIER_HOME/src" "$VIZIER_BIN_DIR/vizier"
mkdir -p "$VIZIER_BIN_DIR/vizier"
out=$(sh "$VIZIER_TEST_REPO/install.sh" 2>&1); rc=$?
assert_rc "$rc" 1 "target is a directory gives rc 1"
assert_contains "$out" "not a symlink" "clearly states the reason"
rmdir "$VIZIER_BIN_DIR/vizier"

# FIX 10 (a reproduced case) -- the target on PATH is a SYMLINK POINTING AT A
# DIRECTORY (different from the case above: here $LINK IS STILL a symlink,
# just its target is a directory, so the `[ ! -L ]` guard doesn't fire). The
# old guard + `ln -sf` (without `-n`) would create a NEW link INSIDE that
# directory, leaving the ORIGINAL symlink pointing at the wrong place, while
# the old post-check `[ -L "$LINK" ]` still passes -- reporting "installed"
# while PATH doesn't run.
rm -rf "$VIZIER_HOME/src" "$VIZIER_BIN_DIR/vizier"
mkdir -p "$VIZIER_TEST_TMP/old-target-dir"
ln -sf "$VIZIER_TEST_TMP/old-target-dir" "$VIZIER_BIN_DIR/vizier"
out=$(sh "$VIZIER_TEST_REPO/install.sh" 2>&1); rc=$?
assert_rc "$rc" 0 "FIX 10: a symlink-to-directory still installs successfully (ln -sfn replaces it correctly)"
[ -L "$VIZIER_BIN_DIR/vizier" ]; assert_rc $? 0 "still a symlink after install"
assert_eq "$(readlink "$VIZIER_BIN_DIR/vizier")" "$VIZIER_HOME/src/bin/vizier" \
  "FIX 10: the symlink points at the CORRECT new target, not lost inside the old directory"
assert_eq "$("$VIZIER_BIN_DIR/vizier")" "stub-v2" "FIX 10: the CLI runs through the replaced symlink"
[ -d "$VIZIER_TEST_TMP/old-target-dir" ]; assert_rc $? 0 "the old directory is not deleted, only the symlink is replaced"
[ -e "$VIZIER_TEST_TMP/old-target-dir/vizier" ]; assert_rc $? 1 \
  "FIX 10: NO stray link inside the old directory (exactly what the old bug used to create)"

# $SRC exists but is not a git repo: report it clearly and give the delete command
rm -rf "$VIZIER_HOME/src"; mkdir -p "$VIZIER_HOME/src"; printf 'junk\n' > "$VIZIER_HOME/src/junk"
out=$(sh "$VIZIER_TEST_REPO/install.sh" 2>&1); rc=$?
assert_rc "$rc" 1 "src not being a git repo gives rc 1"
assert_contains "$out" "rm -rf" "prints the delete command for the captain"
rm -rf "$VIZIER_HOME/src"

# Delete the local `refs/remotes/origin/HEAD` ref then rerun: the update path
# must still run smoothly.
#
# THIS IS ALL THIS CASE PROVES. It does NOT prove the `remote set-head` line
# is necessary: measured directly by removing that line and the suite still
# stayed green, because a `file://` clone environment cannot reproduce a real
# missing-origin/HEAD state. That line is kept as a defense, based on a
# reviewer having reproduced the stuck state on a bare repo with HEAD deleted.
# Name the assertion for what it actually measures, rather than let a name
# promise more than the truth -- this project has already had five tests
# stay green while measuring the wrong thing.
sh "$VIZIER_TEST_REPO/install.sh" >/dev/null 2>&1
git -C "$VIZIER_HOME/src" symbolic-ref --delete refs/remotes/origin/HEAD 2>/dev/null || true
sh "$VIZIER_TEST_REPO/install.sh" >/dev/null 2>&1
assert_rc $? 0 "rerunning after deleting the local origin/HEAD ref still updates"

# A broken URL fails clearly, without leaving behind a dead symlink
export VIZIER_REPO_URL="file://$VIZIER_TEST_TMP/does-not-exist.git"
rm -rf "$VIZIER_HOME/src" "$VIZIER_BIN_DIR/vizier"
out=$(sh "$VIZIER_TEST_REPO/install.sh" 2>&1); rc=$?
assert_rc "$rc" 1 "a broken URL gives rc 1"
[ -L "$VIZIER_BIN_DIR/vizier" ]; assert_rc $? 1 "a failure leaves no dead symlink behind"

vizier_test_teardown
vizier_test_report
