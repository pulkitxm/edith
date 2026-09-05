#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

test_owned_runtime=""
test_owned_shared=""
test_owned_helper=""

fail_isolation() {
    printf '%s\n' "Test isolation refused: $*" >&2
    exit 2
}

validate_test_domain() {
    case "$2" in
        com.pulkit.edith.tests|com.pulkit.edith.tests.*|com.pulkit.edith.test.*|test.*) ;;
        *) fail_isolation "$1 must use a dedicated test namespace." ;;
    esac
    [[ "$2" =~ ^[A-Za-z0-9.-]+$ ]] || fail_isolation "$1 contains invalid characters."
    [[ ${#2} -le 200 ]] || fail_isolation "$1 is too long."
}

validate_test_path() {
    /usr/bin/python3 - "$1" "$2" <<'PY'
import os
import pathlib
import sys
name, raw = sys.argv[1:]
path = pathlib.Path(raw)
resolved = path.resolve()
allowed = any(resolved != base and base in resolved.parents for base in
              [pathlib.Path('/private/tmp'), pathlib.Path('/private/var/folders')])
if not path.is_absolute() or not allowed or '\n' in raw or '\r' in raw:
    raise SystemExit('Test isolation refused: ' + name + ' must be inside a private temporary directory.')
existing = resolved
while not existing.exists():
    existing = existing.parent
if not existing.is_dir() or (existing not in [pathlib.Path('/private/tmp'), pathlib.Path('/private/var/folders')]
                            and existing.stat().st_uid != os.getuid()):
    raise SystemExit('Test isolation refused: ' + name + ' must be a directory owned by the current user.')
PY
}

for test_name in EDITH_SHARED_DEFAULTS_SUITE EDITH_HELPER_DEFAULTS_SUITE EDITH_AGENT_MACH_SERVICE; do
    test_value="${!test_name:-}"
    if [[ -n "$test_value" ]]; then validate_test_domain "$test_name" "$test_value"; fi
done
for test_name in EDITH_DATA_ROOT EDITH_CLOUD_ROOT EDITH_DATABASE_HOME; do
    test_value="${!test_name:-}"
    if [[ -n "$test_value" ]]; then validate_test_path "$test_name" "$test_value"; fi
done

test_temp_parent="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)"
test_owned_runtime="$(/usr/bin/mktemp -d "${test_temp_parent%/}/edith-swift-tests.XXXXXXXX")"
printf '%s\n' "$$" > "$test_owned_runtime/.owner"
test_namespace="com.pulkit.edith.tests.$(/usr/bin/uuidgen | tr '[:upper:]' '[:lower:]')"
export EDITH_TEST_RUNTIME_ROOT="$test_owned_runtime"
export EDITH_DATA_ROOT="${EDITH_DATA_ROOT:-$test_owned_runtime/data}"
export EDITH_CLOUD_ROOT="${EDITH_CLOUD_ROOT:-$test_owned_runtime/cloud}"
export EDITH_DATABASE_HOME="${EDITH_DATABASE_HOME:-$test_owned_runtime/home}"
export EDITH_AGENT_MACH_SERVICE="${EDITH_AGENT_MACH_SERVICE:-$test_namespace.agent}"
export EDITH_DATABASE_KEYCHAIN_SERVICE="$test_namespace.database-credentials"
if [[ -z "${EDITH_SHARED_DEFAULTS_SUITE:-}" ]]; then
    test_owned_shared="$test_namespace.shared"
    export EDITH_SHARED_DEFAULTS_SUITE="$test_owned_shared"
fi
if [[ -z "${EDITH_HELPER_DEFAULTS_SUITE:-}" ]]; then
    test_owned_helper="$test_namespace.helper"
    export EDITH_HELPER_DEFAULTS_SUITE="$test_owned_helper"
fi

finish_isolation() {
    local test_status=$?
    trap - EXIT
    if [[ $test_status -eq 0 ]]; then
        if [[ -n "$test_owned_shared" ]]; then defaults delete "$test_owned_shared" >/dev/null 2>&1 || true; fi
        if [[ -n "$test_owned_helper" ]]; then defaults delete "$test_owned_helper" >/dev/null 2>&1 || true; fi
        if [[ -d "$test_owned_runtime" && -O "$test_owned_runtime" && ! -L "$test_owned_runtime" &&
            -f "$test_owned_runtime/.owner" && ! -L "$test_owned_runtime/.owner" &&
            "$(cat "$test_owned_runtime/.owner" 2>/dev/null)" == "$$" ]]; then
            /bin/rm -rf -- "$test_owned_runtime"
        fi
    else
        printf '%s\n' "Isolated test artifacts retained: $test_owned_runtime" >&2
    fi
    exit "$test_status"
}
trap finish_isolation EXIT
mkdir -p "$EDITH_DATA_ROOT" "$EDITH_CLOUD_ROOT" "$EDITH_DATABASE_HOME"

DEV="$(xcode-select -p)"
FW="$DEV/Library/Developer/Frameworks"
LIB="$DEV/Library/Developer/usr/lib"
FLAGS=()
if [[ -d "$FW/Testing.framework" ]]; then
    FLAGS=(-Xswiftc -F"$FW" -Xlinker -F"$FW"
        -Xlinker -rpath -Xlinker "$FW"
        -Xlinker -rpath -Xlinker "$LIB")
fi
swift test --no-parallel ${FLAGS[@]+"${FLAGS[@]}"} "$@"
