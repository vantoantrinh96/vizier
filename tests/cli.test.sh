#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
ofm_test_setup
CLI="$OFM_TEST_REPO/bin/orca-firstmate"
# `gh auth status` chạm keychain thật, nên test sẽ xanh/đỏ tuỳ máy. Bỏ qua đúng
# phép kiểm đó; doctor thật vẫn kiểm đầy đủ.
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
# Ca này từng để lọt một lỗi xoá nhầm thư mục: $0 là symlink nên dirname "$0"
# không phải nơi script nằm, lib không source được, và guard trỏ vào thư mục
# hiện hành của người gọi.
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

ofm_test_teardown
ofm_test_report
