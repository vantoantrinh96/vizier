#!/usr/bin/env python3
"""Lái một phiên harness tương tác qua pty để kiểm đường wake.

Headless không dùng được: cursor-agent -p không chạy hook nào cả
(docs/verification/2026-08-31-plugin-wake.md). Và gõ chữ với Enter phải TÁCH
RỜI — gửi liền một mạch thì Cursor nhận chữ nhưng không submit.

CẢNH BÁO VỀ LOCAL ECHO: pty vọng lại chính những gì ta ghi vào, nên `--expect`
sẽ khớp cả text của `--send`. Đã đo: chạy driver với `sleep 30` — một chương
trình không đọc stdin bao giờ — mà `--send hello --expect hello` vẫn PASS. Vì
vậy `--expect` PHẢI là chuỗi do agent SINH RA, không phải chuỗi ta gửi đi. Với
smoke Cursor, đó là `orca-firstmate:` trong follow-up của hook.

Tổng thời gian chạy là --wait CỘNG khoảng 10-11 giây: 8s chờ TUI dựng, 2s bơm
sau khi gửi, và tới ~1.2s tắt máy khi con kháng tín hiệu (0.2s Ctrl-C + 0.5s
chờ SIGTERM + 0.5s chờ SIGKILL). Có chặn trên ở mọi bước bình thường.

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

    def shutdown():
        # Ctrl-C qua pty trước (đường lịch sự với một TUI), rồi leo thang tín
        # hiệu và REAP. Không có bước reap + SIGKILL thì một agent tự đặt
        # handler cho TERM/INT/HUP sẽ sống sót và thành mồ côi — đã tái hiện
        # được, và đúng loại rò tiến trình dự án này đã sửa một lần trong wake
        # library. Một driver để sót cursor-agent sống mỗi lần gọi là thứ không
        # được phép giao cho captain.
        try:
            os.write(fd, b"\x03"); time.sleep(0.2); os.write(fd, b"\x03")
        except OSError:
            pass
        for sig, grace in ((signal.SIGTERM, 0.5), (signal.SIGKILL, 0.5)):
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                break
            deadline = time.time() + grace
            while time.time() < deadline:
                try:
                    done, _ = os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    return
                if done == pid:
                    return
                time.sleep(0.05)
        try:
            os.waitpid(pid, 0)
        except (ChildProcessError, OSError):
            pass

    # try/finally, KHÔNG chỉ try/except OSError. Bắt riêng OSError vẫn để hở mọi
    # exception khác — và cái dễ xảy ra nhất là KeyboardInterrupt: captain bấm
    # Ctrl-C trên chính lượt smoke đang chạy. Khi đó `shutdown()` không chạy và
    # agent bị rò, đúng lỗ hổng vòng trước vừa đóng. `finally` phủ mọi đường ra.
    found = None
    write_err = None
    try:
        pump(8)                                  # để TUI dựng xong
        # Ghi có thể nổ OSError nếu con đã chết (Errno 5 trên pty).
        os.write(fd, send.encode()); pump(2)     # gõ chữ
        os.write(fd, b"\r")                      # Enter RIÊNG
        found = pump(wait)
    except OSError as e:
        write_err = e
    finally:
        shutdown()
        try:
            os.close(fd)
        except OSError:
            pass

    if write_err is not None:
        print(f"FAIL: không ghi được vào pty ({write_err})", file=sys.stderr)
        return 1

    if found == "found":
        print(f"PASS: thấy {expect!r}"); return 0
    print(f"FAIL: không thấy {expect!r} trong {wait}s", file=sys.stderr)
    sys.stderr.write(ANSI.sub(b'', buf)[-2000:].decode('utf-8', 'replace'))
    return 1

if __name__ == "__main__":
    raise SystemExit(main())
