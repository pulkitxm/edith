import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).parent / 'hosted-public-release/production-static-inputs.py'
SPEC = importlib.util.spec_from_file_location('signing_inputs', SOURCE)
INPUTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INPUTS)
REQUIREMENT = 'identifier "com.pulkit.edith" and anchor apple generic and certificate leaf[subject.OU] = "ABCDEFGHIJ"'
APPLICATION = Path('/synthetic/Edith.app')


def metadata(arguments, **options):
    if '-r-' in arguments:
        return subprocess.CompletedProcess(arguments, 0, 'designated => ' + REQUIREMENT + '\n', '')
    return subprocess.CompletedProcess(arguments, 0, '', 'TeamIdentifier=ABCDEFGHIJ\nCDHash=' + 'a' * 40 + '\n')


class SigningRequirementTests(unittest.TestCase):
    def test_inline_identity_keeps_deep_strict_verification_and_metadata(self):
        def verify(arguments):
            self.assertEqual(arguments[0], 'codesign')
            self.assertIn('--verify', arguments)
            self.assertIn('--deep', arguments)
            self.assertIn('--strict', arguments)
            self.assertEqual(arguments[-1], str(APPLICATION))
            requirements = [argument[3:] for argument in arguments if argument.startswith('-R=')]
            self.assertEqual(requirements, [REQUIREMENT])
            self.assertNotIn('-R', arguments)
        with patch.object(INPUTS, 'command', side_effect=verify), patch.object(INPUTS.subprocess, 'run', side_effect=metadata):
            actual = INPUTS.signing(APPLICATION, 'ABCDEFGHIJ', REQUIREMENT)
        self.assertEqual(actual, {'codeHash': 'a' * 40, 'requirement': REQUIREMENT})

    def test_signature_failure_cannot_admit_displayed_metadata(self):
        failure = subprocess.CalledProcessError(1, ['codesign'])
        with patch.object(INPUTS, 'command', side_effect=failure), patch.object(INPUTS.subprocess, 'run') as displayed:
            with self.assertRaises(subprocess.CalledProcessError):
                INPUTS.signing(APPLICATION, 'ABCDEFGHIJ', REQUIREMENT)
        displayed.assert_not_called()

    def test_foreign_team_is_rejected_after_successful_verification(self):
        with patch.object(INPUTS, 'command'), patch.object(INPUTS.subprocess, 'run', side_effect=metadata):
            with self.assertRaisesRegex(ValueError, 'Signed code ownership differs'):
                INPUTS.signing(APPLICATION, 'KLMNOPQRST', REQUIREMENT)

    def test_stderr_metadata_cannot_replace_the_designated_requirement_output(self):
        def wrong_stream(arguments, **options):
            if '-r-' in arguments:
                return subprocess.CompletedProcess(arguments, 0, '', 'designated => ' + REQUIREMENT + '\n')
            return metadata(arguments, **options)
        with patch.object(INPUTS, 'command'), patch.object(INPUTS.subprocess, 'run', side_effect=wrong_stream):
            with self.assertRaisesRegex(ValueError, 'Missing designated code requirement'):
                INPUTS.signing(APPLICATION, 'ABCDEFGHIJ', REQUIREMENT)

    def test_carrier_verification_without_an_extra_requirement_remains_strict(self):
        with patch.object(INPUTS, 'command') as verified, patch.object(INPUTS.subprocess, 'run', side_effect=metadata):
            INPUTS.signing(APPLICATION, 'ABCDEFGHIJ')
        arguments = verified.call_args.args[0]
        self.assertIn('--verify', arguments)
        self.assertIn('--deep', arguments)
        self.assertIn('--strict', arguments)
        self.assertFalse(any(argument.startswith('-R') for argument in arguments))


if __name__ == '__main__':
    unittest.main()
