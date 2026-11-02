#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
REVISION_ROOT="${PROJECT_ROOT}/build/independent-quota-window/revisions/w1-c2"
CANDIDATE_ROOT="${QUOTA_WINDOW_CANDIDATE_ROOT:-${REVISION_ROOT}/candidates}"
EXPECTED_VERSION="0.1.0-w1-c2"

if [[ ! -d "${CANDIDATE_ROOT}" ]]; then
  echo "W1 candidate directory not found: ${CANDIDATE_ROOT}" >&2
  exit 1
fi
CANDIDATE_ROOT="$(cd "${CANDIDATE_ROOT}" && pwd -P)"
APP_PATH="${CANDIDATE_ROOT}/QuotaWindowDemo.app"
if [[ ! -d "${APP_PATH}" ]]; then
  echo "QuotaWindowDemo.app not found: ${APP_PATH}" >&2
  exit 1
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP_PATH}/Contents/Info.plist")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist")"
if [[ "${BUNDLE_ID}" != "local.msl.QuotaWindow.Demo" || "${VERSION}" != "${EXPECTED_VERSION}" ]]; then
  echo "Unexpected candidate identity; refusing to open: ${BUNDLE_ID} ${VERSION}" >&2
  exit 1
fi

/usr/bin/codesign --verify --strict --deep "${APP_PATH}"
exec /usr/bin/open -n "${APP_PATH}"
