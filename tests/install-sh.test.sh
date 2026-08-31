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
# `github.com` một mình KHÔNG phân biệt được: chuỗi SSH `git@github.com:...`
# cũng chứa nó. Phải bắt đúng dấu hiệu của dạng SSH.
case "$default_url" in *git@*) assert_eq "ssh" "https" "mặc định KHÔNG được là dạng SSH" ;; esac

# Đích trên PATH đã là THƯ MỤC: phải TỪ CHỐI, không được báo thành công
export OFM_REPO_URL="file://$ORIGIN"
rm -rf "$OFM_HOME/src" "$OFM_BIN_DIR/orca-firstmate"
mkdir -p "$OFM_BIN_DIR/orca-firstmate"
out=$(sh "$OFM_TEST_REPO/install.sh" 2>&1); rc=$?
assert_rc "$rc" 1 "đích là thư mục thì rc 1"
assert_contains "$out" "không phải symlink" "nói rõ lý do"
rmdir "$OFM_BIN_DIR/orca-firstmate"

# FIX 10 (ca đã tái hiện) — Đích trên PATH là một SYMLINK TRỎ TỚI MỘT THƯ MỤC
# (khác ca trên: ở đây $LINK VẪN LÀ symlink, chỉ đích của nó là thư mục nên
# guard `[ ! -L ]` không nổ). Guard cũ + `ln -sf` (không `-n`) sẽ tạo link MỚI
# NẰM BÊN TRONG thư mục đó, để lại symlink GỐC trỏ sai chỗ, mà hậu-kiểm cũ
# `[ -L "$LINK" ]` vẫn pass — báo "đã cài" trong khi PATH không chạy được.
rm -rf "$OFM_HOME/src" "$OFM_BIN_DIR/orca-firstmate"
mkdir -p "$OFM_TEST_TMP/old-target-dir"
ln -sf "$OFM_TEST_TMP/old-target-dir" "$OFM_BIN_DIR/orca-firstmate"
out=$(sh "$OFM_TEST_REPO/install.sh" 2>&1); rc=$?
assert_rc "$rc" 0 "FIX 10: symlink-tới-thư-mục vẫn cài thành công (ln -sfn thay thế đúng)"
[ -L "$OFM_BIN_DIR/orca-firstmate" ]; assert_rc $? 0 "vẫn là symlink sau khi cài"
assert_eq "$(readlink "$OFM_BIN_DIR/orca-firstmate")" "$OFM_HOME/src/bin/orca-firstmate" \
  "FIX 10: symlink trỏ ĐÚNG ĐÍCH mới, không nằm lọt vào bên trong thư mục cũ"
assert_eq "$("$OFM_BIN_DIR/orca-firstmate")" "stub-v2" "FIX 10: CLI chạy được qua symlink đã thay thế"
[ -d "$OFM_TEST_TMP/old-target-dir" ]; assert_rc $? 0 "thư mục cũ không bị xoá, chỉ symlink bị thay thế"
[ -e "$OFM_TEST_TMP/old-target-dir/orca-firstmate" ]; assert_rc $? 1 \
  "FIX 10: KHÔNG có link lạc bên trong thư mục cũ (đúng ca bug cũ tạo ra)"

# $SRC tồn tại nhưng không phải git repo: báo rõ và đưa lệnh xoá
rm -rf "$OFM_HOME/src"; mkdir -p "$OFM_HOME/src"; printf 'junk\n' > "$OFM_HOME/src/junk"
out=$(sh "$OFM_TEST_REPO/install.sh" 2>&1); rc=$?
assert_rc "$rc" 1 "src không phải git repo thì rc 1"
assert_contains "$out" "rm -rf" "in lệnh xoá cho captain"
rm -rf "$OFM_HOME/src"

# Xoá ref cục bộ `refs/remotes/origin/HEAD` rồi chạy lại: đường cập nhật vẫn
# phải chạy trơn.
#
# ĐÂY LÀ TẤT CẢ NHỮNG GÌ CA NÀY CHỨNG MINH. Nó KHÔNG chứng minh dòng
# `remote set-head` là cần thiết: đã đo trực tiếp bằng cách bỏ dòng đó ra và
# suite vẫn xanh, vì môi trường clone `file://` không dựng được tình trạng
# thiếu origin/HEAD thật. Dòng đó giữ lại như phòng thủ, dựa trên việc reviewer
# tái hiện được trạng thái kẹt trên một bare repo bị xoá HEAD. Đặt tên assertion
# đúng bằng điều nó đo, thay vì để một cái tên hứa nhiều hơn sự thật — dự án này
# đã có năm test xanh trong khi đo nhầm thứ.
sh "$OFM_TEST_REPO/install.sh" >/dev/null 2>&1
git -C "$OFM_HOME/src" symbolic-ref --delete refs/remotes/origin/HEAD 2>/dev/null || true
sh "$OFM_TEST_REPO/install.sh" >/dev/null 2>&1
assert_rc $? 0 "chạy lại sau khi xoá ref origin/HEAD cục bộ vẫn cập nhật được"

# URL hỏng thì fail rõ ràng, không để lại symlink chết
export OFM_REPO_URL="file://$OFM_TEST_TMP/does-not-exist.git"
rm -rf "$OFM_HOME/src" "$OFM_BIN_DIR/orca-firstmate"
out=$(sh "$OFM_TEST_REPO/install.sh" 2>&1); rc=$?
assert_rc "$rc" 1 "URL hỏng thì rc 1"
[ -L "$OFM_BIN_DIR/orca-firstmate" ]; assert_rc $? 1 "thất bại thì không để lại symlink chết"

ofm_test_teardown
ofm_test_report
