#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_ROOT="${OVERLAY_A_BUILD_ROOT:-${PROJECT_ROOT}/build/overlay-a}"
CANDIDATE_ROOT="${OVERLAY_A_CANDIDATE_ROOT:-${BUILD_ROOT}/candidates}"
CACHE_ROOT="${BUILD_ROOT}/module-cache"
APP_VERSION="${OVERLAY_A_VERSION:-0.2.0-r2}"
RUNTIME_DIRECTORY_NAME="${OVERLAY_A_RUNTIME_DIRECTORY_NAME:-runtime}"
DEMO_MOUSE_RECEIPT_DIAGNOSTICS="${OVERLAY_A_DEMO_MOUSE_RECEIPT_DIAGNOSTICS:-false}"

if [[ "${DEMO_MOUSE_RECEIPT_DIAGNOSTICS}" != "true" && "${DEMO_MOUSE_RECEIPT_DIAGNOSTICS}" != "false" ]]; then
  echo "Invalid demo mouse-receipt diagnostic setting: ${DEMO_MOUSE_RECEIPT_DIAGNOSTICS}" >&2
  exit 1
fi

if [[ ! "${RUNTIME_DIRECTORY_NAME}" =~ ^[A-Za-z0-9._-]+$ || "${RUNTIME_DIRECTORY_NAME}" == "." || "${RUNTIME_DIRECTORY_NAME}" == ".." ]]; then
  echo "Invalid Overlay runtime directory name: ${RUNTIME_DIRECTORY_NAME}" >&2
  exit 1
fi

if [[ -e "${BUILD_ROOT}" ]]; then
  echo "Refusing to reuse existing build directory: ${BUILD_ROOT}" >&2
  exit 1
fi
if [[ -e "${CANDIDATE_ROOT}" ]]; then
  if [[ ! -d "${CANDIDATE_ROOT}" ]] || [[ -n "$(/usr/bin/find "${CANDIDATE_ROOT}" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
    echo "Refusing to reuse occupied candidate directory: ${CANDIDATE_ROOT}" >&2
    exit 1
  fi
fi

mkdir -p "${CACHE_ROOT}" "${CANDIDATE_ROOT}"

swiftc \
  -parse-as-library \
  -module-cache-path "${CACHE_ROOT}" \
  -target arm64-apple-macosx14.0 \
  -framework AppKit \
  -framework CoreGraphics \
  "${PROJECT_ROOT}/Sources/OverlayPlacement.swift" \
  "${PROJECT_ROOT}/Sources/OverlayRuntimePaths.swift" \
  "${PROJECT_ROOT}/Sources/OverlayTerminationSignal.swift" \
  "${PROJECT_ROOT}/Sources/OverlayInputReceiptDiagnosticLog.swift" \
  "${PROJECT_ROOT}/Sources/OverlayA.swift" \
  -o "${BUILD_ROOT}/OverlayA"

swiftc \
  -parse-as-library \
  -module-cache-path "${CACHE_ROOT}" \
  -target arm64-apple-macosx14.0 \
  -framework AppKit \
  "${PROJECT_ROOT}/Sources/OverlayRuntimePaths.swift" \
  "${PROJECT_ROOT}/Sources/OverlayTerminationSignal.swift" \
  "${PROJECT_ROOT}/Sources/OverlayInputReceiptDiagnosticLog.swift" \
  "${PROJECT_ROOT}/Sources/OverlayADemoHost.swift" \
  -o "${BUILD_ROOT}/OverlayADemoHost"

make_app() {
  local app_path="$1"
  local executable_name="$2"
  local bundle_id="$3"
  local display_name="$4"
  local target_bundle_id="$5"
  local ui_element="$6"
  local diagnostic_plist_entry=""

  if [[ "${DEMO_MOUSE_RECEIPT_DIAGNOSTICS}" == "true" && ( "${bundle_id}" == "org.openai.codex.QuotaOverlayA.Demo" || "${bundle_id}" == "org.openai.codex.QuotaOverlayA.DemoHost" ) ]]; then
    diagnostic_plist_entry="<key>OverlayMouseReceiptDiagnostics</key><true/>"
  fi

  if [[ -e "${app_path}" ]]; then
    echo "Refusing to overwrite existing candidate: ${app_path}" >&2
    exit 1
  fi

  mkdir -p "${app_path}/Contents/MacOS" "${app_path}/Contents/Resources"
  cp "${BUILD_ROOT}/${executable_name}" "${app_path}/Contents/MacOS/${executable_name}"
  cat > "${app_path}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>${executable_name}</string>
  <key>CFBundleIdentifier</key><string>${bundle_id}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${display_name}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><${ui_element}/>
  <key>NSHighResolutionCapable</key><true/>
  <key>OverlayTargetBundleIdentifier</key><string>${target_bundle_id}</string>
  <key>OverlayRuntimeDirectoryName</key><string>${RUNTIME_DIRECTORY_NAME}</string>
  ${diagnostic_plist_entry}
</dict>
</plist>
PLIST
  /usr/bin/codesign --force --deep --sign - "${app_path}"
}

make_app \
  "${CANDIDATE_ROOT}/OverlayA.app" \
  "OverlayA" \
  "org.openai.codex.QuotaOverlayA" \
  "额度摘要候选 Overlay A" \
  "com.openai.codex" \
  "true"

make_app \
  "${CANDIDATE_ROOT}/OverlayADemo.app" \
  "OverlayA" \
  "org.openai.codex.QuotaOverlayA.Demo" \
  "额度摘要候选 Overlay A Demo" \
  "org.openai.codex.QuotaOverlayA.DemoHost" \
  "true"

make_app \
  "${CANDIDATE_ROOT}/OverlayADemoHost.app" \
  "OverlayADemoHost" \
  "org.openai.codex.QuotaOverlayA.DemoHost" \
  "Overlay A 空白模拟宿主" \
  "" \
  "false"

echo "Build complete: ${CANDIDATE_ROOT}"
