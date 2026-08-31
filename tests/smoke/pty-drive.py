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
