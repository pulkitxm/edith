import base64
import contextlib
import json
import os
import pathlib
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
home = pathlib.Path(os.environ['HOME'])
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
signal.signal(signal.SIGHUP, interrupted)
signal.signal(signal.SIGALRM, interrupted)
signal.alarm(880)


def regular(path):
    relative = path.relative_to(home)
    current = home
    for part in relative.parts:
        current = current / part
        metadata = current.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            return False
    return stat.S_ISREG(metadata.st_mode)


def admitted(path):
    relative = path.relative_to(home)
    name = path.name.lower()
    parts = [part.lower() for part in relative.parts]
    if any(part in {'credentials', 'credential', 'secrets', 'auth', 'plugins', 'skills'} for part in parts):
        return False
    if any(word in name for word in ['credential', 'secret', 'auth', 'token', 'config']):
        return False
    if name.endswith(('.sqlite', '.db')):
        return str(relative) in databases or name == 'openclaw-agent.sqlite'
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

with tempfile.TemporaryDirectory(prefix='edith-receipt-snapshot-') as temporary:
    os.chmod(temporary, 0o700)

    def add(path):
        global total
        relative = str(path.relative_to(home))
        if relative in seen or not regular(path) or not admitted(path):
            return
        seen.add(relative)
        before = path.lstat()
        if before.st_size > MAX_FILE:
            raise ValueError('A receipt exceeds the 8 MiB per-file limit')
        if path.suffix.lower() in {'.db', '.sqlite'}:
            backup = pathlib.Path(temporary) / 'snapshot.db'
            with contextlib.closing(sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=10)) as source:
                page_count = source.execute('PRAGMA page_count').fetchone()[0]
                page_size = source.execute('PRAGMA page_size').fetchone()[0]
                if page_count * page_size > MAX_FILE:
                    raise ValueError('SQLite receipt exceeds its bounded capacity')
                with contextlib.closing(sqlite3.connect(backup)) as destination:
                    source.backup(destination, pages=256, sleep=0.01)
            if backup.stat().st_size > MAX_FILE:
                raise ValueError('SQLite backup exceeds its bounded capacity')
            data = backup.read_bytes()
            backup.unlink()
        else:
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
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
                            if isinstance(cwd, str) and cwd.startswith('/') and len(cwd.encode()) <= 4096 and not any(ord(char) < 32 for char in cwd):
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
        if not root.exists():
            continue
        current = home
        safe = True
        for part in pathlib.Path(relative).parts:
            current = current / part
            if current.is_symlink():
                safe = False
                break
        if not safe:
            continue
        for directory, children, names in os.walk(root, followlinks=False):
            children[:] = sorted(child for child in children if not (pathlib.Path(directory) / child).is_symlink())
            for name in sorted(names):
                inspected += 1
                if inspected > 100000:
                    raise ValueError('Receipt discovery exceeds its bounded capacity')
                add(pathlib.Path(directory) / name)
    for relative in databases:
        path = home / relative
        if path.exists():
            add(path)
    config = home / '.codex/config.toml'
    if config.exists() and regular(config) and config.stat().st_size <= 1048576:
        descriptor = os.open(config, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
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
        folder = pathlib.Path(root).name or 'remote'
        project = {'cwd': cwd, 'root': root, 'repositoryID': root, 'repositoryName': folder, 'folderName': pathlib.Path(cwd).name or folder}
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
