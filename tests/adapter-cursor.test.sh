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

bash "$AD" verify "$DIST" "$H"; assert_rc $? 0 "verify thấy entry của ta"

# uninstall gỡ đúng entry của ta và trả file về y như cũ
bash "$AD" uninstall "$H"; assert_rc $? 0 "uninstall thành công"
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("wake-cursor.sh"))] | length' "$H")" "0" "entry của ta đã biến mất"
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("orca/agent-hooks"))] | length' "$H")" "1" "hook Orca còn nguyên"
bash "$AD" verify "$DIST" "$H"; assert_rc $? 1 "verify báo không còn entry"

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

# .hooks.stop dạng object phải bị TỪ CHỐI, không được ép thành mảng
HOBJ="$OFM_TEST_TMP/objstop.json"
printf '%s\n' '{"version":1,"hooks":{"stop":{"a":{"type":"command","command":"x"}}}}' > "$HOBJ"
before=$(cat "$HOBJ")
out=$(bash "$AD" install "$DIST" "$HOBJ" 2>&1); rc=$?
assert_rc "$rc" 1 "hooks.stop dạng object thì rc 1"
assert_contains "$out" "refused" "nói rõ là từ chối"
assert_eq "$(cat "$HOBJ")" "$before" "file object-stop không bị đụng"

# Entry lạ có .command không phải chuỗi vẫn được GIỮ, và không làm hỏng lần cài
HNUM="$OFM_TEST_TMP/numcmd.json"
printf '%s\n' '{"version":1,"hooks":{"stop":[{"type":"command","command":123}]}}' > "$HNUM"
bash "$AD" install "$DIST" "$HNUM" >/dev/null 2>&1; assert_rc $? 0 "entry .command số không chặn được lần cài"
assert_eq "$(jq '[.hooks.stop[] | select((.command|type)=="number")] | length' "$HNUM")" "1" "entry lạ còn nguyên"
assert_eq "$(jq --arg m wake-cursor.sh '[.hooks.stop[] | select((.command|type)=="string" and (.command|contains($m)))] | length' "$HNUM")" "1" "entry của ta được thêm"

# Ba lần cài liên tiếp phải để lại BA backup phân biệt, không đè nhau
rm -rf "$OFM_HOME/backups"
bash "$AD" install "$DIST" "$H" >/dev/null 2>&1
bash "$AD" install "$DIST" "$H" >/dev/null 2>&1
bash "$AD" install "$DIST" "$H" >/dev/null 2>&1
assert_eq "$(ls "$OFM_HOME/backups" | wc -l | tr -d ' ')" "3" "ba lần cài để lại ba backup riêng"

# verify kiểm hình dạng, không chỉ đếm: entry sai timeout phải TRƯỢT
bash "$AD" verify "$DIST" "$H"; assert_rc $? 0 "verify đạt với entry đúng"
jq '(.hooks.stop[] | select(.command | contains("wake-cursor.sh")) | .timeout) = 60' "$H" > "$H.t" && mv "$H.t" "$H"
bash "$AD" verify "$DIST" "$H"; assert_rc $? 1 "verify trượt khi timeout sai"

# Target là symlink: ghi xuyên qua link, không thay thế chính symlink
HREAL="$OFM_TEST_TMP/real-hooks.json"; HLINK="$OFM_TEST_TMP/link-hooks.json"
printf '%s\n' '{"version":1,"hooks":{}}' > "$HREAL"; ln -sf "$HREAL" "$HLINK"
bash "$AD" install "$DIST" "$HLINK" >/dev/null 2>&1
[ -L "$HLINK" ]; assert_rc $? 0 "symlink vẫn là symlink sau khi cài"
assert_eq "$(jq --arg m wake-cursor.sh '[.hooks.stop[] | select(.command|contains($m))] | length' "$HREAL")" "1" "nội dung ghi vào file thật sau link"

# Chuỗi symlink hai tầng: ghi xuyên tới file thật cuối cùng, giữ nguyên cả hai link
R2="$OFM_TEST_TMP/chain-real.json"; L1="$OFM_TEST_TMP/chain-1.json"; L2="$OFM_TEST_TMP/chain-2.json"
printf '%s\n' '{"version":1,"hooks":{}}' > "$R2"; ln -sf "$R2" "$L1"; ln -sf "$L1" "$L2"
bash "$AD" install "$DIST" "$L2" >/dev/null 2>&1; assert_rc $? 0 "cài qua chuỗi hai link"
[ -L "$L2" ] && [ -L "$L1" ]; assert_rc $? 0 "cả hai link còn nguyên là link"
assert_eq "$(jq --arg m wake-cursor.sh '[.hooks.stop[] | select((.command|type)=="string" and (.command|contains($m)))] | length' "$R2")" "1" "nội dung tới đúng file thật cuối chuỗi"

ofm_test_teardown
ofm_test_report
