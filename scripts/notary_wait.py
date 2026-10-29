#!/usr/bin/env python3
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

API = os.environ.get("NOTARY_API_URL", "https://appstoreconnect.apple.com/notary/v2")
TOKEN_LIFETIME = 600


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def der_to_raw(der):
    def integer(offset):
        length = der[offset + 1]
        value = der[offset + 2 : offset + 2 + length].lstrip(b"\x00")
        return value.rjust(32, b"\x00"), offset + 2 + length

    r, offset = integer(2)
    s, _ = integer(offset)
    return r + s


def make_token(key_pem, key_id, issuer, now=None):
    issued = int(now if now is not None else time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    claims = {"iss": issuer, "iat": issued, "exp": issued + TOKEN_LIFETIME, "aud": "appstoreconnect-v1"}
    signing_input = b".".join(
        b64(json.dumps(part, separators=(",", ":")).encode()) for part in (header, claims)
    )
    with tempfile.NamedTemporaryFile("w", suffix=".p8") as key_file:
        os.chmod(key_file.name, 0o600)
        key_file.write(key_pem)
        key_file.flush()
        der = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", key_file.name],
            input=signing_input,
            capture_output=True,
            check=True,
        ).stdout
    return (signing_input + b"." + b64(der_to_raw(der))).decode()


class Transient(Exception):
    pass


def fetch(url, token=None):
    request = urllib.request.Request(url)
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code >= 500 or error.code in (408, 429):
            raise Transient(f"HTTP {error.code}") from error
        raise
    except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as error:
        raise Transient(str(error)) from error


def developer_log(identifier, token):
    try:
        listing = json.loads(fetch(f"{API}/submissions/{identifier}/logs", token))
        location = listing["data"]["attributes"]["developerLogUrl"]
        return fetch(location).decode()
    except Exception as error:
        return f"developer log unavailable: {error}"


def wait(submissions, key_pem, key_id, issuer, poll, deadline, sleep=time.sleep, clock=time.monotonic):
    pending = dict(submissions)
    started = clock()
    failures = 0
    token = None
    token_at = 0
    while pending:
        if clock() - started > deadline:
            for artifact, identifier in pending.items():
                print(f"notarization {identifier} for {artifact} did not finish before the deadline", file=sys.stderr)
            return 1
        if token is None or clock() - token_at > TOKEN_LIFETIME / 2:
            token = make_token(key_pem, key_id, issuer)
            token_at = clock()
        try:
            for artifact, identifier in list(pending.items()):
                body = json.loads(fetch(f"{API}/submissions/{identifier}", token))
                status = body["data"]["attributes"]["status"]
                if status == "Accepted":
                    print(f"notarization {identifier} for {artifact}: Accepted")
                    del pending[artifact]
                elif status in ("Invalid", "Rejected"):
                    print(f"notarization {identifier} for {artifact}: {status}", file=sys.stderr)
                    print(developer_log(identifier, token), file=sys.stderr)
                    return 1
                else:
                    print(f"notarization {identifier} for {artifact}: {status}")
            failures = 0
        except Transient as error:
            failures += 1
            print(f"transient notary error ({error}), retry {failures}", file=sys.stderr)
            sleep(min(poll * 2**failures, 300))
            continue
        except urllib.error.HTTPError as error:
            print(f"notary API rejected the request: HTTP {error.code}", file=sys.stderr)
            return 1
        if pending:
            sleep(poll)
    return 0


def main():
    submissions = json.load(open(sys.argv[1]))
    key_pem = os.environ["NOTARY_KEY"]
    return wait(
        submissions,
        key_pem,
        os.environ["NOTARY_KEY_ID"],
        os.environ["NOTARY_ISSUER_ID"],
        float(os.environ.get("NOTARY_POLL_SECONDS", "30")),
        float(os.environ.get("NOTARY_DEADLINE_SECONDS", str(5 * 3600))),
    )


if __name__ == "__main__":
    sys.exit(main())
