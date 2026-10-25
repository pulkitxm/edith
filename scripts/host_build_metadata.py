import hashlib
import json
import re
from pathlib import Path


def executable_hash(bundle):
    return hashlib.sha256((Path(bundle) / 'Contents/MacOS/Edith').read_bytes()).hexdigest()


def load_metadata(bundle):
    bundle = Path(bundle)
    path = bundle.parent / 'build-metadata.json'
    if not path.is_file():
        return None
    metadata = json.loads(path.read_text())
    if metadata.get('hostExecutableSHA256') != executable_hash(bundle):
        raise ValueError('Host build metadata does not match the source executable')
    return metadata


def write_metadata(bundle, source_metadata, signature):
    bundle = Path(bundle)
    path = bundle.parent / 'build-metadata.json'
    if source_metadata is None:
        path.unlink(missing_ok=True)
        return
    metadata = dict(source_metadata)
    metadata.update(hostExecutableSHA256=executable_hash(bundle), signature=signature)
    path.write_text(json.dumps(metadata, indent=2) + '\n')


def package_version(info, version=None, build=None, release=False):
    result = dict(info)
    if version is None and build is None:
        return result
    if not release:
        raise ValueError('Explicit package version metadata requires release mode')
    if not isinstance(version, str) or len(version) > 64 or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('Release version must be a dotted numeric version')
    if not isinstance(build, str) or len(build) > 18 or not re.fullmatch(r'[0-9]+', build):
        raise ValueError('Release build must be a numeric string')
    result.update(CFBundleShortVersionString=version, CFBundleVersion=build)
    return result
