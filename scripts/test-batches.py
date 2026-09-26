#!/usr/bin/env python3
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
CATALOG = ROOT / "scripts" / "test-batches.json"
SWIFT_ROOTS = (
    ("Packages/Edith/Tests", "swift"),
    ("Packages/EdithStudio/Tests", "studio"),
)
TOKEN_RE = re.compile(
    r'"(?:\\.|[^"\\])*"|'
    r"'(?:\\.|[^'\\])*'|"
    r"//[^\n]*|"
    r"@Suite\b|"
    r"@Test\b|"
    r"\b(?:struct|enum|class|actor|extension)\s+[A-Za-z_][A-Za-z0-9_]*|"
    r"func\s+[A-Za-z_][A-Za-z0-9_]*|"
    r"[{}]"
)
TYPE_NAME_RE = re.compile(r"\b(?:struct|enum|class|actor|extension)\s+([A-Za-z_][A-Za-z0-9_]*)")
FUNC_NAME_RE = re.compile(r"func\s+([A-Za-z_][A-Za-z0-9_]*)")


def load():
    return json.loads(CATALOG.read_text())


def suite_ids(text, target):
    ids = []
    stack = []
    pending_suite = False
    pending_test = False
    pending_type = None
    for token in TOKEN_RE.finditer(text):
        value = token.group(0)
        if value.startswith(("'", '"', "//")):
            continue
        if value.startswith("@Suite"):
            pending_suite = True
            continue
        if value.startswith("@Test"):
            pending_test = True
            continue
        if value.startswith("func ") and pending_test and not stack:
            name = FUNC_NAME_RE.match(value).group(1)
            ids.append(f"{target}/{name}")
            pending_test = False
            continue
        type_name = TYPE_NAME_RE.match(value)
        if type_name:
            pending_type = type_name.group(1)
            continue
        if value == "{":
            stack.append(
                {
                    "name": pending_type,
                    "suite": pending_suite or (pending_type is not None and "Test" in pending_type),
                    "tested": pending_test,
                }
            )
            pending_type = None
            pending_suite = False
            pending_test = False
            continue
        if value == "}":
            if not stack:
                continue
            item = stack.pop()
            if item["name"] and (item["suite"] or item["tested"]):
                ids.append(f"{target}.{item['name']}")
            continue
        if pending_test and stack:
            stack[-1]["tested"] = True
            pending_test = False
    return ids


def discover(group):
    ids = []
    for relative, owner in SWIFT_ROOTS:
        if owner != group:
            continue
        root = ROOT / relative
        for path in sorted(root.rglob("*.swift")):
            target = path.relative_to(root).parts[0]
            ids.extend(suite_ids(path.read_text(), target))
    return ids


def script_files():
    return sorted(
        path.relative_to(ROOT).as_posix()
        for path in (ROOT / "scripts").glob("*.test.js")
    )


def include_batches(batches):
    return [batch for batch in batches if not batch.get("complement")]


def complement(batches):
    found = [batch for batch in batches if batch.get("complement")]
    if len(found) != 1:
        raise SystemExit(f"each group needs one complement batch, found {len(found)}")
    return found[0]


def swift_pattern(batch, batches):
    if batch.get("complement"):
        parts = [item["filter"] for item in include_batches(batches)]
        return "--skip", "(?:" + ")|(?:".join(parts) + ")"
    return "--filter", batch["filter"]


def assign_swift(identifier, batches):
    matched = [
        batch["name"]
        for batch in include_batches(batches)
        if re.match(batch["filter"], identifier)
    ]
    if len(matched) > 1:
        return matched
    if len(matched) == 1:
        return matched
    return [complement(batches)["name"]]


def assign_script(path, batches):
    matched = []
    for batch in include_batches(batches):
        if any(path.startswith(prefix) for prefix in batch["prefixes"]):
            matched.append(batch["name"])
    if len(matched) > 1:
        return matched
    if len(matched) == 1:
        return matched
    return [complement(batches)["name"]]


def script_paths(name, batches):
    owned = []
    for path in script_files():
        owners = assign_script(path, batches)
        if owners == [name]:
            owned.append(path)
    return owned


def check():
    catalog = load()
    failures = []
    for group in ("swift", "studio"):
        batches = catalog[group]
        complement(batches)
        counts = {batch["name"]: 0 for batch in batches}
        for identifier in discover(group):
            owners = assign_swift(identifier, batches)
            if len(owners) != 1:
                failures.append(f"{group} {identifier} -> {owners}")
                continue
            counts[owners[0]] += 1
        for name, count in counts.items():
            if count == 0:
                failures.append(f"{group} batch {name} matches nothing")
    script_batches = catalog["scripts"]
    complement(script_batches)
    script_counts = {batch["name"]: 0 for batch in script_batches}
    for path in script_files():
        owners = assign_script(path, script_batches)
        if len(owners) != 1:
            failures.append(f"scripts {path} -> {owners}")
            continue
        script_counts[owners[0]] += 1
    for name, count in script_counts.items():
        if count == 0:
            failures.append(f"scripts batch {name} matches nothing")
    workflow = (ROOT / ".github/workflows-disabled/ci.yml").read_text()
    listed = re.findall(r"batch: ([a-z0-9-]+)", workflow)
    expected = [batch["name"] for batch in catalog["swift"]]
    if listed != expected:
        failures.append(f"ci swift batches {listed} != {expected}")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(
        "swift "
        + " ".join(f"{batch['name']}={sum(1 for identifier in discover('swift') if assign_swift(identifier, catalog['swift']) == [batch['name']])}" for batch in catalog["swift"])
    )
    return 0


def batch_named(group, name):
    catalog = load()
    for batch in catalog[group]:
        if batch["name"] == name:
            return catalog[group], batch
    raise SystemExit(f"unknown {group} batch {name}")


def main(argv):
    if len(argv) < 2:
        raise SystemExit("usage: test-batches.py check|list|swift-args|studio-args|script-paths")
    command = argv[1]
    catalog = load()
    if command == "check":
        return check()
    if command == "list":
        group = argv[2] if len(argv) > 2 else None
        groups = [group] if group else ("swift", "studio", "scripts")
        for item in groups:
            print(item)
            for batch in catalog[item]:
                print(f"  {batch['name']}")
        return 0
    if command in ("swift-args", "studio-args"):
        group = "swift" if command == "swift-args" else "studio"
        batches, batch = batch_named(group, argv[2])
        flag, pattern = swift_pattern(batch, batches)
        print(flag)
        print(pattern)
        return 0
    if command == "script-paths":
        batches, _batch = batch_named("scripts", argv[2])
        paths = script_paths(argv[2], batches)
        if not paths:
            raise SystemExit(f"scripts batch {argv[2]} matches nothing")
        print("\n".join(paths))
        return 0
    raise SystemExit(f"unknown command {command}")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
