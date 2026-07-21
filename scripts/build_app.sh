#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="VitaPet"
BIN_NAME="VitaPetApp"
BUNDLE_ID="com.vitapet.VitaPet"
VERSION="$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0-dev")"
VERSION="${VERSION#v}"

TARGET_TRIPLE="${VITAPET_TARGET_TRIPLE:-}"
ARCHS_ENV="${ARCHS:-}"
if [ -z "${TARGET_TRIPLE}" ]; then
  if [ -n "${ARCHS_ENV}" ]; then
    # shellcheck disable=SC2206
    ARCH_LIST=(${ARCHS_ENV})
  else
    ARCH_LIST=("$(uname -m)")
  fi
fi

OUT_DIR="dist"
APP_BASENAME="${APP_NAME}.app"
APP_DIR="${OUT_DIR}/${APP_BASENAME}"

BUILD_ARGS=(-c release)
if [ "${VITAPET_BUILD_DISABLE_SANDBOX:-0}" = "1" ]; then
  BUILD_ARGS+=(--disable-sandbox)
fi
if [ -n "${VITAPET_SWIFT_INCLUDE_PATH:-}" ]; then
  BUILD_ARGS+=(-Xswiftc -I -Xswiftc "${VITAPET_SWIFT_INCLUDE_PATH}")
fi
if [ -n "${TARGET_TRIPLE}" ]; then
  BUILD_ARGS+=(--triple "${TARGET_TRIPLE}")
else
  for arch in "${ARCH_LIST[@]}"; do
    BUILD_ARGS+=(--arch "$arch")
  done
fi

echo "==> swift build ${BUILD_ARGS[*]}"
swift build "${BUILD_ARGS[@]}"

BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_DIR}/${BIN_NAME}" "${APP_DIR}/Contents/MacOS/${BIN_NAME}"

# Application resource resolvers prefer the standard signed-bundle location and
# fall back to SwiftPM's Bundle.module location for `swift run` and tests.
for bundle in "${BIN_DIR}"/*.bundle; do
  [ -e "$bundle" ] || continue
  cp -R "$bundle" "${APP_DIR}/Contents/Resources/"
done

ICON_SRC="App/Resources/AppIcon.icns"
if [ "${VITAPET_REGENERATE_ICON:-0}" = "1" ]; then
  echo "==> Regenerating AppIcon.icns"
  swift scripts/generate_icon.swift "🐱" "${ICON_SRC}"
fi
if [ ! -s "${ICON_SRC}" ]; then
  echo "Checked-in AppIcon.icns is missing or empty" >&2
  exit 1
fi
cp "${ICON_SRC}" "${APP_DIR}/Contents/Resources/AppIcon.icns"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${BIN_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticTermination</key>
  <false/>
  <key>NSSupportsSuddenTermination</key>
  <false/>
  <key>NSLocationUsageDescription</key>
  <string>VitaPet uses your location to fetch local weather for pet reactions.</string>
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>VitaPet uses your location to fetch local weather for pet reactions.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "${APP_DIR}"
codesign --verify --deep --strict "${APP_DIR}"

echo "==> Built ${APP_DIR}"

# Default: copy into /Applications so local builds match “install the app” workflow.
# Set INSTALL=0 to only produce dist/ (e.g. CI, or you’ll copy the .app yourself).
if [ "${INSTALL:-1}" = "1" ]; then
  DEST="/Applications/${APP_BASENAME}"
  echo "==> Quitting existing ${APP_NAME} (if running)"
  osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || true
  sleep 1
  killall "${BIN_NAME}" 2>/dev/null || true
  sleep 0.5

  echo "==> Installing to ${DEST}"
  rm -rf "${DEST}"
  cp -R "${APP_DIR}" "${DEST}"
  echo "==> Restarting ${DEST}"
  open "${DEST}"
  LEGACY="/Applications/${APP_NAME}-arm64.app"
  if [ -d "$LEGACY" ]; then
    echo "==> 旧包仍可手动删除: rm -rf \"${LEGACY}\""
  fi
else
  echo "==> Skipped /Applications (INSTALL=0). App bundle: ${APP_DIR}"
fi
