import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    'prepare_parser', Path(__file__).with_name('prepare-argument-parser.py'))
prepare_parser = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare_parser)


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='argument-parser-contract-')
        self.package = Path(self.temporary.name).resolve()
        self.scratch = self.package / '.build'
        self.checkout = self.scratch / 'checkouts/swift-argument-parser'
        self.repository = self.scratch / 'repositories/swift-argument-parser-54a11a8d'
        for path in [self.checkout / '.git', self.checkout / 'Sources/ArgumentParser/Parsable Types',
                     self.checkout / 'Sources/ArgumentParser/Usage', self.repository]:
            path.mkdir(parents=True, mode=0o700, exist_ok=True)
        self.before = {
            'Parsable Types/ParsableArguments.swift':
                'import ArgumentParserToolInfo\n  public static var _errorPrefix: String {\n'
                '    "\\(_errorLabel): "\n  }\n',
            'Usage/DumpHelpGenerator.swift':
                '    case .customDeprecated(_):\n      self = .customDeprecated\n',
        }
        self.after = {
            'Parsable Types/ParsableArguments.swift':
                self.before['Parsable Types/ParsableArguments.swift'].replace(
                    '"\\(_errorLabel): "', '"Error: "'),
            'Usage/DumpHelpGenerator.swift':
                self.before['Usage/DumpHelpGenerator.swift'].replace(
                    'self = .customDeprecated', 'self = .custom'),
        }
        self.hashes = {key: (self.digest(self.before[key]), self.digest(self.after[key]))
                       for key in self.before}
        self.override = patch.object(prepare_parser, 'SOURCES', self.hashes)
        self.override.start()
        for key, value in self.before.items():
            self.source(key).write_text(value)
        self.manifest = b'synthetic package manifest\n'
        (self.package / 'Package.swift').write_bytes(self.manifest)
        self.pin = {'identity': 'swift-argument-parser', 'kind': 'remoteSourceControl',
                    'location': 'https://github.com/apple/swift-argument-parser',
                    'state': {'revision': prepare_parser.REVISION, 'version': '1.8.2'}}
        self.lock = json.dumps({'pins': [self.pin], 'version': 3}).encode()
        (self.package / 'Package.resolved').write_bytes(self.lock)
        self.state = {'object': {'dependencies': [{
            'packageRef': {'identity': 'swift-argument-parser', 'location': self.pin['location'],
                           'kind': 'remoteSourceControl'},
            'state': {'checkoutState': self.pin['state'], 'name': 'sourceControlCheckout'},
            'subpath': 'swift-argument-parser'}]}}
        (self.scratch / 'workspace-state.json').write_text(json.dumps(self.state))
        self.commands = []
        self.unexpected = b''
        self.revision = prepare_parser.REVISION
        self.origin = str(self.repository)
        self.remote = self.pin['location']
        self.untracked = b''
        self.cache_file = self.repository / 'immutable-object'
        self.cache_file.write_bytes(b'synthetic immutable cache object')

    def tearDown(self):
        self.override.stop()
        for path in self.package.rglob('*'):
            if path.is_dir() and not path.is_symlink():
                path.chmod(0o700)
        self.temporary.cleanup()

    def digest(self, value):
        return hashlib.sha256(value.encode()).hexdigest()

    def source(self, key):
        return self.checkout / 'Sources/ArgumentParser' / key

    def runner(self, command, **kwargs):
        self.commands.append(command)
        self.assertEqual(kwargs['env']['GIT_NO_REPLACE_OBJECTS'], '1')
        self.assertEqual(kwargs['env']['GIT_CONFIG_GLOBAL'], os.devnull)
        if command[-2:] == ['rev-parse', '--show-toplevel']:
            return (str(self.checkout) + '\n').encode()
        if command[-2:] == ['rev-parse', 'HEAD']:
            return (self.revision + '\n').encode()
        if command[-2:] == ['get-url', 'origin']:
            return ((self.remote if command[command.index('-C') + 1] == str(self.repository) else self.origin) + '\n').encode()
        if 'diff' in command:
            return self.unexpected
        if 'ls-files' in command:
            return self.untracked
        raise AssertionError(command)

    def prepare(self):
        return prepare_parser.prepare_checkout(self.package, self.scratch, self.runner)

    def assert_unchanged(self):
        self.assertEqual((self.package / 'Package.swift').read_bytes(), self.manifest)
        self.assertEqual((self.package / 'Package.resolved').read_bytes(), self.lock)
        self.assertEqual(self.cache_file.read_bytes(), b'synthetic immutable cache object')

    def test_exact_rewrites_preserve_pins_imports_and_cache_objects(self):
        receipt = self.prepare()
        for key in self.before:
            self.assertEqual(self.source(key).read_text(), self.after[key])
        self.assertEqual(receipt['revision'], prepare_parser.REVISION)
        self.assertEqual(receipt['lockSHA256'], hashlib.sha256(self.lock).hexdigest())
        self.assert_unchanged()
        self.assertEqual(len(self.commands), 18)

    def test_incremental_preparation_does_not_replace_postimage_sources(self):
        first = self.prepare()
        identities = {key: prepare_parser.identity(self.source(key).stat()) for key in self.before}
        self.unexpected = '\n'.join('Sources/ArgumentParser/' + key for key in self.before).encode()
        self.assertEqual(self.prepare(), first)
        self.assertEqual({key: prepare_parser.identity(self.source(key).stat()) for key in self.before},
                         identities)
        self.assert_unchanged()

    def test_bad_second_source_is_rejected_before_first_source_mutation(self):
        second = 'Usage/DumpHelpGenerator.swift'
        self.source(second).write_text(self.before[second] + 'substitution\n')
        with self.assertRaisesRegex(ValueError, 'Pinned ArgumentParser source changed'):
            self.prepare()
        self.assertEqual(self.source('Parsable Types/ParsableArguments.swift').read_text(),
                         self.before['Parsable Types/ParsableArguments.swift'])
        self.assert_unchanged()

    def test_wrong_revision_origin_and_foreign_changes_reject_before_mutation(self):
        for field, value in [('revision', 'b' * 40), ('origin', str(self.package / 'shared-cache')),
                             ('remote', 'https://example.invalid/substitution'),
                             ('unexpected', b'Sources/ArgumentParser/Unexpected.swift\n'),
                             ('untracked', b'Sources/ArgumentParser/Unexpected.swift\n')]:
            original = getattr(self, field)
            setattr(self, field, value)
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.prepare()
            setattr(self, field, original)
            for key in self.before:
                self.assertEqual(self.source(key).read_text(), self.before[key])
        self.assert_unchanged()

    def test_wrong_resolved_workspace_rejects_before_source_mutation(self):
        self.state['object']['dependencies'][0]['state']['checkoutState']['revision'] = 'b' * 40
        (self.scratch / 'workspace-state.json').write_text(json.dumps(self.state))
        with self.assertRaisesRegex(ValueError, 'resolved workspace changed'):
            self.prepare()
        for key in self.before:
            self.assertEqual(self.source(key).read_text(), self.before[key])

    def test_symlink_and_hardlink_source_reject_without_touching_destination(self):
        key = 'Parsable Types/ParsableArguments.swift'
        source = self.source(key)
        destination = self.package / 'outside.swift'
        source.rename(destination)
        for link in ['symlink', 'hardlink']:
            if link == 'symlink':
                source.symlink_to(destination)
            else:
                os.link(destination, source)
            with self.subTest(link=link), self.assertRaises(ValueError):
                self.prepare()
            self.assertEqual(destination.read_text(), self.before[key])
            source.unlink()
        self.assert_unchanged()

    def test_symlinked_checkout_and_writable_directory_reject(self):
        moved = self.scratch / 'real-checkout'
        self.checkout.rename(moved)
        self.checkout.symlink_to(moved, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'Noncanonical'):
            self.prepare()
        self.checkout.unlink()
        moved.rename(self.checkout)
        self.checkout.chmod(0o777)
        with self.assertRaisesRegex(ValueError, 'Unowned or writable'):
            self.prepare()
        self.checkout.chmod(0o700)
        self.assert_unchanged()

    def test_atomic_replacement_preserves_readonly_file_and_directory_modes(self):
        for key in self.before:
            self.source(key).chmod(0o444)
            self.source(key).parent.chmod(0o555)
        self.prepare()
        for key in self.before:
            self.assertEqual(stat.S_IMODE(self.source(key).stat().st_mode), 0o444)
            self.assertEqual(stat.S_IMODE(self.source(key).parent.stat().st_mode), 0o555)
            self.assertEqual(self.source(key).read_text(), self.after[key])
        self.assert_unchanged()

    def test_invalid_postimage_and_rewrite_output_fail_closed(self):
        self.prepare()
        key = 'Usage/DumpHelpGenerator.swift'
        self.source(key).write_text(self.after[key] + 'changed\n')
        with self.assertRaisesRegex(ValueError, 'Pinned ArgumentParser source changed'):
            self.prepare()
        self.source(key).write_text(self.before[key])
        with patch.object(prepare_parser, 'rewrite', return_value=b'wrong output'):
            with self.assertRaisesRegex(ValueError, 'rewrite output changed'):
                self.prepare()
        self.assertEqual(self.source(key).read_text(), self.before[key])

    def test_git_node_and_loader_environment_cannot_redirect_or_execute_preloads(self):
        marker = self.package / 'ambient-executed'
        preload = self.package / 'ambient.cjs'
        preload.write_text("require('node:fs').writeFileSync(" + json.dumps(str(marker)) + ", 'bad');")
        hostile = {
            'GIT_DIR': '/synthetic/foreign.git', 'GIT_WORK_TREE': '/synthetic/foreign',
            'GIT_INDEX_FILE': '/synthetic/foreign.index', 'GIT_COMMON_DIR': '/synthetic/common',
            'GIT_OBJECT_DIRECTORY': '/synthetic/objects', 'GIT_ALTERNATE_OBJECT_DIRECTORIES': '/synthetic/alternate',
            'GIT_CONFIG_COUNT': '1', 'GIT_CONFIG_KEY_0': 'core.worktree',
            'GIT_CONFIG_VALUE_0': '/synthetic/foreign', 'GIT_CONFIG_PARAMETERS': 'foreign',
            'NODE_OPTIONS': '--require=' + str(preload), 'NODE_PATH': str(self.package),
            'DYLD_INSERT_LIBRARIES': '/synthetic/preload', 'LD_PRELOAD': '/synthetic/preload',
            'PYTHONPATH': '/synthetic/modules', 'SWIFT_EXEC': '/synthetic/compiler',
        }
        original_runner = self.runner
        def capture(command, **kwargs):
            self.assertTrue(set(hostile).isdisjoint(kwargs['env']))
            return original_runner(command, **kwargs)
        with patch.dict(os.environ, hostile):
            prepare_parser.prepare_checkout(self.package, self.scratch, capture)
        self.assertFalse(marker.exists())
        for key in self.before:
            self.assertEqual(self.source(key).read_text(), self.after[key])
        self.assert_unchanged()

    def test_resolver_receives_only_closed_environment_with_intended_paths(self):
        intended = {'HOME': str(self.package), 'TMPDIR': str(self.package / 'tmp'),
                    'DEVELOPER_DIR': '/synthetic/toolchain', 'PATH': '/synthetic/bin'}
        def resolver(command, **kwargs):
            self.assertEqual(command[:3], ['swift', 'package', '--package-path'])
            self.assertEqual(command[-3:], ['--jobs', '1', 'resolve'])
            self.assertTrue(kwargs['check'])
            for key, expected in intended.items():
                self.assertEqual(kwargs['env'][key], expected)
            self.assertTrue({'GIT_DIR', 'GIT_CONFIG_COUNT', 'NODE_OPTIONS', 'SWIFT_EXEC'}
                            .isdisjoint(kwargs['env']))
        script = self.package.parent / 'scripts/prepare-argument-parser.py'
        with patch.dict(os.environ, {**intended, 'GIT_DIR': '/synthetic/foreign',
                                    'GIT_CONFIG_COUNT': '1', 'NODE_OPTIONS': 'foreign',
                                    'SWIFT_EXEC': '/synthetic/compiler'}), \
                patch.object(prepare_parser, '__file__', str(script)), \
                patch.object(prepare_parser.subprocess, 'run', side_effect=resolver) as call, \
                patch.object(prepare_parser, 'prepare_checkout', return_value={'synthetic': True}):
            prepare_parser.prepare(self.package)
        call.assert_called_once()
        self.assert_unchanged()

    def test_unrelated_mutation_during_rewrite_rejects_before_our_replacement(self):
        original = prepare_parser.rewrite
        def mutate(source, relative):
            result = original(source, relative)
            (self.checkout / 'Sources/ArgumentParser/Unexpected.swift').write_text('substitution')
            self.untracked = b'Sources/ArgumentParser/Unexpected.swift\n'
            return result
        with patch.object(prepare_parser, 'rewrite', side_effect=mutate):
            with self.assertRaisesRegex(ValueError, 'Untracked ArgumentParser'):
                self.prepare()
        for key in self.before:
            self.assertEqual(self.source(key).read_text(), self.before[key])
        self.assert_unchanged()

    def test_unrelated_mutation_during_atomic_replacement_fails_final_revalidation(self):
        original = prepare_parser.replace_file
        def mutate(path, data, metadata):
            original(path, data, metadata)
            (self.checkout / 'Sources/ArgumentParser/Unexpected.swift').write_text('substitution')
            self.untracked = b'Sources/ArgumentParser/Unexpected.swift\n'
        with patch.object(prepare_parser, 'replace_file', side_effect=mutate):
            with self.assertRaisesRegex(ValueError, 'Untracked ArgumentParser'):
                self.prepare()
        self.assert_unchanged()

    def test_fifo_substitution_between_stat_and_open_cannot_block(self):
        source = self.source('Parsable Types/ParsableArguments.swift')
        original_open = os.open
        substitutions = []
        def substitute(name, flags, *args, **kwargs):
            if name == source.name and kwargs.get('dir_fd') is not None:
                self.assertTrue(flags & os.O_NONBLOCK)
                source.unlink()
                os.mkfifo(source, 0o600)
                substitutions.append(name)
            return original_open(name, flags, *args, **kwargs)
        with patch.object(prepare_parser.os, 'open', side_effect=substitute):
            with self.assertRaisesRegex(ValueError, 'Dependency source changed'):
                prepare_parser.read_file(source)
        self.assertEqual(substitutions, [source.name])
        self.assertTrue(stat.S_ISFIFO(source.stat().st_mode))
        self.assert_unchanged()

    def test_changed_pin_rejected(self):
        for field, value in [('version', '1.8.3'), ('revision', 'b' * 40)]:
            self.pin['state'][field] = value
            (self.package / 'Package.resolved').write_text(json.dumps({'pins': [self.pin]}))
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'pin changed'):
                prepare_parser.validate_pin(self.package)
            self.pin['state'] = {'revision': prepare_parser.REVISION, 'version': '1.8.2'}


if __name__ == '__main__':
    unittest.main()
