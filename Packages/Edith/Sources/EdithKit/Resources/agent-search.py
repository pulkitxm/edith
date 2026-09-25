import base64
import calendar
import json
import math
import os
import re
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
PROMPT_LIMIT = 500
PROMPTS_LIMIT = 6000
REPLY_LIMIT = 300
REPLIES_LIMIT = 3000
TITLE_LIMIT = 80
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


def clean(text, limit):
    return " ".join(text.split())[:limit]


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


def new_digest(path, kind):
    return {
        "path": path, "kind": kind, "sessionID": "", "cwd": "", "branch": None,
        "pullRequest": None, "namedTitle": None, "prompts": [], "replies": [],
        "firstActivity": None, "lastActivity": None, "offset": 0, "size": 0, "modified": 0.0,
    }


def title_of(digest, titles):
    if digest["kind"] == "codex" and not digest.get("namedTitle") and digest["sessionID"] in titles:
        return titles[digest["sessionID"]]
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
    text = clean(raw, PROMPT_LIMIT)
    prompts = digest["prompts"]
    if not text or (prompts and prompts[-1] == text):
        return
    prompts.append(text)
    total = sum(len(item) for item in prompts)
    while total > PROMPTS_LIMIT and len(prompts) > 2:
        total -= len(prompts.pop(1))


def add_reply(digest, raw):
    text = clean(raw, REPLY_LIMIT)
    replies = digest["replies"]
    if not text or (replies and replies[-1] == text):
        return
    replies.append(text)
    total = sum(len(item) for item in replies)
    while total > REPLIES_LIMIT and len(replies) > 1:
        total -= len(replies.pop(0))


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


def candidates(home):
    found = []
    claude = os.path.join(home, ".claude", "projects")
    for project in scan(claude):
        if project.is_dir() and not project.name.startswith("."):
            for entry in scan(project.path):
                add_candidate(found, entry, "claude")
    for kind, roots in (
        ("codex", [os.path.join(home, ".codex", "sessions"), os.path.join(home, ".codex", "archived_sessions")]),
        ("pi", [os.path.join(home, ".pi", "agent", "sessions")]),
    ):
        for root in roots:
            for directory, folders, files in os.walk(root):
                folders[:] = [name for name in folders if not name.startswith(".")]
                for name in files:
                    if name.endswith(".jsonl") and not name.startswith("."):
                        path = os.path.join(directory, name)
                        try:
                            info = os.stat(path)
                        except OSError:
                            continue
                        found.append((path, kind, info.st_size, info.st_mtime))
    return found


def scan(path):
    try:
        return list(os.scandir(path))
    except OSError:
        return []


def add_candidate(found, entry, kind):
    if entry.name.startswith(".") or not entry.name.endswith(".jsonl"):
        return
    try:
        if not entry.is_file():
            return
        info = entry.stat()
    except OSError:
        return
    found.append((entry.path, kind, info.st_size, info.st_mtime))


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


def fields_of(digest, title):
    components = " ".join([part for part in digest["cwd"].split("/") if part][-3:])
    place = " ".join([components, digest.get("branch") or "", digest.get("pullRequest") or "", digest["kind"]])
    return [title, place, " ".join(digest["prompts"]), " ".join(digest["replies"])]


def counts_of(digest, title):
    counts = []
    lengths = []
    for text in fields_of(digest, title):
        bag = {}
        words = terms(text)
        for word in words:
            bag[word] = bag.get(word, 0) + 1
        counts.append(bag)
        lengths.append(len(words))
    return {"title": title, "offset": digest["offset"], "counts": counts, "lengths": lengths}


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
        if saved.get("version") == 2:
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
            json.dump({"version": 2, "digests": sorted(digests.values(), key=lambda item: item["path"])}, handle)
        os.replace(temporary, store)
    except OSError:
        pass


def search(request, home, store, now=None):
    started = time.time()
    now = started if now is None else now
    digests = load(store)
    found = candidates(home)
    present = set(item[0] for item in found)
    dirty = False
    for path in list(digests.keys()):
        if path not in present:
            del digests[path]
            dirty = True
    stale = [
        item for item in found
        if item[0] not in digests
        or digests[item[0]]["size"] != item[2]
        or digests[item[0]]["modified"] != item[3]
    ]
    stale.sort(key=lambda item: -item[3])
    deadline = started + float(request.get("budget", 1.5))
    pending = 0
    for position, (path, kind, size, modified) in enumerate(stale):
        if position > 0 and time.time() > deadline:
            pending = len(stale) - position
            break
        digest = digests.get(path) or new_digest(path, kind)
        if size < digest["offset"]:
            digest = new_digest(path, kind)
        try:
            finished = update(digest, path, deadline)
        except (OSError, ValueError):
            continue
        if finished:
            digest["size"] = size
            digest["modified"] = modified
        if not digest["sessionID"]:
            digest["sessionID"] = os.path.splitext(os.path.basename(path))[0]
        digests[path] = digest
        dirty = True
        if not finished:
            pending = len(stale) - position
            break
    titles = codex_titles(home)
    newest = {}
    for digest in sorted(digests.values(), key=lambda item: item["path"]):
        if not (digest["prompts"] or digest.get("namedTitle")):
            continue
        key = digest["kind"] + "|" + digest["sessionID"]
        kept = newest.get(key)
        if kept is not None and (kept.get("lastActivity") or 0) >= (digest.get("lastActivity") or 0):
            continue
        newest[key] = digest
    entries = sorted(newest.values(), key=lambda item: item["path"])
    documents = []
    for digest in entries:
        title = title_of(digest, titles)
        cached = digest.get("index")
        if not cached or cached.get("title") != title or cached.get("offset") != digest["offset"]:
            cached = counts_of(digest, title)
            digest["index"] = cached
            dirty = True
        documents.append({
            "counts": cached["counts"], "lengths": cached["lengths"],
            "lastActivity": digest.get("lastActivity"),
        })
    query = terms(request.get("query", ""))
    limit = max(1, int(request.get("limit", 12)))
    if query:
        picks = [(entries[index], score) for index, score in rank(query, documents, now)[:limit]]
    else:
        recent = sorted(entries, key=lambda item: -(item.get("lastActivity") or 0))[:limit]
        picks = [(digest, 0.0) for digest in recent]
    machine = request.get("machineID", "")
    hits = []
    for digest, score in picks:
        title = title_of(digest, titles)
        if query:
            text = snippet(list(reversed(digest["prompts"])) + list(reversed(digest["replies"])) + [title], query)
        else:
            text = (digest["prompts"][-1] if digest["prompts"] else "")[:160]
        place_rank = len([
            other for other in entries
            if other["kind"] == digest["kind"] and other["cwd"] == digest["cwd"]
            and (other.get("lastActivity") or 0) > (digest.get("lastActivity") or 0)
        ])
        hits.append({
            "id": "%s|%s|%s" % (machine, digest["kind"], digest["sessionID"]),
            "machineID": machine, "kind": digest["kind"], "sessionID": digest["sessionID"],
            "path": digest["path"], "cwd": digest["cwd"], "branch": digest.get("branch"),
            "pullRequest": digest.get("pullRequest"), "title": title, "snippet": text,
            "summary": summary_of(digest), "lastActivity": digest.get("lastActivity"),
            "score": score, "placeRank": place_rank,
        })
    if dirty:
        save(store, digests)
    return {
        "machineID": machine, "hits": hits, "indexed": len(entries), "pending": pending,
        "error": None, "milliseconds": int((time.time() - started) * 1000),
    }


def main():
    request = json.loads(base64.b64decode(sys.argv[1]).decode("utf-8"))
    home = os.environ.get("EDITH_AGENT_SEARCH_HOME") or os.path.expanduser("~")
    cache = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    store = os.environ.get("EDITH_AGENT_SEARCH_STORE") or os.path.join(cache, "edith", "agent-search", "transcripts-v2.json")
    now = os.environ.get("EDITH_AGENT_SEARCH_NOW")
    sys.stdout.write(json.dumps(search(request, home, store, float(now) if now else None)))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
