# orca-firstmate — Design

Ngày: 2026-08-30
Trạng thái: đã duyệt design trong chat, chờ duyệt spec

## Tóm tắt

`orca-firstmate` là một **agent distro** lấy triết lý của [firstmate](https://github.com/kunchenguid/firstmate) nhưng xây lại từ đầu, Orca-native: mở Claude Code trong thư mục này là thành **first mate** — một liaison duy nhất mà captain (người dùng) trò chuyện, thường qua floating window của Orca. First mate điều phối crew agent chạy trong worktree/terminal do Orca quản lý, trên nhiều host (hiện tại: local + Mac mini; danh sách host thay đổi được trong tương lai).

Nguyên tắc phân vai:

- **Orca sở hữu cơ khí**: worktree, terminal, Run/Task/Dispatch, mailbox, settle, release, federation xuyên host. Distro không bao giờ chép lại state này.
- **First mate sở hữu phán đoán**: chia yêu cầu thành task, sinh brief, chọn host, đọc `worker_done` và quyết bước tiếp theo, nói chuyện với captain bằng ngôn ngữ kết quả.
- **State riêng tối thiểu**: chỉ sổ `requests/` (khái niệm host-dính-theo-request là của distro, Orca không có chỗ chứa) và tri thức `projects/`.

Khác firstmate ở chỗ: không có 162 script bash, không watcher tự chế, không `state/*.meta`, không backend đa multiplexer. Toàn bộ cơ khí thay bằng `orca orchestration` + một Stop hook nhỏ.

## Bối cảnh và lý do

firstmate có backend Orca nhưng chỉ dùng 8 lệnh CLI mức thấp (`status`, `repo add/show`, `worktree create/rm/show`, `terminal create/send/read/close`) và nhét Orca vào khuôn tmux, nên chịu các giới hạn: không busy signal, không secondmate, tự dựng steering inbox. Trong khi Orca (đã kiểm chứng trên máy captain, app 1.4.191, 57 capabilities) có sẵn:

- `orchestration run/task/dispatch/worker-*` — vòng đời worker có giám sát, receipt tường minh.
- `orchestration check --wait --types worker_done,escalation,question` — mailbox blocking, FIFO, replay-tới-khi-ack, hoạt động xuyên host.
- `worktree ps --json` — ảnh chụp toàn fleet một lệnh, gồm `agents[].state`, `linkedPR`, `lastOutputAt`.
- `worker-start --on <environment>` — dispatch sang host khác; sau đó mọi lệnh route bằng Dispatch ID.
- Idempotency capabilities (`worktree.create-idempotency.v1`, `terminal.create-idempotency.v2`).

Giá trị giữ lại từ firstmate là phần Orca **không** có: kỷ luật liaison một đầu mối, authority không suy diễn, brief có hợp đồng, không release khi chưa land, host lỗi không âm thầm thay thế.

Nỗi đau captain cần giải (đã xác nhận): (1) phải tự đi xem từng worktree — cần giám sát tập trung, tự thức dậy theo sự kiện; (2) lặp lại context cho mỗi agent — cần brief sinh tự động từ tri thức project.

## Kiến trúc

```
captain ── chat (Orca floating window / terminal bất kỳ)
   │
   ▼
┌────────────────────────────────────────────┐
│ orca-firstmate (Claude Code + distro này)  │  Run home: máy local
│  AGENTS.md   — identity, phép tắc          │
│  skills/     — brief, routing, supervise   │
│  hooks/      — Stop hook wake              │
│  requests/   — sổ request đang mở          │
│  projects/   — tri thức từng project       │
└──────┬─────────────────────────────────────┘
       │ orca orchestration …
       ▼
  Orca Run (1 request = 1 Run)
       │ worker-start [--on <host>]
  ┌────┴─────┬──────────┐
  ▼          ▼          ▼
Dispatch  Dispatch  Dispatch     local / Mac mini / host tương lai
(worktree + terminal + agent, Orca quản trọn vòng đời)
```

### Cấu trúc thư mục distro

```
orca-firstmate/
  AGENTS.md                  # identity + hard rules + lifecycle (~150 dòng), CLAUDE.md import nó
  CLAUDE.md                  # chỉ chứa @AGENTS.md
  .claude/settings.json      # Stop hook asyncRewake
  hooks/
    wake.sh                  # Stop hook: chờ mailbox, exit 2 để đánh thức (~50 dòng)
  skills/
    brief/SKILL.md           # sinh spec 3 tầng cho task-create
    routing/SKILL.md         # khám phá host, eligibility, chọn host per-request
    supervise/SKILL.md       # xử lý batch mailbox, release/reuse, ack, báo cáo
  requests/                  # state động, git-ignored nhưng bền trên đĩa (restart-proof cần đĩa, không cần git)
  projects/
    <tên>.md                 # tri thức project: build/test/ship, convention, bẫy, gợi ý model
  tests/
    fake-orca/               # orca giả trên PATH trả JSON mẫu
    *.test.sh
  docs/superpowers/specs/    # spec này và các spec sau
```

## Khái niệm Request (đơn vị điều phối)

**Một yêu cầu ban đầu của captain = một Request = một Orca Run.** Không nhất thiết là "feature" — bất kỳ yêu cầu nào ("sửa flaky test rồi thêm dark mode" là một request với hai task).

File `requests/<slug>.md` (frontmatter + ghi chú):

```markdown
---
run_id: <orca run id>
project: platform
host: local | <environment name>
status: open | closed
opened: 2026-08-30
---
Yêu cầu gốc của captain, các quyết định đã chốt, task đã tạo.
```

Vòng đời:

1. **Mở**: captain nêu yêu cầu → first mate xác định project → chạy routing (dưới) → **hỏi captain chọn host một lần** → `run-create --objective` → ghi file request.
2. **Chạy**: mỗi việc con → skill `brief` sinh spec → `task-create --spec` → `worker-start --task <id> --worktree new-top-level --name <n> --agent claude [--model … --effort …] [--on <host>] --setup run`. Mọi task trong request — kể cả fix theo review, retry, việc phát sinh — **kế thừa host đã chọn, không hỏi lại**.
3. **Theo dõi**: sự kiện đánh thức first mate (phần Supervision), xử lý, báo captain phần đáng báo.
4. **Đóng**: captain xác nhận request hoàn tất → first mate release mọi Dispatch còn lại của Run, đặt `status: closed`. Host hết dính. Request mới hỏi host lại từ đầu.

Nhiều request mở song song được, mỗi cái một Run, host có thể khác nhau.

## Routing host

Không có danh sách host trong config — host là first-class của Orca, thêm/xóa bằng `orca environment add/rm`, distro chỉ đọc. Tại thời điểm mở request:

1. **Khám phá**: `orca host list --json` — tập host hiện hữu, không cache.
2. **Sức khỏe**: từng host qua `orca status [--environment <X>] --json`, yêu cầu `reachable=true` và `state="ready"`. Không đạt → loại khỏi vòng chọn.
3. **Khả dụng project**: `orca project setups --project <id> --json` phải có setup `ready` trên host đó. Ràng buộc Orca: dispatch remote chỉ nhận selector worktree remote chính xác hoặc `new-top-level` + `--repo` remote tường minh — nên project chưa setup trên host thì không dispatch được. Captain vẫn chọn host đó → first mate đề nghị `project setup-clone`, chỉ chạy sau khi captain đồng ý.
4. **Chọn**: trình danh sách host đủ điều kiện kèm số worker đang chạy mỗi host (từ `worktree ps` / `worker-list`) → **captain chốt**. Đó là lần hỏi duy nhất của request.

Quy tắc cứng (kế thừa firstmate): **host đã dính mà giữa chừng không reachable → dừng và báo captain, không bao giờ âm thầm chuyển task sang host khác.** Route không khả dụng không bao giờ biến thành local replacement.

Chi tiết federation của Orca cần tôn trọng: `--on` chỉ dùng ở `worker-start`; Run và Task luôn ở server hiện tại (local); các lệnh sau route bằng Dispatch ID, không lặp `--on`.

## Supervision — tự thức dậy theo sự kiện

Hai nửa ghép lại:

**Nửa Orca** — mailbox blocking:

```bash
orca orchestration check --wait --types worker_done,escalation,question --timeout-ms <n> --json
```

Block tới khi có message cho Run; FIFO; replay cùng Delivery tới khi `--ack`; keepalive JSON mỗi 15s ra stderr (lọc bằng `_keepalive`). Hoạt động xuyên host.

**Nửa Claude Code** — `hooks/wake.sh` đăng ký trong `.claude/settings.json` dạng Stop hook `"asyncRewake": true`, timeout dài (tham khảo firstmate: 28800s):

- Không có request nào `status: open` trong `requests/` → exit 0, im lặng, không tốn gì.
- Có → `check --wait --peek` (peek: không đánh dấu đã đọc), `--timeout-ms` đặt ngắn hơn timeout của hook một khoảng an toàn (ví dụ hook 28800s → wait 28500s) để hook luôn tự thoát có kiểm soát. Có message → in một dòng tóm tắt ra stderr, **exit 2** → Claude Code tỉnh dậy kể cả khi idle. Timeout → exit 2 với lý do "re-arm" để lượt kế cắm lại vòng chờ.
- **Hook không bao giờ ack.** Ack thuộc về first mate sau khi xử lý xong. Nhờ replay-tới-ack, hook chết giữa chừng không mất message; phiên mới chỉ cần `check` là thấy lại mọi thứ chưa ack — restart-proof đến từ Orca, không phải từ distro.

Khi tỉnh, first mate (skill `supervise`):

1. `check` đọc batch → xử lý **từng** message trước khi ack.
2. Mỗi `worker_done` được chấp nhận: quyết terminal đi đâu **trước khi ack** — có task nối tiếp cho đúng agent đó → đọc `worker.agent_terminal_handle` từ `worker-show`, rồi `worker-start --task <next> --terminal <handle>` (Orca chuyển ownership cleanup); không → `worker-release --dispatch <id>`. Release chạy cho cả `worker_done` thành công lẫn thất bại, trừ khi captain yêu cầu giữ terminal (`worker-retain`).
3. `--ack <delivery_id>` chỉ sau khi mọi message trong batch được xử lý.
4. Báo captain **một** tin gộp, chỉ điều đáng nói: outcome, PR, quyết định cần captain. `escalation`/`question` → chuyển thành câu hỏi kèm ngữ cảnh; trả lời của captain đi ngược qua `orchestration reply`.

Quy tắc cứng: **không release vì timeout, TUI idle, heartbeat, status, question, escalation, hay `worker_done` bị reject/stale** — chỉ release sau `worker_done` thật đã xử lý. Worker im lâu bất thường → `worker-read --dispatch` (nguồn `auto`: transcript hook-proven hoặc terminal-bounded) để chẩn đoán rồi báo captain.

## Brief tự động

Mỗi project một file `projects/<tên>.md`, captain sửa trực tiếp được. Skill `brief` ghép ba tầng thành `--spec` cho `task-create`:

1. **Bất biến** (mọi worker): báo xong đúng cú pháp `orchestration send --type worker_done … --outcome succeeded|failed` (thất bại phải nằm trong `--outcome`, không chỉ trong prose); bí thì `orchestration ask` chứ không đoán; không tự merge; không rời worktree được giao.
2. **Project** (từ file tri thức): cách build/test, convention, cách ship (PR vào nhánh nào, format commit), bẫy đã biết, link tài liệu.
3. **Task** (từ yêu cầu captain): việc cụ thể + định nghĩa hoàn thành.

Captain chỉ mô tả tầng 3. File project **tự dày lên**: worker vấp bẫy mới → first mate đề nghị thêm một dòng vào file (captain gật mới ghi) — worker sau thừa hưởng.

File project có thể khai gợi ý model per loại task (scout → model rẻ/effort thấp, ship → model mạnh), first mate áp qua `worker-start --model … --effort …` (chỉ với terminal mới; `--effort` đòi `--model`).

## Xử lý lỗi

- `worker-start` thất bại hoặc `outcome_unknown`: exit ≠ 0, JSON có `stage`/`failedStage`, `setup`, `effects`, `residualResources`, lệnh recovery. Quy tắc: **đọc receipt, làm đúng recovery ghi trong đó, không retry mù.** `--retry-of <dispatch_id>` khi thử lại để nối lịch sử (nhớ lặp lại placement vì retry không kế thừa). Còn tài nguyên dư → báo captain.
- Wait-for-setup timeout để setup ở trạng thái `running` là bình thường, không phải bằng chứng thất bại — kiểm tra lại trước khi kết luận.
- `worker-release` trả `release_pending`/`release_unknown`: theo đúng recovery action trong receipt; **cấm** thay bằng `terminal close`. Delivery replay có thể lặp `worker-release` an toàn.
- Host dính chết giữa request: dừng, báo, chờ captain quyết (đổi host cho request là quyết định của captain, không của first mate).
- `ask` của worker timeout: câu hỏi vẫn pending, resume bằng message ID gốc — không tạo câu hỏi trùng.

## Kiểm thử

- **fake-orca**: script `tests/fake-orca/orca` đặt trước PATH, trả JSON mẫu đã đối chiếu với schema thật (lấy từ `orca agent-context --json` và output thật trên máy captain). Test lifecycle không cần app: routing loại host không ready, brief ghép đúng 3 tầng, hook exit 0 khi không có request mở / exit 2 khi có message, supervise không ack trước khi xử lý xong batch.
- **Smoke thật** (chạy tay, có Orca thật): mở request → 1 task echo → worker chạy → `worker_done` → hook đánh thức → release → đóng request. Một biến thể `--on "Mac mini"`.
- Ghi kết quả smoke thật vào `docs/verification/` kèm version app đã kiểm (học cách firstmate làm evidence theo version, vì Orca không có protocol version marker — capabilities trong `orca status` là gate tương thích).

## Ngoài phạm vi v1 (YAGNI, chủ động ghi lại để khỏi bò vào)

- Gate quyền hạn kiểu no-mistakes / delivery mode per-project — v1 mặc định worker mở PR, captain merge; nói lại sau khi dùng thật.
- Relay (X/Discord), AFK mode, voice.
- Secondmate/coordinator lồng nhau — flat: một first mate, N worker.
- Tự cân bằng tải giữa host — captain chọn host per-request là đủ.
- Scout report format riêng — v1 scout trả kết quả trong `worker_done` body; tách format khi thấy cần.

## Rủi ro đã biết

- **Gắn chặt schema orchestration của Orca**: Orca không có version marker ổn định; đổi contract sẽ lộ lúc runtime. Giảm nhẹ: kiểm `orchestration.contract.v1` trong capabilities lúc session start; fake-orca fixtures ghi rõ version app đã đối chiếu.
- **Stop hook asyncRewake là hành vi của Claude Code**, đổi harness là mất cơ chế wake — chấp nhận: distro này chọn Claude Code làm harness duy nhất của v1.
- App Orca phải đang chạy — `orca open` ở session start nếu chưa.
