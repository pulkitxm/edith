validate_build_jobs() {
  case "$1" in
    "") ;;
    *[!0-9]*|0)
      echo "EDITH_BUILD_JOBS must be a positive integer" >&2
      return 1
      ;;
  esac
}

xcodebuild_with_jobs() {
  local jobs="$1"
  shift
  if [ -n "$jobs" ]; then
    xcodebuild -jobs "$jobs" "$@"
  else
    xcodebuild "$@"
  fi
}

swift_build_with_jobs() {
  local jobs="$1"
  local swift_bin="$2"
  shift 2
  if [ -n "$jobs" ]; then
    "$swift_bin" build --jobs "$jobs" "$@"
  else
    "$swift_bin" build "$@"
  fi
}
