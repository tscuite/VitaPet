#!/usr/bin/env bash
# Isolated native rendering checks; build first with INSTALL=0. No real app/data is opened.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK="$(mktemp -d "${TMPDIR:-/tmp}/vitapet-render.XXXXXX")"
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
if [ ! -f "$BIN/RenderEngine.o" ]; then
  echo 'Build first: INSTALL=0 bash scripts/build_app.sh' >&2
  exit 1
fi
cp -R "$BIN/VitaPet_RenderEngine.bundle" "$CHECK/"
swiftc -sdk "$SDK" -target "$(uname -m)-apple-macosx14.0" -swift-version 6 -strict-concurrency=complete \
  -parse-as-library -I "$BIN" "$BIN/RenderEngine.o" scripts/RenderEngineChecks.swift -o "$CHECK/RenderEngineChecks"
"$CHECK/RenderEngineChecks"
