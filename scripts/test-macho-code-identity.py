import hashlib
import struct
import unittest
import tempfile
from pathlib import Path
from unittest.mock import patch
import macho_code_identity
from macho_code_identity import identity_from_bytes, normalize_signed_and_unsigned, rounded

TEXT_COMMAND = 32
LINK_COMMAND = 184
SIGNATURE_COMMAND = 256


def pair(signature_bytes=64, filetype=2):
    fileoff = 32768
    unsigned_size = fileoff + 16300
    signature_start = (unsigned_size + 15) // 16 * 16
    signed_size = signature_start + signature_bytes
    vmsize = rounded(signed_size - fileoff)
    text = struct.pack('<II16sQQQQiiII', 0x19, 152, b'__TEXT', 0x100000000, fileoff, 0, fileoff, 5, 5, 1, 0)
    text += struct.pack('<16s16sQQIIIIIIII', b'__text', b'__TEXT', 0x100001000, 64, 4096, 2, 0, 0, 0, 0, 0, 0)
    link = lambda size: struct.pack('<II16sQQQQiiII', 0x19, 72, b'__LINKEDIT', 0x100008000, vmsize, fileoff, size, 1, 1, 0, 0)
    signature = struct.pack('<IIII', 0x1d, 16, signature_start, signature_bytes)
    rpath = struct.pack('<III', 0x8000001c, 24, 12) + b'/fixture\0\0\0\0'
    unsigned = bytearray(unsigned_size)
    unsigned[4096:4160] = b'T' * 64
    unsigned[fileoff:] = b'L' * 16300
    signed = bytearray(unsigned) + bytearray(signature_start - unsigned_size) + b'S' * signature_bytes
    unsigned_commands = text + link(16300) + rpath
    signed_commands = text + link(signed_size - fileoff) + signature + rpath
    for data, commands, count in [(signed, signed_commands, 4), (unsigned, unsigned_commands, 3)]:
        struct.pack_into('<8I', data, 0, 0xfeedfacf, 0x0100000c, 0, filetype, count, len(commands), 0, 0)
        data[32:32 + len(commands)] = commands
    return signed, unsigned


def expected():
    signed, unsigned = pair()
    return hashlib.sha256(normalize_signed_and_unsigned(signed, unsigned)).hexdigest()


class StrictMachOIdentityTests(unittest.TestCase):
    def test_signature_removal_uses_only_a_private_copy_and_a_bounded_process(self):
        signed, unsigned = pair(512)
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'original'
            source.write_bytes(signed)
            def remove(arguments, **options):
                copied = Path(arguments[-1])
                self.assertNotEqual(copied, source)
                self.assertEqual(copied.read_bytes(), signed)
                self.assertEqual(arguments[:2], ['codesign', '--remove-signature'])
                self.assertEqual(options['timeout'], 30)
                self.assertTrue(options['check'])
                copied.write_bytes(unsigned)
            with patch.object(macho_code_identity.subprocess, 'run', side_effect=remove) as process:
                result = macho_code_identity.executable_identity(source, expected())
            process.assert_called_once()
            self.assertEqual(source.read_bytes(), signed)
            self.assertEqual(result['signedSHA256'], hashlib.sha256(signed).hexdigest())
            self.assertEqual(result['rawUnsignedSHA256'], hashlib.sha256(unsigned).hexdigest())

    def test_signature_crossing_page_keeps_all_code_and_records_both_unsigned_hashes(self):
        source = identity_from_bytes(*pair(), expected())
        worker = identity_from_bytes(*pair(512), expected())
        self.assertEqual(source['normalizedUnsignedSHA256'], worker['normalizedUnsignedSHA256'])
        self.assertNotEqual(source['rawUnsignedSHA256'], worker['rawUnsignedSHA256'])
        self.assertNotEqual(source['signedSHA256'], worker['signedSHA256'])
        self.assertEqual(source['rawUnsignedBytes'], worker['rawUnsignedBytes'])

    def test_linkedit_payload_changed_during_removal_rejected(self):
        signed, unsigned = pair(512)
        unsigned[40000] ^= 1
        with self.assertRaisesRegex(ValueError, 'Other executable bytes'):
            normalize_signed_and_unsigned(signed, unsigned)

    def test_matching_linkedit_payload_tamper_does_not_match_pinned_code(self):
        signed, unsigned = pair(512)
        signed[40000] ^= 1
        unsigned[40000] ^= 1
        with self.assertRaisesRegex(ValueError, 'pinned source'):
            identity_from_bytes(signed, unsigned, expected())

    def test_matching_text_payload_tamper_does_not_match_pinned_code(self):
        signed, unsigned = pair(512)
        signed[4100] ^= 1
        unsigned[4100] ^= 1
        with self.assertRaisesRegex(ValueError, 'pinned source'):
            identity_from_bytes(signed, unsigned, expected())

    def test_section_metadata_change_during_removal_rejected(self):
        signed, unsigned = pair(512)
        unsigned[TEXT_COMMAND + 72 + 32] ^= 1
        with self.assertRaisesRegex(ValueError, 'Other executable bytes'):
            normalize_signed_and_unsigned(signed, unsigned)

    def test_matching_section_metadata_tamper_does_not_match_pinned_code(self):
        signed, unsigned = pair(512)
        signed[TEXT_COMMAND + 72 + 32] ^= 1
        unsigned[TEXT_COMMAND + 72 + 32] ^= 1
        with self.assertRaisesRegex(ValueError, 'pinned source'):
            identity_from_bytes(signed, unsigned, expected())

    def test_unrelated_load_command_bytes_are_not_ignored(self):
        signed, unsigned = pair(512)
        signed[SIGNATURE_COMMAND + 16 + 12] ^= 1
        unsigned[SIGNATURE_COMMAND + 12] ^= 1
        with self.assertRaisesRegex(ValueError, 'pinned source'):
            identity_from_bytes(signed, unsigned, expected())

    def test_invalid_signed_input_never_invokes_signature_removal(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'Edith'
            signed, _ = pair(512)
            struct.pack_into('<Q', signed, LINK_COMMAND + 32, 49152)
            source.write_bytes(signed)
            with patch.object(macho_code_identity.subprocess, 'run') as command, self.assertRaisesRegex(ValueError, 'mapping does not match'):
                macho_code_identity.executable_identity(source)
            command.assert_not_called()
            self.assertEqual(source.read_bytes(), signed)

    def test_signature_removal_cannot_change_unrelated_header_fields(self):
        signed, unsigned = pair(512)
        unsigned[28] ^= 1
        with self.assertRaisesRegex(ValueError, 'Other executable bytes'):
            normalize_signed_and_unsigned(signed, unsigned)

    def test_signed_linkedit_mapping_must_be_justified_by_signature_size(self):
        signed, unsigned = pair(512)
        struct.pack_into('<Q', signed, LINK_COMMAND + 32, 49152)
        with self.assertRaisesRegex(ValueError, 'mapping does not match'):
            normalize_signed_and_unsigned(signed, unsigned)

    def test_signature_tail_bounds_are_checked_before_removal(self):
        for field, value in [(8, 10), (8, 2**32 - 16), (12, 0), (12, 2**32 - 1)]:
            signed, unsigned = pair(512)
            struct.pack_into('<I', signed, SIGNATURE_COMMAND + field, value)
            with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, 'signature tail bounds'):
                normalize_signed_and_unsigned(signed, unsigned)

    def test_signature_alignment_padding_must_be_zero(self):
        signed, unsigned = pair(512)
        signed[len(unsigned)] = 1
        with self.assertRaisesRegex(ValueError, 'Unexpected bytes'):
            normalize_signed_and_unsigned(signed, unsigned)

    def test_linkedit_sections_are_never_normalized(self):
        signed, unsigned = pair(512)
        struct.pack_into('<I', signed, LINK_COMMAND + 64, 1)
        with self.assertRaisesRegex(ValueError, 'segment bounds'):
            normalize_signed_and_unsigned(signed, unsigned)

    def test_invalid_section_file_range_is_rejected(self):
        signed, unsigned = pair(512)
        struct.pack_into('<I', signed, TEXT_COMMAND + 72 + 48, len(signed) + 1)
        with self.assertRaisesRegex(ValueError, 'Section data'):
            normalize_signed_and_unsigned(signed, unsigned)

    def test_unknown_architecture_and_fat_binaries_are_rejected(self):
        for offset, value in [(0, 0xcafebabe), (4, 0x01000007), (8, 2), (12, 6)]:
            signed, unsigned = pair(512)
            struct.pack_into('<I', signed, offset, value)
            with self.subTest(offset=offset), self.assertRaisesRegex(ValueError, 'Only thin arm64'):
                normalize_signed_and_unsigned(signed, unsigned)

    def test_malformed_command_bounds_are_rejected(self):
        for offset, value in [(16, 4097), (20, 2**32 - 1), (TEXT_COMMAND + 4, 7)]:
            signed, unsigned = pair(512)
            struct.pack_into('<I', signed, offset, value)
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                normalize_signed_and_unsigned(signed, unsigned)

    def test_signature_remaining_after_removal_is_rejected(self):
        signed, unsigned = pair(512)
        struct.pack_into('<I', unsigned, SIGNATURE_COMMAND, 0x1d)
        with self.assertRaisesRegex(ValueError, 'signature command'):
            normalize_signed_and_unsigned(signed, unsigned)


class StrictDylibIdentityTests(StrictMachOIdentityTests):
    def test_explicit_dylib_admission_preserves_all_bytes_except_verified_signature_mapping(self):
        original = identity_from_bytes(*pair(64, 6), filetype=6)
        rebound = identity_from_bytes(*pair(512, 6), original['normalizedUnsignedSHA256'], filetype=6)
        self.assertNotEqual(original['signedSHA256'], rebound['signedSHA256'])
        self.assertNotEqual(original['rawUnsignedSHA256'], rebound['rawUnsignedSHA256'])
        for signed, unsigned in [pair(64, 6), pair(64, 2)]:
            with self.assertRaises(ValueError):
                identity_from_bytes(signed, unsigned, filetype=2 if signed[12] == 6 else 6)

    def test_dylib_payload_load_command_section_and_header_tampering_cannot_match_source(self):
        expected_hash = identity_from_bytes(*pair(64, 6), filetype=6)['normalizedUnsignedSHA256']
        for offset in [4100, 40000, SIGNATURE_COMMAND + 28, TEXT_COMMAND + 104, 28]:
            signed, unsigned = pair(512, 6)
            unsigned_offset = offset - 16 if offset == SIGNATURE_COMMAND + 28 else offset
            signed[offset] ^= 1
            unsigned[unsigned_offset] ^= 1
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                identity_from_bytes(signed, unsigned, expected_hash, filetype=6)

    def test_dylib_malformed_signature_segment_and_truncation_are_rejected(self):
        for offset, value in [(SIGNATURE_COMMAND + 8, 10), (SIGNATURE_COMMAND + 12, 0), (LINK_COMMAND + 64, 1), (16, 4097), (TEXT_COMMAND + 4, 7), (LINK_COMMAND + 48, 0xffffffff)]:
            signed, unsigned = pair(512, 6)
            struct.pack_into('<I', signed, offset, value)
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                identity_from_bytes(signed, unsigned, filetype=6)
        signed, unsigned = pair(512, 6)
        with self.assertRaises(ValueError):
            identity_from_bytes(signed[:31], unsigned, filetype=6)
        struct.pack_into('<I', signed, SIGNATURE_COMMAND + 16, 0x1d)
        with self.assertRaises(ValueError):
            identity_from_bytes(signed, unsigned, filetype=6)

    def test_unsupported_filetype_is_rejected_before_removing_signature(self):
        with self.assertRaisesRegex(ValueError, 'Unsupported'):
            identity_from_bytes(*pair(), filetype=8)


if __name__ == '__main__':
    unittest.main()
