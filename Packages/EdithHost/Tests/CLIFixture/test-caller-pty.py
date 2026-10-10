import errno
import fcntl
import json
import os
import select
import signal
import struct
import subprocess
import sys
import termios
import time


def run_case(cancel):
    master, slave = os.openpty()
    process = None
    try:
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        os.write(slave, b"baseline")
        assert os.read(master, 8) == b"baseline"
        original = termios.tcgetattr(slave)
        original_flags = fcntl.fcntl(slave, fcntl.F_GETFL)
        payload = bytes([0, 255, 3, 4, 13, 10, 120, 0])
        args = [sys.argv[1], "calendar", "stream-terminal"]
        if not cancel:
            args += ["--count", str(len(payload) + 1)]
        process = subprocess.Popen(args, stdin=slave, stdout=slave, stderr=subprocess.PIPE, close_fds=True)
        output = bytearray()
        errors = bytearray()
        deadline = time.monotonic() + 12

        def receive_until(predicate):
            while not predicate():
                assert time.monotonic() < deadline, (bytes(output), bytes(errors), process.poll())
                for fd in select.select([master, process.stderr.fileno()], [], [], 0.1)[0]:
                    try:
                        data = os.read(fd, 65536)
                    except OSError as error:
                        if error.errno == errno.EIO and fd == master:
                            data = b""
                        else:
                            raise
                    if fd == master:
                        output.extend(data)
                    else:
                        errors.extend(data)
                assert process.poll() is None or predicate(), (process.returncode, bytes(errors))

        receive_until(lambda: b"interactive=true\n" in errors and b"resize=80x24\n" in errors)
        raw = termios.tcgetattr(slave)
        assert raw[3] & (termios.ICANON | termios.ECHO | termios.ISIG) == 0
        os.write(master, payload)
        receive_until(lambda: len(output) >= len(payload))
        assert bytes(output) == payload
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
        receive_until(lambda: b"resize=120x40\n" in errors)
        if cancel:
            process.send_signal(signal.SIGTERM)
        else:
            os.write(master, b"z")
            receive_until(lambda: len(output) == len(payload) + 1)
            assert bytes(output) == payload + b"z"
        code = process.wait(timeout=6)
        assert code == (130 if cancel else 0), (code, bytes(errors))
        assert fcntl.fcntl(slave, fcntl.F_GETFL) == original_flags, (original_flags, fcntl.fcntl(slave, fcntl.F_GETFL), cancel)
        assert termios.tcgetattr(slave) == original, (termios.tcgetattr(slave), original)
        assert b"error:" not in errors if not cancel else b"error:" in errors or process.returncode == 130
        return {"cancel": cancel, "exitCode": code, "exactBytes": True, "resize": True, "termiosRestored": True}
    finally:
        if process is not None:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
            process.stderr.close()
        os.close(master)
        os.close(slave)


print(json.dumps({"ownedCallerPTY": [run_case(False), run_case(True)]}))
