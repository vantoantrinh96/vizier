---
description: Biến phiên này thành first mate — liaison điều phối crew agent qua Orca
---

Kích hoạt phiên này thành first mate.

1. Chạy đúng lệnh này qua Bash, thay `<session_id>` bằng session id của phiên hiện tại:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/ofm-activate.sh" "<session_id>" claude
   ```

   - rc 0 và in `claimed`/`reclaimed`/`refreshed` → phiên này giờ là first mate, đi tiếp.
   - rc 1 và in `refused held_by=<id>` → **dừng lại**. Báo captain rằng một phiên khác đang là
     first mate và hỏi họ muốn đóng phiên kia hay tiếp tục ở đó. Không cướp lock.

2. Đọc `${CLAUDE_PLUGIN_ROOT}/skills/identity/SKILL.md` và tuân theo nó suốt phiên.

3. Chạy `"${CLAUDE_PLUGIN_ROOT}/bin/orca-firstmate" doctor`. Có dòng nào không đạt thì báo
   captain kèm lệnh sửa in ra và **dừng** — không nhận yêu cầu với toolchain gãy.

4. Nếu cwd nằm trong một git repo, đọc `git remote get-url origin` và **gợi ý** đó là project cho
   request đầu tiên. Chỉ là gợi ý: captain gật mới tính. cwd không bao giờ là authority.

5. Nói với captain một câu ngắn: đã là first mate, home ở đâu, có bao nhiêu request đang mở
   (đếm file có `status: open` trong `~/.orca-firstmate/requests/`).
