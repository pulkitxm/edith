import base64
import contextlib
import json
import os
import pathlib
import ntpath
import re
import subprocess
import urllib.parse
import signal
import sqlite3
import stat
import tempfile
import time

MAX_FILE = 8388608
MAX_TOTAL = 41943040
MAX_COUNT = 10000
windows = os.name == 'nt' or os.environ.get('EDITH_USAGE_SNAPSHOT_WINDOWS') == '1'
home = pathlib.Path(os.environ.get('EDITH_USAGE_SNAPSHOT_HOME') or os.environ['HOME']).absolute()
if not home.is_dir():
    raise RuntimeError('The saved machine home is unavailable; check Git Bash HOME and cygpath')
roots = [
    '.claude/projects', 'Library/Application Support/Claude/local-agent-mode-sessions',
    '.codex/sessions', '.codex/archived_sessions', '.local/share/opencode/storage/message',
    '.cursor/chats', '.pi/agent/sessions', '.commandcode/projects', '.local/share/amp',
    '.factory/sessions', '.config/manicode/projects', '.config/manicode-dev/projects',
    '.config/manicode-staging/projects', '.hermes/sessions', '.local/share/goose/sessions',
    '.local/share/Block/goose/sessions', 'Library/Application Support/goose/sessions',
    '.local/share/kilo', '.gemini/tmp', '.copilot', '.kimi/sessions', '.kimi-code/sessions',
    '.qwen/projects', '.openclaw', '.clawdbot', '.moltbot', '.moldbot', '.grok/sessions',
]
databases = [
    '.local/share/opencode/opencode.db', '.hermes/state.db',
    '.local/share/goose/sessions/sessions.db', '.local/share/Block/goose/sessions/sessions.db',
    'Library/Application Support/goose/sessions/sessions.db', '.local/share/kilo/kilo.db',
]

def interrupted(signum, frame):
    raise InterruptedError('Receipt snapshot cancelled')

signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)
if hasattr(signal, 'SIGHUP'):
    signal.signal(signal.SIGHUP, interrupted)
if hasattr(signal, 'SIGALRM'):
    signal.signal(signal.SIGALRM, interrupted)
    signal.alarm(880)


def unsafe(path):
    metadata = path.lstat()
    return stat.S_ISLNK(metadata.st_mode) or bool(getattr(metadata, 'st_file_attributes', 0) & 0x400)


def present(path):
    try:
        path.lstat()
        return True
    except FileNotFoundError:
        return False
    except OSError as error:
        raise RuntimeError('Cannot inspect a supported receipt source; check its read permissions') from error


def regular(path):
    relative = path.relative_to(home)
    current = home
    for part in relative.parts:
        current = current / part
        metadata = current.lstat()
        if stat.S_ISLNK(metadata.st_mode) or getattr(metadata, 'st_file_attributes', 0) & 0x400:
            return False
    return stat.S_ISREG(metadata.st_mode)


def admitted(path):
    relative = path.relative_to(home)
    name = path.name.lower()
    parts = [part.lower() for part in relative.parts]
    if any(part in {'credentials', 'credential', 'secrets', 'auth', 'plugins', 'skills', 'node_modules', '.git'} for part in parts):
        return False
    if any(word in name for word in ['credential', 'secret', 'auth', 'token', 'config']):
        return False
    if name.endswith(('.sqlite', '.db')):
        return relative.as_posix() in databases or name == 'openclaw-agent.sqlite'
    if path.suffix.lower() not in {'.json', '.jsonl'}:
        return False
    if parts[0] in {'.openclaw', '.clawdbot', '.moltbot', '.moldbot', '.copilot'} and 'sessions' not in parts and 'session-state' not in parts:
        return False
    if '.grok' in parts and name not in {'updates.jsonl', 'summary.json'}:
        return False
    if '.factory' in parts and not name.endswith('.settings.json'):
        return False
    if any(part in parts for part in ['manicode', 'manicode-dev', 'manicode-staging']) and name != 'chat-messages.json':
        return False
    if ('.kimi' in parts or '.kimi-code' in parts) and name != 'wire.jsonl':
        return False
    if 'local-agent-mode-sessions' in parts and not ('.claude' in parts and 'projects' in parts):
        return False
    return True


files = []
seen = set()
total = 0
inspected = 0
workdirs = set()

with (contextlib.nullcontext(None) if windows else tempfile.TemporaryDirectory(prefix='edith-receipt-snapshot-')) as temporary:
    if temporary is not None:
        os.chmod(temporary, 0o700)

    def add(path):
        global total
        relative = path.relative_to(home).as_posix()
        if relative in seen or not regular(path) or not admitted(path):
            return
        seen.add(relative)
        before = path.lstat()
        if before.st_size > MAX_FILE:
            raise ValueError('A receipt exceeds the 8 MiB per-file limit')
        if path.suffix.lower() in {'.db', '.sqlite'}:
            backup = None if windows else pathlib.Path(temporary) / 'snapshot.db'
            with contextlib.closing(sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=10)) as source:
                page_count = source.execute('PRAGMA page_count').fetchone()[0]
                page_size = source.execute('PRAGMA page_size').fetchone()[0]
                if page_count * page_size > MAX_FILE:
                    raise ValueError('SQLite receipt exceeds its bounded capacity')
                if windows:
                    if not hasattr(sqlite3.Connection, 'serialize'):
                        raise RuntimeError('Python 3.11 or newer with SQLite serialization is required for safe Windows SQLite receipt snapshots')
                    with contextlib.closing(sqlite3.connect(':memory:')) as destination:
                        source.backup(destination, pages=256, sleep=0.01)
                        serialized = bytearray(destination.serialize())
                        if serialized[:16] != b'SQLite format 3\x00' or len(serialized) < 100:
                            raise ValueError('SQLite backup did not produce a valid database')
                        serialized[18:20] = b'\x01\x01'
                        data = bytes(serialized)
                else:
                    with contextlib.closing(sqlite3.connect(backup)) as destination:
                        source.backup(destination, pages=256, sleep=0.01)
            if not windows:
                if backup.stat().st_size > MAX_FILE:
                    raise ValueError('SQLite backup exceeds its bounded capacity')
                data = backup.read_bytes()
                backup.unlink()
        else:
            descriptor = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0) | getattr(os, 'O_BINARY', 0))
            with os.fdopen(descriptor, 'rb') as stream:
                opened = os.fstat(stream.fileno())
                if not stat.S_ISREG(opened.st_mode) or opened.st_ino != before.st_ino or opened.st_dev != before.st_dev:
                    raise ValueError('Receipt changed while opening')
                data = stream.read(MAX_FILE + 1)
                after = os.fstat(stream.fileno())
                if after.st_size != opened.st_size or after.st_mtime_ns != opened.st_mtime_ns:
                    raise ValueError('Receipt changed during snapshot, retry collection')
        if len(data) > MAX_FILE or total + len(data) > MAX_TOTAL or len(files) >= MAX_COUNT:
            raise ValueError('Receipt snapshot exceeds its bounded capacity')
        total += len(data)
        if path.suffix.lower() in {'.json', '.jsonl'}:
            try:
                records = [json.loads(data)] if path.suffix.lower() == '.json' else [json.loads(line) for line in data.splitlines() if line.strip()]
                stack = records[:]
                nodes = 0
                while stack:
                    record = stack.pop()
                    nodes += 1
                    if nodes > 100000:
                        raise ValueError('Receipt context exceeds its bounded capacity')
                    if isinstance(record, dict):
                        for key in ['cwd', 'directory', 'projectPath']:
                            cwd = record.get(key)
                            if isinstance(cwd, str) and (cwd.startswith('/') or re.match(r'^[A-Za-z]:[\\/]', cwd)) and len(cwd.encode()) <= 4096 and not any(ord(char) < 32 for char in cwd):
                                workdirs.add(cwd)
                                if len(workdirs) > MAX_COUNT:
                                    raise ValueError('Receipt projects exceed their bounded capacity')
                        stack.extend(record.values())
                    elif isinstance(record, list):
                        stack.extend(record)
            except (json.JSONDecodeError, UnicodeDecodeError):
                pass
        files.append({'path': relative, 'modifiedAt': before.st_mtime, 'data': base64.b64encode(data).decode('ascii')})

    for relative in roots:
        root = home / relative
        if not present(root):
            continue
        current = home
        safe = True
        for part in pathlib.Path(relative).parts:
            current = current / part
            if unsafe(current):
                safe = False
                break
        if not safe:
            raise ValueError('A supported receipt root is a symbolic link or Windows junction; select a regular receipt home')
        if not root.is_dir():
            raise ValueError('A supported receipt root is not a directory; check its saved machine path')
        def enumeration_error(error):
            raise error
        for directory, children, names in os.walk(root, followlinks=False, onerror=enumeration_error):
            children[:] = sorted(child for child in children if child.lower() not in {'node_modules', '.git', 'credentials', 'secrets', 'auth', 'plugins', 'skills'} and not unsafe(pathlib.Path(directory) / child))
            for name in sorted(names):
                inspected += 1
                if inspected > 100000:
                    raise ValueError('Receipt discovery exceeds its bounded capacity')
                add(pathlib.Path(directory) / name)
    for relative in databases:
        path = home / relative
        if present(path):
            add(path)
    config = home / '.codex/config.toml'
    if present(config) and regular(config) and config.stat().st_size <= 1048576:
        descriptor = os.open(config, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0) | getattr(os, 'O_BINARY', 0))
        with os.fdopen(descriptor, 'r') as stream:
            text = stream.read(1048577)
        tier = re.search(r'^\s*service_tier\s*=\s*"(fast|flex|default|auto|priority)"\s*$', text, re.MULTILINE)
        if tier:
            data = ('service_tier = "' + tier.group(1) + '"\n').encode()
            files.append({'path': '.codex/config.toml', 'modifiedAt': config.stat().st_mtime, 'data': base64.b64encode(data).decode('ascii')})

    def git(cwd, arguments):
        try:
            result = subprocess.run(['git', '-C', cwd] + arguments, capture_output=True, timeout=5)
            if result.returncode == 0 and len(result.stdout) <= 4096:
                return result.stdout.decode('utf-8').strip()
        except (OSError, subprocess.TimeoutExpired, UnicodeDecodeError):
            return None
        return None

    projects = []
    for cwd in sorted(workdirs):
        root = git(cwd, ['rev-parse', '--show-toplevel']) or cwd
        folder = ntpath.basename(ntpath.normpath(root)) if re.match(r'^[A-Za-z]:', root) else pathlib.Path(root).name
        folder = folder or 'remote'
        project = {'cwd': cwd, 'root': root, 'repositoryID': root, 'repositoryName': folder, 'folderName': (ntpath.basename(ntpath.normpath(cwd)) if re.match(r'^[A-Za-z]:', cwd) else pathlib.Path(cwd).name) or folder}
        origin = git(cwd, ['remote', 'get-url', 'origin'])
        if origin:
            match = re.fullmatch(r'git@([^:]+):(.+?)(?:\.git)?', origin)
            if match:
                origin = 'https://' + match.group(1) + '/' + match.group(2)
            parsed = urllib.parse.urlsplit(origin)
            if parsed.scheme in {'http', 'https'} and parsed.hostname and not parsed.username and not parsed.password and not parsed.query and not parsed.fragment:
                repository = re.sub(r'\.git$', '', parsed.path.rstrip('/'))
                project['repositoryID'] = parsed.hostname + repository
                project['repositoryName'] = repository.rsplit('/', 1)[-1]
                project['repositoryURL'] = parsed.scheme + '://' + parsed.netloc + repository
        branch = git(cwd, ['branch', '--show-current'])
        if branch:
            project['worktree'] = branch
        projects.append(project)
    context = {'projects': projects, 'timeZone': 'UTC'}
    if len(json.dumps(context).encode('utf-8')) > 4194304 or len(files) > MAX_COUNT:
        raise ValueError('Receipt context exceeds its bounded capacity')
    result = json.dumps({'version': 1, 'files': files, 'context': context}, separators=(',', ':'))
    if len(result.encode('utf-8')) > 67108864:
        raise ValueError('Encoded snapshot exceeds 64 MiB')
    print(result)
