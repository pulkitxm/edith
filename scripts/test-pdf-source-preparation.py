import gzip
import hashlib
import importlib.util
import io
import os
import re
from pathlib import Path
import stat
import tarfile
import tempfile
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[1] / 'apps/companion/prepare-pdf-extract.py'
SPEC = importlib.util.spec_from_file_location('pdf_source_preparation', SOURCE)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


VALUE_FIXTURE_SOURCE = """fn get_catalog(doc: &Document) -> &Dictionary {
    match doc.trailer.get(b"Root").unwrap() {
        &Object::Reference(ref id) => {
            match doc.get_object(*id) {
                Ok(&Object::Dictionary(ref catalog)) => { return catalog; }
                _ => {}
            }
        }
        _ => {}
    }
    panic!();
}

fn get_pages(doc: &Document) -> &Dictionary {
    let catalog = get_catalog(doc);
    match catalog.get(b"Pages").unwrap() {
        &Object::Reference(ref id) => {
            match doc.get_object(*id) {
                Ok(&Object::Dictionary(ref pages)) => { return pages; }
                other => {dlog!("pages: {:?}", other)}
            }
        }
        other => { dlog!("pages: {:?}", other)}
    }
    dlog!("catalog {:?}", catalog);
    panic!();
}


    dlog!("Page count: {}", get::<i64>(&doc, &get_pages(&doc), b"Count"));

    dlog!("Pages: {:?}", get_pages(&doc));

    dlog!("Type: {:?}", get_pages(&doc).get(b"Type").and_then(|x| x.as_name()).unwrap());

#[derive(Clone)]
struct PdfSimpleFont<'a> {
    font: &'a Dictionary,
    doc: &'a Document,
    encoding: Option<Vec<u16>>,
    unicode_map: Option<HashMap<u32, String>>,
    widths: HashMap<CharCode, f64>,
    missing_width: f64,
}

#[derive(Clone)]
struct PdfType3Font<'a> {
    font: &'a Dictionary,
    doc: &'a Document,
}

fn original_simple_font() { PdfSimpleFont {doc, font, widths: width_map, encoding: encoding_table, missing_width, unicode_map} }
fn original_type3_font() { PdfType3Font {doc, font, widths: width_map, encoding: encoding_table, unicode_map} }

impl OriginalFont {
    fn decode(&self, chars: &[u8]) -> String {
        let strings = self.char_codes(chars).map(|x| self.decode_char(x.0)).collect::<Vec<_>>();
        strings.join("")
    }
}

#[derive(Clone, Debug)]
struct Type0Func {
    domain: Vec<f64>,
    range: Vec<f64>,
    contents: Vec<u8>,
    size: Vec<i64>,
    bits_per_sample: i64,
    encode: Vec<f64>,
    decode: Vec<f64>,
}

#[derive(Clone, Debug)]
struct Type2Func {
    c0: Option<Vec<f64>>,
    c1: Option<Vec<f64>>,
    n: f64,
}

#[derive(Clone, Debug)]
pub struct CalGray {
    white_point: [f64; 3],
    black_point: Option<[f64; 3]>,
    gamma: Option<f64>,
}

#[derive(Clone, Debug)]
pub struct CalRGB {
    white_point: [f64; 3],
    black_point: Option<[f64; 3]>,
    gamma: Option<[f64; 3]>,
    matrix: Option<Vec<f64>>
}

#[derive(Clone, Debug)]
pub struct Lab {
    white_point: [f64; 3],
    black_point: Option<[f64; 3]>,
    range: Option<[f64; 4]>,
}

#[derive(Clone)]
pub struct Separation {
    name: String,
    alternate_space: AlternateColorSpace,
    tint_transform: Box<Function>,
}

#[derive(Clone, Debug)]
enum Function {
    Type0(Type0Func),
    Type2(Type2Func),
    Type3,
    Type4(Vec<u8>),
}

impl Function {
    fn parse_original() { validate_function_type(); validate_domain(); validate_range(); decode_sampled_stream(); }
}
"""


def fixture_sources():
    values = {name: ('synthetic font source ' + name).encode() for name in MODULE.SOURCE_FILES}
    values['Cargo.toml.orig'] = b'version = "0.12.1"\nlopdf = {version = "0.42", default-features = false, features = ["wasm_js"]}\nlicense = "MIT"\n'
    library = """use std::result::Result;
pub use lopdf::*;
macro_rules! dlog {
    ($($e:expr),*) => { {} }
}
let contents = doc.get_page_content(object_id).unwrap();
let nan = std::f64::NAN;
fn get_descriptor(&self) -> Option<PdfFontDescriptor> {}
fn char_codes(&'a self, chars: &'a [u8]) -> PdfFontIter {}
pub fn new(file: &mut dyn std::io::Write) -> HTMLOutput {}
pub fn new(file: &mut dyn std::io::Write) -> SVGOutput {}
Entry::Occupied(e) => {
                                                    panic!("unexpected entry in unicode map")
}
dlog!("{} = {} ({:?})", code, name, unicode);
                                if let Some(ref mut unicode_map) = unicode_map {
    dlog!("{} {:?}", code, unicode_map.get(&(code as u32)));
}
if let Some(ref unicode_map) = unicode_map {
    dlog!("{} {:?}", code, unicode_map.get(&(code as u32)));
}
let name = encoding.get(b"Type").and_then(|x| x.as_name()).and_then(|x| Ok(pdf_to_utf8(x)));
                dlog!("name: {}", name);
let name = if is_core_font(&base_name) {
    &base_name
} else {
    warn!("no widths and not core font {:?}", base_name);
    "Helvetica"
};
if font_metrics.0 == base_name { keep_original_matching(); }
if let Ok(Object::Name(name)) = name_encoded {
                    dlog!("name: {}", pdf_to_utf8(name));
}
fn new(doc: &'a Document, font: &'a Dictionary) -> PdfCIDFont<'a> {
        let base_name = get_name_string(doc, font, b"BaseFont");
    let descendants = maybe_get_array(doc, font, b"DescendantFonts").expect("Descendant fonts required");
    dlog!("base_name {} {:?}", base_name, font);
}
for (k, v) in *info {
    match v {
        &Object::String(ref s, StringFormat::Literal) => { dlog!("{}: {}", pdf_to_utf8(k), pdf_to_utf8(s)); }
    }
}
fn format_original() -> fmt::Result { keep_original_formatting() }
"""
    library += VALUE_FIXTURE_SOURCE
    library += ''.join(f'fn result_{index}() -> Result<(), OutputError> {{ preserve_result_{index}() }}\n' for index in range(46))
    values['src/lib.rs'] = library.encode()
    table = ''.join(f'        ("synthetic-{index}", {index}),\n' for index in range(4700))
    values['src/glyphnames.rs'] = ("const names: [(&'static str, u16); 4700] = [\n" + table + "];\nlet result = names.binary_search_by_key(&name, |&(name, _code)| &name);\nresult.ok().map(|indx| names[indx].1)\n").encode()
    values['LICENSE'] = b'synthetic license preserved\n'
    return values


def archive(values, extra=None):
    result = io.BytesIO()
    with tarfile.open(fileobj=result, mode='w:gz', format=tarfile.USTAR_FORMAT) as output:
        for name, value in values.items():
            member = tarfile.TarInfo('pdf-extract-0.12.1/' + name)
            member.size = len(value)
            output.addfile(member, io.BytesIO(value))
        if extra is not None:
            output.addfile(extra, io.BytesIO(b'x' * extra.size))
    return result.getvalue()


def unpack(data):
    return MODULE.source_files(data, hashlib.sha256(data).hexdigest())


class PDFSourcePreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='pdf-source-')
        self.root = Path(os.path.realpath(self.temporary.name))
        os.chmod(self.root, 0o700)
        self.values = fixture_sources()
        self.data = archive(self.values)
        self.files = unpack(self.data)
        self.target = self.root / 'pdf-extract'
        self.expected = {name: hashlib.sha256(value).hexdigest() for name, value in self.files.items()}

    def tearDown(self):
        self.temporary.cleanup()

    def test_reviewed_adaptations_preserve_all_font_bytes_and_license(self):
        for name in MODULE.SOURCE_FILES:
            if name not in ('Cargo.toml.orig', 'src/lib.rs', 'src/glyphnames.rs'):
                self.assertEqual(self.files[name], self.values[name])
        self.assertEqual(self.files['LICENSE'], self.values['LICENSE'])
        self.assertIn(b'version = "0.13.0"', self.files['Cargo.toml'])
        self.assertIn(b'lopdf = {version = "0.45"', self.files['Cargo.toml'])
        self.assertIn(b'let contents = doc.get_page_content(object_id);\n', self.files['src/lib.rs'])
        self.assertNotIn('Cargo.toml.orig', self.files)

    def test_result_types_and_inferred_lifetimes_remain_equivalent(self):
        library = self.files['src/lib.rs'].decode()
        self.assertIn('use std::result::Result as StdResult;', library)
        self.assertIn('pub use lopdf::*;', library)
        self.assertEqual(library.count('-> StdResult<(), OutputError>'), 46)
        self.assertIn('fn format_original() -> fmt::Result { keep_original_formatting() }', library)
        self.assertNotIn('-> Result<', library)
        self.assertIn('let nan = f64::NAN;', library)
        for signature in (
            "fn get_descriptor(&self) -> Option<PdfFontDescriptor<'_>>",
            "fn char_codes(&'a self, chars: &'a [u8]) -> PdfFontIter<'a>",
            "pub fn new(file: &mut dyn std::io::Write) -> HTMLOutput<'_>",
            "pub fn new(file: &mut dyn std::io::Write) -> SVGOutput<'_>",
        ):
            self.assertIn(signature, library)
        for index in range(46):
            self.assertIn(f'{{ preserve_result_{index}() }}', library)

    def test_discarded_logging_and_runtime_initializers_do_not_change(self):
        original = self.values['src/lib.rs'].decode()
        library = self.files['src/lib.rs'].decode()
        macro = 'macro_rules! dlog {\n    ($($e:expr),*) => { {} }\n}'
        self.assertIn(macro, original)
        self.assertIn(macro, library)
        def initializers(source):
            return [re.sub(r'^let _?(name|base_name) = ', 'let binding = ', line.strip())
                for line in source.splitlines() if re.match(r'^\s*let _?(name|base_name) = ', line)]
        self.assertEqual(initializers(original), initializers(library))
        self.assertIn('panic!("unexpected entry in unicode map")', library)
        self.assertIn('if font_metrics.0 == base_name { keep_original_matching(); }', library)
        self.assertIn('warn!("no widths and not core font {:?}", base_name);', library)
        self.assertIn('let descendants = maybe_get_array(doc, font, b"DescendantFonts").expect("Descendant fonts required");', library)
        self.assertIn('for (_k, v) in *info {', library)
        self.assertIn('Entry::Occupied(_e)', library)
        self.assertNotIn('Entry::Occupied(e)', library)

    def test_all_4700_glyph_entries_and_lookup_semantics_are_preserved(self):
        original = self.values['src/glyphnames.rs']
        current = self.files['src/glyphnames.rs']
        def payload(value):
            return value.split(b' = [\n', 1)[1].split(b'];\n', 1)[0]
        self.assertEqual(payload(original), payload(current))
        self.assertEqual(payload(current).count(b'("synthetic-'), 4700)
        self.assertIn(b"const NAMES: [(&'static str, u16); 4700]", current)
        self.assertIn(b'NAMES.binary_search_by_key(&name, |&(name, _code)| &name)', current)
        self.assertIn(b'result.ok().map(|indx| NAMES[indx].1)', current)

    def test_foreign_type_table_and_duplicate_warning_anchors_fail_closed(self):
        for name, previous, current in (
            ('src/lib.rs', b'-> Result<', b'-> ForeignResult<'),
            ('src/lib.rs', b'std::f64::NAN', b'std::f64::NAN + std::f64::NAN'),
            ('src/lib.rs', b'Option<PdfFontDescriptor>', b"Option<PdfFontDescriptor<'static>>"),
            ('src/glyphnames.rs', b'names[indx].1', b'foreign[indx].1'),
            ('src/glyphnames.rs', b'; 4700]', b'; 4699]'),
        ):
            with self.subTest(name=name, previous=previous):
                values = dict(self.values)
                values[name] = values[name].replace(previous, current, 1)
                with self.assertRaisesRegex(ValueError, 'warning adaptation'):
                    unpack(archive(values))

    def test_retained_values_keep_debug_fields_and_clone_state(self):
        library = self.files['src/lib.rs'].decode()
        original = self.values['src/lib.rs'].decode()
        for name in ('Type0Func', 'Type2Func', 'CalGray', 'CalRGB', 'Lab', 'Separation'):
            expression = r'(?:pub )?struct ' + name + r' \{([^}]+)\}'
            self.assertEqual(re.search(expression, original).group(1), re.search(expression, library).group(1))
            self.assertIn('impl Clone for ' + name + ' {', library)
        self.assertEqual(library.count('#[derive(Debug)]'), original.count('#[derive(Clone, Debug)]'))
        self.assertEqual(library.count('#[allow('), original.count('#[allow('))
        validation = 'validate_function_type(); validate_domain(); validate_range(); decode_sampled_stream();'
        self.assertIn(validation, original)
        self.assertIn(validation, library)
        self.assertIn('Self::Type0(value) => Self::Type0(value.clone())', library)
        self.assertIn('Self::Type2(value) => Self::Type2(value.clone())', library)
        self.assertIn('Self::Type4(value) => Self::Type4(value.clone())', library)
        self.assertNotIn('fn get_catalog(', library)
        self.assertNotIn('fn get_pages(', library)
        self.assertNotIn('fn decode(&self, chars:', library)
        self.assertIn('PdfSimpleFont {doc, font, widths: width_map, encoding: encoding_table, missing_width, unicode_map}', library)
        self.assertIn('PdfType3Font {font, widths: width_map, encoding: encoding_table, unicode_map}', library)

    def test_value_layout_changes_and_duplicate_private_helpers_fail_closed(self):
        for previous, current in (
            (b'bits_per_sample: i64,', b'bits_per_sample: i32,'),
            (b'pub struct CalRGB {', b'pub struct CalRGB {\n    unknown_field: f64,'),
            (b'impl Function {', b'impl ForeignFunction {'),
            (b'fn get_catalog(', b'fn changed_catalog('),
            (b"struct PdfType3Font<'a> {", b"struct ForeignFont<'a> {"),
        ):
            with self.subTest(previous=previous):
                values = dict(self.values)
                values['src/lib.rs'] = values['src/lib.rs'].replace(previous, current, 1)
                with self.assertRaisesRegex(ValueError, 'value adaptation'):
                    unpack(archive(values))
        values = dict(self.values)
        values['src/lib.rs'] += VALUE_FIXTURE_SOURCE.encode()
        with self.assertRaisesRegex(ValueError, 'adaptation'):
            unpack(archive(values))

    def test_wrong_checksum_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'checksum'):
            MODULE.source_files(self.data, '0' * 64)

    def test_missing_extractor_is_rejected(self):
        self.values.pop('src/lib.rs')
        with self.assertRaisesRegex(ValueError, 'Missing'):
            unpack(archive(self.values))

    def test_changed_or_duplicate_adaptation_anchor_is_rejected(self):
        for value in (b'changed upstream API', self.values['src/lib.rs'] * 2):
            with self.subTest(value=value):
                self.values['src/lib.rs'] = value
                with self.assertRaisesRegex(ValueError, 'adaptation'):
                    unpack(archive(self.values))

    def test_traversal_absolute_backslash_and_duplicate_members_are_rejected(self):
        for name in ('pdf-extract-0.12.1/../escape', '/escape', 'pdf-extract-0.12.1/a\\b', 'pdf-extract-0.12.1/src/lib.rs'):
            with self.subTest(name=name):
                member = tarfile.TarInfo(name)
                member.size = 1
                with self.assertRaises(ValueError):
                    unpack(archive(self.values, member))

    def test_links_directories_and_special_members_are_rejected(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.DIRTYPE, tarfile.FIFOTYPE):
            with self.subTest(kind=kind):
                member = tarfile.TarInfo('pdf-extract-0.12.1/unsafe')
                member.type = kind
                member.linkname = 'src/lib.rs'
                with self.assertRaisesRegex(ValueError, 'member'):
                    unpack(archive(self.values, member))

    def test_large_archive_is_rejected_before_open(self):
        data = b'x' * (MODULE.MAXIMUM_BYTES + 1)
        with self.assertRaisesRegex(ValueError, 'checksum'):
            MODULE.source_files(data, hashlib.sha256(data).hexdigest())

    def test_compressed_expansion_is_bounded_before_tar_parsing(self):
        data = gzip.compress(b'x' * (MODULE.MAXIMUM_BYTES * 2 + 1))
        with self.assertRaisesRegex(ValueError, 'expanded'):
            unpack(data)

    def test_install_is_private_complete_and_repeat_verifiable(self):
        MODULE.install(self.target, self.files)
        MODULE.snapshot(self.target, self.expected)
        MODULE.snapshot(self.target, self.expected)
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o700)
        for name in self.files:
            self.assertEqual(stat.S_IMODE((self.target / name).stat().st_mode), 0o600)

    def test_changed_current_output_is_rejected_without_replacement(self):
        MODULE.install(self.target, self.files)
        path = self.target / 'src/lib.rs'
        path.write_bytes(b'changed current output')
        with self.assertRaisesRegex(ValueError, 'changed'):
            MODULE.snapshot(self.target, self.expected)
        self.assertEqual(path.read_bytes(), b'changed current output')

    def test_missing_and_extra_current_output_is_rejected(self):
        MODULE.install(self.target, self.files)
        path = self.target / 'README.md'
        path.unlink()
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            MODULE.snapshot(self.target, self.expected)
        path.write_bytes(self.files['README.md'])
        os.chmod(path, 0o600)
        (self.target / 'extra').write_bytes(b'extra')
        with self.assertRaisesRegex(ValueError, 'Unexpected'):
            MODULE.snapshot(self.target, self.expected)

    def test_unsafe_generated_file_and_parent_are_rejected(self):
        MODULE.install(self.target, self.files)
        path = self.target / 'README.md'
        os.chmod(path, 0o644)
        with self.assertRaisesRegex(ValueError, 'private'):
            MODULE.snapshot(self.target, self.expected)
        os.chmod(path, 0o600)
        os.link(path, self.root / 'hardlink')
        with self.assertRaisesRegex(ValueError, 'private'):
            MODULE.snapshot(self.target, self.expected)
        (self.root / 'hardlink').unlink()
        path.unlink()
        path.symlink_to(self.root / 'outside')
        with self.assertRaises(OSError):
            MODULE.snapshot(self.target, self.expected)

    def test_symlink_or_writable_directory_is_rejected(self):
        MODULE.install(self.target, self.files)
        os.chmod(self.target / 'src', 0o755)
        with self.assertRaisesRegex(ValueError, 'private'):
            MODULE.snapshot(self.target, self.expected)
        alias = self.root / 'alias'
        alias.symlink_to(self.target, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'private'):
            MODULE.snapshot(alias, self.expected)

    def test_access_time_changes_do_not_invalidate_stable_file_identity(self):
        MODULE.install(self.target, self.files)
        before = (self.target / 'README.md').stat()
        with patch.object(MODULE.os, 'fstat', wraps=os.fstat):
            MODULE.snapshot(self.target, self.expected)
        after = (self.target / 'README.md').stat()
        self.assertEqual(MODULE.file_identity(before), MODULE.file_identity(after))

    def test_tracked_manifest_prepares_real_private_sources_without_changing_metadata(self):
        for mode in (0o600, 0o644):
            with self.subTest(mode=mode):
                root = self.root / str(mode)
                root.mkdir(mode=0o700)
                target = root / 'pdf-extract'
                target.mkdir(mode=0o755)
                manifest = target / 'Cargo.toml'
                manifest.write_bytes(self.files['Cargo.toml'])
                os.chmod(manifest, mode)
                before = MODULE.file_identity(manifest.stat())
                with patch.object(MODULE, '__file__', str(root / 'prepare-pdf-extract.py')), patch.object(MODULE, 'download', return_value=self.data), patch.object(MODULE, 'ARCHIVE_SHA256', hashlib.sha256(self.data).hexdigest()):
                    self.assertEqual(MODULE.prepare(), target)
                    self.assertEqual(MODULE.prepare(), target)
                self.assertEqual(before, MODULE.file_identity(manifest.stat()))
                self.assertEqual(manifest.read_bytes(), self.files['Cargo.toml'])
                self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o700)
                for name, value in self.files.items():
                    self.assertEqual((target / name).read_bytes(), value)
                    self.assertEqual(stat.S_IMODE((target / name).stat().st_mode), mode if name == 'Cargo.toml' else 0o600)
                self.assertEqual((target / 'LICENSE').read_bytes(), self.values['LICENSE'])

    def test_tracked_manifest_rejects_changed_bytes_links_and_writable_modes_before_source_creation(self):
        self.target.mkdir(mode=0o755)
        manifest = self.target / 'Cargo.toml'
        manifest.write_bytes(self.files['Cargo.toml'])
        os.chmod(manifest, 0o644)
        for mode in (0o666, 0o664, 0o620):
            os.chmod(manifest, mode)
            with self.assertRaisesRegex(ValueError, 'immutable'):
                MODULE.immutable_manifest(manifest, self.files['Cargo.toml'])
        os.chmod(manifest, 0o644)
        manifest.write_bytes(b'foreign metadata')
        with self.assertRaisesRegex(ValueError, 'immutable|adaptations'):
            MODULE.immutable_manifest(manifest, self.files['Cargo.toml'])
        manifest.write_bytes(self.files['Cargo.toml'])
        os.link(manifest, self.root / 'linked-manifest')
        with self.assertRaisesRegex(ValueError, 'immutable'):
            MODULE.immutable_manifest(manifest, self.files['Cargo.toml'])
        (self.root / 'linked-manifest').unlink()
        manifest.unlink()
        manifest.symlink_to(self.root / 'outside')
        with self.assertRaises(OSError):
            MODULE.immutable_manifest(manifest, self.files['Cargo.toml'])
        self.assertFalse((self.target / 'src').exists())

    def test_tracked_metadata_never_relaxes_private_generated_source_checks(self):
        self.target.mkdir(mode=0o755)
        manifest = self.target / 'Cargo.toml'
        manifest.write_bytes(self.files['Cargo.toml'])
        os.chmod(manifest, 0o644)
        MODULE.immutable_manifest(manifest, self.files['Cargo.toml'])
        MODULE.install(self.target, self.files, True)
        source = self.target / 'src/lib.rs'
        os.chmod(source, 0o644)
        with self.assertRaisesRegex(ValueError, 'private'):
            MODULE.snapshot(self.target, self.expected, True)
        os.chmod(source, 0o600)
        source.write_bytes(b'changed parser')
        with self.assertRaisesRegex(ValueError, 'changed'):
            MODULE.snapshot(self.target, self.expected, True)
        self.assertEqual(source.read_bytes(), b'changed parser')
        self.assertEqual(manifest.read_bytes(), self.files['Cargo.toml'])


if __name__ == '__main__':
    unittest.main()
