#!/usr/bin/env sh
# Bootstrap vizier.
#
#   curl -fsSL <RAW_URL>/install.sh | sh
#
# Does exactly two things: fetches the source into $VIZIER_HOME/src and places a
# symlink on PATH. DELIBERATELY DOES NOT run `vizier install`: that
# step edits the captain's harness config (for Cursor that's
# ~/.cursor/hooks.json, a file Orca also uses), so it must be an explicit
# decision, not a side effect of `curl | sh`.
#
# POSIX sh, no bashisms: this runs through the user's `sh`, not bash.
set -eu

# The repo is public on GitHub, so both clone and curl need no auth.
#
# USE HTTPS, NOT SSH. The checkout's own remote is in SSH form
# (git@github.com:vantoantrinh96/orca-firstmate.git), but bootstrap runs on a
# fresh machine via `curl | sh` where there's no guarantee of an SSH key for
# that account -- and since the repo is already public, an HTTPS clone needs
# no auth at all. Take the owner/name from the remote, emit it as HTTPS.
REPO_URL="${VIZIER_REPO_URL:-https://github.com/vantoantrinh96/orca-firstmate.git}"

HOME_DIR="${VIZIER_HOME:-$HOME/.vizier}"
SRC="$HOME_DIR/src"
BIN_DIR="${VIZIER_BIN_DIR:-$HOME/.local/bin}"

for t in git jq; do
  command -v "$t" >/dev/null 2>&1 || { echo "error: need $t (brew install $t)" >&2; exit 1; }
done

mkdir -p "$HOME_DIR"
if [ -d "$SRC/.git" ]; then
  git -C "$SRC" fetch --quiet origin || { echo "error: fetch failed from $REPO_URL" >&2; exit 1; }
  # origin/HEAD may not be set yet (an old clone, or a remote that doesn't
  # publish HEAD). When that happens, `reset --hard origin/HEAD` reports
  # "unknown revision" and bootstrap gets stuck permanently. `set-head -a`
  # asks the remote again and self-heals; a failure here does not block.
  git -C "$SRC" remote set-head origin -a >/dev/null 2>&1 || true
  # reset --hard: $SRC is owned by the tool, not a place for hand edits. A
  # hand edit there is deliberately overwritten, rather than leaving
  # bootstrap stuck forever.
  git -C "$SRC" reset --quiet --hard origin/HEAD || { echo "error: reset failed" >&2; exit 1; }
elif [ -e "$SRC" ]; then
  # $SRC exists but is not a git repo -- usually a botched previous clone.
  # DO NOT auto-delete it: it's a directory on the captain's machine. Say so
  # clearly and give the exact command.
  echo "error: $SRC already exists but is not a git repo (a botched clone?)" >&2
  echo "  delete it and rerun:  rm -rf $SRC" >&2
  exit 1
else
  git clone --quiet "$REPO_URL" "$SRC" || { echo "error: clone failed from $REPO_URL" >&2; exit 1; }
fi

[ -x "$SRC/bin/vizier" ] || { echo "error: source is missing bin/vizier" >&2; exit 1; }
mkdir -p "$BIN_DIR" || { echo "error: could not create $BIN_DIR" >&2; exit 1; }

# `ln -sf` is NOT safe when the target is already a DIRECTORY. On macOS's
# BSD ln -- the only platform we ship to -- `-f` does not replace a
# directory; it creates the link INSIDE that directory and exits 0, so the
# script would print "installed" successfully while what's on PATH is a
# directory that can't run. Guard before, and verify again after.
LINK="$BIN_DIR/vizier"
if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
  echo "error: $LINK already exists and is not a symlink; move it aside and rerun" >&2
  exit 1
fi
# FIX 10 (a reproduced case) -- THE GUARD ABOVE DOES NOT CATCH IT when $LINK
# is ALREADY A SYMLINK POINTING AT A DIRECTORY (e.g. left over from a
# previous botched install). In that case `[ -e "$LINK" ]` is true (follows
# the link, reaches the directory) but `[ ! -L "$LINK" ]` is FALSE -- $LINK
# IS STILL A SYMLINK, only its target is a directory -- so the guard above
# doesn't fire. Then `ln -sf` (without `-n`) treats $LINK as that directory
# target and creates a NEW link INSIDE it, instead of replacing $LINK; the
# old post-check `[ -L "$LINK" ]` still passes (the ORIGINAL symlink is
# untouched, irrelevant to what happened) so the script reports "installed"
# while PATH still points at the old/broken location. `-n` forces ln to
# treat $LINK as an entry TO BE REPLACED, without following it even when
# the target is a directory.
ln -sfn "$SRC/bin/vizier" "$LINK" || { echo "error: could not create symlink $LINK" >&2; exit 1; }
# The OLD post-check only asked "is $LINK a symlink" -- not enough, because
# exactly the bug case above still leaves behind A symlink (just the
# original one, pointing at the wrong place). Ask further: does it RESOLVE
# to a regular, executable file, or not.
[ -L "$LINK" ] || { echo "error: $LINK is not a symlink after install" >&2; exit 1; }
[ -f "$LINK" ] && [ -x "$LINK" ] || {
  echo "error: $LINK does not resolve to an executable file after install" >&2; exit 1; }

echo "installed vizier -> $LINK"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: $BIN_DIR is not on PATH yet; add it to your shell profile" ;;
esac
echo
echo "next:"
echo "  vizier doctor     # check Orca, jq, git, gh"
echo "  vizier install    # install into a harness (will edit harness config)"
