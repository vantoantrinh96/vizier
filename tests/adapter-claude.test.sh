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

bash "$AD" install "$DIST" "$TARGET"; assert_rc $? 0 "install thành công"
[ -f "$TARGET/orca-firstmate/hooks/hooks.json" ]; assert_rc $? 0 "chép hooks.json"
[ -f "$TARGET/orca-firstmate/.claude-plugin/plugin.json" ]; assert_rc $? 0 "chép manifest"

# hooks.json phải khai đúng hai hằng số đã kiểm chứng
hooks="$TARGET/orca-firstmate/hooks/hooks.json"
assert_eq "$(jq -r '.hooks.Stop[0].hooks[0].asyncRewake' "$hooks")" "true" "asyncRewake bật"
assert_eq "$(jq -r '.hooks.Stop[0].hooks[0].timeout' "$hooks")" "28800" "timeout 28800"
assert_contains "$(jq -r '.hooks.Stop[0].hooks[0].command' "$hooks")" "CLAUDE_PLUGIN_ROOT" "dùng CLAUDE_PLUGIN_ROOT"
assert_contains "$(jq -r '.hooks.PostCompact[0].hooks[0].command' "$hooks")" "reidentify-claude.sh" "có PostCompact"

# install chạy lại là idempotent, không nhân bản
bash "$AD" install "$DIST" "$TARGET"; assert_rc $? 0 "install lần hai vẫn ok"
assert_eq "$(jq '.hooks.Stop[0].hooks | length' "$hooks")" "1" "không nhân bản hook"

# uninstall xoá sạch thư mục plugin
bash "$AD" uninstall "$TARGET"; assert_rc $? 0 "uninstall thành công"
[ -d "$TARGET/orca-firstmate" ]; assert_rc $? 1 "thư mục plugin đã biến mất"

ofm_test_teardown
ofm_test_report
