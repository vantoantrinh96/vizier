#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
ofm_test_setup

# Bare repo local đóng vai remote: test chạy offline, không phụ thuộc repo đã publish.
ORIGIN="$OFM_TEST_TMP/origin.git"
WORK="$OFM_TEST_TMP/work"
git init --quiet --bare "$ORIGIN"
git clone --quiet "$ORIGIN" "$WORK"
mkdir -p "$WORK/bin"
printf '#!/usr/bin/env bash\necho stub-cli\n' > "$WORK/bin/orca-firstmate"
chmod +x "$WORK/bin/orca-firstmate"
cp "$OFM_TEST_REPO/install.sh" "$WORK/install.sh"
git -C "$WORK" add -A
git -C "$WORK" -c user.email=t@t -c user.name=t commit --quiet -m init
git -C "$WORK" push --quiet origin HEAD:refs/heads/main
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main

export OFM_REPO_URL="file://$ORIGIN"
export OFM_BIN_DIR="$OFM_TEST_TMP/bin"

out=$(sh "$OFM_TEST_REPO/install.sh" 2>&1); rc=$?
assert_rc "$rc" 0 "bootstrap thành công"
[ -d "$OFM_HOME/src/.git" ]; assert_rc $? 0 "clone vào src/"
[ -L "$OFM_BIN_DIR/orca-firstmate" ]; assert_rc $? 0 "tạo symlink"
assert_eq "$("$OFM_BIN_DIR/orca-firstmate")" "stub-cli" "symlink chạy đúng CLI"
assert_contains "$out" "orca-firstmate install" "in bước tiếp theo"

# KHÔNG được tự cài vào harness: đó là quyết định riêng, có sửa file của người khác
assert_eq "$(ls "$OFM_HOME/dist" 2>/dev/null)" "" "bootstrap không tự chạy install"

# Chạy lại là cập nhật, không hỏng
printf '#!/usr/bin/env bash\necho stub-v2\n' > "$WORK/bin/orca-firstmate"
git -C "$WORK" -c user.email=t@t -c user.name=t commit --quiet -am v2
git -C "$WORK" push --quiet origin HEAD:refs/heads/main
sh "$OFM_TEST_REPO/install.sh" >/dev/null 2>&1; assert_rc $? 0 "chạy lại thành công"
assert_eq "$("$OFM_BIN_DIR/orca-firstmate")" "stub-v2" "chạy lại thì cập nhật lên bản mới"

# Thay đổi local trong src bị ghi đè, không làm bootstrap kẹt
printf 'rác\n' > "$OFM_HOME/src/bin/orca-firstmate"
sh "$OFM_TEST_REPO/install.sh" >/dev/null 2>&1; assert_rc $? 0 "src bẩn vẫn cập nhật được"
assert_eq "$("$OFM_BIN_DIR/orca-firstmate")" "stub-v2" "src bẩn được khôi phục"

# Mặc định phải là URL thật, không phải placeholder. Test này là thứ bắt lỗi
# "quên điền" thay vì để nó trôi tới máy người dùng.
grep -q 'OWNER_PLACEHOLDER' "$OFM_TEST_REPO/install.sh"; assert_rc $? 1 "không còn placeholder owner"
default_url=$(sed -n 's/^REPO_URL="\${OFM_REPO_URL:-\(.*\)}"$/\1/p' "$OFM_TEST_REPO/install.sh")
assert_contains "$default_url" "github.com" "mặc định trỏ tới GitHub"
assert_contains "$default_url" "orca-firstmate" "mặc định trỏ đúng repo"

# URL hỏng thì fail rõ ràng, không để lại symlink chết
export OFM_REPO_URL="file://$OFM_TEST_TMP/does-not-exist.git"
rm -rf "$OFM_HOME/src" "$OFM_BIN_DIR/orca-firstmate"
out=$(sh "$OFM_TEST_REPO/install.sh" 2>&1); rc=$?
assert_rc "$rc" 1 "URL hỏng thì rc 1"
[ -L "$OFM_BIN_DIR/orca-firstmate" ]; assert_rc $? 1 "thất bại thì không để lại symlink chết"

ofm_test_teardown
ofm_test_report
