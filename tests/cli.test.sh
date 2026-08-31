#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
ofm_test_setup
. "$OFM_TEST_REPO/lib/ofm-home.sh"
CLI="$OFM_TEST_REPO/bin/orca-firstmate"
export OFM_SKIP_GH_AUTH=1

# doctor sạch khi fake-orca báo ready và mọi tool đều có
out=$(bash "$CLI" doctor 2>&1); rc=$?
assert_rc "$rc" 0 "doctor sạch thì rc 0"
assert_contains "$out" "orca" "doctor nhắc tới orca"

# Orca chưa ready thì doctor fail và nói rõ cách sửa
export OFM_FAKE_ORCA_STATUS='{"ok":true,"result":{"reachable":false,"state":"starting","capabilities":[]}}'
out=$(bash "$CLI" doctor 2>&1); rc=$?
assert_rc "$rc" 1 "Orca chưa ready thì rc 1"
assert_contains "$out" "NOT_READY" "báo NOT_READY"
assert_contains "$out" "orca open" "gợi ý lệnh sửa"

# Thiếu capability bắt buộc cũng fail
export OFM_FAKE_ORCA_STATUS='{"ok":true,"result":{"reachable":true,"state":"ready","capabilities":["other.v1"]}}'
out=$(bash "$CLI" doctor 2>&1); rc=$?
assert_rc "$rc" 1 "thiếu capability thì rc 1"
assert_contains "$out" "orchestration.contract.v1" "nêu đúng capability thiếu"
unset OFM_FAKE_ORCA_STATUS

# install chép payload vào dist rồi gọi adapter
export OFM_CLAUDE_SKILLS_DIR="$OFM_TEST_TMP/claude-skills"
export OFM_CURSOR_HOOKS_JSON="$OFM_TEST_TMP/cursor-hooks.json"
out=$(bash "$CLI" install --harness claude 2>&1); rc=$?
assert_rc "$rc" 0 "install claude thành công"
[ -f "$OFM_HOME/dist/hooks/wake-claude.sh" ]; assert_rc $? 0 "payload nằm ở dist"
[ -f "$OFM_CLAUDE_SKILLS_DIR/orca-firstmate/hooks/hooks.json" ]; assert_rc $? 0 "adapter claude đã cài"

# Harness chưa hỗ trợ thì báo thẳng, không im lặng
out=$(bash "$CLI" install --harness codex 2>&1); rc=$?
assert_rc "$rc" 1 "harness lạ thì rc 1"
assert_contains "$out" "chưa hỗ trợ" "nói thẳng là chưa hỗ trợ"

# FIX 9 — install TRẦN (không --harness) không được đụng Cursor. File đích
# Cursor phải hoàn toàn không tồn tại/không bị sửa sau một install trần, kể cả
# khi cursor-agent có mặt trên máy test này.
rm -rf "$OFM_HOME/dist" "$OFM_CLAUDE_SKILLS_DIR" "$OFM_CURSOR_HOOKS_JSON"
out=$(bash "$CLI" install 2>&1); rc=$?
assert_rc "$rc" 0 "install trần thành công (chỉ cài Claude)"
[ -f "$OFM_CLAUDE_SKILLS_DIR/orca-firstmate/hooks/hooks.json" ]; assert_rc $? 0 "install trần vẫn cài Claude"
[ -e "$OFM_CURSOR_HOOKS_JSON" ]; assert_rc $? 1 "FIX 9: install trần KHÔNG đụng tới file đích Cursor"
assert_contains "$out" "bỏ qua Cursor" "install trần nói rõ đã bỏ qua Cursor và cách xin cài nó"

# uninstall giữ nguyên state
mkdir -p "$OFM_HOME/requests"; printf 'x\n' > "$OFM_HOME/requests/keep.md"
bash "$CLI" uninstall >/dev/null 2>&1
[ -f "$OFM_HOME/requests/keep.md" ]; assert_rc $? 0 "uninstall KHÔNG xoá requests"
[ -d "$OFM_CLAUDE_SKILLS_DIR/orca-firstmate" ]; assert_rc $? 1 "uninstall gỡ adapter"

# uninstall phải dọn cả dấu vết của bootstrap
export OFM_BIN_DIR="$OFM_TEST_TMP/bin"; mkdir -p "$OFM_BIN_DIR" "$OFM_HOME/src"
ln -sf /usr/bin/true "$OFM_BIN_DIR/orca-firstmate"
bash "$CLI" uninstall >/dev/null 2>&1
[ -L "$OFM_BIN_DIR/orca-firstmate" ]; assert_rc $? 1 "uninstall gỡ symlink trên PATH"
[ -d "$OFM_HOME/src" ]; assert_rc $? 1 "uninstall gỡ clone src khi không chạy từ đó"

# install TỪ TRONG bản đã cài phải bị từ chối, không được tự huỷ
bash "$CLI" install --harness claude >/dev/null 2>&1
out=$(bash "$OFM_HOME/dist/bin/orca-firstmate" install --harness claude 2>&1); rc=$?
assert_rc "$rc" 1 "install từ trong dist bị từ chối"
assert_contains "$out" "refused" "nói rõ là từ chối"
[ -f "$OFM_HOME/dist/bin/orca-firstmate" ]; assert_rc $? 0 "dist không bị xoá sau lần từ chối"

# uninstall chạy TỪ TRONG src thì không xoá src, chỉ in lệnh
mkdir -p "$OFM_HOME/src/bin" "$OFM_HOME/src/lib"
cp "$OFM_TEST_REPO/bin/orca-firstmate" "$OFM_HOME/src/bin/"
cp "$OFM_TEST_REPO/lib/ofm-home.sh" "$OFM_HOME/src/lib/"
out=$(bash "$OFM_HOME/src/bin/orca-firstmate" uninstall 2>&1)
[ -d "$OFM_HOME/src" ]; assert_rc $? 0 "không tự xoá thư mục đang chạy từ đó"
assert_contains "$out" "rm -rf" "in lệnh xoá cho captain"

# Gọi qua SYMLINK — đúng cách install.sh cài CLI, và là đường gọi thật duy nhất.
LINKDIR="$OFM_TEST_TMP/pathbin"; mkdir -p "$LINKDIR"
ln -sf "$OFM_TEST_REPO/bin/orca-firstmate" "$LINKDIR/orca-firstmate"
DECOY="$OFM_TEST_TMP/decoy"; mkdir -p "$DECOY/dist" "$DECOY/src"
printf 'keep\n' > "$DECOY/dist/keep.txt"; printf 'keep\n' > "$DECOY/src/keep.txt"
( cd "$DECOY" && OFM_SKIP_GH_AUTH=1 "$LINKDIR/orca-firstmate" uninstall >/dev/null 2>&1 )
[ -f "$DECOY/dist/keep.txt" ]; assert_rc $? 0 "gọi qua symlink KHÔNG xoá dist/ của thư mục hiện hành"
[ -f "$DECOY/src/keep.txt" ]; assert_rc $? 0 "gọi qua symlink KHÔNG xoá src/ của thư mục hiện hành"
out=$( cd "$DECOY" && OFM_SKIP_GH_AUTH=1 "$LINKDIR/orca-firstmate" doctor 2>&1 ); rc=$?
assert_rc "$rc" 0 "doctor chạy được qua symlink"

# Capability phải khớp CHÍNH XÁC, không phải substring
export OFM_FAKE_ORCA_STATUS='{"ok":true,"result":{"reachable":true,"state":"ready","capabilities":["orchestration.contract.v10"]}}'
out=$(bash "$CLI" doctor 2>&1); rc=$?
assert_rc "$rc" 1 "capability v10 KHÔNG được tính là v1"
assert_contains "$out" "orchestration.contract.v1" "nêu capability còn thiếu"
unset OFM_FAKE_ORCA_STATUS

# Chuỗi symlink sâu quá trần phải BÁO LỖI, không âm thầm dùng đường dẫn giải dở
# Test: tạo ĐỦ symlink để vượt trần 16 hop mà vẫn bash được execute
# Vận dụng: nếu không có check thì sẽ source lib từ đường dẫn sai, fail với không đọc được lib
DEEP="$OFM_TEST_TMP/deep"; rm -rf "$DEEP"
mkdir -p "$DEEP"
cp "$OFM_TEST_REPO/bin/orca-firstmate" "$DEEP/script"
# Tạo symlink chain: d0/link -> script, d1/link -> ../d0/link, d2/link -> ../d1/link, ...
# Mỗi level thêm một hop để readlink phải tuần tự đi qua
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
assert_rc "$rc" 2 "chuỗi symlink quá sâu thì rc 2"
assert_contains "$out" "symlink" "nói rõ lý do là chuỗi symlink"

# FIX 4 — `unlock` là đường thoát tường minh khỏi một lock kẹt-nhưng-sống
# (CLAUDE_PID sống nhưng session id đã đổi sau /clear hoặc resume). Không cần
# tham số: in ra chủ hiện tại rồi gỡ, để captain tự gọi khi họ chắc phiên cũ
# đã xong.
printf 'session_id=sess-stuck\nharness=claude\npid=999999\nsince=1\n' > "$(ofm_lock_path)"
out=$(bash "$CLI" unlock 2>&1); rc=$?
assert_rc "$rc" 0 "unlock thành công"
assert_contains "$out" "sess-stuck" "unlock báo đúng session_id đang giữ"
assert_contains "$out" "999999" "unlock báo đúng pid đang giữ"
assert_eq "$(ofm_lock_get session_id)" "" "unlock thật sự xoá lock"
# Gọi lại khi không còn lock: không nổ, báo rõ không có gì để gỡ
out=$(bash "$CLI" unlock 2>&1); rc=$?
assert_rc "$rc" 0 "unlock khi không có lock vẫn rc 0"
assert_contains "$out" "không có lock" "nói rõ không có lock nào"

ofm_test_teardown
ofm_test_report
