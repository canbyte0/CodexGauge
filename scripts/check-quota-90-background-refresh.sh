#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
TASK_TMP="$(mktemp -d /private/tmp/quota90-background-check.XXXXXX)"
trap 'rm -rf "${TASK_TMP}"' EXIT

COMMON_SOURCES=(
  "${PROJECT_ROOT}/Sources/QuotaWindowLayout.swift"
  "${PROJECT_ROOT}/Sources/QuotaRealData.swift"
  "${PROJECT_ROOT}/Sources/QuotaRealProvider.swift"
  "${PROJECT_ROOT}/Sources/QuotaRealModel.swift"
)
FRAMEWORKS=(-framework AppKit -framework SwiftUI -framework CoreGraphics)

xcrun swiftc -D QUOTA_TESTING -parse-as-library \
  -module-cache-path "${TASK_TMP}/module-cache-90" \
  -target arm64-apple-macosx14.0 "${FRAMEWORKS[@]}" \
  "${COMMON_SOURCES[@]}" "${PROJECT_ROOT}/validation/Quota90BackgroundRefreshCheck.swift" \
  -o "${TASK_TMP}/quota90-background-check" 2> "${TASK_TMP}/compile-90.log"
"${TASK_TMP}/quota90-background-check" "${PROJECT_ROOT}/validation/quota90-fake-app-server.pl"

# The shared model's old visibility-driven mode remains a regression boundary.
xcrun swiftc -D QUOTA_TESTING -parse-as-library \
  -module-cache-path "${TASK_TMP}/module-cache-85" \
  -target arm64-apple-macosx14.0 "${FRAMEWORKS[@]}" \
  "${COMMON_SOURCES[@]}" "${PROJECT_ROOT}/validation/Quota85StateCheck.swift" \
  -o "${TASK_TMP}/quota85-state-check" 2> "${TASK_TMP}/compile-85.log"
"${TASK_TMP}/quota85-state-check"

# Production-model and independently prepared first-quota account-switch checks.
xcrun swiftc -D QUOTA_TESTING -parse-as-library \
  -module-cache-path "${TASK_TMP}/module-cache-real-state" \
  -target arm64-apple-macosx14.0 "${FRAMEWORKS[@]}" \
  "${COMMON_SOURCES[@]}" "${PROJECT_ROOT}/validation/QuotaRealStateCheck.swift" \
  -o "${TASK_TMP}/quota-real-state-check" 2> "${TASK_TMP}/compile-real-state.log"
"${TASK_TMP}/quota-real-state-check"

xcrun swiftc -D QUOTA_TESTING -parse-as-library \
  -module-cache-path "${TASK_TMP}/module-cache-initial-switch" \
  -target arm64-apple-macosx14.0 "${FRAMEWORKS[@]}" \
  "${COMMON_SOURCES[@]}" \
  "${PROJECT_ROOT}/validation/AccountSwitchDuringInitialQuotaCheck.swift" \
  -o "${TASK_TMP}/initial-account-switch-check" 2> "${TASK_TMP}/compile-initial-switch.log"
"${TASK_TMP}/initial-account-switch-check"
