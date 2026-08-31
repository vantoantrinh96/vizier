#!/usr/bin/env sh
# Bootstrap orca-firstmate.
#
#   curl -fsSL <RAW_URL>/install.sh | sh
#
# Chỉ làm hai việc: lấy source về $OFM_HOME/src và đặt một symlink lên PATH.
# CỐ TÌNH KHÔNG chạy `orca-firstmate install`: bước đó sửa cấu hình harness của
# captain (với Cursor là ~/.cursor/hooks.json, file Orca cũng dùng), nên nó
# phải là một quyết định tường minh, không phải hệ quả của `curl | sh`.
#
# POSIX sh, không bashism: nó chạy qua `sh` của người dùng, không phải bash.
set -eu

# Repo public trên GitHub, nên clone và curl đều không cần auth.
# OWNER lấy từ `git remote get-url origin` ở Step 0; không để nguyên chuỗi này.
REPO_URL="${OFM_REPO_URL:-https://github.com/vantoantrinh96/orca-firstmate.git}"

HOME_DIR="${OFM_HOME:-$HOME/.orca-firstmate}"
SRC="$HOME_DIR/src"
BIN_DIR="${OFM_BIN_DIR:-$HOME/.local/bin}"

for t in git jq; do
  command -v "$t" >/dev/null 2>&1 || { echo "error: cần $t (brew install $t)" >&2; exit 1; }
done

mkdir -p "$HOME_DIR"
if [ -d "$SRC/.git" ]; then
  git -C "$SRC" fetch --quiet origin || { echo "error: fetch thất bại từ $REPO_URL" >&2; exit 1; }
  # reset --hard: $SRC do tool sở hữu, không phải chỗ để sửa tay. Sửa tay ở đó
  # bị ghi đè có chủ đích, thay vì làm bootstrap kẹt mãi.
  git -C "$SRC" reset --quiet --hard origin/HEAD || { echo "error: reset thất bại" >&2; exit 1; }
else
  git clone --quiet "$REPO_URL" "$SRC" || { echo "error: clone thất bại từ $REPO_URL" >&2; exit 1; }
fi

[ -x "$SRC/bin/orca-firstmate" ] || { echo "error: source thiếu bin/orca-firstmate" >&2; exit 1; }
mkdir -p "$BIN_DIR"
ln -sf "$SRC/bin/orca-firstmate" "$BIN_DIR/orca-firstmate"

echo "đã cài orca-firstmate -> $BIN_DIR/orca-firstmate"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "lưu ý: $BIN_DIR chưa nằm trong PATH; thêm nó vào shell profile" ;;
esac
echo
echo "tiếp theo:"
echo "  orca-firstmate doctor     # kiểm Orca, jq, git, gh"
echo "  orca-firstmate install    # cài vào harness (sẽ sửa cấu hình harness)"
