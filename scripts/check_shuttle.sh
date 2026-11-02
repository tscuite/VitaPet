#!/usr/bin/env bash
# Offline checks with temporary scripts; --check-local-plugin only reads the real plugin's menu.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK="$(mktemp -d "${TMPDIR:-/tmp}/vitapet-shuttle.XXXXXX")"
trap 'rm -rf "$CHECK"' EXIT
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
if [ -z "${SDKROOT:-}" ] && [[ "$(xcode-select -p)" != *Xcode*.app* ]]; then
  for candidate in $(ls -d "$(xcode-select -p)"/SDKs/MacOSX[0-9]*.sdk | sort -rV); do
    [ -L "$candidate" ] && continue
    interface="$candidate/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface"
    if [ -f "$interface" ] && ! grep -q 'public macro State' "$interface"; then SDK="$candidate"; break; fi
  done
fi
BIN="$(SDKROOT="$SDK" swift build -c release --arch "$(uname -m)" --show-bin-path)"
if [ ! -f "$BIN/ChatUI.o" ]; then
  echo 'Build first: INSTALL=0 bash scripts/build_app.sh' >&2
  exit 1
fi
cp -R "$BIN/VitaPet_Localization.bundle" "$BIN/VitaPet_ChatUI.bundle" "$BIN/VitaPet_RenderEngine.bundle" "$CHECK/"
swiftc -sdk "$SDK" -target "$(uname -m)-apple-macosx14.0" -swift-version 6 -strict-concurrency=complete \
  -parse-as-library -D SHUTTLE_MENU_CHECKS -I "$BIN" \
  "$BIN/Localization.o" "$BIN/ChatUI.o" "$BIN/AIEngine.o" "$BIN/RenderEngine.o" "$BIN/EventBus.o" "$BIN/UsageMonitor.o" \
  App/Sources/ShuttlePlugin.swift App/Sources/ShuttleMenuController.swift App/Sources/StatusBarController.swift \
  scripts/ShuttleChecks.swift -o "$CHECK/ShuttleChecks"
"$CHECK/ShuttleChecks" "$@"
