#!/usr/bin/env bash

signing_keychain_path=""
signing_keychain_p12=""

signing_keychain_drop() {
  local entries=() entry
  while IFS= read -r entry; do
    entry="$(echo "$entry" | sed 's/[",]//g' | xargs)"
    [ -n "$entry" ] && [ "$entry" != "$signing_keychain_path" ] && entries+=("$entry")
  done < <(security list-keychains -d user)
  security list-keychains -d user -s ${entries[@]+"${entries[@]}"} >/dev/null 2>&1 || true
}

signing_keychain_close() {
  [ -n "$signing_keychain_path" ] || return 0
  signing_keychain_drop
  security delete-keychain "$signing_keychain_path" >/dev/null 2>&1 || true
  rm -f "$signing_keychain_p12"
  signing_keychain_path=""
}

signing_keychain_open() {
  local identity="$1" login="$HOME/Library/Keychains/login.keychain-db" wwdr probe attempt
  if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$identity"; then
    return 0
  fi
  : "${MACOS_CERT_P12_BASE64:?the signing certificate is missing from .env}"
  : "${MACOS_CERT_PASSWORD:?the certificate password is missing from .env}"
  wwdr="$(find /Applications/Xcode*.app -iname 'AppleWWDRCA-2030.cer' 2>/dev/null | head -1)"
  signing_keychain_path="$HOME/Library/Keychains/edith-signing-$$.keychain-db"
  signing_keychain_p12="$(mktemp -t edith-signing).p12"
  printf '%s' "$MACOS_CERT_P12_BASE64" | base64 -D > "$signing_keychain_p12"
  probe="$(mktemp -t edith-probe)"
  local round others entry
  for round in 1 2 3 4 5; do
    signing_keychain_drop
    security delete-keychain "$signing_keychain_path" >/dev/null 2>&1 || true
    security create-keychain -p edith "$signing_keychain_path"
    security set-keychain-settings "$signing_keychain_path"
    security unlock-keychain -p edith "$signing_keychain_path"
    [ -z "$wwdr" ] || security import "$wwdr" -k "$signing_keychain_path" -T /usr/bin/codesign >/dev/null 2>&1 || true
    security import "$signing_keychain_p12" -k "$signing_keychain_path" -P "$MACOS_CERT_PASSWORD" \
      -T /usr/bin/codesign >/dev/null 2>&1
    security set-key-partition-list -S apple-tool:,apple: -s -k edith "$signing_keychain_path" >/dev/null 2>&1
    others=()
    while IFS= read -r entry; do
      entry="$(echo "$entry" | sed 's/[",]//g' | xargs)"
      [ -n "$entry" ] && [ "$entry" != "$signing_keychain_path" ] && [ "$entry" != "$login" ] && others+=("$entry")
    done < <(security list-keychains -d user)
    security list-keychains -d user -s "$login" "$signing_keychain_path" ${others[@]+"${others[@]}"}
    for attempt in 1 2 3 4 5 6; do
      cp /bin/echo "$probe"
      if codesign --force --sign "$identity" "$probe" >/dev/null 2>&1; then
        rm -f "$probe"
        return 0
      fi
      [ "$round$attempt" = 11 ] && echo "waiting for macOS to trust the signing certificate" >&2
      sleep 5
    done
  done
  rm -f "$probe"
  echo "could not build a working signing keychain for $identity" >&2
  return 1
}
