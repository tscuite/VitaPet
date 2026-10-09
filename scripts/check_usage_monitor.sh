#!/usr/bin/env bash
# Compile actual module sources; all checks use fixtures/temp storage, never home, Keychain or live networking.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vitapet-usage-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
FLAGS=(-sdk "$SDK" -target "$(uname -m)-apple-macosx14.0" -swift-version 6 -strict-concurrency=complete)
swiftc "${FLAGS[@]}" -enable-testing -emit-library -emit-module -module-name UsageMonitor \
  Modules/UsageMonitor/Sources/*.swift \
  -emit-module-path "$CHECK_DIR/UsageMonitor.swiftmodule" -o "$CHECK_DIR/libUsageMonitor.dylib"
swiftc "${FLAGS[@]}" -parse-as-library -I "$CHECK_DIR" -L "$CHECK_DIR" -lUsageMonitor \
  -Xlinker -rpath -Xlinker "$CHECK_DIR" scripts/UsageMonitorChecks.swift scripts/PiLocalSpendChecks.swift scripts/UsageGoogleChecks.swift -o "$CHECK_DIR/check-usage-monitor"
"$CHECK_DIR/check-usage-monitor"
# A presence probe is a credential API call too. Check the compiled module without opening Keychain.
nm -u "$CHECK_DIR/libUsageMonitor.dylib" > "$CHECK_DIR/imports.txt"
if grep -Eq '_Sec(Item|Keychain)' "$CHECK_DIR/imports.txt"; then
  echo 'FAIL: UsageMonitor still imports Keychain credential APIs' >&2
  exit 1
fi
if rg -l 'Sec(Item|Keychain)[A-Za-z_]*|readKeychain|hasCredential|saveCredential' \
    App/Sources Modules --glob '*.swift' --glob '!**/Tests/**'; then
  echo 'FAIL: production Keychain access/probe entry point was reintroduced' >&2
  exit 1
fi
printf '%s\n' 'PASS: production sources and compiled UsageMonitor contain no Keychain credential API or presence-probe entry point.'
