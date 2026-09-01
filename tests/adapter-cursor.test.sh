#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
vizier_test_setup
AD="$VIZIER_TEST_REPO/bin/vizier-adapter-cursor.sh"
DIST="$VIZIER_TEST_TMP/dist"; mkdir -p "$DIST/hooks"; printf 'x\n' > "$DIST/hooks/wake-cursor.sh"
H="$VIZIER_TEST_TMP/cursor-hooks.json"

# Mimics the captain's real file: Orca already has entries here beforehand.
cat > "$H" <<'JSON'
{
  "version": 1,
  "hooks": {
    "preToolUse": [{"matcher":"Shell","command":"rtk hook cursor"}],
    "stop": [{"type":"command","command":"/Users/x/.orca/agent-hooks/cursor-hook.sh","timeout":10}],
    "afterAgentResponse": [{"type":"command","command":"/Users/x/.orca/agent-hooks/cursor-hook.sh","timeout":10}]
  }
}
JSON
before=$(shasum -a 256 "$H" | awk '{print $1}')

bash "$AD" install "$DIST" "$H"; assert_rc $? 0 "install succeeded"

# The other party's entries must remain intact, one by one
assert_eq "$(jq -r '.hooks.preToolUse | length' "$H")" "1" "preToolUse preserved"
assert_eq "$(jq -r '.hooks.afterAgentResponse[0].command' "$H")" "/Users/x/.orca/agent-hooks/cursor-hook.sh" "Orca hook preserved"
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("orca/agent-hooks"))] | length' "$H")" "1" "Orca's stop hook preserved"
assert_eq "$(jq -r '.version' "$H")" "1" "version preserved"

# Our entry matches the verified constants exactly
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("wake-cursor.sh"))] | length' "$H")" "1" "exactly one entry added"
assert_eq "$(jq -r '.hooks.stop[] | select(.command | contains("wake-cursor.sh")) | .loop_limit' "$H")" "200" "loop_limit is 200"
assert_eq "$(jq -r '.hooks.stop[] | select(.command | contains("wake-cursor.sh")) | .timeout' "$H")" "28800" "timeout is 28800"

# A backup exists before writing
ls "$VIZIER_HOME"/backups/cursor-hooks.*.json >/dev/null 2>&1; assert_rc $? 0 "a backup file exists"

# Idempotent: running three times still leaves exactly one entry
bash "$AD" install "$DIST" "$H" >/dev/null
bash "$AD" install "$DIST" "$H" >/dev/null
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("wake-cursor.sh"))] | length' "$H")" "1" "rerunning does not duplicate"
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("orca/agent-hooks"))] | length' "$H")" "1" "rerunning does not duplicate the other party's entry"

bash "$AD" verify "$DIST" "$H"; assert_rc $? 0 "verify sees our entry"

# uninstall removes exactly our entry and returns the file to its previous state
bash "$AD" uninstall "$H"; assert_rc $? 0 "uninstall succeeded"
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("wake-cursor.sh"))] | length' "$H")" "0" "our entry is gone"
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("orca/agent-hooks"))] | length' "$H")" "1" "Orca's hook is still intact"
bash "$AD" verify "$DIST" "$H"; assert_rc $? 1 "verify reports the entry is gone"

# A missing file is created fresh and valid, no crash
H2="$VIZIER_TEST_TMP/fresh.json"
bash "$AD" install "$DIST" "$H2"; assert_rc $? 0 "a new file is created"
assert_eq "$(jq -r '.version' "$H2")" "1" "the new file has version 1"

# Broken JSON must be REFUSED, absolutely never overwritten
printf 'not json at all' > "$VIZIER_TEST_TMP/broken.json"
out=$(bash "$AD" install "$DIST" "$VIZIER_TEST_TMP/broken.json" 2>&1); rc=$?
assert_rc "$rc" 1 "broken JSON gives rc 1"
assert_contains "$out" "refus" "clearly states this is a refusal"
assert_eq "$(cat "$VIZIER_TEST_TMP/broken.json")" "not json at all" "the broken file is untouched"

# .hooks.stop as an object must be REFUSED, never coerced into an array
HOBJ="$VIZIER_TEST_TMP/objstop.json"
printf '%s\n' '{"version":1,"hooks":{"stop":{"a":{"type":"command","command":"x"}}}}' > "$HOBJ"
before=$(cat "$HOBJ")
out=$(bash "$AD" install "$DIST" "$HOBJ" 2>&1); rc=$?
assert_rc "$rc" 1 "hooks.stop as an object gives rc 1"
assert_contains "$out" "refused" "clearly states this is a refusal"
assert_eq "$(cat "$HOBJ")" "$before" "the object-stop file is untouched"

# A foreign entry whose .command is not a string is still KEPT, and does not break the install
HNUM="$VIZIER_TEST_TMP/numcmd.json"
printf '%s\n' '{"version":1,"hooks":{"stop":[{"type":"command","command":123}]}}' > "$HNUM"
bash "$AD" install "$DIST" "$HNUM" >/dev/null 2>&1; assert_rc $? 0 "a numeric .command entry does not block the install"
assert_eq "$(jq '[.hooks.stop[] | select((.command|type)=="number")] | length' "$HNUM")" "1" "the foreign entry remains"
assert_eq "$(jq --arg m wake-cursor.sh '[.hooks.stop[] | select((.command|type)=="string" and (.command|contains($m)))] | length' "$HNUM")" "1" "our entry was added"

# Three installs in a row must leave THREE distinct backups, not overwrite each other
rm -rf "$VIZIER_HOME/backups"
bash "$AD" install "$DIST" "$H" >/dev/null 2>&1
bash "$AD" install "$DIST" "$H" >/dev/null 2>&1
bash "$AD" install "$DIST" "$H" >/dev/null 2>&1
assert_eq "$(ls "$VIZIER_HOME/backups" | wc -l | tr -d ' ')" "3" "three installs leave three separate backups"

# verify checks the shape, not just a count: an entry with the wrong timeout must FAIL
bash "$AD" verify "$DIST" "$H"; assert_rc $? 0 "verify passes with a correct entry"
jq '(.hooks.stop[] | select(.command | contains("wake-cursor.sh")) | .timeout) = 60' "$H" > "$H.t" && mv "$H.t" "$H"
bash "$AD" verify "$DIST" "$H"; assert_rc $? 1 "verify fails when the timeout is wrong"

# Target is a symlink: write through the link, don't replace the symlink itself
HREAL="$VIZIER_TEST_TMP/real-hooks.json"; HLINK="$VIZIER_TEST_TMP/link-hooks.json"
printf '%s\n' '{"version":1,"hooks":{}}' > "$HREAL"; ln -sf "$HREAL" "$HLINK"
bash "$AD" install "$DIST" "$HLINK" >/dev/null 2>&1
[ -L "$HLINK" ]; assert_rc $? 0 "the symlink is still a symlink after install"
assert_eq "$(jq --arg m wake-cursor.sh '[.hooks.stop[] | select(.command|contains($m))] | length' "$HREAL")" "1" "content was written to the real file through the link"

# Two-level symlink chain: write through to the final real file, both links preserved
R2="$VIZIER_TEST_TMP/chain-real.json"; L1="$VIZIER_TEST_TMP/chain-1.json"; L2="$VIZIER_TEST_TMP/chain-2.json"
printf '%s\n' '{"version":1,"hooks":{}}' > "$R2"; ln -sf "$R2" "$L1"; ln -sf "$L1" "$L2"
bash "$AD" install "$DIST" "$L2" >/dev/null 2>&1; assert_rc $? 0 "install through a two-link chain"
[ -L "$L2" ] && [ -L "$L1" ]; assert_rc $? 0 "both links are still links"
assert_eq "$(jq --arg m wake-cursor.sh '[.hooks.stop[] | select((.command|type)=="string" and (.command|contains($m)))] | length' "$R2")" "1" "content reached the real file at the end of the chain"

# FIX 3 -- the read-back-after-retry gate USED TO BE A TAUTOLOGY: it called
# `vizier_no_lost_update "$(_count_others "$H")" "$(_count_others "$H")" ...`,
# both reads of the SAME file RIGHT AFTER the retry had just finished
# writing, so they always produced the same number -- that gate could never
# detect a lost update on the RETRY PASS, no matter what actually happened.
# A real file race itself can't be reproduced in a unit test (noted below),
# but we can simulate it DETERMINISTICALLY by replacing `mv` on PATH: every
# time `_merge_ours` calls exactly `mv "$tmp" "$H"`, after the real mv
# finishes, the wrapper INSERTS an extra foreign entry into $H -- exactly
# like another process `mv`-ing over it right after us. No wall-clock wait
# needed at all, since everything is sequential within the same function call.
AD_MV_DIR="$VIZIER_TEST_TMP/mvshadow"; mkdir -p "$AD_MV_DIR"
HRACE="$VIZIER_TEST_TMP/race-hooks.json"
cat > "$HRACE" <<'JSON'
{"version":1,"hooks":{"stop":[{"type":"command","command":"/Users/x/.orca/agent-hooks/cursor-hook.sh","timeout":10}]}}
JSON
cat > "$AD_MV_DIR/mv" <<'SH'
#!/usr/bin/env bash
set -u
target="${VIZIER_TEST_MV_TARGET:-}"
match=0
if [ "$#" -eq 2 ] && [ -n "$target" ] && [ "$2" = "$target" ]; then
  case "$1" in *.vizier.*) match=1 ;; esac
fi
if [ "$match" != 1 ]; then exec /bin/mv "$@"; fi
n_file="${VIZIER_TEST_MV_STATE:?}"
n=$(( $(cat "$n_file" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" > "$n_file"
/bin/mv "$1" "$2"
# The "other writer" mv-ing over it RIGHT AFTER us: adds a foreign entry, distinguished by n.
t=$(mktemp "$2.race.XXXXXX")
jq --arg cmd "race-writer-$n" '.hooks.stop += [{type:"command",command:$cmd,timeout:10}]' "$2" > "$t" \
  && /bin/mv "$t" "$2"
exit 0
SH
chmod +x "$AD_MV_DIR/mv"
export VIZIER_TEST_MV_TARGET="$HRACE"
export VIZIER_TEST_MV_STATE="$VIZIER_TEST_TMP/mv-race-n"
rm -f "$VIZIER_TEST_MV_STATE"
out=$(PATH="$AD_MV_DIR:$PATH" bash "$AD" install "$DIST" "$HRACE" 2>&1); rc=$?
assert_rc "$rc" 1 "FIX 3: a REAL race happening again on the retry is DETECTED and refused"
assert_contains "$out" "refused" "clearly states this is a refusal"
assert_eq "$(cat "$VIZIER_TEST_MV_STATE")" "2" "both the first merge and the retry ran (the retry was actually triggered)"
# The OLD (tautological) gate would never reach this refused branch: it
# always compared `_count_others "$H"` against itself AFTER race-writer-2
# had already finished writing, so it always saw a "match" and reported a
# successful install -- exactly the bug FIX 3 fixes.
unset VIZIER_TEST_MV_TARGET VIZIER_TEST_MV_STATE

# The lost-update decision rule, checked with pre-built numbers. The race
# itself can't be reproduced in a unit test, but the RULE must be checkable.
. "$VIZIER_TEST_REPO/lib/vizier-merge-lib.sh"
vizier_no_lost_update 3 3 1; assert_rc $? 0 "no mismatch, ours is exactly one -> ok"
vizier_no_lost_update 3 4 1; assert_rc $? 1 "the other party's entries increased -> mismatch"
vizier_no_lost_update 3 2 1; assert_rc $? 1 "the other party's entries decreased -> mismatch"
vizier_no_lost_update 3 3 0; assert_rc $? 1 "ours disappeared -> mismatch"
vizier_no_lost_update 3 3 2; assert_rc $? 1 "ours doubled -> mismatch"
vizier_no_lost_update 3 "" 1; assert_rc $? 1 "an empty count counts as a mismatch, not as equal"
vizier_no_lost_update "" "" 1; assert_rc $? 1 "both empty still counts as a mismatch"

vizier_test_teardown
vizier_test_report
