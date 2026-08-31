#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
ofm_test_setup
AD="$OFM_TEST_REPO/bin/ofm-adapter-cursor.sh"
DIST="$OFM_TEST_TMP/dist"; mkdir -p "$DIST/hooks"; printf 'x\n' > "$DIST/hooks/wake-cursor.sh"
H="$OFM_TEST_TMP/cursor-hooks.json"

# Bắt chước file thật của captain: Orca đã có entry ở đây từ trước.
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

bash "$AD" install "$DIST" "$H"; assert_rc $? 0 "install thành công"

# Entry của người khác phải còn nguyên vẹn, từng cái một
assert_eq "$(jq -r '.hooks.preToolUse | length' "$H")" "1" "giữ nguyên preToolUse"
assert_eq "$(jq -r '.hooks.afterAgentResponse[0].command' "$H")" "/Users/x/.orca/agent-hooks/cursor-hook.sh" "giữ nguyên hook Orca"
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("orca/agent-hooks"))] | length' "$H")" "1" "giữ nguyên stop hook của Orca"
assert_eq "$(jq -r '.version' "$H")" "1" "giữ nguyên version"

# Entry của ta đúng hằng số đã kiểm chứng
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("wake-cursor.sh"))] | length' "$H")" "1" "thêm đúng một entry"
assert_eq "$(jq -r '.hooks.stop[] | select(.command | contains("wake-cursor.sh")) | .loop_limit' "$H")" "200" "loop_limit 200"
assert_eq "$(jq -r '.hooks.stop[] | select(.command | contains("wake-cursor.sh")) | .timeout' "$H")" "28800" "timeout 28800"

# Có sao lưu trước khi ghi
ls "$OFM_HOME"/backups/cursor-hooks.*.json >/dev/null 2>&1; assert_rc $? 0 "có file sao lưu"

# Idempotent: chạy ba lần vẫn đúng một entry
bash "$AD" install "$DIST" "$H" >/dev/null
bash "$AD" install "$DIST" "$H" >/dev/null
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("wake-cursor.sh"))] | length' "$H")" "1" "chạy lại không nhân bản"
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("orca/agent-hooks"))] | length' "$H")" "1" "chạy lại không nhân bản của người khác"

bash "$AD" verify "$H"; assert_rc $? 0 "verify thấy entry của ta"

# uninstall gỡ đúng entry của ta và trả file về y như cũ
bash "$AD" uninstall "$H"; assert_rc $? 0 "uninstall thành công"
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("wake-cursor.sh"))] | length' "$H")" "0" "entry của ta đã biến mất"
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("orca/agent-hooks"))] | length' "$H")" "1" "hook Orca còn nguyên"
bash "$AD" verify "$H"; assert_rc $? 1 "verify báo không còn entry"

# File thiếu thì tạo mới hợp lệ, không nổ
H2="$OFM_TEST_TMP/fresh.json"
bash "$AD" install "$DIST" "$H2"; assert_rc $? 0 "tạo được file mới"
assert_eq "$(jq -r '.version' "$H2")" "1" "file mới có version 1"

# JSON hỏng thì TỪ CHỐI, tuyệt đối không ghi đè
printf 'not json at all' > "$OFM_TEST_TMP/broken.json"
out=$(bash "$AD" install "$DIST" "$OFM_TEST_TMP/broken.json" 2>&1); rc=$?
assert_rc "$rc" 1 "JSON hỏng thì rc 1"
assert_contains "$out" "refus" "nói rõ là từ chối"
assert_eq "$(cat "$OFM_TEST_TMP/broken.json")" "not json at all" "file hỏng không bị đụng tới"

ofm_test_teardown
ofm_test_report
