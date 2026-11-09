#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
APP_ICON="${PROJECT_ROOT}/Resources/AppIcon.icns"
COMPATIBILITY_CONFIG="${PROJECT_ROOT}/Resources/QuotaHostCompatibility.json"
REVISION_NAME="${QUOTA_BUTTON_REVISION:-a1-c1}"
if [[ ! "${REVISION_NAME}" =~ ^a1-c[0-9]+$ ]]; then
  echo "Invalid QUOTA_BUTTON_REVISION: ${REVISION_NAME}" >&2
  exit 1
fi
REVISION_ROOT="${PROJECT_ROOT}/build/anchored-quota-button/revisions/${REVISION_NAME}"
MODULE_CACHE="${REVISION_ROOT}/module-cache"
BUILD_TEMP="${REVISION_ROOT}/build-temp"
SWIFT_TARGET="arm64-apple-macosx14.0"
FRAMEWORKS=(-framework AppKit -framework SwiftUI -framework CoreGraphics)
LEGACY_PROFILE_VARIABLES=(
  QUOTA_BUTTON_PROFILE_HOST_BUNDLE_IDENTIFIER
  QUOTA_BUTTON_PROFILE_HOST_BUILD_VERSION
  QUOTA_BUTTON_PROFILE_HOST_SHORT_VERSION
  QUOTA_BUTTON_PROFILE_HOST_INFO_PLIST_SHA256
)
for variable_name in "${LEGACY_PROFILE_VARIABLES[@]}"; do
  if [[ -n "${!variable_name:-}" ]]; then
    echo "Legacy host-profile build parameter ${variable_name} is unsupported; update the bundled compatibility JSON instead." >&2
    exit 2
  fi
done
BUTTON_SOURCES=(
  "${PROJECT_ROOT}/Sources/QuotaWindowLayout.swift"
  "${PROJECT_ROOT}/Sources/QuotaCountdown.swift"
  "${PROJECT_ROOT}/Sources/QuotaHostCompatibility.swift"
  "${PROJECT_ROOT}/Sources/QuotaSidebarGlyph.swift"
  "${PROJECT_ROOT}/Sources/QuotaRealData.swift"
  "${PROJECT_ROOT}/Sources/QuotaRealProvider.swift"
  "${PROJECT_ROOT}/Sources/QuotaRealModel.swift"
  "${PROJECT_ROOT}/Sources/OverlayRuntimePaths.swift"
  "${PROJECT_ROOT}/Sources/OverlayTerminationSignal.swift"
  "${PROJECT_ROOT}/Sources/QuotaWindowReal.swift"
  "${PROJECT_ROOT}/Sources/QuotaAnchoredButton.swift"
)
MOCK_HOST_SOURCES=("${PROJECT_ROOT}/Sources/QuotaButtonMockHost.swift")

if [[ ! -f "${APP_ICON}" ]]; then
  echo "App icon not found; run bash scripts/generate-app-icon.sh: ${APP_ICON}" >&2
  exit 1
fi
if [[ ! -f "${COMPATIBILITY_CONFIG}" ]]; then
  echo "Default host compatibility resource is missing: ${COMPATIBILITY_CONFIG}" >&2
  exit 1
fi

if [[ -e "${REVISION_ROOT}" ]]; then
  echo "Refusing to overwrite existing a1-c1 revision: ${REVISION_ROOT}" >&2
  exit 1
fi

mkdir -p "${REVISION_ROOT}" "${MODULE_CACHE}" "${BUILD_TEMP}" \
  "${REVISION_ROOT}/candidates" "${REVISION_ROOT}/test-candidates" "${REVISION_ROOT}/mock-host"

PRODUCTION_APP="${REVISION_ROOT}/candidates/QuotaButton.app"
TEST_APP="${REVISION_ROOT}/test-candidates/QuotaButtonMock.app"
MOCK_HOST_APP="${REVISION_ROOT}/mock-host/QuotaButtonMockHost.app"

build_binary() {
  local label="$1"
  local output="$2"
  shift 2
  local command=(xcrun swiftc -parse-as-library -module-cache-path "${MODULE_CACHE}" -target "${SWIFT_TARGET}" "${FRAMEWORKS[@]}" "$@" -o "${output}")
  {
    echo "label=${label}"
    echo "target=${SWIFT_TARGET}"
    echo "swift_version=$(xcrun swiftc -version | tr '\n' ' ')"
    echo "sdk_version=$(xcrun --sdk macosx --show-sdk-version)"
    echo "builder_sha256=$(shasum -a 256 "${BASH_SOURCE[0]}" | awk '{print $1}')"
    echo "compatibility_resource=${COMPATIBILITY_CONFIG}"
    echo "compatibility_resource_sha256=$(shasum -a 256 "${COMPATIBILITY_CONFIG}" | awk '{print $1}')"
    echo "compatibility_schema_version=1"
    echo "command_argv_begin"
    for ((index = 0; index < ${#command[@]}; index++)); do
      printf 'argv[%02d]=%s\n' "${index}" "${command[${index}]}"
    done
    echo "command_argv_end"
    echo "source_sha256_begin"
    for input in "$@"; do
      [[ "${input}" == -D ]] && continue
      if [[ -f "${input}" ]]; then shasum -a 256 "${input}"; fi
    done
    echo "source_sha256_end"
  } > "${REVISION_ROOT}/${label}-build-inputs.txt"

  if "${command[@]}" > "${REVISION_ROOT}/${label}-swiftc-output.log" 2>&1; then
    echo "compiler_exit=0" > "${REVISION_ROOT}/${label}-build-result.txt"
  else
    local status=$?
    echo "compiler_exit=${status}" > "${REVISION_ROOT}/${label}-build-result.txt"
    cat "${REVISION_ROOT}/${label}-swiftc-output.log" >&2
    return "${status}"
  fi
}

package_app() {
  local executable="$1"
  local binary="$2"
  local bundle_id="$3"
  local bundle_name="$4"
  local version="$5"
  local runtime_name="$6"
  local ui_element="true"
  local compatibility_metadata=""
  if [[ "${bundle_id}" == "local.msl.QuotaButton.MockHost" ]]; then ui_element="false"; fi
  mkdir -p "${executable}/Contents/MacOS" "${executable}/Contents/Resources"
  if [[ "${bundle_id}" == "local.msl.QuotaButton.Anchored" || "${bundle_id}" == "local.msl.QuotaButton.Mock" ]]; then
    cp "${COMPATIBILITY_CONFIG}" "${executable}/Contents/Resources/QuotaHostCompatibility.json"
    compatibility_metadata="  <key>QuotaHostCompatibilitySchemaVersion</key><integer>1</integer>"
  fi
  cp "${binary}" "${executable}/Contents/MacOS/$(basename "${binary}")"
  cat > "${executable}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>$(basename "${binary}")</string>
  <key>CFBundleIdentifier</key><string>${bundle_id}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${bundle_name}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><${ui_element}/>
  <key>NSHighResolutionCapable</key><true/>
  <key>OverlayRuntimeDirectoryName</key><string>${runtime_name}</string>
${compatibility_metadata}
</dict>
</plist>
PLIST
  if [[ "${bundle_id}" == "local.msl.QuotaButton.Anchored" ]]; then
    cp "${APP_ICON}" "${executable}/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "${executable}/Contents/Info.plist"
  fi
  /usr/bin/codesign --force --deep --sign - "${executable}" > "${REVISION_ROOT}/codesign-$(basename "${executable}")-sign.log" 2>&1
  /usr/bin/codesign --verify --strict --deep --verbose=4 "${executable}" > "${REVISION_ROOT}/codesign-$(basename "${executable}")-verify.log" 2>&1
  {
    echo "path=${executable}"
    echo "bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${executable}/Contents/Info.plist")"
    echo "version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${executable}/Contents/Info.plist")"
    echo "binary_sha256=$(shasum -a 256 "${executable}/Contents/MacOS/$(basename "${binary}")" | awk '{print $1}')"
    if [[ "${bundle_id}" == "local.msl.QuotaButton.Anchored" ]]; then
      echo "app_icon=AppIcon.icns"
      echo "app_icon_sha256=$(shasum -a 256 "${executable}/Contents/Resources/AppIcon.icns" | awk '{print $1}')"
    fi
    echo "codesign_verify_exit=0"
  } > "${REVISION_ROOT}/$(basename "${executable}")-identity.txt"
}

build_binary production-button "${BUILD_TEMP}/QuotaButton" -D QUOTA_ANCHORED_BUTTON "${BUTTON_SOURCES[@]}"
package_app "${PRODUCTION_APP}" "${BUILD_TEMP}/QuotaButton" "local.msl.QuotaButton.Anchored" "额度按钮" "0.1.0-${REVISION_NAME}" "${REVISION_NAME}-runtime"

build_binary mock-button "${BUILD_TEMP}/QuotaButtonMock" -D QUOTA_ANCHORED_BUTTON -D QUOTA_ANCHORED_TESTING "${BUTTON_SOURCES[@]}"
package_app "${TEST_APP}" "${BUILD_TEMP}/QuotaButtonMock" "local.msl.QuotaButton.Mock" "额度按钮模拟候选" "0.1.0-${REVISION_NAME}-mock" "${REVISION_NAME}-mock-runtime"

build_binary mock-host "${BUILD_TEMP}/QuotaButtonMockHost" "${MOCK_HOST_SOURCES[@]}"
package_app "${MOCK_HOST_APP}" "${BUILD_TEMP}/QuotaButtonMockHost" "local.msl.QuotaButton.MockHost" "固定额度按钮模拟宿主" "0.1.0-${REVISION_NAME}-mock-host" "${REVISION_NAME}-host-runtime"

{
  echo "revision_name=${REVISION_NAME}"
  echo "revision=${REVISION_ROOT}"
  echo "production_candidate=${PRODUCTION_APP}"
  echo "production_bundle_id=local.msl.QuotaButton.Anchored"
  echo "test_candidate=${TEST_APP}"
  echo "test_bundle_id=local.msl.QuotaButton.Mock"
  echo "test_target_bundle_id=local.msl.QuotaButton.MockHost"
  echo "mock_host=${MOCK_HOST_APP}"
  echo "mock_host_bundle_id=local.msl.QuotaButton.MockHost"
  echo "compatibility_resource=${COMPATIBILITY_CONFIG}"
  echo "compatibility_resource_sha256=$(shasum -a 256 "${COMPATIBILITY_CONFIG}" | awk '{print $1}')"
  echo "compatibility_schema_version=1"
  echo "c6_candidate=build/independent-quota-window/revisions/w3-c6/candidates/QuotaWindow.app"
  echo "no_formal_host_launch=true"
} > "${REVISION_ROOT}/${REVISION_NAME}-binding.txt"

echo "build_complete=${REVISION_ROOT}"
