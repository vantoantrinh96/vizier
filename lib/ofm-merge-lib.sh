# shellcheck shell=bash
# Luật quyết định cho merge vào file thuộc về tool khác.
#
# Ở lib chứ không ở adapter, vì adapter có khối `case` dispatch chạy ngay khi
# source — không test được nếu không bịa nhánh chỉ-dành-cho-test vào đúng file
# rủi ro nhất dự án. Lib thì vốn sinh ra để được source.
#
# Bản thân cuộc đua ghi file không tái hiện được trong một unit test, nhưng
# LUẬT quyết định thì phải kiểm được, và đây chính là nó.

# 0 khi không có dấu hiệu mất bản cập nhật.
# Một phép đếm RỖNG (jq lỗi, file không đọc được) tính là LỆCH, không tính là
# bằng nhau: hai chuỗi rỗng so với nhau thì "bằng", và đó là cách một lỗi thật
# đội lốt trạng thái lành.
#
# Kiểm TỪNG đối số riêng, không nối chuỗi rồi kiểm gộp: nối "" + "" + "1" ra
# "1" — toàn chữ số, không rỗng — nên phép kiểm gộp bỏ lọt đúng ca hai đối số
# đầu cùng rỗng. Kiểm riêng từng đối số thì không thể bị hai cái rỗng che lấp
# bởi một cái không rỗng.
ofm_no_lost_update() {  # <others_before> <others_after> <mine_after>
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  case "$2" in ''|*[!0-9]*) return 1 ;; esac
  case "$3" in ''|*[!0-9]*) return 1 ;; esac
  [ "$2" = "$1" ] && [ "$3" = "1" ]
}
