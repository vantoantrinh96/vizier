# orca-firstmate — Design

Ngày: 2026-08-30
Cập nhật: 2026-08-31 — bổ sung Delivery mode/no-mistakes; entry point thành plugin đa harness + CLI cài đặt
Trạng thái: đã duyệt design trong chat, chờ duyệt spec

## Tóm tắt

`orca-firstmate` là một **agent distro** lấy triết lý của [firstmate](https://github.com/kunchenguid/firstmate) nhưng xây lại từ đầu, Orca-native: cài như một **Claude Code plugin**, rồi gõ `/firstmate` trong bất kỳ phiên Claude Code nào ở bất kỳ thư mục nào để phiên đó thành **first mate** — một liaison duy nhất mà captain (người dùng) trò chuyện, thường qua floating window của Orca. First mate điều phối crew agent chạy trong worktree/terminal do Orca quản lý, trên nhiều host (hiện tại: local + Mac mini; danh sách host thay đổi được trong tương lai).

Nguyên tắc phân vai:

- **Orca sở hữu cơ khí**: worktree, terminal, Run/Task/Dispatch, mailbox, settle, release, federation xuyên host. Distro không bao giờ chép lại state này.
- **First mate sở hữu phán đoán**: chia yêu cầu thành task, sinh brief, chọn host, đọc `worker_done` và quyết bước tiếp theo, nói chuyện với captain bằng ngôn ngữ kết quả.
- **State riêng tối thiểu**: chỉ sổ `requests/` (khái niệm host-dính-theo-request là của distro, Orca không có chỗ chứa) và tri thức `projects/`.

Khác firstmate ở chỗ: không có 162 script bash, không watcher tự chế, không `state/*.meta`, không backend đa multiplexer, và không phải `cd` vào một thư mục distro. Toàn bộ cơ khí thay bằng `orca orchestration` + một Stop hook nhỏ.

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
│ phiên Claude Code bất kỳ, cwd bất kỳ       │
│  + plugin orca-firstmate (skills, hook)    │
│  đã gõ /firstmate → giữ lock → là first mate│
└──────┬─────────────────────────────────────┘
       │ đọc/ghi
       ▼
┌────────────────────────────────────────────┐
│ ~/.orca-firstmate/  (home cố định)          │
│  lock        — session_id + pid chủ hiện tại│
│  requests/   — sổ request đang mở           │
│  projects/   — tri thức từng project        │
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

### Cấu trúc plugin (thứ được cài)

```
orca-firstmate/
  .claude-plugin/plugin.json
  commands/
    firstmate.md             # /firstmate — kích hoạt phiên, giữ lock, gợi ý project từ cwd
  skills/
    brief/SKILL.md           # sinh spec 4 tầng cho task-create
    routing/SKILL.md         # khám phá host, eligibility, chọn host per-request
    supervise/SKILL.md       # xử lý batch mailbox, release/reuse, ack, báo cáo
    delivery/SKILL.md        # delivery mode, hợp đồng giao hàng, chính sách ask-user
    identity/SKILL.md        # identity + hard rules; /firstmate và PostCompact đều nạp nó
  hooks/
    hooks.json               # Stop (asyncRewake) + PostCompact
    wake.sh                  # Stop: gate lock → chờ mailbox → exit 2 (~60 dòng)
    reidentify.sh            # PostCompact: lock khớp thì in lại identity ra stderr
  tests/
    fake-orca/               # orca giả trên PATH trả JSON mẫu
    *.test.sh
  docs/superpowers/specs/    # spec này và các spec sau
  docs/verification/         # bằng chứng chạy thật kèm version app
```

### Home (thứ được sinh ra lúc chạy)

```
~/.orca-firstmate/
  lock                       # {session_id, pid, since} — chủ first mate hiện tại
  requests/<slug>.md         # sổ request đang mở
  projects/<tên>.md          # tri thức project: delivery mode, build/test/ship, convention, bẫy, gợi ý model
```

Home tách khỏi plugin có chủ đích: gỡ hoặc nâng cấp plugin không đụng tới state, và state không bao giờ phụ thuộc cwd của phiên.

## Entry point và kích hoạt

**Cài một lần, dùng mọi nơi.** Một lệnh:

```sh
curl -fsSL https://raw.githubusercontent.com/vantoantrinh96/orca-firstmate/main/install.sh | sh
orca-firstmate doctor
orca-firstmate install
```

Repo là **public trên GitHub**, nên `curl` và `git clone` đều không cần auth. Lệnh đầu chỉ clone source vào `~/.orca-firstmate/src` và symlink CLI lên PATH — **cố tình không** tự cài vào harness, vì bước đó sửa cấu hình harness của captain và phải là quyết định tường minh. Lệnh cuối dò harness nào có trên máy rồi cài adapter cho từng cái — **và cách cài khác nhau theo harness**, xem mục CLI cài đặt. Sau đó mọi phiên của harness đó, ở mọi repo, đều **có sẵn** skill và hook nhưng **không** hành xử như first mate.

**`/firstmate` là công tắc.** Gõ nó thì phiên đó:

1. Ghi `~/.orca-firstmate/lock` = `{session_id, pid, since}`. Lock đã có và chủ còn sống → **từ chối**, báo phiên nào đang giữ. Chủ chết mà chưa dọn → thu hồi. **Một first mate tại một thời điểm**, để hai phiên không cùng ghi `requests/`.
2. Nạp skill `identity` — identity và hard rules vào context.
3. Đọc git remote ở cwd và **gợi ý** project cho request đầu tiên. Chỉ là gợi ý; cwd không bao giờ là authority, captain gật mới tính.

Phiên không gõ `/firstmate` thì không giữ lock, nên hook câm và không có gì thay đổi với nó.

**Sống sót qua compact.** Hook `PostCompact`: lock khớp phiên này thì in lại identity + hard rules ra stderr. Không có nó, một lần nén context là first mate quên mình là ai trong khi vẫn đang giữ lock và vẫn đang bị đánh thức.

**Không dùng `CLAUDE.md` của plugin** cho identity — file đó nạp vào *mọi* phiên, kể cả phiên bạn chỉ muốn sửa code. Identity phải là thứ được kích hoạt, không phải thứ luôn bật.

**Truy cập home.** Phiên first mate có cwd bất kỳ, còn state ở `~/.orca-firstmate/`. First mate đọc/ghi home qua Bash. Nếu captain chạy permission mode chặt, thêm `--add-dir ~/.orca-firstmate` khi mở phiên.

## CLI cài đặt và adapter harness

**Luật cứng: CLI chỉ tồn tại lúc cài và lúc chẩn đoán, không bao giờ nằm trên đường chạy.** Cài xong, first mate nói chuyện thẳng với `orca`; không đường runtime nào gọi `orca-firstmate`. Bỏ luật này là xây lại 162 script của firstmate dưới cái tên đẹp hơn.

Bốn lệnh: `install [--harness …]`, `doctor` (preflight ở mục Entry point), `update` (kéo payload mới rồi chép lại), `uninstall` (gỡ payload, **giữ nguyên** `requests/` và `projects/`). Viết bằng bash: CLI này chỉ chép file và kiểm vài thứ, Orca lại chỉ chạy macOS, nên một binary Go cho ~200 dòng là nghi lễ thừa.

### Một repo, nhiều manifest

Mô hình đã được `superpowers` chứng minh và đang chạy trên máy captain — cùng một payload nằm trong cả `~/.claude/skills/` lẫn `~/.cursor/skills/`, mỗi harness một manifest nhỏ cạnh nhau:

```
orca-firstmate/
  .claude-plugin/plugin.json   # manifest Claude Code (Cursor không dùng manifest:
                               # plugin Cursor không nạp hook, đã đo)
  commands/firstmate.md        # dùng chung
  skills/                      # dùng chung: identity, brief, routing, supervise, delivery
  hooks/
    hooks.json                 # schema Claude: Stop (asyncRewake) + PostCompact
    wake-claude.sh
    wake-cursor.sh             # KHÔNG khai trong manifest nào: adapter Cursor
                               # merge nó vào ~/.cursor/hooks.json lúc install
  install.sh
  bin/orca-firstmate
```

**Skill portable gần như miễn phí; wake thì mỗi harness một lần làm.** Đó là toàn bộ chi phí của đa harness, và nó nằm gọn trong hai file `wake-*.sh`.

`install` chép chứ không symlink: một symlink nằm trong thư mục plugin là loại thứ hỏng âm thầm.

**Cursor không cài được dạng plugin.** Đã đo: cùng một hook, đặt trong `~/.cursor/skills/<name>/` với `.cursor-plugin/plugin.json` khai `"hooks"`, **không bao giờ fire** — kể cả khi ép bằng `--plugin-dir`; đặt trong `~/.cursor/hooks.json` thì chạy đủ vòng (`docs/verification/2026-08-31-plugin-wake.md`). Nên adapter Cursor buộc phải **merge phẫu thuật, idempotent** vào `~/.cursor/hooks.json` — chính file Orca đã có 8 entry trong đó: thêm đúng entry của mình, không đụng entry của ai khác, chạy lại không nhân bản, `uninstall` gỡ đúng entry của mình. Đây là ngoại lệ **có bằng chứng** của nguyên tắc "không sửa file config của tool khác", và nó là rủi ro cài đặt lớn nhất của distro.

| | Claude Code | Cursor |
|---|---|---|
| Cài vào | plugin riêng trong `~/.claude/skills/<name>/` | **merge vào `~/.cursor/hooks.json` dùng chung** |
| Gỡ | xoá thư mục | gỡ đúng entry của mình |
| Hỏng thì sao | không ảnh hưởng ai | **có thể phá config Orca và các tool khác** |

### Hợp đồng adapter — ba câu

Mỗi harness phải trả lời được, và câu 3 là câu giết:

1. Nạp skill ở thư mục nào, format nào?
2. Đăng ký turn-end hook bằng schema nào?
3. Cơ chế "chạy nền lâu rồi đánh thức phiên đang idle" là gì?

Hai adapter của v1 trả lời **khác hẳn nhau**, nên đừng viết chung:

| | Claude Code | Cursor |
|---|---|---|
| Event | `Stop` | `stop` |
| Cách chạy | nền, không chặn (`asyncRewake: true`) | **đồng bộ, park giữ turn boundary mở** |
| Kênh đánh thức | `exit 2` + stderr | **`{"followup_message":…}` ra stdout, exit 0** |
| `exit 2` | đánh thức | **no-op im lặng** |
| Chặn vòng lặp | `stop_hook_active` | `loop_count` + `loop_limit` khai trong hooks |
| Tranh chấp | không — async, mỗi Stop một lần bắn | **cần park-owner**: tin captain gõ lúc đang park không giết hook, hai park cùng thấy một message sẽ báo trùng |
| Headless `-p` | fire | **không fire hook nào cả** — đã đo ở cả ba vị trí khai hook |
| Payload nhận diện | `session_id`, `cwd` | `session_id`, `workspace_roots`, `loop_count`, `transcript_path`, `status` |
| Test tự động | được — spike đã tự động hoá trọn vẹn | **không** — phải lái phiên TUI thật qua pty, và gõ text với Enter phải tách rời |
| Token khi chờ | 0 | 0 |

Hệ quả cho Cursor: cần thêm `~/.orca-firstmate/park-owner` (seq tăng dần); trước khi phát follow-up, park phải xác nhận mình còn là chủ mới nhất, không thì im lặng exit 0. Và `loop_limit` khai trong hooks phải cao hơn trần tự chặn của ta, để bound của ta cắn trước và còn kịp báo một câu.

### Tuyên bố giảm cấp

`install` phải **in ra giới hạn của từng harness** ngay lúc cài, không để captain phát hiện sau ba ngày:

- Cursor: không dùng được ở headless `cursor-agent -p` — **không hook nào fire ở chế độ đó**; phải chạy phiên tương tác. Cursor còn đòi trust theo từng thư mục workspace, nên lời hứa "gõ `/firstmate` ở mọi nơi" ở Cursor kèm một lần trust cho mỗi thư mục mới.
- Harness chưa có adapter: `install` báo thẳng "chưa hỗ trợ", không im lặng bỏ qua.
- **`install` không tham số KHÔNG cài Cursor.** Nửa Cursor chưa có đường kích hoạt (`ofm-activate.sh` phụ thuộc biến môi trường chỉ Claude Code có), nên một entry cắm vào `~/.cursor/hooks.json` chỉ đọc lock rồi exit 0: không chức năng, mà vẫn nhận trọn rủi ro ghi vào file Orca dùng chung. Muốn cài thì phải yêu cầu tường minh `--harness cursor`, và adapter in rõ giới hạn đó.
- Harness không trả lời được câu 3 — Codex là ca đã biết, cơ chế của nó là "bounded foreground checkpoints" nên **không đánh thức được phiên idle** — thì adapter đó phải nói rõ orca-firstmate ở đó chạy giảm cấp: vẫn dispatch, vẫn brief, nhưng captain phải tự hỏi "xong chưa".

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
2. **Chạy**: mỗi việc con → skill `brief` sinh spec → `task-create --spec` → `worker-start --task <id> --worktree new-top-level --name <n> --agent claude [--model … --effort …] [--on <host>] --setup run`. Mọi task trong request — kể cả fix theo review, retry, việc phát sinh — **kế thừa host đã chọn, không hỏi lại**. Delivery mode thì ngược lại: chốt riêng cho từng task tại lúc tạo (mục Delivery mode), ghi vào file request kèm một dòng lý do khi lệch posture của project.
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

**Nửa Claude Code** — `hooks/wake.sh` đăng ký trong `hooks/hooks.json` của plugin dạng Stop hook `"asyncRewake": true`, timeout dài (tham khảo firstmate: 28800s). Claude Code bắn Stop hook trên **mọi** Stop của **mọi** phiên trên máy và không dedupe, nên thứ tự cổng chặn là bắt buộc, rẻ trước đắt sau:

- `session_id` trong payload stdin **không khớp** `~/.orca-firstmate/lock` → exit 0. Một lần đọc file; đây là thứ giữ hook câm trong mọi phiên Claude Code khác.
- Khớp lock nhưng không có request nào `status: open` → exit 0, im lặng, không tốn gì.
- **`stop_hook_active: true` trong payload và ta ĐÃ có message → exit 0.** Vì hook dùng `--peek`, message chưa được ack vẫn còn đó ở lượt sau; không có chặn này thì mỗi lần tỉnh lại sinh ra một lần tỉnh nữa — vòng vô hạn. Ta đã nói một lần rồi; nếu first mate không ack, đó là lỗi của first mate, không phải chỗ để hook nói lại. Trước khi im, in một dòng nêu rõ đã chạm trần.
- Có → `check --wait --peek` (peek: không đánh dấu đã đọc), `--timeout-ms` đặt ngắn hơn timeout của hook một khoảng an toàn (ví dụ hook 28800s → wait 28500s) để hook luôn tự thoát có kiểm soát. Có message → in một dòng tóm tắt ra stderr, **exit 2** → Claude Code tỉnh dậy kể cả khi idle. Timeout → exit 2 với lý do "re-arm" để lượt kế cắm lại vòng chờ. **Không được exit 0 ở đây**: phiên đang idle không sinh thêm Stop event nào, nên im lặng lúc hết giờ là giám sát chết vĩnh viễn tới khi captain tự gõ gì đó. Vòng re-arm không phải vòng xoáy — mỗi lần nó chờ tới tám tiếng.
- **Hook không bao giờ ack.** Ack thuộc về first mate sau khi xử lý xong. Nhờ replay-tới-ack, hook chết giữa chừng không mất message; phiên mới chỉ cần `check` là thấy lại mọi thứ chưa ack — restart-proof đến từ Orca, không phải từ distro.

Khi tỉnh, first mate (skill `supervise`):

1. `check` đọc batch → xử lý **từng** message trước khi ack.
2. Mỗi `worker_done` được chấp nhận: quyết terminal đi đâu **trước khi ack** — có task nối tiếp cho đúng agent đó → đọc `worker.agent_terminal_handle` từ `worker-show`, rồi `worker-start --task <next> --terminal <handle>` (Orca chuyển ownership cleanup); không → `worker-release --dispatch <id>`. Release chạy cho cả `worker_done` thành công lẫn thất bại, trừ khi captain yêu cầu giữ terminal (`worker-retain`).
3. `--ack <delivery_id>` chỉ sau khi mọi message trong batch được xử lý.
4. Báo captain **một** tin gộp, chỉ điều đáng nói: outcome, PR, quyết định cần captain. `escalation`/`question` → chuyển thành câu hỏi kèm ngữ cảnh; trả lời của captain đi ngược qua `orchestration reply`. `question` mang một ask-user finding của no-mistakes đi qua chính sách của skill `delivery` trước, không mặc định chuyển thẳng cho captain.

Toàn bộ chuỗi này đã kiểm chứng chạy thật ở dạng plugin — xem `docs/verification/2026-08-31-plugin-wake.md`.

Quy tắc cứng: **không release vì timeout, TUI idle, heartbeat, status, question, escalation, hay `worker_done` bị reject/stale** — chỉ release sau `worker_done` thật đã xử lý. Thêm một điều kiện cho mode `no-mistakes`: `worker_done` chỉ được coi là terminal khi body báo outcome axi terminal (`passed`, `checks-passed`, `failed`, `cancelled`); thiếu thì **không release**, vì có thể một run vẫn đang sở hữu nhánh. Worker im lâu bất thường → `worker-read --dispatch` (nguồn `auto`: transcript hook-proven hoặc terminal-bounded) để chẩn đoán rồi báo captain.

## Brief tự động

Mỗi project một file `projects/<tên>.md`, captain sửa trực tiếp được. Skill `brief` ghép bốn tầng thành `--spec` cho `task-create`:

1. **Bất biến** (mọi worker): báo xong đúng cú pháp `orchestration send --type worker_done … --outcome succeeded|failed` (thất bại phải nằm trong `--outcome`, không chỉ trong prose); bí thì `orchestration ask` chứ không đoán; không tự merge; không rời worktree được giao; **dùng CLI chính chủ** — `git` và `gh` cho GitHub, không wrapper bên thứ ba, trừ khi file tri thức project khai công cụ khác cho project đó; **không bao giờ stop/restart/update daemon `no-mistakes`** — một instance dùng chung mọi worktree và host, restart là giết run đang chạy của người khác, gặp lỗi daemon thì escalate rồi dừng.
2. **Project** (từ file tri thức): cách build/test, convention, cách ship (PR vào nhánh nào, format commit), bẫy đã biết, link tài liệu.
3. **Hợp đồng giao hàng** (từ mode đã chốt): mở đầu bằng một dòng cố định `Delivery contract: mode=<mode>`, kèm định nghĩa hoàn thành riêng của mode đó — chi tiết ở mục Delivery mode dưới.
4. **Task** (từ yêu cầu captain): việc cụ thể + định nghĩa hoàn thành.

Captain chỉ mô tả tầng 4; tầng 3 first mate tự chốt tại intake. File project **tự dày lên**: worker vấp bẫy mới → first mate đề nghị thêm một dòng vào file (captain gật mới ghi) — worker sau thừa hưởng.

File project có thể khai gợi ý model per loại task (scout → model rẻ/effort thấp, ship → model mạnh), first mate áp qua `worker-start --model … --effort …` (chỉ với terminal mới; `--effort` đòi `--model`).

## Delivery mode và no-mistakes

[`no-mistakes`](https://github.com/kunchenguid/no-mistakes) là một tool ngoài, không phải phần của distro: nó dựng một git proxy nội bộ đứng trước remote thật, và khi ta `git push no-mistakes` thì daemon tạo worktree dùng-một-lần, chạy pipeline cố định `intent → rebase → review → test → document → lint → push → pr → ci`, chỉ forward nhánh tới push target và mở PR sau khi mọi bước qua. Agent lái nó qua `no-mistakes axi`, một surface non-interactive in TOON ra stdout.

Phân vai giữ đúng tinh thần firstmate: **no-mistakes sở hữu pipeline, distro chỉ chọn mode và định tuyến quyết định.** Không chép lại cơ chế gate vào đây; `axi --help` của bản đang cài là authoritative.

### Mode

v1 có hai mode:

- **`direct-PR`** (mặc định): worker implement, push nhánh riêng, mở PR. Không pipeline.
- **`no-mistakes`**: worker implement, commit, rồi lái pipeline qua `axi`.

Mode khai trong frontmatter `projects/<tên>.md` (`delivery: direct-PR`) — đó là posture chuẩn của project. Captain chỉ định khác cho một task cụ thể thì task đó theo captain, first mate ghi lý do một dòng vào file request. **Project chưa có file tri thức → hỏi captain, không đoán mode.**

`local-only` (nhánh sạch tại chỗ, không remote) ngoài phạm vi v1.

### Hợp đồng giao hàng trong brief

Tầng 3 của brief mở đầu bằng dòng cố định `Delivery contract: mode=<mode>`, rồi:

- **`direct-PR`**: implement → push nhánh riêng → mở PR **bằng `gh`** → `worker_done --outcome succeeded` kèm URL `https://…` đầy đủ. Không bao giờ push nhánh mặc định, không bao giờ tự merge.
- **`no-mistakes`**: chạy `no-mistakes doctor`, nếu repo chưa init trong worktree thì `no-mistakes init`; implement → commit → `axi run --intent <ý định của captain>` → lái tiếp **mọi** `axi run`/`axi respond` cho tới outcome. `worker_done` chỉ gửi khi axi trả outcome terminal, và **body phải chứa outcome đó** (`passed` / `checks-passed` / `failed` / `cancelled`) cùng PR URL.

Vì brief đã bắt worker tự chạy `doctor`/`init`, **routing không cần probe gate readiness trên host** — host thiếu binary thì worker escalate. Đỡ hẳn một vòng khám phá xuyên host.

### Ask-user finding đi qua mailbox Orca

Pipeline dừng ở finding cần người quyết. Worker **không bao giờ tự trả lời finding của chính nó**: nó gọi `orchestration ask` kèm finding ID, step, các lựa chọn, và khuyến nghị của nó. First mate tỉnh dậy qua đúng message type `question` đã có sẵn trong mục Supervision, quyết theo chính sách dưới, rồi `orchestration reply` trả về **một quyết định chính xác**: action, finding ID, và câu lệnh `axi respond` cụ thể. Worker áp dụng và lái tiếp.

**First mate không bao giờ tự gọi `axi respond` cho run của worker.** Một run có đúng một người lái.

Chính sách quyết (skill `delivery` là owner duy nhất):

- **First mate tự quyết** finding không mơ hồ so với intent đã chấp nhận: sửa lỗi thật, hoàn thiện thiết kế đã duyệt, sửa hồi quy do một vòng fix trước làm hỏng, sửa nhỏ bắt buộc để hành vi đã chấp nhận đúng — kể cả khi khó.
- **Escalate lên captain** khi: Fix sẽ mở rộng hợp đồng (thêm guarantee, subsystem, abstraction, bề mặt tương thích, yêu cầu giám sát liên tục mà intent không đòi); là quyết định sản phẩm hoặc kiến trúc chưa chốt; nhiều finding cùng một chủ đề cho thấy các vòng fix đang đắp máy móc quanh một abstraction đáng ngờ; hoặc destructive, không đảo ngược được, nhạy cảm bảo mật.
- Nhãn của reviewer (`security`, `correctness`, `required`) là **bằng chứng về finding, không phải thẩm quyền nới scope**.

Escalation gửi captain nêu đủ: yêu cầu gốc, phần hợp đồng bị nới, phương án nhỏ nhất không nới, hệ quả của nhận và của từ chối, và khuyến nghị kèm lý do.

### An toàn release

Với task mode `no-mistakes`, `worker_done` thiếu outcome axi terminal thì **không release** — `worker-read --dispatch` để chẩn đoán rồi báo captain. Đây là chỗ Orca-native rẻ hơn firstmate thật: firstmate phải có một lớp attribution đối chiếu branch/head để đoán run nào thuộc worktree nào, còn ở đây hợp đồng brief bắt worker tự khai outcome, nên distro không cần lớp đó.

### Merge authority

v1: **captain merge mọi PR.** Thẩm quyền merge thường trực kiểu `yolo` ngoài phạm vi — nhưng ghi lại cho đúng: `yolo` là một trục **trực giao** với delivery mode, nó chỉ nói ai được merge, không nói work đi qua pipeline nào.

## Phụ thuộc bên ngoài

Cố ý giữ ngắn. Toàn bộ bề mặt phụ thuộc của distro:

| Thứ | Bắt buộc | Vì sao |
|---|---|---|
| Orca app + `orca` CLI | luôn | worktree, terminal, Run/Task/Dispatch, mailbox, federation |
| Claude Code **hoặc** Cursor | luôn | harness của first mate; mỗi cái một cơ chế đánh thức, xem mục CLI cài đặt |
| `git`, `gh` | luôn | worker push nhánh và mở PR |
| `jq` | luôn | hook parse payload JSON trên stdin và adapter Cursor merge JSON |
| `no-mistakes` | chỉ khi task mode `no-mistakes` | chạy validation pipeline; xem mục Delivery mode |

**Không dùng wrapper CLI của bên thứ ba.** firstmate bơm `gh-axi`, `chrome-devtools-axi`, `lavish-axi`, `tasks-axi`, `quota-axi` vào mọi brief và mọi lần bootstrap; orca-firstmate không. Lý do: phần lớn trong số đó tồn tại để dựng lại thứ Orca đã có (`tasks-axi` là sổ backlog tự chế — ở đây là `requests/` + Orca Run; `lavish-axi` board là fleet view tự chế — ở đây là `worktree ps --json`), còn phần còn lại chỉ là lớp mỏng trên CLI chính chủ. Đổi lại: worker parse JSON của `gh` tốn token hơn TOON, chấp nhận được.

`no-mistakes` là ngoại lệ có chủ đích, không phải wrapper: nó **là** pipeline, không có CLI chính chủ nào thay thế.

## Xử lý lỗi

- `worker-start` thất bại hoặc `outcome_unknown`: exit ≠ 0, JSON có `stage`/`failedStage`, `setup`, `effects`, `residualResources`, lệnh recovery. Quy tắc: **đọc receipt, làm đúng recovery ghi trong đó, không retry mù.** `--retry-of <dispatch_id>` khi thử lại để nối lịch sử (nhớ lặp lại placement vì retry không kế thừa). Còn tài nguyên dư → báo captain.
- Wait-for-setup timeout để setup ở trạng thái `running` là bình thường, không phải bằng chứng thất bại — kiểm tra lại trước khi kết luận.
- `worker-release` trả `release_pending`/`release_unknown`: theo đúng recovery action trong receipt; **cấm** thay bằng `terminal close`. Replay của mailbox delivery có thể lặp `worker-release` an toàn.
- Host dính chết giữa request: dừng, báo, chờ captain quyết (đổi host cho request là quyết định của captain, không của first mate).
- `ask` của worker timeout: câu hỏi vẫn pending, resume bằng message ID gốc — không tạo câu hỏi trùng.
- Lỗi daemon `no-mistakes`: worker escalate rồi dừng, không tự chữa. First mate cũng không restart daemon để "thông" một run — daemon dùng chung, restart giết run của worker khác. Đây là việc của captain trên máy sở hữu daemon.

## Kiểm thử

- **fake-orca**: script `tests/fake-orca/orca` đặt trước PATH, trả JSON mẫu đã đối chiếu với schema thật (lấy từ `orca agent-context --json` và output thật trên máy captain). Test lifecycle không cần app: routing loại host không ready, brief ghép đúng 4 tầng, hook exit 0 khi không có request mở / exit 2 khi có message, supervise không ack trước khi xử lý xong batch. Thêm ba ca cho delivery: brief mode `no-mistakes` sinh đúng dòng `Delivery contract:` và DoD chờ outcome axi; supervise **không** release khi `worker_done` của task `no-mistakes` thiếu outcome; `question` mang ask-user finding đi vào chính sách của `delivery` thay vì ack thẳng. Và ba ca cho entry point: `wake.sh` exit 0 khi `session_id` không khớp lock; `/firstmate` từ chối khi lock còn chủ sống; `/firstmate` thu hồi lock khi chủ đã chết.
- **Smoke thật** (chạy tay, có Orca thật): mở request → 1 task echo → worker chạy → `worker_done` → hook đánh thức → release → đóng request. Một biến thể `--on "Mac mini"`.
- Ghi kết quả smoke thật vào `docs/verification/` kèm version app đã kiểm (học cách firstmate làm evidence theo version, vì Orca không có protocol version marker — capabilities trong `orca status` là gate tương thích).

## Ngoài phạm vi v1 (YAGNI, chủ động ghi lại để khỏi bò vào)

- `local-only` (nhánh sạch tại chỗ, merge có kiểm soát vào `main` local) — v1 chỉ `direct-PR` và `no-mistakes`.
- Registry mode đầy đủ kiểu `no-mistakes-prod-only` (mode có điều kiện, phân loại bề mặt từng task) — v1 mode phẳng theo project, captain override được từng task.
- `yolo` / thẩm quyền merge thường trực — v1 captain merge mọi PR.
- Relay (X/Discord), AFK mode, voice.
- Secondmate/coordinator lồng nhau — flat: một first mate, N worker.
- Tự cân bằng tải giữa host — captain chọn host per-request là đủ.
- Scout report format riêng — v1 scout trả kết quả trong `worker_done` body; tách format khi thấy cần.

## Rủi ro đã biết

- **Gắn chặt schema orchestration của Orca**: Orca không có version marker ổn định; đổi contract sẽ lộ lúc runtime. Giảm nhẹ: kiểm `orchestration.contract.v1` trong capabilities lúc session start; fake-orca fixtures ghi rõ version app đã đối chiếu.
- **Stop hook `asyncRewake` là hành vi của Claude Code**, đổi harness là mất cơ chế wake — chấp nhận: distro này chọn Claude Code làm harness duy nhất của v1. Đã kiểm chứng trên 2.1.236 ở dạng plugin (`docs/verification/2026-08-31-plugin-wake.md`); docs Claude Code có ghi field này cho command hook nhưng **không** nói plugin hook honor nó, nên đây là hành vi cần đo lại khi lên version mới.
- **Adapter Cursor ghi vào file dùng chung.** Đã kiểm chứng cơ chế wake chạy đủ vòng ở `~/.cursor/hooks.json` cấp user, nhưng cũng vì thế `install` phải sửa một file Orca đang dùng. Merge sai là phá supervision của Orca, không chỉ của ta. Giảm nhẹ: merge idempotent theo khoá riêng, sao lưu trước khi ghi, và `doctor` kiểm lại entry của mình còn nguyên vẹn.
- **Cursor TUI báo version khác `--version`.** TUI in `2026.08.25-3e8eec8` còn `--version` in `2026.08.11-e8db854`. Đừng gate tương thích bằng `--version`.
- **Plugin hook chạy trong mọi phiên Claude Code trên máy.** Một `wake.sh` lỗi là lỗi toàn máy, không chỉ lỗi first mate. Giảm nhẹ: cổng lock đứng trước mọi thứ khác và mọi nhánh không chắc chắn đều exit 0.
- App Orca phải đang chạy — `orca open` ở session start nếu chưa.
- **Phụ thuộc thêm vào `no-mistakes`** cho mode cùng tên: tên outcome và tên lệnh `axi` có thể đổi giữa các version. Giảm nhẹ có sẵn trong thiết kế: distro **không bao giờ parse output TOON của axi** — worker lái pipeline và tự khai outcome trong `worker_done`, nên bề mặt gắn kết chỉ là bốn tên outcome terminal, không phải cả schema.
