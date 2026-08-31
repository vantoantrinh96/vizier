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

## Đo lại bằng phiên tương tác (pty)

Headless không đo được thì lái phiên TUI thật qua `pty.fork()`: gõ text, gửi Enter tách rời
(gõ và Enter cùng lúc thì Cursor nhận chữ nhưng **không** submit), rồi đọc terminal có đóng dấu
thời gian. cursor-agent TUI báo version **2026.08.25-3e8eec8**, mới hơn con số `--version` in ra
(`2026.08.11-e8db854`) và mới hơn version firstmate verify.

### Kết quả 1 — plugin cấp user KHÔNG nạp hook

Cùng một hook probe đặt tại `~/.cursor/skills/ofm-probe/` với `.cursor-plugin/plugin.json` khai
`"hooks": "./hooks/hooks-cursor.json"`: một lượt tương tác đầy đủ chạy xong (agent trả lời,
spinner tắt, composer về idle, ngồi im 75s) và **không hook nào fire**. `--plugin-dir` tường minh
cũng không.

### Kết quả 2 — `~/.cursor/hooks.json` cấp user CHẠY, đủ cả vòng đánh thức

Cùng probe đó khai trong `~/.cursor/hooks.json`:

```
530.3  stop fire (lượt 1 kết thúc)
538.4  WOKE sau 8s park          <- hook chặn, phiên chờ
538.5  EMIT {"followup_message": ...}
       TUI hiện "Working" -> model chạy lượt mới -> in "PROBEWAKE"
541.2  stop fire lại (lượt 2 kết thúc)
549.3  WOKE, KHÔNG emit          <- guard chặn, vòng lặp có đáy
```

`beforeSubmitPrompt`, `stop`, `afterAgentResponse` đều fire. Payload `stop` mang:
`session_id`, `workspace_roots`, `loop_count`, `conversation_id`, `generation_id`,
`cursor_version`, `transcript_path`, `model`, `status`, `user_email`, và bộ đếm token.

Xác nhận đúng những gì firstmate mô tả: hook chạy đồng bộ và park, kênh duy nhất là một
`{"followup_message": ...}` trên stdout với exit 0, `loop_count` là bản Cursor của
`stop_hook_active`.

`~/.cursor/hooks.json` được sao lưu và khôi phục byte-exact sau **mỗi** lần đo
(sha256 `ba94bfa2…5c7e35c7` khớp cả hai lần).

## Hệ quả bắt buộc cho thiết kế

**Adapter Cursor không thể là plugin.** Nó buộc phải ghi vào `~/.cursor/hooks.json` — chính file
mà Orca đã có 8 entry trong đó. Nên `install` cho Cursor phải là **merge phẫu thuật, idempotent**:
thêm đúng entry của mình, không đụng entry của ai khác, chạy lại không nhân bản; `uninstall` gỡ
đúng entry của mình. Đây là ngoại lệ có bằng chứng của nguyên tắc "không sửa file config của tool
khác", không phải sự tuỳ tiện.

Hai adapter vì thế khác nhau ở cả *nơi cài*, không chỉ ở cơ chế wake:

| | Claude Code | Cursor |
|---|---|---|
| Cài vào | plugin riêng, `~/.claude/skills/<name>/` | **merge vào `~/.cursor/hooks.json` dùng chung** |
| Gỡ | xoá thư mục | gỡ đúng entry của mình |
| Rủi ro cài | không | ghi đè config người khác nếu merge sai |

Chưa kiểm: Cursor có nạp `skills/` từ `~/.cursor/skills/` hay không (superpowers nằm ở đó nên
nhiều khả năng có, nhưng chưa đo).

---

# Kiểm chứng: `stop_hook_active` xuyên chuỗi đánh thức

Ngày: 2026-08-31
Claude Code: 2.1.236

## Câu hỏi

`hooks/wake-claude.sh` dùng `stop_hook_active` để chặn vòng lặp vô hạn: hook `--peek` nên một
message chưa ack vẫn còn đó ở Stop kế tiếp, và mỗi lần đánh thức lại sinh ra một lần nữa. Nhưng
tài liệu công khai mô tả `stop_hook_active` là cờ cho trường hợp hook **chặn** lần stop — còn
`asyncRewake` thì đã đo là KHÔNG chặn (RESULT về sau 0.08s trong khi hook còn chạy 12s). Nên cờ
này có được đặt trên cái Stop **sau** một lần đánh thức bằng exit 2 hay không là chuyện phải đo.

## Cách đo

Plugin throwaway với Stop hook `asyncRewake`, gate theo `cwd`, ghi lại `stop_hook_active` mỗi lần
fire, exit 2 ở hai lần đầu rồi exit 0. Lái bằng một phiên `--input-format stream-json` giữ sống.

## Kết quả

```
fire#1  stop_hook_active=false     <- sau lượt người dùng thật
fire#2  stop_hook_active=true      <- sau lần đánh thức bởi exit 2
fire#3  stop_hook_active=true      <- sau lần đánh thức thứ hai
```

## Hệ quả

1. **Trần theo `stop_hook_active` CÓ chạm.** Vòng lặp vô hạn thực sự bị chặn.
2. **Nhưng cờ này không phân biệt được "message cũ chưa ack" với "message mới".** Sau *bất kỳ*
   lần exit 2 nào — kể cả một lần re-arm do hết giờ, hoàn toàn không liên quan tới message nào —
   mọi Stop tiếp theo trong chuỗi đều có cờ true. Nên một message MỚI tới trong chuỗi re-arm sẽ bị
   coi là lần lặp và bị nuốt im lặng.
3. Do đó chặn vòng lặp phải dựa trên **danh tính message đã báo**, không dựa trên cờ. Cờ chỉ nói
   "lượt này do hook gây ra", không nói "ta đã báo đúng thứ này rồi".
