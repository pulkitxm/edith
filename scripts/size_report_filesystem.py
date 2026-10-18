from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
import stat


def identity(status):
    return (status.st_dev, status.st_ino, status.st_mode, status.st_size,
            status.st_mtime_ns, status.st_ctime_ns)


class TreeSnapshot:
    def __init__(self, root):
        self.root = Path(root).absolute()
        root_status = self.root.lstat()
        if stat.S_ISLNK(root_status.st_mode):
            raise ValueError("Size inventory root must not be a symbolic link")
        self._canonical_root = self.root.resolve(strict=True)
        self.entries = {}
        self._walk(self.root)
        if (self.entries[self.root] != identity(root_status)
                or self.root.resolve(strict=True) != self._canonical_root):
            raise ValueError("Size inventory changed during traversal")

    def _walk(self, path):
        before = path.lstat()
        self.entries[path] = identity(before)
        if stat.S_ISDIR(before.st_mode):
            with os.scandir(path) as directory:
                children = sorted(Path(entry.path) for entry in directory)
            for child in children:
                self._walk(child)
        elif stat.S_ISLNK(before.st_mode):
            target = path.resolve(strict=True)
            if not target.is_relative_to(self._canonical_root):
                raise ValueError("Size inventory link escapes its root")
        elif stat.S_ISREG(before.st_mode):
            with stable_file(path) as source:
                source.read(1)
        else:
            raise ValueError("Size inventory contains an unsupported entry")
        if identity(path.lstat()) != self.entries[path]:
            raise ValueError("Size inventory changed during traversal")

    @property
    def files(self):
        return [path for path, status in sorted(self.entries.items()) if stat.S_ISREG(status[2])]

    def verify(self):
        current = TreeSnapshot(self.root)
        if current.entries != self.entries or current._canonical_root != self._canonical_root:
            raise ValueError("Size inventory changed during measurement")


@contextmanager
def stable_file(path):
    path = Path(path)
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode):
        raise ValueError("Size input must be a regular file")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        if identity(os.fstat(source.fileno())) != identity(before):
            raise ValueError("Size input changed before reading")
        yield source
        if (identity(os.fstat(source.fileno())) != identity(before)
                or identity(path.lstat()) != identity(before)):
            raise ValueError("Size input changed during reading")


def digest_file(path):
    digest = hashlib.sha256()
    with stable_file(path) as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_bytes(path):
    with stable_file(path) as source:
        return source.read()
