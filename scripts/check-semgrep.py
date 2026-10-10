import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile


MUSIC_PATH = "Extensions/music/Native/src/lib.rs"
MUSIC_UNSAFE_RULE = "rust.lang.security.unsafe-usage.unsafe-usage"
MUSIC_REVIEWED_SHA256 = "444d86e0b09c661230b5478375c898e2ae3b46f70494bf074041abdb94129f8a"
MAXIMUM_REPORT_BYTES = 64 * 1024 * 1024


def blocking_findings(report, exit_code, source_sha256):
    if exit_code not in (0, 1):
        raise ValueError(f"Semgrep exited with {exit_code}")
    if not isinstance(report, dict):
        raise ValueError("Semgrep report must be an object")
    if not isinstance(report.get("results"), list) or not isinstance(report.get("errors"), list):
        raise ValueError("Semgrep report is missing results or errors")
    for error in report["errors"]:
        if not isinstance(error, dict) or error.get("level") != "warn" or error.get("code") != 3:
            raise ValueError("Semgrep reported scan errors")
        if error.get("path", "").removeprefix("./") == MUSIC_PATH:
            raise ValueError("Semgrep could not fully parse the reviewed Music source")
    remaining = []
    reviewed = 0
    for finding in report["results"]:
        if not isinstance(finding, dict) or not isinstance(finding.get("check_id"), str) or not isinstance(finding.get("path"), str):
            raise ValueError("Semgrep finding is malformed")
        path = finding["path"].removeprefix("./")
        if (
            finding["check_id"] == MUSIC_UNSAFE_RULE
            and path == MUSIC_PATH
            and source_sha256 == MUSIC_REVIEWED_SHA256
        ):
            reviewed += 1
        else:
            remaining.append(finding)
    return remaining, reviewed


def read_report(path):
    if path.stat().st_size > MAXIMUM_REPORT_BYTES:
        raise ValueError("Semgrep report exceeds the bounded report size")
    return json.loads(path.read_bytes())


def main(arguments):
    if arguments[:1] == ["--"]:
        arguments = arguments[1:]
    if not arguments:
        raise ValueError("Pass the Semgrep executable after --")
    root = pathlib.Path(__file__).resolve().parent.parent
    source_sha256 = hashlib.sha256((root / MUSIC_PATH).read_bytes()).hexdigest()
    with tempfile.TemporaryDirectory(prefix="edith-semgrep-") as temporary:
        report_path = pathlib.Path(temporary) / "report.json"
        with report_path.open("wb") as output:
            result = subprocess.run(
                arguments + [
                    "scan", "--error", "--json", "--config", "p/rust", "--config", "p/swift",
                    "--config", "p/secrets", "--config", "p/github-actions", ".",
                ],
                cwd=root,
                stdout=output,
                timeout=600,
                check=False,
            )
        report = read_report(report_path)
        remaining, reviewed = blocking_findings(report, result.returncode, source_sha256)
    for finding in remaining:
        print(f"{finding['path']}: {finding['check_id']}", file=sys.stderr)
    print(f"Semgrep: {reviewed} reviewed Music FFI findings, {len(remaining)} blocking findings, {len(report['errors'])} parser warnings")
    return 1 if remaining else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"Semgrep check failed: {error}", file=sys.stderr)
        sys.exit(1)
