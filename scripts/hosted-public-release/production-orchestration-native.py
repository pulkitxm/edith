import base64
import importlib.util
import json
import os
from pathlib import Path
import sys
from types import SimpleNamespace


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def main(state_file, python):
    state = json.loads(Path(state_file).read_text())
    args = [value for value in sys.argv[1:] if value not in ['-I', '-B']]
    if args[0] == '-c':
        assert "spec_from_file_location('cohort',sys.argv[1])" in args[1]
        assert Path(args[2]).resolve(strict=True) == Path(state['repository']) / 'scripts/hosted-public-release/production-cohort.py'
        os.execv(python, [python, *sys.argv[1:]])
    path = Path(args[0])
    if not path.is_absolute():
        path = Path.cwd() / path
    path = path.resolve(strict=True)
    root = Path(state['repository'])
    assert path.parent == root / 'scripts/hosted-public-release'
    assert path.name in ['production-static-inputs.py', 'production-sparkle-inputs.py', 'production-feed-preferences.py']
    sys.platform = 'darwin'
    value = load('synthetic_native_entry', path)
    inputs = value if path.name == 'production-static-inputs.py' else getattr(value, 'INPUTS', None)

    def signing(path, team, requirement=None):
        path = Path(path)
        assert path.is_relative_to(root / 'local') or path.is_relative_to(root / 'dist')
        return {'codeHash': 'a' * 40, 'requirement': requirement or 'synthetic unexecuted designated requirement'}

    def inspect_host(directory, expected, generation, release_channel, normalized):
        identity = inputs.release_tag(inputs.ROOT, expected, generation, release_channel)
        assert inputs.STATIC.file_hash(directory / 'Edith.dmg') == {'bytes': expected['dmgBytes'], 'sha256': expected['dmgSHA256']}
        actual = state[generation]['host']
        assert expected['hostExecutableSHA256'] == actual['hostExecutableSHA256']
        assert normalized == actual['normalizedUnsignedSHA256']
        result = {'deepStrictSignatureVerified': True, 'generation': generation, 'source': expected['source'], 'dmg': str(directory / 'Edith.dmg'), 'tagIdentity': identity, 'publicStaticProof': {'sparkleEd25519Verified': True}, 'implementation': {'signedSHA256': expected['hostExecutableSHA256'], 'normalizedUnsignedSHA256': actual['normalizedUnsignedSHA256'], 'normalization': expected['normalization']}, 'role': {'role': 'host', 'executable': inputs.COHORT.EXECUTABLE, 'codeHash': ('a' if generation == 'previous' else 'b') * 40, 'requirement': expected['designatedRequirement']}}
        if release_channel is not None:
            result['releaseChannel'] = release_channel
        return result

    if inputs is not None:
        inputs.signing = signing
        inputs.inspect_host = inspect_host
    if path.name == 'production-sparkle-inputs.py':
        context = json.loads(Path(args[1]).read_text())
        original_command = inputs.command

        def command(arguments, timeout=60):
            if arguments[0] == 'git':
                assert arguments[:3] == ['git', '-C', str(root)]
                return original_command(arguments, timeout)
            assert timeout == 120 and arguments[0] == 'hdiutil'
            mount = Path(arguments[arguments.index('-mountpoint') + 1]) if arguments[1] == 'attach' else Path(arguments[2])
            assert mount.is_relative_to(root / 'local')
            if arguments[1] == 'detach':
                return b''
            assert arguments[1] == 'attach'
            bundle = mount / 'Edith.app'
            executable = bundle / 'Contents/MacOS/Edith'
            executable.parent.mkdir(parents=True, mode=0o700)
            executable.write_bytes(base64.b64decode(state[context['generation']]['executable']))
            executable.chmod(0o600)
            for relative in value.EXECUTABLES.values():
                executable = bundle / value.PREFIX / relative
                executable.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                executable.write_bytes(b'synthetic unexecuted Sparkle executable')
                executable.chmod(0o600)
            return b''

        inputs.command = command
    if path.name == 'production-feed-preferences.py':
        value.pwd.getpwuid = lambda uid: SimpleNamespace(pw_dir=state['home'])
        value.hosted_account(args[2])

        def synchronize(replacement):
            held = value.directory(Path(state['home']) / 'Library/Preferences')
            try:
                data, previous = value.read(held, value.DOMAIN)
                document = value.preferences(data)
                if replacement is None:
                    document.pop(value.KEY, None)
                else:
                    document[value.KEY] = replacement
                import plistlib
                value.replace(held, value.DOMAIN, plistlib.dumps(document), previous)
                return replacement
            finally:
                os.close(held)

        print(json.dumps({'setup': value.setup, 'restore': value.restore}[args[1]](*args[2:], synchronize)))
        return
    sys.argv = [str(path), *args[1:]]
    value.main()
