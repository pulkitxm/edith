import base64
import calendar
import json
import math
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
import unicodedata

STOP = set(
    "a about after all also am an and any are as at be been but by can could did do does for "
    "from had has have he her his how i if in into is it its just me my no not of on or our "
    "please she so than that the their them then there these they this those to too us was we "
    "were what when where which while who why will with would you your".split()
)
SUFFIXES = [
    "izations", "isations", "ization", "isation", "ational", "fulness", "ousness", "iveness",
    "ations", "ation", "ments", "ment", "ities", "ity", "izing", "ising", "izes", "ises",
    "ized", "ised", "ize", "ise", "ings", "ing", "ness", "ances", "ance", "ences", "ence",
    "ers", "er", "ies", "ied", "es", "ed", "ly", "s",
]
WEIGHTS = [3.0, 2.0, 1.5, 0.6]
K1 = 1.2
B = 0.75
PREFIX_WEIGHT = 0.6
RECENCY_BOOST = 0.2
RECENCY_DAYS = 14.0
TITLE_LIMIT = 80
TERMINAL_LINES = 4000
HERDR_TIMEOUT = 10
CHUNK = 4 << 20
LINE_LIMIT = 2 << 20
WORD = re.compile(r"[^\W_]+")
UNICODE_WORD = []
STAMP = re.compile(
    r"(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(\.\d+)?(Z|[+-]\d\d:?\d\d)?"
)
MARKERS = {
    "claude": [b'"type":"user"', b'"type":"assistant"', b'"type":"ai-title"', b'"type":"pr-link"'],
    "codex": [
        b'"session_meta"', b'"user_message"', b'"agent_message"', b'"type":"message"',
        b'"turn_context"',
    ],
    "pi": [b'"type":"session"', b'"type":"session_info"', b'"type":"message"'],
}
STEMS = {}


def stem(word):
    cached = STEMS.get(word)
    if cached is not None:
        return cached
    result = trim_e(word)
    if len(word) > 3 and word.isalpha():
        for suffix in SUFFIXES:
            if not word.endswith(suffix):
                continue
            if suffix == "s" and (word.endswith("ss") or word.endswith("us") or word.endswith("is")):
                continue
            root = word[: -len(suffix)]
            if suffix in ("ies", "ied"):
                root += "y"
            if len(root) < (4 if suffix in ("ed", "ly") else 3):
                continue
            result = trim_e(root)
            break
    else:
        result = word
    STEMS[word] = result
    return result


def trim_e(word):
    if word.endswith("e") and len(word) > 3:
        return word[:-1]
    return word


def word_pattern(text):
    try:
        text.encode("ascii")
        return WORD
    except UnicodeEncodeError:
        pass
    if not UNICODE_WORD:
        marks = []
        start = None
        for code in range(0x300, 0x10000):
            mark = unicodedata.category(chr(code)).startswith("M")
            if mark and start is None:
                start = code
            elif not mark and start is not None:
                marks.append("%s-%s" % (re.escape(chr(start)), re.escape(chr(code - 1))))
                start = None
        UNICODE_WORD.append(re.compile("(?:[^\\W_]|[" + "".join(marks) + "])+"))
    return UNICODE_WORD[0]


def terms(text):
    lowered = text.lower()
    return [
        stem(word)
        for word in word_pattern(lowered).findall(lowered)
        if word not in STOP and (len(word) > 1 or word[0].isnumeric())
    ]


def clean(text, limit=None):
    collapsed = " ".join(text.split())
    return collapsed if limit is None else collapsed[:limit]


def parse_time(value):
    match = STAMP.match(value or "")
    if not match:
        return None
    parts = [int(match.group(index)) for index in range(1, 7)]
    seconds = calendar.timegm((parts[0], parts[1], parts[2], parts[3], parts[4], parts[5], 0, 0, 0))
    if match.group(7):
        seconds += float(match.group(7))
    zone = match.group(8)
    if zone and zone != "Z":
        sign = 1 if zone[0] == "+" else -1
        digits = zone[1:].replace(":", "")
        seconds -= sign * (int(digits[:2]) * 3600 + int(digits[2:]) * 60)
    return float(seconds)


def new_digest(path, kind, session=""):
    return {
        "path": path, "kind": kind, "sessionID": session, "cwd": "", "branch": None,
        "pullRequest": None, "namedTitle": None, "prompts": [], "replies": [],
        "firstActivity": None, "lastActivity": None, "offset": 0, "size": 0, "modified": 0.0,
    }


def title_of(digest):
    if digest.get("namedTitle"):
        return digest["namedTitle"]
    if digest["prompts"]:
        return digest["prompts"][0][:TITLE_LIMIT]
    return "Session " + digest["sessionID"][:8]


def summary_of(digest):
    prompts = digest["prompts"]
    if not prompts:
        return ""
    opening = prompts[0][:160]
    if len(prompts) > 1:
        return opening + " … " + prompts[-1][:160]
    return opening


def add_prompt(digest, raw):
    text = clean(raw)
    prompts = digest["prompts"]
    if text and not (prompts and prompts[-1] == text):
        prompts.append(text)


def add_reply(digest, raw):
    text = clean(raw)
    replies = digest["replies"]
    if text and not (replies and replies[-1] == text):
        replies.append(text)


def touch(digest, stamp):
    if stamp is None:
        return
    first = digest.get("firstActivity")
    last = digest.get("lastActivity")
    digest["firstActivity"] = stamp if first is None else min(first, stamp)
    digest["lastActivity"] = stamp if last is None else max(last, stamp)


def texts(content):
    if isinstance(content, str):
        return [content]
    if not isinstance(content, list):
        return []
    found = []
    for part in content:
        if isinstance(part, dict) and part.get("type") in ("text", "input_text", "output_text"):
            text = part.get("text")
            if isinstance(text, str):
                found.append(text)
    return found


def injected(text):
    trimmed = text.lstrip()
    return trimmed.startswith("<") or trimmed.startswith("# AGENTS.md") or trimmed.startswith("Caveat:")


def read_claude(item, line, digest):
    if item.get("isSidechain") is True:
        return
    kind = item.get("type")
    if kind == "ai-title" and isinstance(item.get("aiTitle"), str):
        digest["namedTitle"] = clean(item["aiTitle"], TITLE_LIMIT)
    elif kind == "pr-link":
        repository = item.get("prRepository")
        number = item.get("prNumber")
        if isinstance(repository, str) and isinstance(number, int):
            digest["pullRequest"] = "%s#%d" % (repository, number)
    elif kind == "user":
        if isinstance(item.get("cwd"), str) and item["cwd"]:
            digest["cwd"] = item["cwd"]
        branch = item.get("gitBranch")
        if isinstance(branch, str) and branch and branch != "HEAD":
            digest["branch"] = branch
        if item.get("isMeta") is True or item.get("isCompactSummary") is True:
            return
        message = item.get("message")
        if isinstance(message, dict):
            for text in texts(message.get("content")):
                if not injected(text):
                    add_prompt(digest, text)
    elif kind == "assistant":
        message = item.get("message")
        if b'"type":"text"' in line and isinstance(message, dict):
            for text in texts(message.get("content")):
                add_reply(digest, text)


def read_codex(item, digest):
    payload = item.get("payload")
    if not isinstance(payload, dict):
        payload = {}
    kind = item.get("type")
    if kind == "session_meta":
        if isinstance(payload.get("id"), str):
            digest["sessionID"] = payload["id"]
        if isinstance(payload.get("cwd"), str) and payload["cwd"]:
            digest["cwd"] = payload["cwd"]
        git = payload.get("git")
        if isinstance(git, dict) and isinstance(git.get("branch"), str) and git["branch"]:
            digest["branch"] = git["branch"]
    elif kind == "turn_context":
        if isinstance(payload.get("cwd"), str) and payload["cwd"]:
            digest["cwd"] = payload["cwd"]
    elif kind == "event_msg":
        message = payload.get("message")
        if payload.get("type") == "user_message" and isinstance(message, str) and not injected(message):
            add_prompt(digest, message)
        elif payload.get("type") == "agent_message" and isinstance(message, str):
            add_reply(digest, message)
    elif kind == "response_item" and payload.get("type") == "message":
        if payload.get("role") == "user":
            for text in texts(payload.get("content")):
                if not injected(text):
                    add_prompt(digest, text)
        elif payload.get("role") == "assistant":
            for text in texts(payload.get("content")):
                add_reply(digest, text)


def read_pi(item, digest):
    kind = item.get("type")
    if kind == "session":
        if isinstance(item.get("id"), str):
            digest["sessionID"] = item["id"]
        if isinstance(item.get("cwd"), str) and item["cwd"]:
            digest["cwd"] = item["cwd"]
    elif kind == "session_info":
        if isinstance(item.get("name"), str) and item["name"]:
            digest["namedTitle"] = clean(item["name"], TITLE_LIMIT)
    elif kind == "message":
        message = item.get("message")
        if not isinstance(message, dict):
            return
        if message.get("role") == "user":
            for text in texts(message.get("content")):
                if not injected(text):
                    add_prompt(digest, text)
        elif message.get("role") == "assistant":
            for text in texts(message.get("content")):
                add_reply(digest, text)


def consume(line, digest):
    kind = digest["kind"]
    if not any(marker in line for marker in MARKERS[kind]):
        return None
    if kind == "claude" and b'"tool_result"' in line:
        return None
    try:
        item = json.loads(line.decode("utf-8"))
    except ValueError:
        return None
    if not isinstance(item, dict):
        return None
    if kind == "claude":
        read_claude(item, line, digest)
    elif kind == "codex":
        read_codex(item, digest)
    else:
        read_pi(item, digest)
    stamp = item.get("timestamp")
    if not isinstance(stamp, str):
        return None
    if digest.get("firstActivity") is None:
        touch(digest, parse_time(stamp))
    return stamp


def update(digest, path, deadline=None):
    finished = True
    with open(path, "rb") as handle:
        handle.seek(digest["offset"])
        consumed = digest["offset"]
        carry = b""
        last = None
        skipping = False
        while True:
            chunk = handle.read(CHUNK)
            if not chunk:
                break
            carry += chunk
            start = 0
            while True:
                end = carry.find(b"\n", start)
                if end < 0:
                    break
                if skipping:
                    skipping = False
                elif end - start <= LINE_LIMIT:
                    stamp = consume(carry[start:end], digest)
                    if stamp:
                        last = stamp
                start = end + 1
            consumed += start
            carry = carry[start:]
            if len(carry) > LINE_LIMIT:
                consumed += len(carry)
                carry = b""
                skipping = True
            if len(chunk) < CHUNK:
                break
            if deadline is not None and time.time() > deadline:
                finished = False
                break
    digest["offset"] = consumed
    if last:
        touch(digest, parse_time(last))
    return finished


def codex_titles(home):
    titles = {}
    try:
        with open(os.path.join(home, ".codex", "session_index.jsonl"), "rb") as handle:
            for line in handle:
                try:
                    item = json.loads(line.decode("utf-8"))
                except ValueError:
                    continue
                if isinstance(item, dict) and isinstance(item.get("id"), str):
                    name = item.get("thread_name")
                    if isinstance(name, str) and name:
                        titles[item["id"]] = clean(name, TITLE_LIMIT)
    except OSError:
        pass
    return titles


def field(text):
    bag = {}
    words = terms(text)
    for word in words:
        bag[word] = bag.get(word, 0) + 1
    return [bag, len(words)]


def matches(word, query):
    if word == query:
        return 1.0
    if len(query) >= 4 and word.startswith(query):
        return PREFIX_WEIGHT
    if len(word) >= 4 and query.startswith(word):
        return PREFIX_WEIGHT
    return 0.0


def rank(query, documents, now):
    unique = []
    for term in query:
        if term not in unique:
            unique.append(term)
    if not unique:
        return []
    frequencies = {}
    totals = [0.0] * len(WEIGHTS)
    for document in documents:
        seen = set()
        for field, bag in enumerate(document["counts"]):
            totals[field] += document["lengths"][field]
            seen.update(bag.keys())
        for word in seen:
            frequencies[word] = frequencies.get(word, 0) + 1
    count = float(max(len(documents), 1))
    averages = [max(total / count, 1.0) for total in totals]
    total = float(len(documents))
    expanded = []
    for term in unique:
        options = []
        for word, frequency in frequencies.items():
            weight = matches(word, term)
            if weight > 0:
                idf = math.log(1 + (total - frequency + 0.5) / (frequency + 0.5))
                options.append((word, weight * idf))
        expanded.append(options)
    scored = []
    for index, document in enumerate(documents):
        score = 0.0
        matched = 0
        for options in expanded:
            best = 0.0
            for word, weight in options:
                value = weight * saturation(word, document, averages)
                if value > best:
                    best = value
            if best > 0:
                matched += 1
                score += best
        if matched == 0:
            continue
        score *= (float(matched) / len(unique)) ** 1.5
        last = document.get("lastActivity")
        if last is not None:
            age = max(0.0, now - last) / 86400.0
            score *= 1 + RECENCY_BOOST * math.exp(-age / RECENCY_DAYS)
        scored.append((index, score))
    scored.sort(key=lambda pair: (-pair[1], pair[0]))
    return scored


def saturation(word, document, averages):
    weighted = 0.0
    for field, bag in enumerate(document["counts"]):
        count = bag.get(word)
        if not count:
            continue
        norm = 1 - B + B * document["lengths"][field] / averages[field]
        weighted += WEIGHTS[field] * count / norm
    return weighted * (K1 + 1) / (weighted + K1)


def snippet(candidates_texts, query, limit=160):
    best = None
    best_count = 0
    for text in candidates_texts:
        stems = set(terms(text))
        count = len([term for term in query if any(matches(word, term) > 0 for word in stems)])
        if count > best_count:
            best = text
            best_count = count
    if best is None:
        return (candidates_texts[0] if candidates_texts else "")[:limit]
    return window(best, query, limit)


def window(text, query, limit):
    if len(text) <= limit:
        return text
    position = 0
    for match in word_pattern(text).finditer(text):
        word = stem(match.group(0).lower())
        if any(matches(word, term) > 0 for term in query):
            position = match.start()
            break
    lead = max(0, min(position - 50, len(text) - limit))
    piece = text[lead:lead + limit]
    prefix = "…" if lead > 0 else ""
    suffix = "…" if lead + len(piece) < len(text) else ""
    return prefix + piece.strip() + suffix


def load(store):
    try:
        with open(store, "r") as handle:
            saved = json.load(handle)
        if saved.get("version") == 3:
            return {digest["path"]: digest for digest in saved.get("digests", [])}
    except (OSError, ValueError, AttributeError, KeyError, TypeError):
        pass
    return {}


def save(store, digests):
    directory = os.path.dirname(store)
    try:
        os.makedirs(directory, exist_ok=True)
        temporary = "%s.%d.tmp" % (store, os.getpid())
        with open(temporary, "w") as handle:
            json.dump({"version": 3, "digests": sorted(digests.values(), key=lambda item: item["path"])}, handle)
        os.replace(temporary, store)
    except OSError:
        pass


KINDS = {
    "claude code": "claude", "claude": "claude", "claude-code": "claude",
    "codex": "codex", "openai-codex": "codex", "pi": "pi", "py": "pi", "pi-coding-agent": "pi",
    "opencode": "opencode", "open-code": "opencode", "opencode2": "opencode",
}


def transcript_kind(kind):
    return KINDS.get(kind.strip().lower())


def herdr_binary(home):
    configured = os.environ.get("EDITH_AGENT_SEARCH_HERDR")
    if configured:
        return configured
    found = shutil.which("herdr")
    if found:
        return found
    for candidate in (".local/bin/herdr", ".cargo/bin/herdr"):
        path = os.path.join(home, candidate)
        if os.access(path, os.X_OK):
            return path
    for path in ("/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"):
        if os.access(path, os.X_OK):
            return path
    return None


def run_herdr(binary, arguments):
    if not binary:
        return None
    try:
        result = subprocess.run(
            [binary] + arguments, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=HERDR_TIMEOUT,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.decode("utf-8", "replace")


def first_json(text):
    stripped = text.strip()
    try:
        return json.loads(stripped)
    except ValueError:
        pass
    starts = [index for index in (stripped.find("{"), stripped.find("[")) if index >= 0]
    if not starts:
        return None
    try:
        return json.loads(stripped[min(starts):])
    except ValueError:
        return None


def agent_sessions(snapshot):
    item = first_json(snapshot or "")
    try:
        agents = item["result"]["snapshot"]["agents"]
    except (TypeError, KeyError):
        return {}
    sessions = {}
    for agent in agents:
        if not isinstance(agent, dict):
            continue
        pane = agent.get("pane_id")
        session = agent.get("agent_session")
        value = session.get("value") if isinstance(session, dict) else None
        if isinstance(pane, str) and isinstance(value, str) and value:
            sessions[pane] = value
    return sessions


def alive(pid):
    try:
        os.kill(pid, 0)
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def live_claude(home):
    folder = os.path.join(home, ".claude", "sessions")
    found = []
    for entry in scan(folder):
        if not entry.name.endswith(".json"):
            continue
        try:
            with open(entry.path, "r") as handle:
                item = json.load(handle)
        except (OSError, ValueError):
            continue
        if not isinstance(item, dict):
            continue
        pid = item.get("pid")
        session = item.get("sessionId")
        if isinstance(pid, int) and isinstance(session, str) and alive(pid):
            started = item.get("startedAt") or 0
            found.append({"id": session, "cwd": item.get("cwd") or "", "modified": float(started) / 1000})
    return found


def scan(path):
    try:
        return list(os.scandir(path))
    except OSError:
        return []


def claude_file(home, session):
    for project in scan(os.path.join(home, ".claude", "projects")):
        if project.is_dir() and not project.name.startswith("."):
            path = os.path.join(project.path, session + ".jsonl")
            if os.path.isfile(path):
                return path
    return None


def roots(home, kind):
    if kind == "codex":
        return [os.path.join(home, ".codex", "sessions"), os.path.join(home, ".codex", "archived_sessions")]
    if kind == "pi":
        return [os.path.join(home, ".pi", "agent", "sessions")]
    return []


def head(path, kind):
    digest = new_digest(path, kind)
    try:
        with open(path, "rb") as handle:
            data = handle.read(256 << 10)
    except OSError:
        return digest
    for line in data.split(b"\n")[:20]:
        consume(line, digest)
        if digest["sessionID"] and digest["cwd"]:
            break
    return digest


def metas(home, kind):
    found = []
    for root in roots(home, kind):
        for directory, folders, files in os.walk(root):
            folders[:] = [name for name in folders if not name.startswith(".")]
            for name in files:
                if not name.endswith(".jsonl") or name.startswith("."):
                    continue
                path = os.path.join(directory, name)
                try:
                    modified = os.stat(path).st_mtime
                except OSError:
                    continue
                digest = head(path, kind)
                found.append({"path": path, "id": digest["sessionID"], "cwd": digest["cwd"], "modified": modified})
    found.sort(key=lambda item: -item["modified"])
    return found


def opencode_database(home):
    data = os.environ.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share")
    return os.path.join(data, "opencode", "opencode.db")


def opencode_rows(database, sql, arguments):
    if not os.path.isfile(database):
        return []
    try:
        connection = sqlite3.connect("file:%s?mode=ro" % database, uri=True, timeout=0.5)
        try:
            return connection.execute(sql, arguments).fetchall()
        finally:
            connection.close()
    except sqlite3.Error:
        return []


def opencode_sessions(database):
    rows = opencode_rows(database, "select id, directory, coalesce(title, ''), time_updated from session_v2", ())
    return [{"id": row[0], "cwd": row[1] or "", "title": row[2] or "", "modified": float(row[3] or 0) / 1000} for row in rows]


def opencode_digest(database, session):
    digest = new_digest(database + "#" + session["id"], "opencode", session["id"])
    digest["cwd"] = session["cwd"]
    if session["title"]:
        digest["namedTitle"] = clean(session["title"], TITLE_LIMIT)
    rows = opencode_rows(
        database, "select type, data, time_created from session_message where session_id = ? order by seq",
        (session["id"],),
    )
    for kind, data, created in rows:
        try:
            item = json.loads(data)
        except (TypeError, ValueError):
            continue
        if not isinstance(item, dict):
            continue
        if kind == "user":
            if isinstance(item.get("text"), str):
                add_prompt(digest, item["text"])
        elif kind == "assistant":
            for text in texts(item.get("content")):
                add_reply(digest, text)
        else:
            continue
        touch(digest, float(created or 0) / 1000)
    return digest


def standardized(path):
    trimmed = (path or "").strip()
    while len(trimmed) > 1 and trimmed.endswith("/"):
        trimmed = trimmed[:-1]
    return trimmed


def normalized_title(title):
    index = 0
    while index < len(title) and not title[index].isalnum():
        index += 1
    return clean(title[index:]).lower()


class Engine(object):
    def __init__(self, home, store, herdr):
        self.home = home
        self.store = store
        self.herdr = herdr
        self.digests = load(store)
        self.dirty = False
        self.titles = None
        self.metas = {}
        self.opencode = None

    def codex_titles(self):
        if self.titles is None:
            self.titles = codex_titles(self.home)
        return self.titles

    def meta_list(self, kind):
        if kind not in self.metas:
            self.metas[kind] = metas(self.home, kind)
        return self.metas[kind]

    def opencode_list(self):
        if self.opencode is None:
            self.opencode = opencode_sessions(opencode_database(self.home))
        return self.opencode

    def link(self, kind, value):
        if value.startswith("/") and os.path.isfile(value):
            return ("file", value, kind)
        if kind == "claude":
            path = claude_file(self.home, value)
            return ("file", path, kind) if path else None
        if kind in ("codex", "pi"):
            for meta in self.meta_list(kind):
                if meta["id"] == value or value in meta["path"]:
                    return ("file", meta["path"], kind)
            return None
        for session in self.opencode_list():
            if session["id"] == value:
                return ("opencode", session)
        return None

    def known_title(self, kind, session, deadline):
        if kind == "claude":
            path = claude_file(self.home, session)
            if not path:
                return None
            digest, _ = self.read(path, kind, deadline)
            return title_of(digest) if digest else None
        if kind == "codex":
            return self.codex_titles().get(session)
        if kind == "pi":
            for meta in self.meta_list("pi"):
                if meta["id"] == session:
                    digest, _ = self.read(meta["path"], "pi", deadline)
                    return title_of(digest) if digest else None
            return None
        for item in self.opencode_list():
            if item["id"] == session:
                return item["title"]
        return None

    def title_matches(self, kind, session, pane_title, deadline):
        wanted = normalized_title(pane_title)
        if not wanted:
            return False
        known = self.known_title(kind, session, deadline)
        if not known:
            return False
        have = normalized_title(known)
        return bool(have) and (have.startswith(wanted) or wanted.startswith(have))

    def resolve(self, targets, herdr_links, deadline):
        links = {}
        claimed = set()
        unlinked = []
        for target in targets:
            kind = transcript_kind(target["kind"])
            if kind is None:
                links[target["id"]] = ("terminal",)
                continue
            value = herdr_links.get(target["session"] + "|" + target["pane"])
            link = self.link(kind, value) if value else None
            if link is None:
                unlinked.append(target)
                continue
            links[target["id"]] = link
            claimed.add(value)
        live = None
        for target in unlinked:
            kind = transcript_kind(target["kind"])
            place = standardized(target["cwd"])
            if kind == "claude":
                if live is None:
                    live = live_claude(self.home)
                candidates = [item for item in live if standardized(item["cwd"]) == place]
            elif kind in ("codex", "pi"):
                candidates = [item for item in self.meta_list(kind) if standardized(item["cwd"]) == place]
            else:
                candidates = [item for item in self.opencode_list() if standardized(item["cwd"]) == place]
            available = sorted([item for item in candidates if item["id"] not in claimed], key=lambda item: -item["modified"])
            chosen = None
            for item in available:
                if self.title_matches(kind, item["id"], target["title"], deadline):
                    chosen = item
                    break
            if chosen is None and available:
                chosen = available[0]
            link = self.link(kind, chosen["id"]) if chosen else None
            if link is None:
                links[target["id"]] = ("terminal",)
                continue
            claimed.add(chosen["id"])
            links[target["id"]] = link
        return links

    def read(self, path, kind, deadline):
        try:
            info = os.stat(path)
        except OSError:
            return self.digests.get(path), True
        size = info.st_size
        modified = info.st_mtime
        digest = self.digests.get(path) or new_digest(path, kind)
        if digest["size"] == size and digest["modified"] == modified:
            return digest, True
        if size < digest["offset"]:
            digest = new_digest(path, kind)
        try:
            finished = update(digest, path, deadline)
        except (OSError, ValueError):
            return self.digests.get(path), True
        if finished:
            digest["size"] = size
            digest["modified"] = modified
        if not digest["sessionID"]:
            digest["sessionID"] = os.path.splitext(os.path.basename(path))[0]
        if kind == "codex" and not digest.get("namedTitle"):
            title = self.codex_titles().get(digest["sessionID"])
            if title:
                digest["namedTitle"] = title
        self.digests[path] = digest
        self.dirty = True
        return digest, finished

    def body(self, digest):
        count = len(digest["prompts"]) + len(digest["replies"])
        cached = digest.get("body")
        if not cached or cached.get("offset") != digest["offset"] or cached.get("count") != count:
            cached = {
                "offset": digest["offset"], "count": count,
                "prompts": field(" ".join(digest["prompts"])),
                "replies": field(" ".join(digest["replies"])),
            }
            digest["body"] = cached
            if not digest["path"].endswith("#" + digest["sessionID"]):
                self.dirty = True
        return cached["prompts"], cached["replies"]

    def document(self, target, history):
        folder = " ".join([part for part in target["cwd"].split("/") if part][-3:])
        place = " ".join([folder, target["kind"]])
        kind, value = history
        if kind == "transcript":
            prompts, replies = self.body(value)
            fields = [
                field(target["title"] + " " + title_of(value)),
                field(" ".join([place, value.get("branch") or "", value.get("pullRequest") or ""])),
                prompts, replies,
            ]
            last = value.get("lastActivity")
        elif kind == "terminal":
            fields = [field(target["title"]), field(place), field(value), field("")]
            last = None
        else:
            fields = [field(target["title"]), field(place), field(""), field("")]
            last = None
        return {"counts": [item[0] for item in fields], "lengths": [item[1] for item in fields], "lastActivity": last}

    def search(self, request, now=None):
        started = time.time()
        now = started if now is None else now
        targets = request.get("targets") or []
        herdr_links = {}
        for session in sorted(set(target["session"] for target in targets)):
            snapshot = run_herdr(self.herdr, ["--session", session, "api", "snapshot"])
            for pane, value in agent_sessions(snapshot).items():
                herdr_links[session + "|" + pane] = value
        deadline = started + float(request.get("budget", 1.5))
        links = self.resolve(targets, herdr_links, deadline)
        pending = 0
        histories = {}
        for target in targets:
            link = links.get(target["id"], ("terminal",))
            if link[0] == "file":
                digest, finished = self.read(link[1], link[2], deadline)
                if not finished:
                    pending += 1
                histories[target["id"]] = ("transcript", digest) if digest else ("missing", None)
            elif link[0] == "opencode":
                histories[target["id"]] = ("transcript", opencode_digest(opencode_database(self.home), link[1]))
            else:
                text = run_herdr(self.herdr, [
                    "--session", target["session"], "pane", "read", target["pane"], "--source", "recent",
                    "--lines", str(TERMINAL_LINES),
                ])
                histories[target["id"]] = ("terminal", text) if text is not None else ("missing", None)
        query = terms(request.get("query", ""))
        documents = [self.document(target, histories[target["id"]]) for target in targets]
        if query:
            order = rank(query, documents, now)
        else:
            order = [(index, 0.0) for index in range(len(targets))]
        hits = [hit_for(targets[index], histories[targets[index]["id"]], score, query) for index, score in order]
        used = set(link[1] for link in links.values() if link[0] == "file")
        for path in list(self.digests.keys()):
            if path not in used:
                del self.digests[path]
                self.dirty = True
        if self.dirty:
            save(self.store, self.digests)
        return {
            "machineID": request.get("machineID", ""), "hits": hits, "pending": pending, "error": None,
            "milliseconds": int((time.time() - started) * 1000),
        }


def hit_for(target, history, score, query):
    kind, value = history
    if kind == "transcript":
        if query:
            text = snippet(list(reversed(value["prompts"])) + list(reversed(value["replies"])) + [title_of(value)], query)
        else:
            text = (value["prompts"][-1] if value["prompts"] else "")[:160]
        return {
            "id": target["id"], "source": "transcript", "sessionID": value["sessionID"],
            "title": title_of(value), "snippet": text, "summary": summary_of(value),
            "lastActivity": value.get("lastActivity"), "score": score,
        }
    if kind == "terminal":
        lines = [clean(line) for line in value.splitlines()]
        lines = [line for line in lines if line]
        if query:
            text = snippet(list(reversed(lines)), query)
        else:
            text = (lines[-1] if lines else "")[:160]
        return {
            "id": target["id"], "source": "terminal", "sessionID": None, "title": target["title"],
            "snippet": text, "summary": " ".join(lines[-3:])[:320], "lastActivity": None, "score": score,
        }
    return {
        "id": target["id"], "source": "none", "sessionID": None, "title": target["title"], "snippet": "",
        "summary": "", "lastActivity": None, "score": score,
    }


def main():
    request = json.loads(base64.b64decode(sys.argv[1]).decode("utf-8"))
    home = os.environ.get("EDITH_AGENT_SEARCH_HOME") or os.path.expanduser("~")
    cache = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    store = os.environ.get("EDITH_AGENT_SEARCH_STORE") or os.path.join(cache, "edith", "agent-search", "sessions-v3.json")
    now = os.environ.get("EDITH_AGENT_SEARCH_NOW")
    engine = Engine(home, store, herdr_binary(home))
    sys.stdout.write(json.dumps(engine.search(request, float(now) if now else None)))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
