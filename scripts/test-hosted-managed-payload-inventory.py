import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('inventory', Path(__file__).parent / 'hosted-managed-views/payload-inventory.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PayloadInventoryTests(unittest.TestCase):
    def test_signed_code_and_resources_are_separate_from_signature_resources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / 'runtime.dylib').write_bytes(struct.pack('<4I', 0xfeedfacf, 0x0100000c, 0, 6))
            (root / 'settings.json').write_text('{"synthetic":true}')
            (root / '_CodeSignature').mkdir()
            (root / '_CodeSignature/CodeResources').write_text('signature')
            calls = []
            def identity(path, *, filetype):
                calls.append((path.name, filetype))
                return {'signedSHA256': 'a' * 64, 'rawUnsignedSHA256': 'b' * 64, 'normalizedUnsignedSHA256': 'c' * 64}
            verified = []
            result = module.payload_inventory(root, identity=identity, verify=verified.append)
            self.assertEqual(verified, [root])
            self.assertEqual(calls, [('runtime.dylib', 6)])
            self.assertEqual(set(result['resources']), {'settings.json'})
            self.assertEqual(set(result['signatures']), {'_CodeSignature/CodeResources'})
            self.assertEqual(result['regularFiles'], 3)

    def test_symlink_and_disguised_signature_resource_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / 'link').symlink_to('/synthetic-missing')
            with self.assertRaisesRegex(ValueError, 'nonregular'):
                module.payload_inventory(root, verify=lambda _: None)
            (root / 'link').unlink()
            (root / '_CodeSignature').mkdir()
            (root / '_CodeSignature/hidden-code').write_bytes(b'payload')
            with self.assertRaisesRegex(ValueError, 'signature resource'):
                module.payload_inventory(root, verify=lambda _: None)

    def test_signature_failure_prevents_any_code_inventory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            def fail(_):
                raise ValueError('signature failure')
            with self.assertRaisesRegex(ValueError, 'signature failure'):
                module.payload_inventory(root, identity=lambda _: self.fail('read code'), verify=fail)

    def test_fat_or_unknown_native_code_is_never_treated_as_resource(self):
        for data in [b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca', b'\xfe\xed\xfa\xce', struct.pack('<4I', 0xfeedfacf, 0x0100000c, 0, 8), b'\xcf\xfa\xed\xfe']:
            with self.subTest(data=data), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                (root / 'code').write_bytes(data)
                with self.assertRaises(ValueError):
                    module.payload_inventory(root, verify=lambda _: None)


if __name__ == '__main__':
    unittest.main()
