#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
ofm_test_setup
AD="$OFM_TEST_REPO/bin/ofm-adapter-claude.sh"
DIST="$OFM_TEST_TMP/dist"; TARGET="$OFM_TEST_TMP/claude-skills"
mkdir -p "$DIST/hooks" "$DIST/lib" "$DIST/skills/identity" "$DIST/commands" "$DIST/.claude-plugin"
cp "$OFM_TEST_REPO/hooks/hooks.json" "$DIST/hooks/"
cp "$OFM_TEST_REPO/.claude-plugin/plugin.json" "$DIST/.claude-plugin/"
printf 'x\n' > "$DIST/hooks/wake-claude.sh"

bash "$AD" install "$DIST" "$TARGET"; assert_rc $? 0 "install succeeded"
[ -f "$TARGET/orca-firstmate/hooks/hooks.json" ]; assert_rc $? 0 "hooks.json copied"
[ -f "$TARGET/orca-firstmate/.claude-plugin/plugin.json" ]; assert_rc $? 0 "manifest copied"

# hooks.json must declare exactly the two verified constants
hooks="$TARGET/orca-firstmate/hooks/hooks.json"
assert_eq "$(jq -r '.hooks.Stop[0].hooks[0].asyncRewake' "$hooks")" "true" "asyncRewake is on"
assert_eq "$(jq -r '.hooks.Stop[0].hooks[0].timeout' "$hooks")" "28800" "timeout is 28800"
assert_contains "$(jq -r '.hooks.Stop[0].hooks[0].command' "$hooks")" "CLAUDE_PLUGIN_ROOT" "uses CLAUDE_PLUGIN_ROOT"
assert_contains "$(jq -r '.hooks.PostCompact[0].hooks[0].command' "$hooks")" "reidentify-claude.sh" "has PostCompact"

# running install again is idempotent, no duplication
bash "$AD" install "$DIST" "$TARGET"; assert_rc $? 0 "second install still ok"
assert_eq "$(jq '.hooks.Stop[0].hooks | length' "$hooks")" "1" "hook is not duplicated"

# uninstall removes the whole plugin directory
bash "$AD" uninstall "$TARGET"; assert_rc $? 0 "uninstall succeeded"
[ -d "$TARGET/orca-firstmate" ]; assert_rc $? 1 "plugin directory is gone"

ofm_test_teardown
ofm_test_report
