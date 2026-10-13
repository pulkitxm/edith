import hashlib
import os
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('synthetic_sparkle_inputs', Path(__file__).parent / 'hosted-public-release/production-sparkle-inputs.py')
INPUTS = importlib.util.module_from_spec(spec)
spec.loader.exec_module(INPUTS)


class ProductionSparkleInputTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='sparkle-input-synthetic-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.root.chmod(0o700)
        self.bundle = self.root / 'Edith.app'
        self.host = self.bundle / 'Contents/MacOS/Edith'
        self.write(self.host, b'synthetic unexecuted host')
        self.expected = {'hostExecutableSHA256': hashlib.sha256(self.host.read_bytes()).hexdigest(), 'teamIdentifier': 'ABCDEFGHIJ', 'designatedRequirement': 'synthetic fixed host requirement'}
        for relative in INPUTS.EXECUTABLES.values():
            self.write(self.bundle / INPUTS.PREFIX / relative, b'synthetic unexecuted Sparkle role')

    def write(self, path, data):
        path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o600)

    def signing(self, path, team, requirement=None):
        self.assertEqual(team, self.expected['teamIdentifier'])
        return {'codeHash': 'a' * 40, 'requirement': 'synthetic fixed role requirement'}

    def test_all_four_exact_canonical_roles_derive_only_from_actual_verified_bundle_bytes(self):
        with patch.object(INPUTS.INPUTS, 'signing', side_effect=self.signing) as signing:
            result = INPUTS.roles(self.bundle, self.expected)
        self.assertEqual(len(result), 4)
        self.assertEqual(signing.call_count, 5)
        self.assertEqual({row['role'] for row in result}, set(INPUTS.EXECUTABLES))
        self.assertEqual({row['executable'] for row in result}, {'/Applications/Edith.app/' + INPUTS.PREFIX + relative for relative in INPUTS.EXECUTABLES.values()})
        self.assertEqual(signing.call_args_list[0].args, (self.bundle, self.expected['teamIdentifier'], self.expected['designatedRequirement']))

    def test_wrong_host_or_missing_role_rejects_before_any_role_admission(self):
        self.host.write_bytes(b'different synthetic host')
        with patch.object(INPUTS.INPUTS, 'signing') as signing, self.assertRaisesRegex(ValueError, 'host executable differs'):
            INPUTS.roles(self.bundle, self.expected)
        signing.assert_not_called()
        self.expected['hostExecutableSHA256'] = hashlib.sha256(self.host.read_bytes()).hexdigest()
        (self.bundle / INPUTS.PREFIX / 'Autoupdate').unlink()
        with patch.object(INPUTS.INPUTS, 'signing', side_effect=self.signing), self.assertRaises(FileNotFoundError):
            INPUTS.roles(self.bundle, self.expected)

    def test_changed_role_during_signature_check_rejects_even_when_signature_callback_returns(self):
        def changing(path, team, requirement=None):
            result = self.signing(path, team, requirement)
            if path.name == 'Autoupdate':
                path.write_bytes(b'changed synthetic role')
            return result
        with patch.object(INPUTS.INPUTS, 'signing', side_effect=changing), self.assertRaisesRegex(ValueError, 'changed during verification'):
            INPUTS.roles(self.bundle, self.expected)

    def test_symlink_and_hardlinked_role_never_reach_its_signature_check(self):
        role = self.bundle / INPUTS.PREFIX / 'Autoupdate'
        external = self.root / 'external'
        self.write(external, b'synthetic untouched')
        role.unlink()
        role.symlink_to(external)
        with patch.object(INPUTS.INPUTS, 'signing', side_effect=self.signing) as signing, self.assertRaises(ValueError):
            INPUTS.roles(self.bundle, self.expected)
        self.assertEqual(signing.call_count, 1)
        self.assertEqual(external.read_bytes(), b'synthetic untouched')
        role.unlink()
        os.link(external, role)
        with patch.object(INPUTS.INPUTS, 'signing', side_effect=self.signing) as signing, self.assertRaises(ValueError):
            INPUTS.roles(self.bundle, self.expected)
        self.assertEqual(signing.call_count, 1)
        self.assertEqual(external.read_bytes(), b'synthetic untouched')


if __name__ == '__main__':
    unittest.main()
