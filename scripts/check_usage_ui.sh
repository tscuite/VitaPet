#!/usr/bin/env bash
# Offline native checks. Run INSTALL=0 bash scripts/build_app.sh first; no app install/start.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK="$(mktemp -d "${TMPDIR:-/tmp}/vitapet-usage-ui.XXXXXX")"
trap 'rm -rf "$CHECK"' EXIT
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
# Match the build script's CLT workaround; SwiftUI macros require Xcode plugins.
if [ -z "${SDKROOT:-}" ] && [[ "$(xcode-select -p)" != *Xcode*.app* ]]; then
  for candidate in $(ls -d "$(xcode-select -p)"/SDKs/MacOSX[0-9]*.sdk | sort -rV); do
    [ -L "$candidate" ] && continue
    interface="$candidate/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface"
    if [ -f "$interface" ] && ! grep -q 'public macro State' "$interface"; then SDK="$candidate"; break; fi
  done
fi
BIN="$(SDKROOT="$SDK" swift build -c release --arch "$(uname -m)" --show-bin-path)"
if [ ! -f "$BIN/Localization.o" ] || [ ! -d "$BIN/VitaPet_ChatUI.bundle" ]; then
  echo 'Build first: INSTALL=0 bash scripts/build_app.sh' >&2
  exit 1
fi
FLAGS=(-sdk "$SDK" -target "$(uname -m)-apple-macosx14.0" -swift-version 6 -strict-concurrency=complete)
swiftc "${FLAGS[@]}" -enable-testing -emit-library -emit-module -module-name UsageMonitor \
  Modules/UsageMonitor/Sources/*.swift \
  -emit-module-path "$CHECK/UsageMonitor.swiftmodule" -o "$CHECK/libUsageMonitor.dylib"
LINK=(-I "$CHECK" -I "$BIN" -L "$CHECK" -lUsageMonitor -Xlinker -rpath -Xlinker "$CHECK")
cp -R "$BIN/VitaPet_Localization.bundle" "$BIN/VitaPet_ChatUI.bundle" "$CHECK/"
# Independent upstream source module: never linked into the app or replaced by the port itself.
swiftc "${FLAGS[@]}" -enable-testing -emit-library -emit-module -module-name CodeNotchReference \
  Modules/UsageMonitor/Tests/CodeNotchReference/*.swift \
  -emit-module-path "$CHECK/CodeNotchReference.swiftmodule" -o "$CHECK/libCodeNotchReference.dylib"
swiftc "${FLAGS[@]}" -parse-as-library "${LINK[@]}" -lCodeNotchReference "$BIN/Localization.o" \
  Modules/ChatUI/Sources/UsageTooltipCopy.swift Modules/ChatUI/Sources/UsageResetCopy.swift \
  Modules/ChatUI/Sources/UsageTokenFormat.swift scripts/CodexParityChecks.swift -o "$CHECK/CodexParityChecks"
"$CHECK/CodexParityChecks"
swiftc "${FLAGS[@]}" -D USAGE_PRESENTATION_CHECKS "${LINK[@]}" "$BIN/Localization.o" \
  Modules/ChatUI/Sources/UsagePresentation.swift Modules/ChatUI/Tests/UsagePresentationChecks.swift \
  -o "$CHECK/UsagePresentationChecks"
"$CHECK/UsagePresentationChecks"
swiftc "${FLAGS[@]}" -enable-testing -parse-as-library -emit-library -emit-module -module-name ChatUI \
  "${LINK[@]}" "$BIN/Localization.o" Modules/ChatUI/Sources/Usage*.swift \
  -o "$CHECK/libChatUI.dylib" -emit-module-path "$CHECK/ChatUI.swiftmodule"
swiftc "${FLAGS[@]}" -parse-as-library -D USAGE_PANEL_CHECKS "${LINK[@]}" -lChatUI \
  App/Sources/UsageBarController.swift Modules/ChatUI/Tests/UsageBarPanelChecks.swift \
  -o "$CHECK/UsageBarPanelChecks"
"$CHECK/UsageBarPanelChecks"
