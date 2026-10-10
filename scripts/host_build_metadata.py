import hashlib
import json
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
