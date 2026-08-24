#!/usr/bin/env bash
#
# test.sh - run the Swift test suite.
#
#   ./test.sh                          # full suite
#   ./test.sh --filter LimitMathTests  # one suite
#
# With Command Line Tools (no Xcode), SwiftPM misses the search paths for
# the CLT-bundled Testing.framework and its lib_TestingInterop.dylib -
# add them. With full Xcode the directory doesn't exist and this is a
# plain `swift test`.
set -eo pipefail
cd "$(dirname "$0")"

DEV="$(xcode-select -p)"
FW="$DEV/Library/Developer/Frameworks"
LIB="$DEV/Library/Developer/usr/lib"
FLAGS=()
if [[ -d "$FW/Testing.framework" ]]; then
  FLAGS=(-Xswiftc -F"$FW" -Xlinker -F"$FW"
         -Xlinker -rpath -Xlinker "$FW"
         -Xlinker -rpath -Xlinker "$LIB")
fi
exec swift test ${FLAGS[@]+"${FLAGS[@]}"} "$@"
