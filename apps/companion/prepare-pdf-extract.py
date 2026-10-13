import gzip
import hashlib
import io
import os
from pathlib import Path, PurePosixPath
import stat
import sys
import tarfile
import urllib.request


ARCHIVE_URL = 'https://static.crates.io/crates/pdf-extract/pdf-extract-0.12.1.crate'
ARCHIVE_SHA256 = 'e5c4820f5811e424ce037d08493ac87752ecc54339e0f1e40c3d17da93278861'
MAXIMUM_BYTES = 2 * 1024**2
SOURCE_FILES = ('Cargo.toml.orig', 'README.md', 'src/lib.rs', 'src/core_fonts.rs', 'src/encodings.rs', 'src/glyphnames.rs', 'src/zapfglyphnames.rs')
ADAPTATIONS = (
    ('Cargo.toml', 'version = "0.12.1"', 'version = "0.13.0"'),
    ('Cargo.toml', 'lopdf = {version = "0.42", default-features = false, features = ["wasm_js"]}', 'lopdf = {version = "0.45", default-features = false, features = ["wasm_js"]}'),
    ('src/lib.rs', 'doc.get_page_content(object_id).unwrap()', 'doc.get_page_content(object_id)'),
)


WARNING_ADAPTATIONS = (
    ('src/lib.rs', 'use std::result::Result;', 'use std::result::Result as StdResult;', 1),
    ('src/lib.rs', '-> Result<', '-> StdResult<', 46),
    ('src/lib.rs', 'std::f64::NAN', 'f64::NAN', 1),
    ('src/lib.rs', 'fn get_descriptor(&self) -> Option<PdfFontDescriptor>', "fn get_descriptor(&self) -> Option<PdfFontDescriptor<'_>>", 1),
    ('src/lib.rs', "fn char_codes(&'a self, chars: &'a [u8]) -> PdfFontIter", "fn char_codes(&'a self, chars: &'a [u8]) -> PdfFontIter<'a>", 1),
    ('src/lib.rs', 'pub fn new(file: &mut dyn std::io::Write) -> HTMLOutput', "pub fn new(file: &mut dyn std::io::Write) -> HTMLOutput<'_>", 1),
    ('src/lib.rs', 'pub fn new(file: &mut dyn std::io::Write) -> SVGOutput', "pub fn new(file: &mut dyn std::io::Write) -> SVGOutput<'_>", 1),
    ('src/lib.rs', 'other => {dlog!("pages: {:?}", other)}', '_other => {dlog!("pages: {:?}", _other)}', 1),
    ('src/lib.rs', 'other => { dlog!("pages: {:?}", other)}', '_other => { dlog!("pages: {:?}", _other)}', 1),
    ('src/lib.rs', 'Entry::Occupied(e) => {\n                                                    panic!("unexpected entry in unicode map")', 'Entry::Occupied(_e) => {\n                                                    panic!("unexpected entry in unicode map")', 1),
    ('src/lib.rs', 'dlog!("{} = {} ({:?})", code, name, unicode);\n                                if let Some(ref mut unicode_map) = unicode_map {', 'dlog!("{} = {} ({:?})", code, name, unicode);\n                                if let Some(ref mut _unicode_map) = unicode_map {', 1),
    ('src/lib.rs', 'if let Some(ref unicode_map) = unicode_map {', 'if let Some(ref _unicode_map) = unicode_map {', 1),
    ('src/lib.rs', 'dlog!("{} {:?}", code, unicode_map.get(&(code as u32)));', 'dlog!("{} {:?}", code, _unicode_map.get(&(code as u32)));', 2),
    ('src/lib.rs', 'let name = encoding.get(b"Type").and_then(|x| x.as_name()).and_then(|x| Ok(pdf_to_utf8(x)));\n                dlog!("name: {}", name);', 'let _name = encoding.get(b"Type").and_then(|x| x.as_name()).and_then(|x| Ok(pdf_to_utf8(x)));\n                dlog!("name: {}", _name);', 1),
    ('src/lib.rs', 'let name = if is_core_font(&base_name) {', 'let _name = if is_core_font(&base_name) {', 1),
    ('src/lib.rs', 'if let Ok(Object::Name(name)) = name_encoded {\n                    dlog!("name: {}", pdf_to_utf8(name));', 'if let Ok(Object::Name(_name)) = name_encoded {\n                    dlog!("name: {}", pdf_to_utf8(_name));', 1),
    ('src/lib.rs', "fn new(doc: &'a Document, font: &'a Dictionary) -> PdfCIDFont<'a> {\n        let base_name = get_name_string(doc, font, b\"BaseFont\");", "fn new(doc: &'a Document, font: &'a Dictionary) -> PdfCIDFont<'a> {\n        let _base_name = get_name_string(doc, font, b\"BaseFont\");", 1),
    ('src/lib.rs', 'dlog!("base_name {} {:?}", base_name, font);', 'dlog!("base_name {} {:?}", _base_name, font);', 1),
    ('src/lib.rs', 'for (k, v) in *info {', 'for (_k, v) in *info {', 1),
    ('src/lib.rs', '&Object::String(ref s, StringFormat::Literal) => { dlog!("{}: {}", pdf_to_utf8(k), pdf_to_utf8(s)); }', '&Object::String(ref _s, StringFormat::Literal) => { dlog!("{}: {}", pdf_to_utf8(_k), pdf_to_utf8(_s)); }', 1),
    ('src/glyphnames.rs', "const names: [(&'static str, u16); 4700]", "const NAMES: [(&'static str, u16); 4700]", 1),
    ('src/glyphnames.rs', 'names.binary_search_by_key', 'NAMES.binary_search_by_key', 1),
    ('src/glyphnames.rs', 'names[indx].1', 'NAMES[indx].1', 1),
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def source_files(data, expected_sha256):
    require(0 < len(data) <= MAXIMUM_BYTES and hashlib.sha256(data).hexdigest() == expected_sha256, 'Official PDF source archive checksum differs')
    result = {}
    names = set()
    total = 0
    with gzip.GzipFile(fileobj=io.BytesIO(data)) as compressed:
        expanded = compressed.read(MAXIMUM_BYTES * 2 + 1)
    require(0 < len(expanded) <= MAXIMUM_BYTES * 2, 'Unbounded expanded PDF source archive')
    with tarfile.open(fileobj=io.BytesIO(expanded), mode='r:') as archive:
        for number, member in enumerate(archive, 1):
            require(number <= 64, 'Invalid PDF source inventory')
            parts = member.name.split('/')
            require(parts[0] == 'pdf-extract-0.12.1' and len(parts) > 1 and all(part not in ('', '.', '..') for part in parts) and '\\' not in member.name and '\0' not in member.name, 'Unsafe PDF source archive path')
            require(member.name not in names and member.isfile() and not member.pax_headers, 'Invalid PDF source archive member')
            names.add(member.name)
            total += member.size
            require(0 <= member.size <= MAXIMUM_BYTES and total <= MAXIMUM_BYTES, 'Unbounded PDF source archive')
            name = '/'.join(parts[1:])
            if name in SOURCE_FILES or PurePosixPath(name).name.startswith(('LICENSE', 'COPYING')):
                value = archive.extractfile(member).read(member.size + 1)
                require(len(value) == member.size, 'PDF source member changed')
                result[name] = value
    require(all(name in result for name in SOURCE_FILES), 'Missing PDF extractor or font source')
    result['Cargo.toml'] = result.pop('Cargo.toml.orig')
    for name, previous, current in ADAPTATIONS:
        value = result[name].decode('utf8')
        require(value.count(previous) == 1, 'Reviewed PDF source adaptation no longer matches')
        result[name] = value.replace(previous, current).encode('utf8')
    for name, previous, current, count in WARNING_ADAPTATIONS:
        value = result[name].decode('utf8')
        require(value.count(previous) == count, 'Reviewed PDF warning adaptation no longer matches')
        result[name] = value.replace(previous, current).encode('utf8')
    return result


def private_directory(path):
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700 and path.resolve(strict=True) == path, 'Generated PDF source directory is not private and owned')


def file_identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def snapshot(path, expected_hashes):
    private_directory(path)
    actual = set()
    for current, directories, files in os.walk(path, followlinks=False):
        directory = Path(current)
        private_directory(directory)
        for child in directories:
            private_directory(directory / child)
        for child in files:
            file = directory / child
            name = file.relative_to(path).as_posix()
            require(name in expected_hashes, 'Unexpected generated PDF source file')
            descriptor = os.open(file, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            try:
                info = os.fstat(descriptor)
                require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1 and stat.S_IMODE(info.st_mode) == 0o600 and 0 < info.st_size <= MAXIMUM_BYTES, 'Generated PDF source file is not private and owned')
                with os.fdopen(os.dup(descriptor), 'rb') as stream:
                    value = stream.read(info.st_size + 1)
                after = os.fstat(descriptor)
                require(file_identity(info) == file_identity(after) == file_identity(file.lstat()) and len(value) == info.st_size, 'Generated PDF source changed during verification')
                require(hashlib.sha256(value).hexdigest() == expected_hashes[name], 'Generated PDF source changed; remove the owned generated directory and run make prepare-pdf-extract')
            finally:
                os.close(descriptor)
            actual.add(name)
    require(actual == set(expected_hashes), 'Generated PDF source is incomplete; run make prepare-pdf-extract from a fresh generated directory')


def install(path, files):
    expected = {name: hashlib.sha256(value).hexdigest() for name, value in files.items()}
    path.mkdir(mode=0o700)
    for name, value in files.items():
        require(PurePosixPath(name).as_posix() == name and all(part not in ('', '.', '..') for part in name.split('/')) and not name.startswith('/'), 'Unsafe generated PDF source path')
        target = path / name
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        private_directory(target.parent)
        descriptor = os.open(target, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(value)
            stream.flush()
            os.fsync(stream.fileno())
    snapshot(path, expected)


def download():
    request = urllib.request.Request(ARCHIVE_URL, headers={'User-Agent': 'pdf-source-preparation/1'})
    with urllib.request.urlopen(request, timeout=60) as response:
        require(response.geturl() == ARCHIVE_URL, 'Unexpected PDF source archive origin')
        return response.read(MAXIMUM_BYTES + 1)


def prepare():
    root = Path(__file__).resolve().parent
    local = root / 'local'
    local.mkdir(mode=0o700, exist_ok=True)
    private_directory(local)
    files = source_files(download(), ARCHIVE_SHA256)
    target = local / 'pdf-extract'
    if target.exists() or target.is_symlink():
        snapshot(target, {name: hashlib.sha256(value).hexdigest() for name, value in files.items()})
    else:
        install(target, files)
    return target


if __name__ == '__main__':
    try:
        print(prepare())
    except (OSError, EOFError, ValueError, tarfile.TarError) as error:
        sys.exit('PDF dependency preparation failed: ' + str(error))
