import hashlib
import os
from pathlib import Path
import stat
import subprocess
import weakref


ADMITTED_IMAGES = weakref.WeakSet()
MAXIMUM_IMAGE_BYTES = 268_435_456


def metadata(value):
    return tuple(getattr(value, name) for name in (
        'st_dev', 'st_ino', 'st_mode', 'st_uid', 'st_nlink', 'st_size',
        'st_mtime_ns', 'st_ctime_ns'))


class PinnedToolchainPath:
    def __init__(self, path, directory=False):
        self.path = Path(path)
        if not self.path.is_absolute() or self.path.resolve(strict=True) != self.path:
            raise ValueError('Noncanonical selected toolchain path')
        self.descriptor = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
                                  | os.O_NONBLOCK | (os.O_DIRECTORY if directory else 0))
        try:
            value = os.fstat(self.descriptor)
            kind = stat.S_ISDIR if directory else stat.S_ISREG
            if (not kind(value.st_mode) or value.st_uid != 0 or value.st_mode & 0o022
                    or not directory and (value.st_nlink != 1 or value.st_mode & 0o111 == 0
                                          or not 0 < value.st_size <= MAXIMUM_IMAGE_BYTES)):
                raise ValueError('Unowned selected toolchain path')
            self.original = metadata(value)
            self.validate()
            if not directory:
                digest = hashlib.sha256()
                offset = 0
                while offset < value.st_size:
                    block = os.pread(self.descriptor, min(1_048_576, value.st_size - offset), offset)
                    if not block:
                        raise ValueError('Incomplete selected toolchain image')
                    digest.update(block)
                    offset += len(block)
                self.validate()
                self.sha256 = digest.hexdigest()
        except BaseException:
            self.close()
            raise

    def validate(self):
        if (self.path.resolve(strict=True) != self.path
                or metadata(os.lstat(self.path)) != self.original
                or metadata(os.fstat(self.descriptor)) != self.original):
            raise RuntimeError('Selected toolchain image identity changed')

    def close(self):
        if self.descriptor is not None:
            os.close(self.descriptor)
            self.descriptor = None

    def __del__(self):
        if getattr(self, 'descriptor', None) is not None:
            self.close()


class SelectedToolchainImages:
    def __init__(self, developer):
        developer = Path(developer)
        if developer.parts[-2:] != ('Contents', 'Developer'):
            raise ValueError('Unexpected selected developer layout')
        toolchain = developer / 'Toolchains/XcodeDefault.xctoolchain'
        self.pins = []
        self.images = {}
        try:
            for directory in (developer, toolchain.parent, toolchain, toolchain / 'usr', toolchain / 'usr/bin'):
                self.pins.append(PinnedToolchainPath(directory, directory=True))
            for name in ('swift-frontend', 'swift-package'):
                image = PinnedToolchainPath(toolchain / 'usr/bin' / name)
                self.pins.append(image)
                subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '--all-architectures', str(image.path)],
                               check=True, timeout=30, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                self.images[str(image.path)] = image
            self.validate()
            ADMITTED_IMAGES.add(self)
        except BaseException:
            for pin in self.pins:
                pin.close()
            raise

    def validate(self):
        for pin in self.pins:
            pin.validate()

    def permits(self, path):
        if self not in ADMITTED_IMAGES or path not in self.images:
            return False
        self.validate()
        return True


def admitted_images(value):
    return type(value) is SelectedToolchainImages and value in ADMITTED_IMAGES
