# Kiểm chứng: cơ chế wake ở dạng Claude Code plugin

Ngày: 2026-08-31
Claude Code: 2.1.236
Cách chạy: plugin throwaway `ofm-probe` scaffold bằng `claude plugin init` vào `~/.claude/skills/`
(auto-load dạng `<name>@skills-dir`), Stop hook bash ngủ 12s rồi exit 2 một lần, gate theo `cwd`
để không chạm session khác. Đã xoá sau khi đo.

## Câu hỏi

Spec giả định Stop hook `asyncRewake` đánh thức được first mate đang idle. Docs Claude Code
xác nhận field này cho **command hook** trong `settings.json`, nhưng **không nói** plugin
`hooks/hooks.json` có honor nó hay không. Toàn bộ cơ chế giám sát phụ thuộc câu trả lời.

## Cách đo

`claude -p` headless không phân biệt được sync với async: cả hai phase (có và không có
`asyncRewake`) đều mất ~37-39s, vì process không thoát khi hook còn chạy. Phải giữ một phiên
sống bằng `--input-format stream-json --output-format stream-json`, gửi một lượt rồi giữ stdin
mở 45s, và đóng dấu thời gian từng dòng output.

## Kết quả

```
847.224  ASSISTANT 'ok'
847.275  hook FIRE            hook bắt đầu, chặn 12s
847.303  RESULT success       phiên KHÔNG chờ hook -> async
859.339  hook EXIT2
859.377  SYSTEM init          phiên idle tỉnh dậy, chạy lượt mới
860.711  ASSISTANT 'ok'
872.839  hook EXIT0           im lặng, không đánh thức
887.832  (đóng stdin)         phiên đứng yên từ 872 tới đây
```

Năm điều được chứng minh, tất cả trong dạng plugin:

1. Stop hook do plugin cung cấp **fire được**.
2. `asyncRewake: true` **được honor**: RESULT về sau 0.08s trong khi hook còn chạy thêm 12s.
3. exit 2 **đánh thức phiên đang idle** sau 40ms, stderr vào context dạng system reminder.
4. exit 0 **câm tuyệt đối** — không lượt nào phát sinh, phiên đứng yên 15s tới khi đóng stdin.
5. Payload stdin có `session_id`, `cwd`, `stop_hook_active`, `transcript_path`,
   `permission_mode`, `last_assistant_message`, `prompt_id`.

## Hệ quả cho thiết kế

- Dạng plugin khả thi, không cần fallback về `.claude/settings.json` cấp project.
- `session_id` trong payload là thứ cho phép gate "phiên này có phải first mate không" bằng
  một lần đọc file, nên hook câm được trong mọi session Claude Code khác trên máy.
- Claude Code bắn Stop hook trên **mọi** Stop và **không dedupe** (xem header
  `firstmate/bin/fm-claude-stop-autoarm.sh`), nên cổng chặn phải là thao tác rẻ nhất có thể.

## Giới hạn của phép đo

Đo trên một phiên stream-json, không phải TUI tương tác. Hành vi async đã chứng minh ở tầng
protocol; phần TUI hiển thị ra sao chưa kiểm. Không đo với timeout dài (dùng 120s, spec định
dùng ~28800s).

---

# Kiểm chứng: hook Cursor cấp user

Ngày: 2026-08-31
cursor-agent: 2026.08.11-e8db854 (đúng version firstmate đã verify adapter Cursor)

## Câu hỏi

firstmate chứng minh cơ chế `stop` của Cursor ở `.cursor/hooks.json` **cấp project** với `--trust`.
orca-firstmate cài **cấp user**. Cấp user có fire không?

## Kết quả: headless không đo được câu đó

Ba cấu hình, cùng một hook probe, chạy `cursor-agent -p --trust`:

| Nơi khai hook | Hook fire? |
|---|---|
| plugin `~/.cursor/skills/ofm-probe` (auto-discovery) | không |
| cùng plugin, ép bằng `--plugin-dir` | không |
| `~/.cursor/hooks.json` cấp user — đúng chỗ Orca đang dùng | **không** |

Cấu hình thứ ba là cấu hình đối chứng: đó là vị trí đã biết chắc chạy, vì Orca tự cài 8 event
của nó ở đó. Nó cũng không fire.

**Kết luận: `cursor-agent -p` không chạy hook nào, không riêng gì turn-end.** README firstmate
chỉ ghi "no turn-end hook in headless"; phép đo này cho thấy phạm vi rộng hơn thế.

File `~/.cursor/hooks.json` của captain được sao lưu trước và khôi phục byte-exact ngay sau
phép đo (sha256 khớp: `ba94bfa2…5c7e35c7`).

## Hệ quả cho thiết kế

- Adapter Cursor **không thể có test tự động** cho đường wake. Phải smoke test tay, đúng cách
  firstmate làm.
- Câu hỏi "plugin cấp user có nạp hook không" **vẫn mở**; phải đo bằng phiên tương tác.
- `cursor-agent` đòi trust theo từng thư mục workspace (`--trust` hoặc quyết định tương tác).
  Với orca-firstmate "chạy ở mọi nơi", nghĩa là mỗi thư mục mới captain gõ `/firstmate` đều
  vướng một lần trust. Cần cân nhắc ở adapter Cursor.

## Probe còn lại trên máy

`~/.cursor/skills/ofm-probe/` — đã gate theo cwd nên câm ở mọi phiên khác. Xoá bằng
`rm -rf ~/.cursor/skills/ofm-probe`.
