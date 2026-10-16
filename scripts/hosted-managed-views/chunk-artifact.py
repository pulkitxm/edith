import io
import json
import os
import stat
import sys
import zipfile
from pathlib import Path


def read_chunk_artifact(path):
    path = Path(path)
    if not path.is_absolute() or path.resolve(strict=True) != path:
        raise ValueError('Chunk archive must be canonical')
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_nlink != 1 or stat.S_IMODE(before.st_mode) != 0o600 or not 0 < before.st_size <= 4 * 1024**2:
            raise ValueError('Chunk archive must be a bounded owned0600 regular file')
        data = os.read(descriptor, before.st_size + 1)
        after = os.fstat(descriptor)
        keys = ('st_dev', 'st_ino', 'st_uid', 'st_mode', 'st_nlink', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
        if len(data) != before.st_size or any(getattr(before, key) != getattr(after, key) for key in keys):
            raise ValueError('Chunk archive changed during read')
    finally:
        os.close(descriptor)
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        entries = archive.infolist()
        if len(entries) != 1:
            raise ValueError('Expected exactly one chunk result')
        entry = entries[0]
        if entry.filename != 'result.json' or not 0 < entry.file_size <= 4 * 1024**2 or entry.flag_bits & 1 or stat.S_IFMT(entry.external_attr >> 16) not in (0, stat.S_IFREG):
            raise ValueError('Unexpected chunk result entry')
        result = archive.read(entry)
        if len(result) != entry.file_size:
            raise ValueError('Chunk result bytes differ')
    value = json.loads(result)
    if not isinstance(value, dict):
        raise ValueError('Chunk result must be an object')
    return value


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise ValueError('Expected one chunk archive')
    print(json.dumps(read_chunk_artifact(sys.argv[1])))
