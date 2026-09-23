import os
import subprocess
import sys

NANOSECONDS = 1_000_000_000


def git(root, *arguments):
    return subprocess.run(['git', *arguments], cwd=root, check=True, capture_output=True).stdout


def tracked_blobs(root):
    blobs = {}
    for record in git(root, 'ls-files', '-s', '-z').split(b'\0'):
        if record:
            metadata, _, path = record.partition(b'\t')
            blobs[path] = metadata.split(b' ')[1]
    return blobs


def source_times(root):
    blobs = tracked_blobs(root)
    times = {}
    commit_time = None
    for record in git(root, 'log', '-z', '--no-renames', '--name-only', '--format=%x01%ct', 'HEAD').split(b'\0'):
        if record.startswith(b'\x01'):
            commit_time = int(record[1:])
            continue
        path = record.removeprefix(b'\n')
        if path in blobs and path not in times:
            times[path] = commit_time * NANOSECONDS + int(blobs[path][:8], 16) % NANOSECONDS
    missing = sorted(blobs.keys() - times.keys())
    if missing:
        raise SystemExit('No commit history found for ' + os.fsdecode(missing[0]) + '.')
    return times


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    if git(root, 'rev-parse', '--is-shallow-repository').strip() == b'true':
        raise SystemExit('Source times need the full history: check out with fetch-depth: 0.')
    times = source_times(root)
    for path, time in times.items():
        target = os.path.join(os.fsencode(root), path)
        if os.path.lexists(target):
            os.utime(target, ns=(time, time), follow_symlinks=False)
    print(f'Restored commit times for {len(times)} tracked files.')


if __name__ == '__main__':
    main()
