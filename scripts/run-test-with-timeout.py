#!/usr/bin/env python3
import argparse
import math
import os
import pathlib
import signal
import subprocess
import sys


def process_tree(root):
    processes = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,pgid=,comm="],
        text=True,
        capture_output=True,
        check=True,
    )
    rows = [line.strip().split(None, 3) for line in processes.stdout.splitlines()]
    descendants = {root}
    while True:
        children = {
            int(row[0]) for row in rows
            if len(row) == 4 and (int(row[1]) in descendants or int(row[2]) == root)
        }
        if children <= descendants:
            break
        descendants.update(children)
    return [(int(row[0]), row[3]) for row in rows if len(row) == 4 and int(row[0]) in descendants]


def sample_group(processes):
    if sys.platform != "darwin":
        return
    for pid, command in processes:
        if "swiftpm-testing-helper" not in command:
            continue
        print(f"Capturing stalled test process {pid}", flush=True)
        try:
            subprocess.run(["sample", str(pid), "1", "10", "-file", "/dev/stdout"], timeout=120)
        except subprocess.TimeoutExpired:
            print("Stack capture timed out", file=sys.stderr, flush=True)


def signal_processes(processes, value):
    for pid, _ in reversed(processes):
        try:
            os.kill(pid, value)
        except ProcessLookupError:
            pass


def stop_group(process, processes):
    signal_processes(processes, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    signal_processes(processes, signal.SIGKILL)


def report_events(path):
    if path is None:
        return
    try:
        with path.open("rb") as source:
            source.seek(0, os.SEEK_END)
            source.seek(max(0, source.tell() - 65536))
            lines = source.read().decode("utf-8", errors="replace").splitlines()[-20:]
        print("Last test events:", file=sys.stderr, flush=True)
        for line in lines:
            print(line, file=sys.stderr, flush=True)
    except OSError as error:
        print(f"Test events unavailable: {error}", file=sys.stderr, flush=True)


def run(command, timeout, events=None):
    process = subprocess.Popen(command, start_new_session=True)
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        print(f"Test command exceeded {timeout:g} seconds: {command}", file=sys.stderr, flush=True)
        report_events(events)
        processes = process_tree(process.pid)
        try:
            sample_group(processes)
        except (OSError, subprocess.SubprocessError) as error:
            print(f"Stack capture failed: {error}", file=sys.stderr, flush=True)
        finally:
            stop_group(process, processes)
            process.wait()
        return 124


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--events", type=pathlib.Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    command = arguments.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command or not math.isfinite(arguments.timeout) or arguments.timeout <= 0:
        parser.error("provide a command and a positive timeout")
    return run(command, arguments.timeout, arguments.events)


if __name__ == "__main__":
    sys.exit(main())
