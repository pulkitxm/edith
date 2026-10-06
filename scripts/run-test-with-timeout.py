#!/usr/bin/env python3
import argparse
import math
import os
import signal
import subprocess
import sys


def sample_group(group):
    if sys.platform != "darwin":
        return
    processes = subprocess.run(
        ["ps", "-axo", "pid=,pgid=,comm="],
        text=True,
        capture_output=True,
        check=True,
    )
    for line in processes.stdout.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) != 3 or int(fields[1]) != group:
            continue
        if "swiftpm-testing-helper" not in fields[2]:
            continue
        print(f"Capturing stalled test process {fields[0]}", flush=True)
        try:
            subprocess.run(["sample", fields[0], "3", "-file", "/dev/stdout"], timeout=20)
        except subprocess.TimeoutExpired:
            print("Stack capture timed out", file=sys.stderr, flush=True)


def stop_group(process):
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def run(command, timeout):
    process = subprocess.Popen(command, start_new_session=True)
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        print(f"Test command exceeded {timeout:g} seconds: {command}", file=sys.stderr, flush=True)
        try:
            sample_group(process.pid)
        except (OSError, subprocess.SubprocessError) as error:
            print(f"Stack capture failed: {error}", file=sys.stderr, flush=True)
        finally:
            stop_group(process)
            process.wait()
        return 124


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    command = arguments.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command or not math.isfinite(arguments.timeout) or arguments.timeout <= 0:
        parser.error("provide a command and a positive timeout")
    return run(command, arguments.timeout)


if __name__ == "__main__":
    sys.exit(main())
