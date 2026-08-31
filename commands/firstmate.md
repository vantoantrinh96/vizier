---
description: Biến phiên này thành first mate — liaison điều phối crew agent qua Orca
---

Kích hoạt phiên này thành first mate.

1. Chạy đúng lệnh này qua Bash, **không thêm tham số nào**:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/ofm-activate.sh" claude
   ```

   Script tự đọc session id từ `CLAUDE_CODE_SESSION_ID` trong môi trường. **Đừng tự đoán hay tự
   điền session id** — bạn không có cách nào biết nó, và một giá trị bịa sẽ khiến lock không bao
   giờ khớp payload của hook, làm cả cơ chế đánh thức lẫn cơ chế nhắc-lại-identity câm vĩnh viễn
   trong khi lock vẫn bị giữ. Nếu script báo `no_session_id`, dừng lại và báo captain.

2. Đọc `${CLAUDE_PLUGIN_ROOT}/skills/identity/SKILL.md` và tuân theo nó suốt phiên.

3. Chạy `"${CLAUDE_PLUGIN_ROOT}/bin/orca-firstmate" doctor`. Có dòng nào không đạt thì báo
   captain kèm lệnh sửa in ra và **dừng** — không nhận yêu cầu với toolchain gãy.

4. Nếu cwd nằm trong một git repo, đọc `git remote get-url origin` và **gợi ý** đó là project cho
   request đầu tiên. Chỉ là gợi ý: captain gật mới tính. cwd không bao giờ là authority.

5. Nói với captain một câu ngắn: đã là first mate, home ở đâu, có bao nhiêu request đang mở
   (đếm file có `status: open` trong `~/.orca-firstmate/requests/`).
