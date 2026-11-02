#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
REVISION_ROOT="${PROJECT_ROOT}/build/independent-quota-window/revisions/w1-c2"
CANDIDATE_ROOT="${REVISION_ROOT}/candidates"
APP_PATH="${CANDIDATE_ROOT}/QuotaWindowDemo.app"
BUNDLE_ID="local.msl.QuotaWindow.Demo"
APP_VERSION="0.1.0-w1-c2"
RUNTIME_DIRECTORY_NAME="runtime"
MODULE_CACHE="${REVISION_ROOT}/module-cache"
BUILD_TEMP="${REVISION_ROOT}/build-temp"

if [[ -e "${REVISION_ROOT}" ]]; then
  echo "Refusing to reuse existing W1 c2 revision path: ${REVISION_ROOT}" >&2
  exit 1
fi

mkdir -p "${CANDIDATE_ROOT}" "${MODULE_CACHE}" "${BUILD_TEMP}"

SWIFT_SOURCES=(
  "${PROJECT_ROOT}/Sources/QuotaWindowLayout.swift"
  "${PROJECT_ROOT}/Sources/OverlayRuntimePaths.swift"
  "${PROJECT_ROOT}/Sources/OverlayTerminationSignal.swift"
  "${PROJECT_ROOT}/Sources/QuotaWindowDemo.swift"
)
SWIFT_TARGET="arm64-apple-macosx14.0"
SWIFT_FRAMEWORKS=(-framework AppKit -framework SwiftUI -framework CoreGraphics)
SWIFT_COMMAND=(
  xcrun swiftc
  -parse-as-library
  -module-cache-path "${MODULE_CACHE}"
  -target "${SWIFT_TARGET}"
  "${SWIFT_FRAMEWORKS[@]}"
  "${SWIFT_SOURCES[@]}"
  -o "${BUILD_TEMP}/QuotaWindowDemo"
)

{
  echo "candidate=${APP_PATH}"
  echo "bundle_id=${BUNDLE_ID}"
  echo "version=${APP_VERSION}"
  echo "runtime_directory_name=${RUNTIME_DIRECTORY_NAME}"
  echo "target=${SWIFT_TARGET}"
  echo "swift_version=$(xcrun swiftc -version | tr '\n' ' ')"
  echo "sdk_version=$(xcrun --sdk macosx --show-sdk-version)"
  echo "builder_sha256=$(shasum -a 256 "${SCRIPT_DIR}/build-quota-window-demo.sh" | awk '{print $1}')"
  echo "command_argv_begin"
  for ((index = 0; index < ${#SWIFT_COMMAND[@]}; index++)); do
    printf 'argv[%02d]=%s\n' "${index}" "${SWIFT_COMMAND[${index}]}"
  done
  echo "command_argv_end"
  echo "compiled_source_sha256_begin"
  for input in "${SWIFT_SOURCES[@]}"; do
    shasum -a 256 "${input}"
  done
  echo "compiled_source_sha256_end"
} > "${REVISION_ROOT}/build-inputs.txt"

BUILD_LOG="${REVISION_ROOT}/swiftc-output.log"
if "${SWIFT_COMMAND[@]}" > "${BUILD_LOG}" 2>&1; then
  echo "compiler_exit=0" > "${REVISION_ROOT}/build-result.txt"
else
  build_status=$?
  echo "compiler_exit=${build_status}" > "${REVISION_ROOT}/build-result.txt"
  cat "${BUILD_LOG}" >&2
  exit "${build_status}"
fi

mkdir -p "${APP_PATH}/Contents/MacOS" "${APP_PATH}/Contents/Resources"
cp "${BUILD_TEMP}/QuotaWindowDemo" "${APP_PATH}/Contents/MacOS/QuotaWindowDemo"
cat > "${APP_PATH}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>QuotaWindowDemo</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>额度示例窗</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><false/>
  <key>NSHighResolutionCapable</key><true/>
  <key>OverlayRuntimeDirectoryName</key><string>${RUNTIME_DIRECTORY_NAME}</string>
</dict>
</plist>
PLIST

SIGN_LOG="${REVISION_ROOT}/codesign-sign-output.log"
if /usr/bin/codesign --force --deep --sign - "${APP_PATH}" > "${SIGN_LOG}" 2>&1; then
  echo "codesign_sign_exit=0" >> "${REVISION_ROOT}/build-result.txt"
else
  sign_status=$?
  echo "codesign_sign_exit=${sign_status}" >> "${REVISION_ROOT}/build-result.txt"
  cat "${SIGN_LOG}" >&2
  exit "${sign_status}"
fi

VERIFY_LOG="${REVISION_ROOT}/codesign-verify-output.log"
if /usr/bin/codesign --verify --strict --deep --verbose=4 "${APP_PATH}" > "${VERIFY_LOG}" 2>&1; then
  echo "codesign_verify_exit=0" >> "${REVISION_ROOT}/build-result.txt"
else
  verify_status=$?
  echo "codesign_verify_exit=${verify_status}" >> "${REVISION_ROOT}/build-result.txt"
  cat "${VERIFY_LOG}" >&2
  exit "${verify_status}"
fi

/usr/bin/codesign -dv --verbose=4 "${APP_PATH}" > "${REVISION_ROOT}/codesign-description.log" 2>&1
{
  echo "candidate=${APP_PATH}"
  echo "bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP_PATH}/Contents/Info.plist")"
  echo "version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist")"
  echo "main_executable_sha256=$(shasum -a 256 "${APP_PATH}/Contents/MacOS/QuotaWindowDemo" | awk '{print $1}')"
} > "${REVISION_ROOT}/candidate-identity.txt"

echo "build_complete=${APP_PATH}"
