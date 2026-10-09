#!/usr/bin/env bash
# Run the real growth/storage sources without XCTest or a running VitaPet instance.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vitapet-care.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT

swiftc -swift-version 6 -strict-concurrency=complete \
  -emit-library -emit-module -module-name RenderEngine \
  Modules/RenderEngine/Sources/CompanionProgress.swift \
  -emit-module-path "$CHECK_DIR/RenderEngine.swiftmodule" \
  -o "$CHECK_DIR/libRenderEngine.dylib"
swiftc -swift-version 6 -strict-concurrency=complete \
  -I "$CHECK_DIR" -L "$CHECK_DIR" -lRenderEngine \
  -Xlinker -rpath -Xlinker "$CHECK_DIR" \
  Modules/Persistence/Sources/CompanionStore.swift \
  Modules/ChatUI/Sources/SpritePackPreviewRenderPolicy.swift scripts/CompanionChecks.swift \
  -o "$CHECK_DIR/check-companion"
"$CHECK_DIR/check-companion"
