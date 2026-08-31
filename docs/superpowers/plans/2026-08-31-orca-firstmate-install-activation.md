# orca-firstmate — Plan 1: Cài đặt và kích hoạt

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cài orca-firstmate bằng một lệnh vào Claude Code và Cursor, để gõ `/firstmate` ở bất kỳ thư mục nào biến phiên đó thành first mate, và một message trong mailbox Orca đánh thức được phiên đang idle.

**Architecture:** Một repo mang payload dùng chung (skill, command) cộng hai adapter harness. Payload cài vào `~/.orca-firstmate/dist/`; state chạy ở `~/.orca-firstmate/` và không bao giờ phụ thuộc cwd. Một file `lock` vừa bầu ra first mate duy nhất vừa làm cổng chặn cho hook — vì hook chạy sau mỗi lượt của **mọi** phiên harness trên máy. Adapter Claude là plugin trong thư mục riêng; adapter Cursor buộc phải merge vào `~/.cursor/hooks.json` dùng chung.

**Tech Stack:** bash (`set -u`, POSIX-ish), `jq` cho JSON, `orca` CLI, Claude Code plugin hooks, Cursor user-level hooks. Test bằng bash + `fake-orca` trên PATH; đường wake của Cursor test bằng pty driver Python.

**Spec:** `docs/superpowers/specs/2026-08-30-orca-firstmate-design.md`
**Bằng chứng đã đo:** `docs/verification/2026-08-31-plugin-wake.md` — mọi hằng số hành vi hook dưới đây lấy từ file này, không phải từ trí nhớ.

## Global Constraints

- **Platform: macOS only.** Orca chỉ chạy macOS; không viết nhánh Linux/Windows.
- **Không dependency runtime ngoài:** `orca` CLI, `jq`, `git`, `gh`. `jq` là bắt buộc vì cả hai hook đều parse payload JSON trên stdin — spec đã bổ sung nó vào bảng phụ thuộc. Tuyệt đối không dùng họ `*-axi` npm (`gh-axi`, `tasks-axi`, `quota-axi`, `chrome-devtools-axi`, `lavish-axi`) — captain từ chối wrapper bên thứ ba khi có CLI chính chủ.
- **CLI chỉ có mặt lúc cài và lúc chẩn đoán.** Không đường runtime nào được gọi `orca-firstmate`. Hook và skill nói chuyện thẳng với `orca`.
- **Mọi hook exit 0 ở mọi nhánh không chắc chắn.** Hook chạy trong mọi phiên harness trên máy captain; một hook lỗi là lỗi toàn máy.
- **Claude Stop hook:** `"asyncRewake": true`, `"timeout": 28800`. Đánh thức bằng `exit 2`, nội dung ra **stderr**.
- **Cursor stop hook:** `exit 2` là **no-op im lặng**. Kênh duy nhất là đúng một object `{"followup_message": "..."}` trên **stdout** kèm `exit 0`. Đăng ký `"loop_limit": 200`; trần tự chặn của ta là `OFM_CURSOR_LOOP_CEILING=5`, thấp hơn để bound của ta cắn trước.
- **`~/.cursor/hooks.json` là file dùng chung** — Orca đã có 8 entry trong đó. Chỉ được thêm/gỡ đúng entry của mình, nhận diện bằng chuỗi `wake-cursor.sh` trong `command`. Luôn sao lưu trước khi ghi.
- **Lệnh Orca luôn truyền `--run <run_id>` tường minh.** Không bao giờ dựa vào Run bound theo terminal: phiên first mate không phải terminal Orca.
- **`OFM_HOME` ghi đè home** cho test. Production mặc định `$HOME/.orca-firstmate`.
- **Không gate tương thích Cursor bằng `cursor-agent --version`** — TUI báo `2026.08.25-3e8eec8` còn `--version` báo `2026.08.11-e8db854`.

## Cấu trúc file

| File | Trách nhiệm |
|---|---|
| `lib/ofm-home.sh` | đường dẫn home, đọc/ghi `lock`, xác định pid harness và liveness |
| `lib/ofm-wake-lib.sh` | quét request đang mở, chờ nhiều Run cùng lúc, rút một dòng tóm tắt |
| `hooks/wake-claude.sh` | Stop hook Claude: cổng lock → chờ → `exit 2` + stderr |
| `hooks/wake-cursor.sh` | stop hook Cursor: cổng lock → trần loop → park-owner → `followup_message` |
| `hooks/reidentify-claude.sh` | PostCompact: lock khớp thì in lại identity ra stderr |
| `hooks/hooks.json` | manifest hook Claude (Stop + PostCompact) |
| `skills/identity/SKILL.md` | identity và hard rules của first mate |
| `commands/firstmate.md` | `/firstmate` — kích hoạt phiên |
| `.claude-plugin/plugin.json` | manifest plugin Claude Code |
| `bin/ofm-adapter-claude.sh` | cài/gỡ adapter Claude |
| `bin/ofm-adapter-cursor.sh` | merge/unmerge `~/.cursor/hooks.json` |
| `bin/orca-firstmate` | CLI: `install`, `doctor`, `update`, `uninstall` |
| `install.sh` | bootstrap `curl \| sh` — clone source, symlink CLI, KHÔNG tự cài vào harness |
| `tests/helpers.sh` | môi trường test tách biệt, fake harness, khẳng định |
| `tests/fake-orca/orca` | `orca` giả trên PATH |
| `tests/*.test.sh` | một file test mỗi đơn vị |
| `tests/run-all.sh` | chạy toàn bộ |

---

### Task 1: Bộ khung test và `fake-orca`

Không có cái này thì mọi task sau không chứng minh được gì. Làm trước.

**Files:**
- Create: `tests/helpers.sh`
- Create: `tests/fake-orca/orca`
- Create: `tests/run-all.sh`
- Create: `tests/helpers.test.sh`

**Interfaces:**
- Consumes: không
- Produces: `ofm_test_setup` (đặt `OFM_HOME` vào thư mục tạm, đưa `fake-orca` lên đầu `PATH`, export `OFM_TEST_TMP`), `ofm_test_teardown`, `assert_eq <got> <want> <label>`, `assert_rc <got> <want> <label>`, `assert_contains <haystack> <needle> <label>`, `fake_orca_queue <run_id> <json_line>` (nạp sẵn message cho `check` của run đó), `fake_orca_calls` (in log lệnh đã gọi).

- [ ] **Step 1: Viết test thất bại cho helpers**

```bash
# tests/helpers.test.sh
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"

ofm_test_setup

assert_contains "$OFM_HOME" "$OFM_TEST_TMP" "OFM_HOME nằm trong thư mục tạm"
[ -d "$OFM_HOME" ]; assert_rc $? 0 "OFM_HOME đã được tạo"

# fake-orca phải đứng trước orca thật trên PATH
resolved=$(command -v orca)
assert_contains "$resolved" "fake-orca" "orca giải ra fake-orca"

# check không có message thì trả rỗng và rc 0
out=$(orca orchestration check --run run_a --peek --json); rc=$?
assert_rc "$rc" 0 "check rỗng trả rc 0"
assert_eq "$out" "" "check rỗng không in gì"

# queue rồi check thì trả đúng dòng đó
fake_orca_queue run_a '{"type":"worker_done","outcome":"succeeded","body":"PR opened"}'
out=$(orca orchestration check --run run_a --peek --json)
assert_contains "$out" "worker_done" "check trả message đã queue"

# mọi lệnh đều được ghi log
assert_contains "$(fake_orca_calls)" "orchestration check --run run_a" "lệnh được ghi log"

ofm_test_teardown
ofm_test_report
```

- [ ] **Step 2: Chạy để thấy nó fail**

Run: `bash tests/helpers.test.sh`
Expected: FAIL — `tests/helpers.sh: No such file or directory`

- [ ] **Step 3: Viết `tests/helpers.sh`**

```bash
# tests/helpers.sh — môi trường test tách biệt. Source, đừng chạy.
# Mọi test chạy trong một OFM_HOME tạm và một PATH có fake-orca đứng trước,
# nên không test nào chạm vào home hay Orca thật của captain.
OFM_TEST_FAILURES=0
OFM_TEST_ASSERTS=0

ofm_test_setup() {
  OFM_TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ofm-test.XXXXXX") || exit 1
  export OFM_TEST_TMP
  export OFM_HOME="$OFM_TEST_TMP/home"
  mkdir -p "$OFM_HOME/requests" "$OFM_HOME/projects"
  export OFM_FAKE_ORCA_STATE="$OFM_TEST_TMP/fake-orca"
  mkdir -p "$OFM_FAKE_ORCA_STATE/queue"
  : > "$OFM_FAKE_ORCA_STATE/calls.log"
  OFM_TEST_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  export OFM_TEST_REPO
  export PATH="$OFM_TEST_REPO/tests/fake-orca:$PATH"
}

ofm_test_teardown() {
  [ -n "${OFM_TEST_TMP:-}" ] && rm -rf "$OFM_TEST_TMP"
}

fake_orca_queue() {  # <run_id> <json_line>
  printf '%s\n' "$2" >> "$OFM_FAKE_ORCA_STATE/queue/$1"
}

fake_orca_calls() { cat "$OFM_FAKE_ORCA_STATE/calls.log" 2>/dev/null; }

_ofm_fail() {
  OFM_TEST_FAILURES=$((OFM_TEST_FAILURES+1))
  printf 'FAIL: %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2" >&2
}

assert_eq() {  # <got> <want> <label>
  OFM_TEST_ASSERTS=$((OFM_TEST_ASSERTS+1))
  [ "$1" = "$2" ] || _ofm_fail "$1" "$2" "$3"
}

assert_rc() {  # <got_rc> <want_rc> <label>
  OFM_TEST_ASSERTS=$((OFM_TEST_ASSERTS+1))
  [ "$1" = "$2" ] || _ofm_fail "rc=$1" "rc=$2" "$3"
}

assert_contains() {  # <haystack> <needle> <label>
  OFM_TEST_ASSERTS=$((OFM_TEST_ASSERTS+1))
  case "$1" in *"$2"*) ;; *) _ofm_fail "$1" "chứa '$2'" "$3" ;; esac
}

ofm_test_report() {
  if [ "$OFM_TEST_FAILURES" -eq 0 ]; then
    printf 'ok: %s asserts passed (%s)\n' "$OFM_TEST_ASSERTS" "$(basename "$0")"
    exit 0
  fi
  printf 'FAILED: %s of %s asserts (%s)\n' "$OFM_TEST_FAILURES" "$OFM_TEST_ASSERTS" "$(basename "$0")" >&2
  exit 1
}
```

- [ ] **Step 4: Viết `tests/fake-orca/orca`**

```bash
#!/usr/bin/env bash
# orca giả cho test. Ghi log mọi lệnh, phục vụ message đã queue, và KHÔNG
# BAO GIỜ chạm mạng hay app thật. Chỉ hiện thực đúng bề mặt các test cần.
set -u
STATE="${OFM_FAKE_ORCA_STATE:?fake-orca cần OFM_FAKE_ORCA_STATE}"
printf '%s\n' "$*" >> "$STATE/calls.log"

run_id=""
wait_mode=0
timeout_ms=0
prev=""
for arg in "$@"; do
  case "$prev" in
    --run) run_id=$arg ;;
    --timeout-ms) timeout_ms=$arg ;;
  esac
  [ "$arg" = "--wait" ] && wait_mode=1
  prev=$arg
done

case "$1 ${2:-}" in
  "orchestration check")
    q="$STATE/queue/${run_id:-_none}"
    if [ -s "$q" ]; then
      cat "$q"
      exit 0
    fi
    if [ "$wait_mode" = 1 ]; then
      # Mô phỏng chờ: ngủ tối đa timeout rồi trả rỗng, giống hệt một lần
      # timeout thật. Test dùng timeout rất nhỏ.
      slept=0
      while [ "$slept" -lt "${timeout_ms:-0}" ]; do
        [ -s "$q" ] && { cat "$q"; exit 0; }
        sleep 0.05
        slept=$((slept+50))
      done
    fi
    exit 0
    ;;
  "status --json"|"status")
    printf '%s\n' "${OFM_FAKE_ORCA_STATUS:-{\"ok\":true,\"result\":{\"reachable\":true,\"state\":\"ready\",\"capabilities\":[\"orchestration.contract.v1\"]}}}"
    exit 0
    ;;
esac
exit 0
```

- [ ] **Step 5: Viết `tests/run-all.sh`**

```bash
#!/usr/bin/env bash
# Chạy mọi tests/*.test.sh, báo cáo gộp. Exit khác 0 nếu có file nào fail.
set -u
cd "$(dirname "$0")" || exit 1
failed=0
for t in *.test.sh; do
  if bash "$t"; then :; else failed=$((failed+1)); fi
done
if [ "$failed" -eq 0 ]; then
  printf '\nALL TEST FILES PASSED\n'; exit 0
fi
printf '\n%s TEST FILE(S) FAILED\n' "$failed" >&2; exit 1
```

- [ ] **Step 6: Chạy test cho pass**

Run: `chmod +x tests/fake-orca/orca tests/run-all.sh && bash tests/helpers.test.sh`
Expected: PASS — dòng cuối là `ok: <n> asserts passed (helpers.test.sh)`. Con số cụ thể KHÔNG phải hợp đồng: nếu nó lệch, đếm lại assert trong test là đúng, đừng sửa test cho khớp con số.

- [ ] **Step 7: Commit**

```bash
git add tests/
git commit -m "test: add isolated test harness and a fake orca CLI"
```

---

### Task 2: Home và lock

`lock` làm hai việc bằng một file: bầu ra first mate duy nhất, và làm cổng chặn rẻ nhất cho hook.

**Files:**
- Create: `lib/ofm-home.sh`
- Create: `tests/lock.test.sh`

**Interfaces:**
- Consumes: không
- Produces:
  - `ofm_home` → in đường dẫn home
  - `ofm_lock_path`, `ofm_requests_dir` → in đường dẫn
  - `ofm_lock_get <key>` → in giá trị, rỗng khi không có
  - `ofm_harness_pid <harness>` → in pid tổ tiên gần nhất khớp, rỗng khi không tìm thấy
  - `ofm_lock_claim <session_id> <harness> <pid>` → rc 0 chiếm được (in `claimed` hoặc `reclaimed`), rc 1 bị từ chối (in `held_by=<session_id>`)
  - `ofm_lock_matches <session_id>` → rc 0 khi khớp
  - `ofm_lock_release <session_id>` → rc 0, chỉ xoá khi đúng chủ

- [ ] **Step 1: Viết test thất bại**

```bash
# tests/lock.test.sh
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
ofm_test_setup
. "$OFM_TEST_REPO/lib/ofm-home.sh"

assert_eq "$(ofm_home)" "$OFM_HOME" "ofm_home tôn trọng OFM_HOME"
assert_eq "$(ofm_lock_path)" "$OFM_HOME/lock" "đường dẫn lock"

# Không có lock thì không phiên nào khớp
ofm_lock_matches "sess-a"; assert_rc $? 1 "không lock thì không khớp"

# Chiếm lock lần đầu
out=$(ofm_lock_claim "sess-a" claude $$); assert_rc $? 0 "chiếm được lock trống"
assert_contains "$out" "claimed" "báo claimed"
assert_eq "$(ofm_lock_get session_id)" "sess-a" "ghi session_id"
assert_eq "$(ofm_lock_get harness)" "claude" "ghi harness"
ofm_lock_matches "sess-a"; assert_rc $? 0 "chủ khớp"
ofm_lock_matches "sess-b"; assert_rc $? 1 "phiên khác không khớp"

# Chủ còn sống thì phiên khác bị từ chối
out=$(ofm_lock_claim "sess-b" claude $$); assert_rc $? 1 "từ chối khi chủ còn sống"
assert_contains "$out" "held_by=sess-a" "nêu tên chủ đang giữ"
assert_eq "$(ofm_lock_get session_id)" "sess-a" "lock không bị đổi chủ"

# Chính chủ gọi lại thì làm mới, không từ chối
ofm_lock_claim "sess-a" claude $$ >/dev/null; assert_rc $? 0 "chính chủ gọi lại thì ok"

# Chủ đã chết thì thu hồi được
printf 'session_id=sess-dead\nharness=claude\npid=999999\nsince=1\n' > "$(ofm_lock_path)"
out=$(ofm_lock_claim "sess-c" claude $$); assert_rc $? 0 "thu hồi được lock chết"
assert_contains "$out" "reclaimed" "báo reclaimed"
assert_eq "$(ofm_lock_get session_id)" "sess-c" "chủ mới đã ghi"

# Pid không phải số thì coi như không chứng minh được, KHÔNG thu hồi bừa
printf 'session_id=sess-x\nharness=claude\npid=abc\nsince=1\n' > "$(ofm_lock_path)"
ofm_lock_claim "sess-d" claude $$ >/dev/null; assert_rc $? 1 "pid rác thì không cướp lock"

# ofm_harness_pid: tìm được tổ tiên là bash (chính shell test), và không bịa ra pid
hp=$(ofm_harness_pid bash)
case "$hp" in ''|*[!0-9]*) assert_eq "$hp" "<numeric pid>" "tìm được pid tổ tiên bash" ;; esac
kill -0 "${hp:-0}" 2>/dev/null; assert_rc $? 0 "pid tổ tiên trả về đang sống"
assert_eq "$(ofm_harness_pid definitely-not-a-real-harness-xyz)" "" "không tìm thấy thì trả rỗng"

# Bất biến chống race: nhiều phiên cùng giành lock trống thì KHÔNG QUÁ MỘT phiên
# tin mình giữ lock. Không assert "đúng một" vì kẻ ghi cuối có thể ghi sau lần
# đọc lại của kẻ đọc cuối; bất biến thật là "không quá một".
rm -f "$(ofm_lock_path)"
race="$OFM_TEST_TMP/race"; mkdir -p "$race"
for i in 1 2 3 4 5 6 7 8 9 10; do
  ( ofm_lock_claim "race-$i" claude $$ > "$race/$i.out" 2>&1 ) &
done
wait
# ĐÚNG MỘT, không phải "không quá một": kẻ `mv` thành công cuối cùng, theo định
# nghĩa, không có ai ghi sau nó, nên lần đọc lại của nó phải thấy chính nó. Bản
# trước assert <=1 và đo ra 0 — nhưng đó là va chạm tên tmp, không phải race.
wins=$(grep -l '^claimed' "$race"/*.out 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$wins" "1" "đúng một phiên giành được lock trống"
losers=$(grep -l '^refused' "$race"/*.out 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$losers" "9" "chín phiên còn lại đều bị từ chối, không ai lỗi ghi"
owners=$(sed -n 's/^session_id=//p' "$(ofm_lock_path)" | wc -l | tr -d ' ')
assert_eq "$owners" "1" "lock cuối cùng chỉ ghi tên một phiên"

# session_id chứa newline phá lock file, phải bị chặn ngay ở cửa
rm -f "$(ofm_lock_path)"
out=$(ofm_lock_claim "$(printf 'a\nb')" claude $$); rc=$?
assert_rc "$rc" 1 "session_id chứa newline bị từ chối"
assert_contains "$out" "newline" "nói rõ lý do"
assert_eq "$(ofm_lock_get session_id)" "" "không ghi lock nào khi session_id xấu"
out=$(ofm_lock_claim "" claude $$); rc=$?
assert_rc "$rc" 1 "session_id rỗng bị từ chối"

# Release chỉ có tác dụng với đúng chủ
printf 'session_id=sess-e\nharness=claude\npid=%s\nsince=1\n' $$ > "$(ofm_lock_path)"
ofm_lock_release "sess-other" >/dev/null
assert_eq "$(ofm_lock_get session_id)" "sess-e" "người lạ không release được"
ofm_lock_release "sess-e" >/dev/null
assert_eq "$(ofm_lock_get session_id)" "" "đúng chủ thì release được"

ofm_test_teardown
ofm_test_report
```

- [ ] **Step 2: Chạy để thấy nó fail**

Run: `bash tests/lock.test.sh`
Expected: FAIL — `lib/ofm-home.sh: No such file or directory`

- [ ] **Step 3: Viết `lib/ofm-home.sh`**

```bash
# shellcheck shell=bash
# Đường dẫn home và lock first-mate duy nhất. Source từ hook, CLI và test.
#
# LOCK LÀ CỔNG CHẶN CỦA HOOK. Hook chạy sau mỗi lượt của MỌI phiên harness
# trên máy, nên ofm_lock_matches phải là thao tác rẻ nhất có thể (một lần đọc
# file) và mọi nhánh không chắc chắn phải trả "không khớp".
#
# LIVENESS KHÔNG BAO GIỜ ĐOÁN. Một pid không phân giải được là "chưa chứng
# minh được", không phải "đã chết": cướp lock của một first mate còn sống là
# hỏng nặng hơn nhiều so với việc bắt captain gỡ tay một lock cũ.

ofm_home() { printf '%s' "${OFM_HOME:-$HOME/.orca-firstmate}"; }
ofm_lock_path() { printf '%s/lock' "$(ofm_home)"; }
ofm_requests_dir() { printf '%s/requests' "$(ofm_home)"; }

ofm_lock_get() {  # <key>
  local f
  f=$(ofm_lock_path)
  [ -f "$f" ] || return 0
  sed -n "s/^$1=//p" "$f" 2>/dev/null | head -1
}

ofm_harness_pid() {  # <harness> — in pid tổ tiên gần nhất khớp, rỗng nếu không có
  local want=$1 pid=$$ hops=0 comm ppid
  while [ "$pid" != "1" ] && [ "$hops" -lt 20 ]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 0
    case "$comm" in *"$want"*) printf '%s' "$pid"; return 0 ;; esac
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$ppid" ] || return 0
    pid=$ppid
    hops=$((hops + 1))
  done
}

ofm_lock_matches() {  # <session_id>
  local want=$1 have
  [ -n "$want" ] || return 1
  have=$(ofm_lock_get session_id)
  [ -n "$have" ] && [ "$have" = "$want" ]
}

_ofm_lock_write() {  # <session_id> <harness> <pid>
  local f tmp
  f=$(ofm_lock_path)
  mkdir -p "$(ofm_home)" || return 1
  # mktemp, KHÔNG "$f.$$": trong bash, `$$` bên trong subshell là pid của shell
  # CHA, nên nhiều subshell cùng cha dùng chung một tên tmp, ghi đè lẫn nhau và
  # làm `mv` thất bại. Test race chính là ca đó, và nó từng đo sai vì lỗi này —
  # báo "không ai giành được lock" khi thực ra chỉ là va chạm tên file tạm.
  tmp=$(mktemp "$f.XXXXXX") || return 1
  printf 'session_id=%s\nharness=%s\npid=%s\nsince=%s\n' "$1" "$2" "$3" "$(date +%s)" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# Đọc LẠI lock sau khi ghi, và chỉ báo thành công khi ta thực sự là chủ.
# Vì sao cần: chuỗi đọc-quyết-ghi trong ofm_lock_claim không nguyên tử, nên hai
# phiên cùng thấy lock trống (hoặc cùng thấy một chủ đã chết) đều ghi và đều
# tưởng mình thắng — đúng hỏng hóc tệ nhất của thiết kế này: hai phiên cùng ghi
# requests/. Đọc lại biến bất biến thành "KHÔNG BAO GIỜ có quá một phiên tin
# mình giữ lock", không cần thêm file mutex nào và không sinh trạng thái mutex cũ.
_ofm_lock_confirm() {  # <session_id> <verb> <detail>
  local sid=$1 verb=$2 detail=$3 winner
  if ofm_lock_matches "$sid"; then
    printf '%s %s\n' "$verb" "$detail"
    return 0
  fi
  winner=$(ofm_lock_get session_id)
  printf 'refused held_by=%s pid=%s\n' "${winner:-unknown}" "$(ofm_lock_get pid)"
  return 1
}

ofm_lock_claim() {  # <session_id> <harness> <pid>
  local sid=$1 harness=$2 pid=$3 owner owner_pid
  # Lock file là key=value theo dòng và đọc bằng sed, nên một session_id chứa
  # newline sẽ ghi ra file mà chính ta không đọc lại được -> claimant đơn lẻ bị
  # refused một cách bí ẩn. Chặn ngay ở cửa, nói rõ lý do.
  case "$sid" in '') printf 'refused reason=empty_session_id\n'; return 1 ;; esac
  if [ "$(printf '%s' "$sid" | tr -cd '\n' | wc -c | tr -d ' ')" != "0" ]; then
    printf 'refused reason=session_id_has_newline\n'
    return 1
  fi
  owner=$(ofm_lock_get session_id)
  if [ -n "$owner" ]; then
    if [ "$owner" = "$sid" ]; then
      _ofm_lock_write "$sid" "$harness" "$pid" || return 1
      printf 'refreshed session_id=%s\n' "$sid"
      return 0
    fi
    owner_pid=$(ofm_lock_get pid)
    case "$owner_pid" in
      ''|*[!0-9]*)
        # Không phân giải được chủ cũ: từ chối thay vì cướp.
        printf 'refused held_by=%s pid=unresolvable\n' "$owner"
        return 1
        ;;
    esac
    # CHỈ liveness quyết định. Một pid còn sống không bao giờ bị cướp lock, kể
    # cả khi `ps -o comm=` không khớp harness: tên lệnh không khớp là bằng chứng
    # yếu về "không phải harness đó", không phải bằng chứng về "đã chết". Cướp
    # lock của một first mate còn sống thì hai phiên cùng ghi requests/.
    if kill -0 "$owner_pid" 2>/dev/null; then
      printf 'refused held_by=%s pid=%s\n' "$owner" "$owner_pid"
      return 1
    fi
    _ofm_lock_write "$sid" "$harness" "$pid" || return 1
    _ofm_lock_confirm "$sid" reclaimed "from=$owner dead_pid=$owner_pid"
    return $?
  fi
  _ofm_lock_write "$sid" "$harness" "$pid" || return 1
  _ofm_lock_confirm "$sid" claimed "session_id=$sid"
}

ofm_lock_release() {  # <session_id> — chỉ đúng chủ mới xoá được
  ofm_lock_matches "$1" || { printf 'not_owner\n'; return 0; }
  rm -f "$(ofm_lock_path)"
  printf 'released\n'
}
```

- [ ] **Step 4: Chạy test cho pass**

Run: `bash tests/lock.test.sh`
Expected: PASS — dòng cuối là `ok: <n> asserts passed (lock.test.sh)`. Con số cụ thể KHÔNG phải hợp đồng: nếu nó lệch, đếm lại assert trong test là đúng, đừng sửa test cho khớp con số.

- [ ] **Step 5: Commit**

```bash
git add lib/ofm-home.sh tests/lock.test.sh
git commit -m "feat: add the home paths and single-first-mate lock"
```

---

### Task 3: Quét request và chờ nhiều Run

Tách khỏi hook vì cả hai harness dùng chung, và vì đây là phần duy nhất có logic đồng thời.

**Files:**
- Create: `lib/ofm-wake-lib.sh`
- Create: `tests/wake-lib.test.sh`

**Interfaces:**
- Consumes: `lib/ofm-home.sh` (`ofm_requests_dir`)
- Produces:
  - `ofm_open_run_ids` → in mỗi dòng một `run_id` của request có `status: open`
  - `ofm_wait_any_run <timeout_ms>` → đọc run id từ stdin, chờ song song, in **một dòng** tóm tắt của message đầu tiên tới; rỗng khi hết giờ. Luôn rc 0.
  - `ofm_summarize <json_line>` → in một dòng ngắn dạng `<type> run=<id> <detail>`

- [ ] **Step 1: Viết test thất bại**

```bash
# tests/wake-lib.test.sh
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
ofm_test_setup
. "$OFM_TEST_REPO/lib/ofm-home.sh"
. "$OFM_TEST_REPO/lib/ofm-wake-lib.sh"
# Nhịp poll production là 1000ms; test hạ xuống để chạy nhanh.
export OFM_WAKE_POLL_MS=50

mk_request() {  # <slug> <run_id> <status>
  printf -- '---\nrun_id: %s\nproject: demo\nhost: local\nstatus: %s\nopened: 2026-08-31\n---\nyêu cầu gốc\n' \
    "$2" "$3" > "$(ofm_requests_dir)/$1.md"
}

assert_eq "$(ofm_open_run_ids)" "" "không có request thì không có run"

mk_request one run_a open
mk_request two run_b closed
assert_eq "$(ofm_open_run_ids)" "run_a" "chỉ lấy request open"

mk_request three run_c open
got=$(ofm_open_run_ids | sort | tr '\n' ',')
assert_eq "$got" "run_a,run_c," "lấy được nhiều run open"

# Hết giờ mà không có message thì in rỗng, rc vẫn 0
out=$(ofm_open_run_ids | ofm_wait_any_run 200); rc=$?
assert_rc "$rc" 0 "hết giờ vẫn rc 0"
assert_eq "$out" "" "hết giờ thì không in gì"

# Message ở run thứ hai vẫn được bắt: chờ song song, không tuần tự
fake_orca_queue run_c '{"type":"worker_done","run_id":"run_c","outcome":"succeeded","body":"PR https://x/1"}'
out=$(ofm_open_run_ids | ofm_wait_any_run 3000)
assert_contains "$out" "worker_done" "bắt được message của run thứ hai"
assert_contains "$out" "run_c" "tóm tắt nêu run id"

# Tóm tắt luôn gói về một dòng
lines=$(printf '%s' "$out" | wc -l | tr -d ' ')
assert_eq "$lines" "0" "tóm tắt là đúng một dòng, không newline cuối"

# Frontmatter là nguồn duy nhất: "status: open" trong phần văn xuôi không tính
printf -- '---\nrun_id: run_body\nstatus: closed\n---\nstatus: open\n' > "$(ofm_requests_dir)/body.md"
assert_eq "$(ofm_open_run_ids | grep -c run_body || true)" "0" "status trong văn xuôi không tính"
# File không mở bằng `---` thì bỏ qua hẳn
printf 'lời nói đầu\n---\nrun_id: run_late\nstatus: open\n---\n' > "$(ofm_requests_dir)/late.md"
assert_eq "$(ofm_open_run_ids | grep -c run_late || true)" "0" "frontmatter không ở đầu file thì bỏ qua"
rm -f "$(ofm_requests_dir)/body.md" "$(ofm_requests_dir)/late.md"

# CRLF không được âm thầm biến một request đang mở thành không-mở
printf -- '---\r\nrun_id: run_crlf\r\nstatus: open\r\n---\r\n' > "$(ofm_requests_dir)/crlf.md"
assert_eq "$(ofm_open_run_ids | grep -c run_crlf || true)" "1" "frontmatter CRLF vẫn đọc được"
rm -f "$(ofm_requests_dir)/crlf.md"

# ofm_summarize: newline lọt qua .type hay .run_id cũng phải bị gói về một dòng
s=$(ofm_summarize '{"type":"worker\ndone","run_id":"r\n1","body":"a\nb"}')
assert_eq "$(printf '%s' "$s" | grep -c . )" "1" "tóm tắt luôn đúng một dòng dù mọi trường có newline"

# Giết tiến trình chờ từ ngoài thì con `orca` phải chết theo, không để lại mồ côi
printf -- '---\nrun_id: run_orphanprobe\nstatus: open\n---\nx\n' > "$(ofm_requests_dir)/orphan.md"
( printf 'run_orphanprobe\n' | ofm_wait_any_run 30000 >/dev/null 2>&1 ) & waiter=$!
sleep 0.8
kill "$waiter" 2>/dev/null || true
sleep 0.8
leaked=$(pgrep -f 'run_orphanprobe' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$leaked" "0" "không để lại orca mồ côi sau khi tiến trình chờ bị giết"
pkill -f 'run_orphanprobe' 2>/dev/null || true
rm -f "$(ofm_requests_dir)/orphan.md"

# Dòng keepalive bị bỏ qua, không bị coi là message
fake_orca_queue run_a '{"_keepalive":true}'
out=$(printf 'run_a\n' | ofm_wait_any_run 300)
assert_eq "$out" "" "keepalive không tính là message"

ofm_test_teardown
ofm_test_report
```

- [ ] **Step 2: Chạy để thấy nó fail**

Run: `bash tests/wake-lib.test.sh`
Expected: FAIL — `lib/ofm-wake-lib.sh: No such file or directory`

- [ ] **Step 3: Viết `lib/ofm-wake-lib.sh`**

```bash
# shellcheck shell=bash
# Quét request đang mở và chờ mailbox nhiều Run cùng lúc.
# Cần source lib/ofm-home.sh trước.
#
# VÌ SAO CHỜ SONG SONG: `orca orchestration check` là per-Run (`--run <id>`),
# và spec cho phép nhiều request mở cùng lúc. Chờ tuần tự thì một Run im lặng
# sẽ chặn message của Run khác suốt cả timeout. Ta bung mỗi Run một tiến trình
# nền, ai có tin trước thì thắng, rồi giết phần còn lại.
#
# LUÔN TRUYỀN --run: phiên first mate không phải terminal Orca nên không có
# Run nào bound theo terminal để dựa vào.

OFM_WAKE_TYPES="${OFM_WAKE_TYPES:-worker_done,escalation,question}"
# Nhịp poll. Production để 1000ms: ở timeout tám tiếng thì đó là 28.500 vòng
# thay vì 285.000, mà độ trễ đánh thức thêm dưới một giây thì con người không
# nhận ra. Test hạ xuống 50ms cho nhanh.
OFM_WAKE_POLL_MS="${OFM_WAKE_POLL_MS:-1000}"

# Chỉ trả về phần frontmatter: khối giữa dòng `---` thứ nhất và `---` thứ hai.
# Một chữ "status:" nằm trong phần văn xuôi không được phép quyết định gì, và
# `tr -d '\r'` để một file CRLF không âm thầm bị coi là không-mở.
_ofm_frontmatter() {  # <file>
  awk '
    NR==1 && $0 != "---" { exit }
    /^---[[:space:]]*$/ { n++; if (n==2) exit; next }
    n==1 { print }
  ' "$1" 2>/dev/null | tr -d '\r'
}

ofm_open_run_ids() {
  local dir f fm status run
  dir=$(ofm_requests_dir)
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    fm=$(_ofm_frontmatter "$f")
    [ -n "$fm" ] || continue
    status=$(printf '%s\n' "$fm" | sed -n 's/^status:[[:space:]]*//p' | head -1)
    [ "$status" = "open" ] || continue
    run=$(printf '%s\n' "$fm" | sed -n 's/^run_id:[[:space:]]*//p' | head -1)
    [ -n "$run" ] && printf '%s\n' "$run"
  done
}

ofm_summarize() {  # <json_line>
  local line=$1 type run detail
  type=$(printf '%s' "$line" | jq -r '.type // "message"' 2>/dev/null)
  run=$(printf '%s' "$line" | jq -r '.run_id // ""' 2>/dev/null)
  detail=$(printf '%s' "$line" | jq -r '.outcome // .body // ""' 2>/dev/null | tr '\n\r\t' '   ' | cut -c1-120)
  # MỌI trường đi qua tr, không chỉ detail: caller dựa vào "đúng một dòng", và
  # một newline lọt qua .type hay .run_id phá hợp đồng đó y như trong .body.
  printf '%s run=%s %s' "${type:-message}" "${run:-?}" "${detail}" \
    | tr '\n\r\t' '   ' | sed 's/[[:space:]]*$//'
}

# Đọc run id từ stdin, chờ tối đa <timeout_ms>, in một dòng tóm tắt hoặc rỗng.
ofm_wait_any_run() {  # <timeout_ms>
  # Cả thân hàm nằm trong một subshell để `trap` chỉ thuộc về nó, không dính
  # vào shell của caller.
  (
    local timeout_ms=$1 tmp run i=0 line poll_s deadline f
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/ofm-wake.XXXXXX") || return 0
    # TRAP TRƯỚC KHI SPAWN BẤT CỨ GÌ. Nếu tiến trình này bị giết từ ngoài —
    # harness cắt hook, captain đóng phiên, máy sleep — thì mọi `orca --wait`
    # con phải chết theo. Không có trap thì MỖI LƯỢT của MỖI phiên trên máy để
    # lại một tiến trình mồ côi có thể sống tới tám tiếng. Trap cũng là đường
    # dọn duy nhất cho cả ba lối ra bình thường, nên không còn chỗ nào phải
    # nhớ gọi cleanup bằng tay.
    trap '_ofm_wake_kill_all "$tmp"; rm -rf "$tmp"' EXIT INT TERM HUP
    while IFS= read -r run; do
      [ -n "$run" ] || continue
      i=$((i + 1))
      (
        orca orchestration check --wait --peek --run "$run" \
          --types "$OFM_WAKE_TYPES" --timeout-ms "$timeout_ms" --json \
          2>/dev/null > "$tmp/$i.out"
      ) &
      printf '%s\n' "$!" >> "$tmp/pids"
    done
    [ "$i" -gt 0 ] || return 0

    # Deadline theo giờ THẬT, không theo bộ đếm logic: bộ đếm cộng dồn nhịp
    # poll rồi trôi khỏi thời gian thực, vì mỗi vòng còn tốn thời gian chạy
    # thân vòng — và càng trôi khi file lớn dần.
    poll_s=$(awk -v m="${OFM_WAKE_POLL_MS:-1000}" 'BEGIN{printf "%.3f", m/1000}')
    deadline=$(( $(date +%s) + (timeout_ms + 999) / 1000 ))
    while :; do
      for f in "$tmp"/*.out; do
        [ -s "$f" ] || continue
        # grep rẻ đứng trước jq: `--types` đã bảo đảm mọi message trả về đều
        # có `type`, còn keepalive của Orca đi ra stderr và bị bỏ, nên hầu hết
        # vòng lặp không phải fork jq nào.
        grep -q '"type"' "$f" 2>/dev/null || continue
        line=$(jq -rc 'select(._keepalive|not) | select(.type? != null)' "$f" 2>/dev/null | head -1)
        [ -n "$line" ] || continue
        ofm_summarize "$line"
        return 0
      done
      [ "$(date +%s)" -lt "$deadline" ] || return 0
      sleep "$poll_s"
    done
  )
}

_ofm_wake_kill_all() {  # <tmpdir>
  local p
  [ -f "$1/pids" ] || return 0
  while IFS= read -r p; do
    case "$p" in ''|*[!0-9]*) continue ;; esac
    kill "$p" 2>/dev/null || true
  done < "$1/pids"
  wait 2>/dev/null || true
}
```

- [ ] **Step 4: Chạy test cho pass**

Run: `bash tests/wake-lib.test.sh`
Expected: PASS — dòng cuối là `ok: <n> asserts passed (wake-lib.test.sh)`. Con số cụ thể KHÔNG phải hợp đồng: nếu nó lệch, đếm lại assert trong test là đúng, đừng sửa test cho khớp con số.

- [ ] **Step 5: Commit**

```bash
git add lib/ofm-wake-lib.sh tests/wake-lib.test.sh
git commit -m "feat: wait on every open run's mailbox concurrently"
```

---

### Task 4: Stop hook cho Claude Code

**Files:**
- Create: `hooks/wake-claude.sh`
- Create: `tests/wake-claude.test.sh`

**Interfaces:**
- Consumes: `ofm_lock_matches`, `ofm_open_run_ids`, `ofm_wait_any_run`
- Produces: hook nhận payload JSON trên stdin; `exit 0` im lặng hoặc `exit 2` kèm một dòng stderr. `OFM_WAIT_TIMEOUT_MS` ghi đè timeout cho test.

- [ ] **Step 1: Viết test thất bại**

```bash
# tests/wake-claude.test.sh
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
ofm_test_setup
. "$OFM_TEST_REPO/lib/ofm-home.sh"
HOOK="$OFM_TEST_REPO/hooks/wake-claude.sh"
export OFM_WAIT_TIMEOUT_MS=300

payload() { printf '{"session_id":"%s","cwd":"/tmp","hook_event_name":"Stop"}' "$1"; }
mk_request() {
  printf -- '---\nrun_id: %s\nproject: demo\nhost: local\nstatus: %s\nopened: 2026-08-31\n---\nx\n' \
    "$2" "$3" > "$(ofm_requests_dir)/$1.md"
}

# Không có lock: câm tuyệt đối. Đây là cổng bảo vệ mọi phiên khác trên máy.
out=$(payload sess-a | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 0 "không lock thì exit 0"
assert_eq "$out" "" "không lock thì không in gì"
assert_eq "$(fake_orca_calls)" "" "không lock thì không gọi orca"

# Lock của phiên khác: vẫn câm
printf 'session_id=sess-other\nharness=claude\npid=%s\nsince=1\n' $$ > "$(ofm_lock_path)"
out=$(payload sess-a | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 0 "session_id khác lock thì exit 0"
assert_eq "$(fake_orca_calls)" "" "session_id khác thì không gọi orca"

# Đúng chủ nhưng không có request mở: exit 0, vẫn không gọi orca
printf 'session_id=sess-a\nharness=claude\npid=%s\nsince=1\n' $$ > "$(ofm_lock_path)"
out=$(payload sess-a | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 0 "không request mở thì exit 0"
assert_eq "$(fake_orca_calls)" "" "không request mở thì không gọi orca"

# Đúng chủ, có request mở, không có message: exit 0 và CÓ gọi orca
mk_request one run_a open
out=$(payload sess-a | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 0 "hết giờ thì exit 0"
assert_contains "$(fake_orca_calls)" "--run run_a" "có chờ đúng run"

# Có message: exit 2 và in tóm tắt ra STDERR
fake_orca_queue run_a '{"type":"worker_done","run_id":"run_a","outcome":"succeeded"}'
err=$(payload sess-a | bash "$HOOK" 2>&1 >/dev/null); rc=$?
assert_rc "$rc" 2 "có message thì exit 2"
assert_contains "$err" "worker_done" "stderr mang tóm tắt"
stdout=$(payload sess-a | bash "$HOOK" 2>/dev/null); 
assert_eq "$stdout" "" "không in gì ra stdout"

# Payload rác không làm hook nổ
out=$(printf 'not json' | bash "$HOOK" 2>&1); rc=$?
assert_rc "$rc" 0 "payload rác thì exit 0"

ofm_test_teardown
ofm_test_report
```

- [ ] **Step 2: Chạy để thấy nó fail**

Run: `bash tests/wake-claude.test.sh`
Expected: FAIL — `hooks/wake-claude.sh: No such file or directory`

- [ ] **Step 3: Viết `hooks/wake-claude.sh`**

```bash
#!/usr/bin/env bash
# Stop hook của Claude Code — nửa Claude của cơ chế tự thức dậy.
#
# Đăng ký với "asyncRewake": true và "timeout": 28800. Đã kiểm chứng trên
# Claude Code 2.1.236 (docs/verification/2026-08-31-plugin-wake.md):
#   - asyncRewake được honor trong plugin hook: phiên không bị chặn.
#   - exit 2 đánh thức phiên đang IDLE, stderr vào context dạng system reminder.
#   - exit 0 câm tuyệt đối.
#
# HOOK NÀY CHẠY SAU MỖI LƯỢT CỦA MỌI PHIÊN CLAUDE CODE TRÊN MÁY, không dedupe.
# Nên thứ tự cổng chặn là bắt buộc, rẻ trước đắt sau, và mọi nhánh không chắc
# chắn đều exit 0.
#
# HOOK KHÔNG BAO GIỜ ACK. Ack thuộc về first mate sau khi xử lý xong batch;
# nhờ replay-tới-ack của Orca, hook chết giữa chừng không mất message.
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)" || exit 0
[ -r "$LIB/ofm-home.sh" ] || exit 0
# shellcheck source=/dev/null
. "$LIB/ofm-home.sh"
# shellcheck source=/dev/null
. "$LIB/ofm-wake-lib.sh"

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null || true)
session_id=$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null) || exit 0

# Cổng 1 — rẻ nhất: phiên này có phải first mate không?
ofm_lock_matches "$session_id" || exit 0

# Cổng 2: có gì để chờ không? Home rỗng thì không tốn một lệnh orca nào.
runs=$(ofm_open_run_ids)
[ -n "$runs" ] || exit 0

# Chờ ngắn hơn timeout của hook một khoảng an toàn để hook luôn tự thoát
# có kiểm soát thay vì bị harness giết giữa chừng.
summary=$(printf '%s\n' "$runs" | ofm_wait_any_run "${OFM_WAIT_TIMEOUT_MS:-28500000}")
[ -n "$summary" ] || exit 0

printf 'orca-firstmate: %s\n' "$summary" >&2
exit 2
```

- [ ] **Step 4: Chạy test cho pass**

Run: `chmod +x hooks/wake-claude.sh && bash tests/wake-claude.test.sh`
Expected: PASS — dòng cuối là `ok: <n> asserts passed (wake-claude.test.sh)`. Con số cụ thể KHÔNG phải hợp đồng: nếu nó lệch, đếm lại assert trong test là đúng, đừng sửa test cho khớp con số.

- [ ] **Step 5: Commit**

```bash
git add hooks/wake-claude.sh tests/wake-claude.test.sh
git commit -m "feat: add the Claude Code stop hook that wakes an idle first mate"
```

---

### Task 5: Stop hook cho Cursor

Khác Claude ở **mọi** primitive: chạy đồng bộ, `exit 2` vô hiệu, kênh duy nhất là `followup_message` trên stdout, và hai park có thể cùng sống nên phải có park-owner.

**Files:**
- Create: `hooks/wake-cursor.sh`
- Create: `tests/wake-cursor.test.sh`

**Interfaces:**
- Consumes: `ofm_lock_matches`, `ofm_open_run_ids`, `ofm_wait_any_run`
- Produces: hook đọc payload Cursor trên stdin (`session_id`, `loop_count`); in đúng một object `{"followup_message": "..."}` ra stdout rồi `exit 0`, hoặc không in gì và `exit 0`. Dùng `$(ofm_home)/park-owner` làm sổ giành quyền.

- [ ] **Step 1: Viết test thất bại**

```bash
# tests/wake-cursor.test.sh
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
ofm_test_setup
. "$OFM_TEST_REPO/lib/ofm-home.sh"
HOOK="$OFM_TEST_REPO/hooks/wake-cursor.sh"
export OFM_WAIT_TIMEOUT_MS=300

payload() {  # <session_id> <loop_count>
  printf '{"session_id":"%s","loop_count":%s,"workspace_roots":["/tmp"],"status":"completed"}' "$1" "$2"
}
mk_request() {
  printf -- '---\nrun_id: %s\nproject: demo\nhost: local\nstatus: open\nopened: 2026-08-31\n---\nx\n' \
    "$2" > "$(ofm_requests_dir)/$1.md"
}

# Không lock: câm
out=$(payload sess-a 0 | bash "$HOOK" 2>/dev/null); rc=$?
assert_rc "$rc" 0 "không lock thì exit 0"
assert_eq "$out" "" "không lock thì stdout rỗng"

printf 'session_id=sess-a\nharness=cursor-agent\npid=%s\nsince=1\n' $$ > "$(ofm_lock_path)"
mk_request one run_a

# Có message: in đúng một object followup_message, exit 0 (KHÔNG phải exit 2)
fake_orca_queue run_a '{"type":"worker_done","run_id":"run_a","outcome":"succeeded"}'
out=$(payload sess-a 0 | bash "$HOOK" 2>/dev/null); rc=$?
assert_rc "$rc" 0 "Cursor luôn exit 0, kể cả khi đánh thức"
assert_contains "$out" "followup_message" "in followup_message"
assert_contains "$out" "worker_done" "followup mang tóm tắt"
lines=$(printf '%s\n' "$out" | grep -c . )
assert_eq "$lines" "1" "in đúng MỘT dòng JSON"
printf '%s' "$out" | jq -e '.followup_message' >/dev/null 2>&1
assert_rc $? 0 "stdout là JSON hợp lệ"

# Trần loop cắn trước loop_limit của Cursor
out=$(payload sess-a 5 | bash "$HOOK" 2>/dev/null); rc=$?
assert_rc "$rc" 0 "chạm trần thì exit 0"
assert_eq "$out" "" "chạm trần thì không emit"

# Park cũ hơn phải đứng im khi đã có park mới hơn
printf '7\n' > "$OFM_HOME/park-owner"
out=$(payload sess-a 0 | OFM_CURSOR_PARK_SEQ=3 bash "$HOOK" 2>/dev/null)
assert_eq "$out" "" "park cũ không emit khi đã bị thay"

ofm_test_teardown
ofm_test_report
```

- [ ] **Step 2: Chạy để thấy nó fail**

Run: `bash tests/wake-cursor.test.sh`
Expected: FAIL — `hooks/wake-cursor.sh: No such file or directory`

- [ ] **Step 3: Viết `hooks/wake-cursor.sh`**

```bash
#!/usr/bin/env bash
# stop hook của Cursor — nửa Cursor của cơ chế tự thức dậy.
#
# KHÔNG DÙNG LẠI ĐƯỢC CÔNG THỨC CỦA CLAUDE. Đã đo trên cursor-agent TUI
# 2026.08.25-3e8eec8 (docs/verification/2026-08-31-plugin-wake.md):
#   - Cursor chạy hook ĐỒNG BỘ và chờ nó: hook "park" giữ turn boundary mở.
#   - exit 2 là NO-OP IM LẶNG. Không bao giờ dựa vào nó.
#   - Kênh duy nhất là đúng một {"followup_message": "..."} trên STDOUT + exit 0.
#     Cursor nhận nó và chạy một lượt model mới.
#   - `loop_count` trong payload là bản Cursor của stop_hook_active.
#   - Hook này KHÔNG cài được dạng plugin; nó chỉ fire từ ~/.cursor/hooks.json.
#
# PARK-OWNER. Một tin captain gõ lúc hook đang park được nhận ngay và KHÔNG
# giết hook đang park. Nên hai park có thể cùng sống, cùng thấy một message
# (ta dùng --peek nên không ai ack), và cùng báo -> trùng. Mỗi lần chạy giành
# một số thứ tự tăng dần; trước khi emit phải xác nhận mình vẫn là số mới nhất.
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)" || exit 0
[ -r "$LIB/ofm-home.sh" ] || exit 0
# shellcheck source=/dev/null
. "$LIB/ofm-home.sh"
# shellcheck source=/dev/null
. "$LIB/ofm-wake-lib.sh"

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null || true)
session_id=$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null) || exit 0
loop_count=$(printf '%s' "$payload" | jq -r '.loop_count // 0' 2>/dev/null)

ofm_lock_matches "$session_id" || exit 0

# Trần tự chặn, đặt THẤP HƠN loop_limit đăng ký trong hooks.json, để bound của
# ta cắn trước và Cursor không lặng lẽ ngừng gọi hook ở trần của nó.
ceiling=${OFM_CURSOR_LOOP_CEILING:-5}
case "$loop_count" in ''|*[!0-9]*) loop_count=0 ;; esac
[ "$loop_count" -lt "$ceiling" ] || exit 0

runs=$(ofm_open_run_ids)
[ -n "$runs" ] || exit 0

# Giành quyền park trước khi chờ.
owner_file="$(ofm_home)/park-owner"
if [ -n "${OFM_CURSOR_PARK_SEQ:-}" ]; then
  my_seq=$OFM_CURSOR_PARK_SEQ
else
  prev=$(cat "$owner_file" 2>/dev/null | tr -d ' ')
  case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
  my_seq=$((prev + 1))
  printf '%s\n' "$my_seq" > "$owner_file" 2>/dev/null || exit 0
fi

summary=$(printf '%s\n' "$runs" | ofm_wait_any_run "${OFM_WAIT_TIMEOUT_MS:-28500000}")
[ -n "$summary" ] || exit 0

# Còn là park mới nhất không? Nếu không, đứng im: park mới sẽ thấy cùng
# message đó vì chưa ai ack.
current=$(cat "$owner_file" 2>/dev/null | tr -d ' ')
case "$current" in ''|*[!0-9]*) current=$my_seq ;; esac
[ "$current" = "$my_seq" ] || exit 0

jq -cn --arg m "orca-firstmate: $summary" '{followup_message:$m}'
exit 0
```

- [ ] **Step 4: Chạy test cho pass**

Run: `chmod +x hooks/wake-cursor.sh && bash tests/wake-cursor.test.sh`
Expected: PASS — dòng cuối là `ok: <n> asserts passed (wake-cursor.test.sh)`. Con số cụ thể KHÔNG phải hợp đồng: nếu nó lệch, đếm lại assert trong test là đúng, đừng sửa test cho khớp con số.

- [ ] **Step 5: Commit**

```bash
git add hooks/wake-cursor.sh tests/wake-cursor.test.sh
git commit -m "feat: add the Cursor stop hook that answers with a follow-up message"
```

---

### Task 6: Identity, `/firstmate`, và hook PostCompact

**Files:**
- Create: `skills/identity/SKILL.md`
- Create: `commands/firstmate.md`
- Create: `hooks/reidentify-claude.sh`
- Create: `bin/ofm-activate.sh`
- Create: `tests/activate.test.sh`

**Interfaces:**
- Consumes: `ofm_lock_claim`, `ofm_lock_matches`, `ofm_harness_pid`
- Produces: `bin/ofm-activate.sh <session_id> <harness>` → rc 0 và in `claimed`/`reclaimed`/`refreshed`, hoặc rc 1 và in `refused held_by=<id>`. `/firstmate` gọi đúng script này qua Bash.

> **Vì sao có `bin/ofm-activate.sh`:** `/firstmate` là file markdown, không chạy được logic. Nó bảo agent chạy đúng một lệnh; script giữ toàn bộ ngữ nghĩa lock ở một nơi test được, thay vì rải thành prose cho model tự diễn giải.

- [ ] **Step 1: Viết test thất bại**

```bash
# tests/activate.test.sh
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
ofm_test_setup
. "$OFM_TEST_REPO/lib/ofm-home.sh"
ACT="$OFM_TEST_REPO/bin/ofm-activate.sh"

out=$(bash "$ACT" sess-a claude); rc=$?
assert_rc "$rc" 0 "kích hoạt lần đầu thành công"
assert_contains "$out" "claimed" "báo claimed"
assert_eq "$(ofm_lock_get session_id)" "sess-a" "lock ghi đúng phiên"

# Home được tạo đầy đủ ngay lần kích hoạt đầu
[ -d "$OFM_HOME/requests" ]; assert_rc $? 0 "tạo requests/"
[ -d "$OFM_HOME/projects" ]; assert_rc $? 0 "tạo projects/"

# Phiên thứ hai bị từ chối khi chủ còn sống
out=$(bash "$ACT" sess-b claude); rc=$?
assert_rc "$rc" 1 "phiên thứ hai bị từ chối"
assert_contains "$out" "held_by=sess-a" "nói rõ ai đang giữ"

# Thiếu tham số thì fail rõ ràng, không im lặng
out=$(bash "$ACT" 2>&1); rc=$?
assert_rc "$rc" 2 "thiếu tham số thì rc 2"
assert_contains "$out" "usage" "in usage"

# PostCompact: khớp lock thì in identity ra stderr, lệch thì câm
HOOK="$OFM_TEST_REPO/hooks/reidentify-claude.sh"
err=$(printf '{"session_id":"sess-a"}' | bash "$HOOK" 2>&1 >/dev/null); rc=$?
assert_rc "$rc" 0 "reidentify luôn exit 0"
assert_contains "$err" "first mate" "in lại identity"
err=$(printf '{"session_id":"sess-zzz"}' | bash "$HOOK" 2>&1 >/dev/null)
assert_eq "$err" "" "phiên khác thì câm"

ofm_test_teardown
ofm_test_report
```

- [ ] **Step 2: Chạy để thấy nó fail**

Run: `bash tests/activate.test.sh`
Expected: FAIL — `bin/ofm-activate.sh: No such file or directory`

- [ ] **Step 3: Viết `bin/ofm-activate.sh`**

```bash
#!/usr/bin/env bash
# Kích hoạt phiên này thành first mate. /firstmate gọi đúng script này.
# In một dòng kết quả; rc 0 = phiên này là first mate, rc 1 = bị từ chối.
set -u

if [ $# -lt 2 ]; then
  printf 'usage: ofm-activate.sh <session_id> <harness>\n' >&2
  exit 2
fi
session_id=$1
harness=$2

LIB="$(cd "$(dirname "$0")/../lib" 2>/dev/null && pwd)" || { printf 'error: lib not found\n' >&2; exit 2; }
# shellcheck source=/dev/null
. "$LIB/ofm-home.sh"

mkdir -p "$(ofm_home)/requests" "$(ofm_home)/projects" || { printf 'error: cannot create home\n' >&2; exit 2; }

pid=$(ofm_harness_pid "$harness")
[ -n "$pid" ] || pid=$PPID

ofm_lock_claim "$session_id" "$harness" "$pid"
```

- [ ] **Step 4: Viết `hooks/reidentify-claude.sh`**

```bash
#!/usr/bin/env bash
# PostCompact hook: sau khi nén context, first mate quên mình là ai nhưng vẫn
# đang giữ lock và vẫn bị đánh thức. In lại identity ra stderr cho đúng phiên
# đang giữ lock, câm với mọi phiên khác.
set -u
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)" || exit 0
[ -r "$LIB/ofm-home.sh" ] || exit 0
# shellcheck source=/dev/null
. "$LIB/ofm-home.sh"
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null || true)
session_id=$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null) || exit 0
ofm_lock_matches "$session_id" || exit 0

SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills/identity" 2>/dev/null && pwd)/SKILL.md"
if [ -r "$SKILL" ]; then
  printf 'orca-firstmate: phiên này vẫn là first mate. Đọc lại identity:\n' >&2
  cat "$SKILL" >&2
else
  printf 'orca-firstmate: phiên này vẫn là first mate nhưng không đọc được skill identity.\n' >&2
fi
exit 0
```

- [ ] **Step 5: Viết `skills/identity/SKILL.md`**

```markdown
---
name: identity
description: Identity và hard rules của first mate. Nạp khi /firstmate kích hoạt phiên và mỗi lần context bị nén.
---

# Bạn là first mate

Captain nói chuyện với **một** đầu mối duy nhất: bạn. Crew agent chạy trong worktree và
terminal do Orca quản lý. Bạn điều phối, không tự làm.

## Phân vai

- **Orca sở hữu cơ khí**: worktree, terminal, Run/Task/Dispatch, mailbox, release, federation
  xuyên host. Không bao giờ chép lại state đó vào home.
- **Bạn sở hữu phán đoán**: chia yêu cầu thành task, sinh brief, chọn host, đọc `worker_done`,
  quyết bước tiếp, nói với captain bằng ngôn ngữ kết quả chứ không phải ngôn ngữ cơ khí.

## Hard rules

1. **Không tự sửa code project.** Việc đó của worker, trong worktree Orca cấp.
2. **Không suy diễn thẩm quyền.** Merge, hành động phá huỷ, hành động không đảo ngược được,
   và lựa chọn nhạy cảm bảo mật đều cần captain nói rõ.
3. **Host đã chọn cho một request thì dính suốt request.** Host chết giữa chừng thì **dừng và
   báo captain** — không bao giờ âm thầm chuyển task sang host khác.
4. **Chỉ release sau một `worker_done` thật đã xử lý.** Không release vì timeout, TUI idle,
   heartbeat, status, question, escalation, hay `worker_done` bị reject.
5. **Không bao giờ ack trước khi xử lý xong mọi message trong batch.** Orca replay tới khi ack;
   đó là thứ làm cho việc mất phiên không mất tin.
6. **Luôn truyền `--run <run_id>` tường minh** cho mọi lệnh orchestration. Phiên này không phải
   terminal Orca nên không có Run bound để dựa vào.
7. **Không bao giờ stop/restart/update daemon `no-mistakes`.** Một instance dùng chung mọi
   worktree và host.
8. **Dùng CLI chính chủ**: `git`, `gh`. Không wrapper bên thứ ba.

## State

Home ở `~/.orca-firstmate/` — `requests/` là sổ request đang mở, `projects/` là tri thức từng
project. cwd của phiên này **không liên quan** tới state, và không bao giờ là authority cho việc
chọn project.

## Báo cáo

Gộp thành một tin, chỉ nói điều đáng nói: outcome, PR đầy đủ dạng `https://…`, và quyết định cần
captain. Không tường thuật từng bước.
```

- [ ] **Step 6: Viết `commands/firstmate.md`**

```markdown
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
```

- [ ] **Step 7: Chạy test cho pass**

Run: `chmod +x bin/ofm-activate.sh hooks/reidentify-claude.sh && bash tests/activate.test.sh`
Expected: PASS — dòng cuối là `ok: <n> asserts passed (activate.test.sh)`. Con số cụ thể KHÔNG phải hợp đồng: nếu nó lệch, đếm lại assert trong test là đúng, đừng sửa test cho khớp con số.

- [ ] **Step 8: Commit**

```bash
git add skills/identity/SKILL.md commands/firstmate.md hooks/reidentify-claude.sh bin/ofm-activate.sh tests/activate.test.sh
git commit -m "feat: add the identity skill, /firstmate activation, and compaction re-identify"
```

---

### Task 7: Adapter Claude Code

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `hooks/hooks.json`
- Create: `bin/ofm-adapter-claude.sh`
- Create: `tests/adapter-claude.test.sh`

**Interfaces:**
- Consumes: không (chỉ thao tác file)
- Produces: `ofm-adapter-claude.sh install <dist_dir> <target_root>` và `... uninstall <target_root>`; `... detect` → rc 0 khi có `claude` trên PATH. `target_root` mặc định `$HOME/.claude/skills` (test ghi đè).

- [ ] **Step 1: Viết test thất bại**

```bash
# tests/adapter-claude.test.sh
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
ofm_test_setup
AD="$OFM_TEST_REPO/bin/ofm-adapter-claude.sh"
DIST="$OFM_TEST_TMP/dist"; TARGET="$OFM_TEST_TMP/claude-skills"
mkdir -p "$DIST/hooks" "$DIST/lib" "$DIST/skills/identity" "$DIST/commands" "$DIST/.claude-plugin"
cp "$OFM_TEST_REPO/hooks/hooks.json" "$DIST/hooks/"
cp "$OFM_TEST_REPO/.claude-plugin/plugin.json" "$DIST/.claude-plugin/"
printf 'x\n' > "$DIST/hooks/wake-claude.sh"

bash "$AD" install "$DIST" "$TARGET"; assert_rc $? 0 "install thành công"
[ -f "$TARGET/orca-firstmate/hooks/hooks.json" ]; assert_rc $? 0 "chép hooks.json"
[ -f "$TARGET/orca-firstmate/.claude-plugin/plugin.json" ]; assert_rc $? 0 "chép manifest"

# hooks.json phải khai đúng hai hằng số đã kiểm chứng
hooks="$TARGET/orca-firstmate/hooks/hooks.json"
assert_eq "$(jq -r '.hooks.Stop[0].hooks[0].asyncRewake' "$hooks")" "true" "asyncRewake bật"
assert_eq "$(jq -r '.hooks.Stop[0].hooks[0].timeout' "$hooks")" "28800" "timeout 28800"
assert_contains "$(jq -r '.hooks.Stop[0].hooks[0].command' "$hooks")" "CLAUDE_PLUGIN_ROOT" "dùng CLAUDE_PLUGIN_ROOT"
assert_contains "$(jq -r '.hooks.PostCompact[0].hooks[0].command' "$hooks")" "reidentify-claude.sh" "có PostCompact"

# install chạy lại là idempotent, không nhân bản
bash "$AD" install "$DIST" "$TARGET"; assert_rc $? 0 "install lần hai vẫn ok"
assert_eq "$(jq '.hooks.Stop[0].hooks | length' "$hooks")" "1" "không nhân bản hook"

# uninstall xoá sạch thư mục plugin
bash "$AD" uninstall "$TARGET"; assert_rc $? 0 "uninstall thành công"
[ -d "$TARGET/orca-firstmate" ]; assert_rc $? 1 "thư mục plugin đã biến mất"

ofm_test_teardown
ofm_test_report
```

- [ ] **Step 2: Chạy để thấy nó fail**

Run: `bash tests/adapter-claude.test.sh`
Expected: FAIL — `hooks/hooks.json: No such file or directory`

- [ ] **Step 3: Viết `hooks/hooks.json` và `.claude-plugin/plugin.json`**

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/wake-claude.sh",
            "asyncRewake": true,
            "timeout": 28800
          }
        ]
      }
    ],
    "PostCompact": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/reidentify-claude.sh",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

```json
{
  "$schema": "https://anthropic.com/claude-code/plugin.schema.json",
  "name": "orca-firstmate",
  "version": "0.1.0",
  "description": "Talk to one first mate; it runs an Orca-managed crew",
  "skills": "./skills/",
  "commands": "./commands/",
  "hooks": "./hooks/hooks.json"
}
```

- [ ] **Step 4: Viết `bin/ofm-adapter-claude.sh`**

```bash
#!/usr/bin/env bash
# Adapter Claude Code: cài payload thành một plugin trong thư mục RIÊNG.
# Không đụng file config nào của người khác, nên gỡ chỉ là xoá thư mục.
set -u

action=${1:-}
case "$action" in
  detect)
    command -v claude >/dev/null 2>&1 || exit 1
    printf 'claude\n'; exit 0 ;;
  install)
    dist=${2:?usage: install <dist_dir> [target_root]}
    target=${3:-$HOME/.claude/skills}
    [ -d "$dist" ] || { printf 'error: dist not found: %s\n' "$dist" >&2; exit 1; }
    dest="$target/orca-firstmate"
    mkdir -p "$target" || exit 1
    # Chép sạch: xoá bản cũ trước để install là idempotent theo đúng nghĩa,
    # không để lại file của phiên bản trước.
    rm -rf "$dest"
    mkdir -p "$dest" || exit 1
    (cd "$dist" && tar cf - .) | (cd "$dest" && tar xf -) || exit 1
    printf 'installed claude adapter -> %s\n' "$dest"
    printf 'note: Claude Code có cơ chế đánh thức phiên idle đầy đủ (asyncRewake).\n'
    exit 0 ;;
  uninstall)
    target=${2:-$HOME/.claude/skills}
    rm -rf "$target/orca-firstmate"
    printf 'removed claude adapter\n'; exit 0 ;;
  *)
    printf 'usage: ofm-adapter-claude.sh detect|install <dist> [target]|uninstall [target]\n' >&2
    exit 2 ;;
esac
```

- [ ] **Step 5: Chạy test cho pass**

Run: `chmod +x bin/ofm-adapter-claude.sh && bash tests/adapter-claude.test.sh`
Expected: PASS — dòng cuối là `ok: <n> asserts passed (adapter-claude.test.sh)`. Con số cụ thể KHÔNG phải hợp đồng: nếu nó lệch, đếm lại assert trong test là đúng, đừng sửa test cho khớp con số.

- [ ] **Step 6: Commit**

```bash
git add .claude-plugin/plugin.json hooks/hooks.json bin/ofm-adapter-claude.sh tests/adapter-claude.test.sh
git commit -m "feat: add the Claude Code plugin adapter"
```

---

### Task 8: Adapter Cursor — merge phẫu thuật

**Rủi ro cao nhất của cả plan.** File đích là `~/.cursor/hooks.json`, nơi Orca đã có 8 entry. Merge sai là phá supervision của Orca, không chỉ của ta.

**Files:**
- Create: `bin/ofm-adapter-cursor.sh`
- Create: `tests/adapter-cursor.test.sh`

**Interfaces:**
- Consumes: không
- Produces: `ofm-adapter-cursor.sh install <dist_dir> [hooks_json]`, `... uninstall [hooks_json]`, `... verify [hooks_json]` (rc 0 khi có đúng một entry của ta), `... detect`. Entry của ta nhận diện bằng chuỗi `wake-cursor.sh` trong `.command` — tên file là marker, độc lập với đường dẫn cài, nên `OFM_HOME` ghi đè trong test vẫn khớp.

- [ ] **Step 1: Viết test thất bại**

```bash
# tests/adapter-cursor.test.sh
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
ofm_test_setup
AD="$OFM_TEST_REPO/bin/ofm-adapter-cursor.sh"
DIST="$OFM_TEST_TMP/dist"; mkdir -p "$DIST/hooks"; printf 'x\n' > "$DIST/hooks/wake-cursor.sh"
H="$OFM_TEST_TMP/cursor-hooks.json"

# Bắt chước file thật của captain: Orca đã có entry ở đây từ trước.
cat > "$H" <<'JSON'
{
  "version": 1,
  "hooks": {
    "preToolUse": [{"matcher":"Shell","command":"rtk hook cursor"}],
    "stop": [{"type":"command","command":"/Users/x/.orca/agent-hooks/cursor-hook.sh","timeout":10}],
    "afterAgentResponse": [{"type":"command","command":"/Users/x/.orca/agent-hooks/cursor-hook.sh","timeout":10}]
  }
}
JSON
before=$(shasum -a 256 "$H" | awk '{print $1}')

bash "$AD" install "$DIST" "$H"; assert_rc $? 0 "install thành công"

# Entry của người khác phải còn nguyên vẹn, từng cái một
assert_eq "$(jq -r '.hooks.preToolUse | length' "$H")" "1" "giữ nguyên preToolUse"
assert_eq "$(jq -r '.hooks.afterAgentResponse[0].command' "$H")" "/Users/x/.orca/agent-hooks/cursor-hook.sh" "giữ nguyên hook Orca"
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("orca/agent-hooks"))] | length' "$H")" "1" "giữ nguyên stop hook của Orca"
assert_eq "$(jq -r '.version' "$H")" "1" "giữ nguyên version"

# Entry của ta đúng hằng số đã kiểm chứng
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("wake-cursor.sh"))] | length' "$H")" "1" "thêm đúng một entry"
assert_eq "$(jq -r '.hooks.stop[] | select(.command | contains("wake-cursor.sh")) | .loop_limit' "$H")" "200" "loop_limit 200"
assert_eq "$(jq -r '.hooks.stop[] | select(.command | contains("wake-cursor.sh")) | .timeout' "$H")" "28800" "timeout 28800"

# Có sao lưu trước khi ghi
ls "$OFM_HOME"/backups/cursor-hooks.*.json >/dev/null 2>&1; assert_rc $? 0 "có file sao lưu"

# Idempotent: chạy ba lần vẫn đúng một entry
bash "$AD" install "$DIST" "$H" >/dev/null
bash "$AD" install "$DIST" "$H" >/dev/null
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("wake-cursor.sh"))] | length' "$H")" "1" "chạy lại không nhân bản"
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("orca/agent-hooks"))] | length' "$H")" "1" "chạy lại không nhân bản của người khác"

bash "$AD" verify "$H"; assert_rc $? 0 "verify thấy entry của ta"

# uninstall gỡ đúng entry của ta và trả file về y như cũ
bash "$AD" uninstall "$H"; assert_rc $? 0 "uninstall thành công"
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("wake-cursor.sh"))] | length' "$H")" "0" "entry của ta đã biến mất"
assert_eq "$(jq -r '[.hooks.stop[] | select(.command | contains("orca/agent-hooks"))] | length' "$H")" "1" "hook Orca còn nguyên"
bash "$AD" verify "$H"; assert_rc $? 1 "verify báo không còn entry"

# File thiếu thì tạo mới hợp lệ, không nổ
H2="$OFM_TEST_TMP/fresh.json"
bash "$AD" install "$DIST" "$H2"; assert_rc $? 0 "tạo được file mới"
assert_eq "$(jq -r '.version' "$H2")" "1" "file mới có version 1"

# JSON hỏng thì TỪ CHỐI, tuyệt đối không ghi đè
printf 'not json at all' > "$OFM_TEST_TMP/broken.json"
out=$(bash "$AD" install "$DIST" "$OFM_TEST_TMP/broken.json" 2>&1); rc=$?
assert_rc "$rc" 1 "JSON hỏng thì rc 1"
assert_contains "$out" "refus" "nói rõ là từ chối"
assert_eq "$(cat "$OFM_TEST_TMP/broken.json")" "not json at all" "file hỏng không bị đụng tới"

ofm_test_teardown
ofm_test_report
```

- [ ] **Step 2: Chạy để thấy nó fail**

Run: `bash tests/adapter-cursor.test.sh`
Expected: FAIL — `bin/ofm-adapter-cursor.sh: No such file or directory`

- [ ] **Step 3: Viết `bin/ofm-adapter-cursor.sh`**

```bash
#!/usr/bin/env bash
# Adapter Cursor: merge phẫu thuật vào ~/.cursor/hooks.json.
#
# VÌ SAO KHÔNG PHẢI PLUGIN. Đã đo (docs/verification/2026-08-31-plugin-wake.md):
# cùng một hook đặt trong ~/.cursor/skills/<name>/ với .cursor-plugin/plugin.json
# khai "hooks" KHÔNG BAO GIỜ fire, kể cả ép bằng --plugin-dir; đặt trong
# ~/.cursor/hooks.json thì chạy đủ vòng. Cursor không cho ta lựa chọn.
#
# FILE NÀY CÓ CHỦ KHÁC. Orca tự cài 8 entry của nó vào đây. Mọi thao tác phải:
#   - nhận diện entry của ta bằng đúng một chuỗi trong .command (tên file
#     wake-cursor.sh, độc lập với đường dẫn cài);
#   - chỉ thêm/gỡ entry đó, không bao giờ viết lại cả file từ mẫu;
#   - sao lưu trước khi ghi;
#   - TỪ CHỐI khi JSON không parse được, thay vì "sửa" bằng cách ghi đè.
set -u

MARKER="wake-cursor.sh"   # tên file là marker: không tool nào khác có file tên này

_home() { printf '%s' "${OFM_HOME:-$HOME/.orca-firstmate}"; }
_default_hooks() { printf '%s/.cursor/hooks.json' "$HOME"; }

_backup() {  # <hooks_json>
  local dir stamp
  dir="$(_home)/backups"
  mkdir -p "$dir" || return 1
  stamp=$(date +%Y%m%d-%H%M%S)
  cp "$1" "$dir/cursor-hooks.$stamp.json" 2>/dev/null || return 1
  printf '%s/cursor-hooks.%s.json' "$dir" "$stamp"
}

action=${1:-}
case "$action" in
  detect)
    command -v cursor-agent >/dev/null 2>&1 || exit 1
    printf 'cursor\n'; exit 0 ;;

  install)
    dist=${2:?usage: install <dist_dir> [hooks_json]}
    H=${3:-$(_default_hooks)}
    cmd="$dist/hooks/wake-cursor.sh"
    if [ -f "$H" ]; then
      jq -e . "$H" >/dev/null 2>&1 || {
        printf 'refused: %s is not valid JSON; fix or move it, this tool will not overwrite it\n' "$H" >&2
        exit 1
      }
      _backup "$H" >/dev/null || { printf 'refused: cannot write backup\n' >&2; exit 1; }
    else
      mkdir -p "$(dirname "$H")" || exit 1
      printf '{"version":1,"hooks":{}}\n' > "$H" || exit 1
    fi
    tmp="$H.ofm.$$"
    jq --arg cmd "$cmd" --arg marker "$MARKER" '
      .version = (.version // 1)
      | .hooks = (.hooks // {})
      | .hooks.stop = (
          ((.hooks.stop // []) | map(select(((.command // "") | contains($marker)) | not)))
          + [{type:"command", command:$cmd, timeout:28800, loop_limit:200}]
        )
    ' "$H" > "$tmp" 2>/dev/null || { rm -f "$tmp"; printf 'refused: merge failed\n' >&2; exit 1; }
    jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; printf 'refused: merge produced invalid JSON\n' >&2; exit 1; }
    mv "$tmp" "$H" || exit 1
    printf 'installed cursor adapter -> %s\n' "$H"
    printf 'note: Cursor KHÔNG chạy hook ở headless `cursor-agent -p`; phải dùng phiên tương tác.\n'
    printf 'note: Cursor đòi trust theo từng thư mục workspace, nên mỗi thư mục mới cần một lần trust.\n'
    exit 0 ;;

  uninstall)
    H=${2:-$(_default_hooks)}
    [ -f "$H" ] || { printf 'nothing to remove\n'; exit 0; }
    jq -e . "$H" >/dev/null 2>&1 || { printf 'refused: %s is not valid JSON\n' "$H" >&2; exit 1; }
    _backup "$H" >/dev/null || { printf 'refused: cannot write backup\n' >&2; exit 1; }
    tmp="$H.ofm.$$"
    jq --arg marker "$MARKER" '
      .hooks.stop = ((.hooks.stop // []) | map(select(((.command // "") | contains($marker)) | not)))
    ' "$H" > "$tmp" 2>/dev/null || { rm -f "$tmp"; exit 1; }
    jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; exit 1; }
    mv "$tmp" "$H" || exit 1
    printf 'removed cursor adapter entry from %s\n' "$H"
    exit 0 ;;

  verify)
    H=${2:-$(_default_hooks)}
    [ -f "$H" ] || exit 1
    n=$(jq --arg marker "$MARKER" '[(.hooks.stop // [])[] | select((.command // "") | contains($marker))] | length' "$H" 2>/dev/null)
    [ "$n" = "1" ] || exit 1
    exit 0 ;;

  *)
    printf 'usage: ofm-adapter-cursor.sh detect|install <dist> [hooks_json]|uninstall [hooks_json]|verify [hooks_json]\n' >&2
    exit 2 ;;
esac
```

- [ ] **Step 4: Chạy test cho pass**

Run: `chmod +x bin/ofm-adapter-cursor.sh && bash tests/adapter-cursor.test.sh`
Expected: PASS — dòng cuối là `ok: <n> asserts passed (adapter-cursor.test.sh)`. Con số cụ thể KHÔNG phải hợp đồng: nếu nó lệch, đếm lại assert trong test là đúng, đừng sửa test cho khớp con số.

- [ ] **Step 5: Commit**

```bash
git add bin/ofm-adapter-cursor.sh tests/adapter-cursor.test.sh
git commit -m "feat: merge the Cursor stop hook into a file another tool owns"
```

---

### Task 9: CLI `orca-firstmate`

**Files:**
- Create: `bin/orca-firstmate`
- Create: `tests/cli.test.sh`
- Modify: `tests/run-all.sh` (không cần sửa — đã quét `*.test.sh`)

**Interfaces:**
- Consumes: `ofm-adapter-claude.sh`, `ofm-adapter-cursor.sh`, `lib/ofm-home.sh`
- Produces: `orca-firstmate install|doctor|update|uninstall`. `doctor` in mỗi vấn đề một dòng `MISSING: <tool> (install: <cmd>)` hoặc `NOT_READY: <lý do>`, rc 1 khi có vấn đề, rc 0 khi sạch.

- [ ] **Step 1: Viết test thất bại**

```bash
# tests/cli.test.sh
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/helpers.sh"
ofm_test_setup
CLI="$OFM_TEST_REPO/bin/orca-firstmate"
# `gh auth status` chạm keychain thật, nên test sẽ xanh/đỏ tuỳ máy. Bỏ qua đúng
# phép kiểm đó; doctor thật vẫn kiểm đầy đủ.
export OFM_SKIP_GH_AUTH=1

# doctor sạch khi fake-orca báo ready và mọi tool đều có
out=$(bash "$CLI" doctor 2>&1); rc=$?
assert_rc "$rc" 0 "doctor sạch thì rc 0"
assert_contains "$out" "orca" "doctor nhắc tới orca"

# Orca chưa ready thì doctor fail và nói rõ cách sửa
export OFM_FAKE_ORCA_STATUS='{"ok":true,"result":{"reachable":false,"state":"starting","capabilities":[]}}'
out=$(bash "$CLI" doctor 2>&1); rc=$?
assert_rc "$rc" 1 "Orca chưa ready thì rc 1"
assert_contains "$out" "NOT_READY" "báo NOT_READY"
assert_contains "$out" "orca open" "gợi ý lệnh sửa"

# Thiếu capability bắt buộc cũng fail
export OFM_FAKE_ORCA_STATUS='{"ok":true,"result":{"reachable":true,"state":"ready","capabilities":["other.v1"]}}'
out=$(bash "$CLI" doctor 2>&1); rc=$?
assert_rc "$rc" 1 "thiếu capability thì rc 1"
assert_contains "$out" "orchestration.contract.v1" "nêu đúng capability thiếu"
unset OFM_FAKE_ORCA_STATUS

# install chép payload vào dist rồi gọi adapter
export OFM_CLAUDE_SKILLS_DIR="$OFM_TEST_TMP/claude-skills"
export OFM_CURSOR_HOOKS_JSON="$OFM_TEST_TMP/cursor-hooks.json"
out=$(bash "$CLI" install --harness claude 2>&1); rc=$?
assert_rc "$rc" 0 "install claude thành công"
[ -f "$OFM_HOME/dist/hooks/wake-claude.sh" ]; assert_rc $? 0 "payload nằm ở dist"
[ -f "$OFM_CLAUDE_SKILLS_DIR/orca-firstmate/hooks/hooks.json" ]; assert_rc $? 0 "adapter claude đã cài"

# Harness chưa hỗ trợ thì báo thẳng, không im lặng
out=$(bash "$CLI" install --harness codex 2>&1); rc=$?
assert_rc "$rc" 1 "harness lạ thì rc 1"
assert_contains "$out" "chưa hỗ trợ" "nói thẳng là chưa hỗ trợ"

# uninstall giữ nguyên state
mkdir -p "$OFM_HOME/requests"; printf 'x\n' > "$OFM_HOME/requests/keep.md"
bash "$CLI" uninstall >/dev/null 2>&1
[ -f "$OFM_HOME/requests/keep.md" ]; assert_rc $? 0 "uninstall KHÔNG xoá requests"
[ -d "$OFM_CLAUDE_SKILLS_DIR/orca-firstmate" ]; assert_rc $? 1 "uninstall gỡ adapter"

# uninstall phải dọn cả dấu vết của bootstrap
export OFM_BIN_DIR="$OFM_TEST_TMP/bin"; mkdir -p "$OFM_BIN_DIR" "$OFM_HOME/src"
ln -sf /usr/bin/true "$OFM_BIN_DIR/orca-firstmate"
bash "$CLI" uninstall >/dev/null 2>&1
[ -L "$OFM_BIN_DIR/orca-firstmate" ]; assert_rc $? 1 "uninstall gỡ symlink trên PATH"
[ -d "$OFM_HOME/src" ]; assert_rc $? 1 "uninstall gỡ clone src khi không chạy từ đó"

# install TỪ TRONG bản đã cài phải bị từ chối, không được tự huỷ
bash "$CLI" install --harness claude >/dev/null 2>&1
out=$(bash "$OFM_HOME/dist/bin/orca-firstmate" install --harness claude 2>&1); rc=$?
assert_rc "$rc" 1 "install từ trong dist bị từ chối"
assert_contains "$out" "refused" "nói rõ là từ chối"
[ -f "$OFM_HOME/dist/bin/orca-firstmate" ]; assert_rc $? 0 "dist không bị xoá sau lần từ chối"

# uninstall chạy TỪ TRONG src thì không xoá src, chỉ in lệnh
mkdir -p "$OFM_HOME/src/bin" "$OFM_HOME/src/lib"
cp "$OFM_TEST_REPO/bin/orca-firstmate" "$OFM_HOME/src/bin/"
cp "$OFM_TEST_REPO/lib/ofm-home.sh" "$OFM_HOME/src/lib/"
out=$(bash "$OFM_HOME/src/bin/orca-firstmate" uninstall 2>&1)
[ -d "$OFM_HOME/src" ]; assert_rc $? 0 "không tự xoá thư mục đang chạy từ đó"
assert_contains "$out" "rm -rf" "in lệnh xoá cho captain"

ofm_test_teardown
ofm_test_report
```

- [ ] **Step 2: Chạy để thấy nó fail**

Run: `bash tests/cli.test.sh`
Expected: FAIL — `bin/orca-firstmate: No such file or directory`

- [ ] **Step 3: Viết `bin/orca-firstmate`**

```bash
#!/usr/bin/env bash
# orca-firstmate — CLI cài đặt và chẩn đoán.
#
# LUẬT CỨNG: script này CHỈ chạy lúc cài và lúc chẩn đoán. Không đường runtime
# nào được gọi nó. Sau khi cài, first mate nói chuyện thẳng với `orca`.
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_DIR/lib/ofm-home.sh"

DIST="$(ofm_home)/dist"
CLAUDE_SKILLS="${OFM_CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
CURSOR_HOOKS="${OFM_CURSOR_HOOKS_JSON:-$HOME/.cursor/hooks.json}"

_sync_dist() {
  # TỪ CHỐI khi đang chạy từ chính bản đã cài: _sync_dist xoá $DIST rồi chép từ
  # $REPO_DIR, mà khi chạy từ dist thì hai đường dẫn đó là một -> tự huỷ.
  case "$REPO_DIR/" in
    "$DIST"/*|"$DIST/")
      printf 'refused: đang chạy từ bản đã cài (%s).\n' "$REPO_DIR" >&2
      printf '  chạy install/update từ source checkout: %s/src/bin/orca-firstmate install\n' "$(ofm_home)" >&2
      return 1 ;;
  esac
  mkdir -p "$DIST" || return 1
  rm -rf "${DIST:?}/"*
  local item
  for item in lib hooks skills commands bin .claude-plugin; do
    [ -e "$REPO_DIR/$item" ] || continue
    cp -R "$REPO_DIR/$item" "$DIST/" || return 1
  done
  printf 'payload -> %s\n' "$DIST"
}

cmd_doctor() {
  local problems=0 status reachable state caps
  for t in orca jq git gh; do
    command -v "$t" >/dev/null 2>&1 || {
      case "$t" in
        orca) printf 'MISSING: orca (install: brew install orca)\n' ;;
        jq)   printf 'MISSING: jq (install: brew install jq)\n' ;;
        git)  printf 'MISSING: git (install: brew install git)\n' ;;
        gh)   printf 'MISSING: gh (install: brew install gh && gh auth login)\n' ;;
      esac
      problems=$((problems + 1))
    }
  done
  if command -v orca >/dev/null 2>&1; then
    status=$(orca status --json 2>/dev/null)
    reachable=$(printf '%s' "$status" | jq -r '.result.reachable // false' 2>/dev/null)
    state=$(printf '%s' "$status" | jq -r '.result.state // "unknown"' 2>/dev/null)
    caps=$(printf '%s' "$status" | jq -r '(.result.capabilities // []) | join(",")' 2>/dev/null)
    if [ "$reachable" != "true" ] || [ "$state" != "ready" ]; then
      printf 'NOT_READY: Orca reachable=%s state=%s (fix: orca open, rồi chờ app sẵn sàng)\n' "$reachable" "$state"
      problems=$((problems + 1))
    fi
    case "$caps" in
      *orchestration.contract.v1*) ;;
      *) printf 'NOT_READY: Orca thiếu capability orchestration.contract.v1 (fix: cập nhật app Orca)\n'
         problems=$((problems + 1)) ;;
    esac
  fi
  if [ -z "${OFM_SKIP_GH_AUTH:-}" ] && command -v gh >/dev/null 2>&1 && ! gh auth status >/dev/null 2>&1; then
    printf 'NOT_READY: gh chưa đăng nhập (fix: gh auth login)\n'
    problems=$((problems + 1))
  fi
  if [ "$problems" -eq 0 ]; then
    printf 'doctor: ok — orca ready, jq/git/gh sẵn sàng\n'
    return 0
  fi
  return 1
}

cmd_install() {
  local want=all
  while [ $# -gt 0 ]; do
    case "$1" in
      --harness) want=${2:?--harness cần giá trị}; shift 2 ;;
      *) printf 'unknown flag: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  case "$want" in
    all|claude|cursor) ;;
    *) printf 'error: harness "%s" chưa hỗ trợ. v1 chỉ có claude và cursor.\n' "$want" >&2; return 1 ;;
  esac
  _sync_dist || return 1
  local did=0
  if [ "$want" = all ] || [ "$want" = claude ]; then
    if bash "$DIST/bin/ofm-adapter-claude.sh" detect >/dev/null 2>&1 || [ "$want" = claude ]; then
      bash "$DIST/bin/ofm-adapter-claude.sh" install "$DIST" "$CLAUDE_SKILLS" || return 1
      did=$((did + 1))
    fi
  fi
  if [ "$want" = all ] || [ "$want" = cursor ]; then
    if bash "$DIST/bin/ofm-adapter-cursor.sh" detect >/dev/null 2>&1 || [ "$want" = cursor ]; then
      bash "$DIST/bin/ofm-adapter-cursor.sh" install "$DIST" "$CURSOR_HOOKS" || return 1
      did=$((did + 1))
    fi
  fi
  [ "$did" -gt 0 ] || { printf 'không tìm thấy harness nào được hỗ trợ trên máy\n' >&2; return 1; }
  printf 'xong. Mở một phiên mới rồi gõ /firstmate.\n'
}

cmd_uninstall() {
  [ -d "$DIST" ] && bash "$DIST/bin/ofm-adapter-claude.sh" uninstall "$CLAUDE_SKILLS" >/dev/null 2>&1
  [ -d "$DIST" ] && bash "$DIST/bin/ofm-adapter-cursor.sh" uninstall "$CURSOR_HOOKS" >/dev/null 2>&1
  rm -rf "$DIST"
  # Dọn cả những gì install.sh tạo ra, nếu không captain gỡ xong vẫn còn một
  # lệnh chết trên PATH trỏ vào clone đã mồ côi.
  local bin_link="${OFM_BIN_DIR:-$HOME/.local/bin}/orca-firstmate"
  [ -L "$bin_link" ] && rm -f "$bin_link"
  # KHÔNG xoá thư mục đang chứa chính script này: bash đọc script theo từng
  # đoạn, xoá giữa lúc chạy là hành vi không xác định. In lệnh cho captain.
  local src="$(ofm_home)/src"
  case "$REPO_DIR/" in
    "$src"/*|"$src/")
      printf 'đã gỡ adapter, payload và symlink. requests/ và projects/ giữ nguyên ở %s\n' "$(ofm_home)"
      printf 'còn lại source checkout (không tự xoá được vì lệnh này đang chạy từ đó):\n'
      printf '  rm -rf %s\n' "$src"
      return 0 ;;
  esac
  rm -rf "$src"
  printf 'đã gỡ adapter, payload, symlink và clone. requests/ và projects/ giữ nguyên ở %s\n' "$(ofm_home)"
}

case "${1:-}" in
  doctor)    shift; cmd_doctor "$@" ;;
  install)   shift; cmd_install "$@" ;;
  update)    shift; cmd_install "$@" ;;
  uninstall) shift; cmd_uninstall "$@" ;;
  *) printf 'usage: orca-firstmate install [--harness claude|cursor]|doctor|update|uninstall\n' >&2; exit 2 ;;
esac
```

- [ ] **Step 4: Chạy toàn bộ test cho pass**

Run: `chmod +x bin/orca-firstmate && bash tests/cli.test.sh`
Expected: PASS — mọi file test in `ok:`, kết thúc bằng `ALL TEST FILES PASSED`

- [ ] **Step 5: Commit**

```bash
git add bin/orca-firstmate tests/cli.test.sh
git commit -m "feat: add the installer CLI"
```

---

### Task 10: Bootstrap `install.sh` — cài bằng một lệnh

Đây là thứ mọi người dùng chạm đầu tiên, nên nó phải có test như mọi thứ khác. Test dùng một
bare repo local qua `file://` nên chạy được offline, không cần repo đã publish.

**Files:**
- Create: `install.sh`
- Create: `tests/install-sh.test.sh`

**Interfaces:**
- Consumes: `bin/orca-firstmate` (chỉ để symlink; bootstrap không tự chạy `install`)
- Produces: `install.sh` đọc `OFM_REPO_URL`, `OFM_HOME`, `OFM_BIN_DIR`; clone hoặc cập nhật
  `$OFM_HOME/src`, symlink `$OFM_BIN_DIR/orca-firstmate`, rồi in bước tiếp theo. rc 0 khi xong,
  rc 1 khi thiếu `git`/`jq` hoặc clone thất bại.

> **Tiền đề:** repo đã có remote `origin` trỏ tới một repo **public** trên GitHub. Captain tự
> đặt remote đó; Step 0 chỉ đọc lại chứ không tạo.

> **Bootstrap KHÔNG tự chạy `orca-firstmate install`.** Cài binary và cài vào harness là hai
> quyết định khác nhau: cái sau sửa `~/.cursor/hooks.json` của captain. Một `curl | sh` không
> được phép âm thầm làm việc đó.

- [ ] **Step 0: Lấy URL thật của repo**

Repo là public trên GitHub và remote do captain tự đặt. Đọc nó ra, đừng đoán:

```bash
git remote get-url origin
```

Dùng giá trị đó làm mặc định trong `install.sh` ở Step 3, và thay `OWNER_PLACEHOLDER` bằng
owner thật. Nếu `git remote get-url origin` chưa có gì, **dừng và hỏi captain** — đừng bịa URL.

- [ ] **Step 1: Viết test thất bại**

```bash
# tests/install-sh.test.sh
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

# URL hỏng thì fail rõ ràng, không để lại symlink chết
export OFM_REPO_URL="file://$OFM_TEST_TMP/does-not-exist.git"
rm -rf "$OFM_HOME/src" "$OFM_BIN_DIR/orca-firstmate"
out=$(sh "$OFM_TEST_REPO/install.sh" 2>&1); rc=$?
assert_rc "$rc" 1 "URL hỏng thì rc 1"
[ -L "$OFM_BIN_DIR/orca-firstmate" ]; assert_rc $? 1 "thất bại thì không để lại symlink chết"

ofm_test_teardown
ofm_test_report
```

- [ ] **Step 2: Chạy để thấy nó fail**

Run: `bash tests/install-sh.test.sh`
Expected: FAIL — `install.sh: No such file or directory`

- [ ] **Step 3: Viết `install.sh`**

```bash
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
REPO_URL="${OFM_REPO_URL:-https://github.com/OWNER_PLACEHOLDER/orca-firstmate.git}"

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
```

- [ ] **Step 4: Chạy test cho pass**

Run: `chmod +x install.sh && bash tests/install-sh.test.sh`
Expected: PASS — dòng cuối là `ok: <n> asserts passed (install-sh.test.sh)`. Con số cụ thể KHÔNG phải hợp đồng: nếu nó lệch, đếm lại assert trong test là đúng, đừng sửa test cho khớp con số.

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/install-sh.test.sh
git commit -m "feat: add the one-line bootstrap installer"
```

---

### Task 11: Smoke test thật hai harness

Test tự động không chạm Orca thật và không chạm harness thật. Task này đóng khoảng cách đó, và là **cách duy nhất** chứng minh đường wake của Cursor.

**Files:**
- Create: `tests/smoke/pty-drive.py`
- Create: `docs/verification/2026-08-31-smoke-install.md`

**Interfaces:**
- Consumes: `orca-firstmate install`, `/firstmate`, cả hai wake hook
- Produces: một file bằng chứng ghi rõ version app và version harness đã kiểm

- [ ] **Step 1: Viết `tests/smoke/pty-drive.py`**

```python
#!/usr/bin/env python3
"""Lái một phiên harness tương tác qua pty để kiểm đường wake.

Headless không dùng được: cursor-agent -p không chạy hook nào cả
(docs/verification/2026-08-31-plugin-wake.md). Và gõ chữ với Enter phải TÁCH
RỜI — gửi liền một mạch thì Cursor nhận chữ nhưng không submit.

Dùng: pty-drive.py <cmd> [args...] --send <text> --expect <marker> --wait <sec>
"""
import os, pty, re, select, signal, struct, sys, termios, fcntl, time

ANSI = re.compile(rb'\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b[()][B0]|\x1b[=>]')

def main():
    argv = sys.argv[1:]
    send = expect = None
    wait = 120
    cmd = []
    i = 0
    while i < len(argv):
        if argv[i] == "--send": send = argv[i+1]; i += 2
        elif argv[i] == "--expect": expect = argv[i+1]; i += 2
        elif argv[i] == "--wait": wait = int(argv[i+1]); i += 2
        else: cmd.append(argv[i]); i += 1
    if not cmd or send is None or expect is None:
        print(__doc__); return 2

    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(TERM="xterm-256color", LINES="40", COLUMNS="120")
        os.execvp(cmd[0], cmd)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))

    buf = b""
    def pump(sec):
        nonlocal buf
        end = time.time() + sec
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.3)
            if not r: continue
            try: d = os.read(fd, 65536)
            except OSError: return False
            if not d: return False
            buf += d
            if expect.encode() in ANSI.sub(b'', buf):
                return "found"
        return True

    pump(8)                                  # để TUI dựng xong
    os.write(fd, send.encode()); pump(2)     # gõ chữ
    os.write(fd, b"\r")                      # Enter RIÊNG
    found = pump(wait)

    try:
        os.write(fd, b"\x03"); time.sleep(0.4); os.write(fd, b"\x03")
        os.kill(pid, signal.SIGTERM)
    except Exception:
        pass

    if found == "found":
        print(f"PASS: thấy {expect!r}"); return 0
    print(f"FAIL: không thấy {expect!r} trong {wait}s", file=sys.stderr)
    sys.stderr.write(ANSI.sub(b'', buf)[-2000:].decode('utf-8', 'replace'))
    return 1

if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: Chạy smoke Claude Code bằng tay**

```bash
orca-firstmate install --harness claude
orca-firstmate doctor          # phải in "doctor: ok"
# Mở phiên mới, gõ /firstmate, rồi tạo một request giả để hook có việc chờ:
cat > ~/.orca-firstmate/requests/smoke.md <<'EOF'
---
run_id: <run id thật từ `orca orchestration run-create --objective smoke`>
project: smoke
host: local
status: open
opened: 2026-08-31
---
smoke test
EOF
```

Từ một terminal khác, gửi một message vào Run đó rồi xem phiên Claude Code có tự tỉnh không.
Expected: phiên đang idle tự chạy một lượt mới, mang dòng `orca-firstmate: worker_done run=…`.

- [ ] **Step 3: Chạy smoke Cursor bằng pty**

```bash
orca-firstmate install --harness cursor
python3 tests/smoke/pty-drive.py cursor-agent --trust \
  --send "hi" --expect "orca-firstmate:" --wait 90
```

Expected: `PASS: thấy 'orca-firstmate:'` — nghĩa là stop hook park, chờ mailbox, và Cursor đã
chạy một lượt mới mang follow-up.

- [ ] **Step 4: Ghi bằng chứng**

Tạo `docs/verification/2026-08-31-smoke-install.md` ghi: version app Orca (`orca status --json`),
version Claude Code (`claude --version`), version Cursor **lấy từ dòng TUI** chứ không phải
`--version`, lệnh đã chạy, và kết quả từng bước. Ghi cả những gì **không** kiểm được.

- [ ] **Step 5: Commit**

```bash
git add tests/smoke/pty-drive.py docs/verification/2026-08-31-smoke-install.md
git commit -m "test: add the interactive smoke driver and record its evidence"
```

---

## Phần Plan 2 sẽ làm (không thuộc plan này)

Request lifecycle và `requests/<slug>.md`; skill `routing` (khám phá host, eligibility, chọn host
một lần mỗi request); skill `supervise` (batch mailbox, thứ tự xử-lý-trước-ack, release/reuse
terminal); skill `brief` (4 tầng); skill `delivery` (mode, hợp đồng giao hàng, chính sách
ask-user); mở rộng `fake-orca` cho `run-create`/`task-create`/`worker-start`/`worker-release`.

Plan 1 cố tình dựng sẵn chỗ cho chúng: `ofm_open_run_ids` đã đọc đúng frontmatter mà Plan 2 sẽ
ghi, và `skills/identity/SKILL.md` đã phát biểu các hard rule mà skill của Plan 2 phải tuân.
