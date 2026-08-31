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
#
# DÙNG HTTPS, KHÔNG DÙNG SSH. Remote của checkout là dạng SSH
# (git@github.com:vantoantrinh96/orca-firstmate.git), nhưng bootstrap chạy trên
# một máy mới qua `curl | sh` thì chưa chắc có SSH key cho tài khoản đó — và
# repo đã public nên HTTPS clone không cần auth gì cả. Lấy owner/tên từ remote,
# phát ra dạng HTTPS.
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
  # origin/HEAD có thể chưa được đặt (clone cũ, hoặc remote không công bố HEAD).
  # Khi đó `reset --hard origin/HEAD` báo "unknown revision" và bootstrap kẹt
  # vĩnh viễn. `set-head -a` hỏi lại remote và tự chữa; lỗi ở đây không chặn.
  git -C "$SRC" remote set-head origin -a >/dev/null 2>&1 || true
  # reset --hard: $SRC do tool sở hữu, không phải chỗ để sửa tay. Sửa tay ở đó
  # bị ghi đè có chủ đích, thay vì làm bootstrap kẹt mãi.
  git -C "$SRC" reset --quiet --hard origin/HEAD || { echo "error: reset thất bại" >&2; exit 1; }
elif [ -e "$SRC" ]; then
  # $SRC tồn tại nhưng không phải git repo — thường là một lần clone hỏng dở.
  # KHÔNG tự xoá: đó là thư mục trên máy captain. Nói rõ và đưa đúng lệnh.
  echo "error: $SRC đã tồn tại nhưng không phải git repo (clone hỏng dở?)" >&2
  echo "  xoá rồi chạy lại:  rm -rf $SRC" >&2
  exit 1
else
  git clone --quiet "$REPO_URL" "$SRC" || { echo "error: clone thất bại từ $REPO_URL" >&2; exit 1; }
fi

[ -x "$SRC/bin/orca-firstmate" ] || { echo "error: source thiếu bin/orca-firstmate" >&2; exit 1; }
mkdir -p "$BIN_DIR" || { echo "error: không tạo được $BIN_DIR" >&2; exit 1; }

# `ln -sf` KHÔNG an toàn khi đích đã là một THƯ MỤC. Trên BSD ln của macOS —
# nền tảng duy nhất ta ship tới — `-f` không thay thế thư mục; nó tạo link BÊN
# TRONG thư mục đó rồi exit 0, nên script in "đã cài" thành công trong khi thứ
# nằm trên PATH là một thư mục không chạy được. Chặn trước, và kiểm lại sau.
LINK="$BIN_DIR/orca-firstmate"
if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
  echo "error: $LINK đã tồn tại và không phải symlink; dời nó đi rồi chạy lại" >&2
  exit 1
fi
# FIX 10 (ca đã tái hiện) — GUARD TRÊN KHÔNG BẮT ĐƯỢC khi $LINK VỐN ĐÃ LÀ MỘT
# SYMLINK TRỎ TỚI MỘT THƯ MỤC (ví dụ dư lại từ một lần cài hỏng trước). Khi đó
# `[ -e "$LINK" ]` đúng (đi theo link, tới được thư mục) nhưng `[ ! -L "$LINK" ]`
# SAI — $LINK VẪN LÀ MỘT SYMLINK, chỉ đích của nó là thư mục — nên guard trên
# không nổ. Rồi `ln -sf` (không `-n`) coi $LINK như đích thư mục đó và tạo
# link MỚI NẰM BÊN TRONG nó, không thay thế $LINK; hậu-kiểm cũ `[ -L "$LINK" ]`
# vẫn đúng (symlink GỐC còn nguyên, chẳng liên quan gì) nên script báo "đã cài"
# trong khi PATH vẫn trỏ vào chỗ cũ/hỏng. `-n` buộc ln coi $LINK như một entry
# CẦN THAY THẾ, không đi theo nó dù đích là thư mục.
ln -sfn "$SRC/bin/orca-firstmate" "$LINK" || { echo "error: không tạo được symlink $LINK" >&2; exit 1; }
# Hậu-kiểm CŨ chỉ hỏi "$LINK có phải symlink không" — không đủ, vì đúng ca lỗi
# trên vẫn để lại MỘT symlink (chỉ là symlink gốc, trỏ sai chỗ). Hỏi thêm: nó
# có GIẢI RA một file thường, thực thi được, hay không.
[ -L "$LINK" ] || { echo "error: $LINK không phải symlink sau khi cài" >&2; exit 1; }
[ -f "$LINK" ] && [ -x "$LINK" ] || {
  echo "error: $LINK không giải ra một file thực thi được sau khi cài" >&2; exit 1; }

echo "đã cài orca-firstmate -> $LINK"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "lưu ý: $BIN_DIR chưa nằm trong PATH; thêm nó vào shell profile" ;;
esac
echo
echo "tiếp theo:"
echo "  orca-firstmate doctor     # kiểm Orca, jq, git, gh"
echo "  orca-firstmate install    # cài vào harness (sẽ sửa cấu hình harness)"
