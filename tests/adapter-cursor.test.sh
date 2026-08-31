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

# FIX 3 — cổng đọc-lại-sau-retry TRƯỚC ĐÂY LÀ TAUTOLOGY: nó gọi
# `ofm_no_lost_update "$(_count_others "$H")" "$(_count_others "$H")" …`, hai
# lần đọc CÙNG một file NGAY SAU KHI retry vừa ghi xong, nên luôn ra cùng một
# số — cổng đó không bao giờ có thể phát hiện lost update ở LẦN RETRY, bất kể
# chuyện gì thật sự xảy ra. Bản thân một cuộc đua file thật không dựng lại
# được trong unit test (đã ghi ở dưới), nhưng ta có thể mô phỏng NÓ MỘT CÁCH
# TẤT ĐỊNH bằng cách thay `mv` trên PATH: mỗi lần `_merge_ours` gọi đúng
# `mv "$tmp" "$H"`, sau khi mv thật chạy xong, wrapper CHÈN THÊM một entry lạ
# vào $H — y hệt một tiến trình khác vừa `mv` đè lên ngay sau ta. Không cần
# đợi wall-clock nào cả vì mọi thứ tuần tự trong cùng một lời gọi hàm.
AD_MV_DIR="$OFM_TEST_TMP/mvshadow"; mkdir -p "$AD_MV_DIR"
HRACE="$OFM_TEST_TMP/race-hooks.json"
cat > "$HRACE" <<'JSON'
{"version":1,"hooks":{"stop":[{"type":"command","command":"/Users/x/.orca/agent-hooks/cursor-hook.sh","timeout":10}]}}
JSON
cat > "$AD_MV_DIR/mv" <<'SH'
#!/usr/bin/env bash
set -u
target="${OFM_TEST_MV_TARGET:-}"
match=0
if [ "$#" -eq 2 ] && [ -n "$target" ] && [ "$2" = "$target" ]; then
  case "$1" in *.ofm.*) match=1 ;; esac
fi
if [ "$match" != 1 ]; then exec /bin/mv "$@"; fi
n_file="${OFM_TEST_MV_STATE:?}"
n=$(( $(cat "$n_file" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" > "$n_file"
/bin/mv "$1" "$2"
# "Writer khác" mv đè lên NGAY SAU ta: thêm một entry lạ, phân biệt theo n.
t=$(mktemp "$2.race.XXXXXX")
jq --arg cmd "race-writer-$n" '.hooks.stop += [{type:"command",command:$cmd,timeout:10}]' "$2" > "$t" \
  && /bin/mv "$t" "$2"
exit 0
SH
chmod +x "$AD_MV_DIR/mv"
export OFM_TEST_MV_TARGET="$HRACE"
export OFM_TEST_MV_STATE="$OFM_TEST_TMP/mv-race-n"
rm -f "$OFM_TEST_MV_STATE"
out=$(PATH="$AD_MV_DIR:$PATH" bash "$AD" install "$DIST" "$HRACE" 2>&1); rc=$?
assert_rc "$rc" 1 "FIX 3: một race THẬT xảy ra lại ở retry thì bị PHÁT HIỆN và từ chối"
assert_contains "$out" "refused" "nói rõ là từ chối"
assert_eq "$(cat "$OFM_TEST_MV_STATE")" "2" "cả merge đầu lẫn retry đều chạy (retry thật sự được kích hoạt)"
# Cổng CŨ (tautology) sẽ không bao giờ vào được nhánh refused này: nó luôn tự
# so `_count_others "$H"` với chính nó SAU KHI race-writer-2 đã ghi xong, nên
# luôn thấy "khớp" và báo cài thành công — đúng bug mà FIX 3 sửa.
unset OFM_TEST_MV_TARGET OFM_TEST_MV_STATE

# Luật quyết định mất-bản-cập-nhật, kiểm bằng số dựng sẵn. Bản thân cuộc đua
# không tái hiện được trong unit test, nhưng LUẬT thì phải kiểm được.
. "$OFM_TEST_REPO/lib/ofm-merge-lib.sh"
ofm_no_lost_update 3 3 1; assert_rc $? 0 "không lệch, của ta đúng một -> ok"
ofm_no_lost_update 3 4 1; assert_rc $? 1 "entry người khác tăng -> lệch"
ofm_no_lost_update 3 2 1; assert_rc $? 1 "entry người khác giảm -> lệch"
ofm_no_lost_update 3 3 0; assert_rc $? 1 "của ta biến mất -> lệch"
ofm_no_lost_update 3 3 2; assert_rc $? 1 "của ta nhân đôi -> lệch"
ofm_no_lost_update 3 "" 1; assert_rc $? 1 "phép đếm rỗng tính là lệch, không phải bằng nhau"
ofm_no_lost_update "" "" 1; assert_rc $? 1 "cả hai rỗng vẫn tính là lệch"

ofm_test_teardown
ofm_test_report
