#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
REVISION_NAME="${QUOTA_BUTTON_REVISION:-a1-c1}"
if [[ ! "${REVISION_NAME}" =~ ^a1-c[0-9]+$ ]]; then
  echo "Invalid QUOTA_BUTTON_REVISION: ${REVISION_NAME}" >&2
  exit 1
fi
REVISION_ROOT="${PROJECT_ROOT}/build/anchored-quota-button/revisions/${REVISION_NAME}"
HOST_APP="${REVISION_ROOT}/mock-host/QuotaButtonMockHost.app"
BUTTON_APP="${REVISION_ROOT}/test-candidates/QuotaButtonMock.app"
HOST_PID_FILE="${REVISION_ROOT}/runtime/local.msl.QuotaButton.MockHost/mock-host.pid"
BUTTON_PID_FILE="${REVISION_ROOT}/runtime/local.msl.QuotaButton.Mock/quota-button.pid"

for app in "${HOST_APP}" "${BUTTON_APP}"; do
  if [[ ! -d "${app}" ]]; then
    echo "Required a1-c1 mock app is missing: ${app}" >&2
    exit 1
  fi
  /usr/bin/codesign --verify --strict --deep "${app}"
done

host_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${HOST_APP}/Contents/Info.plist")"
button_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${BUTTON_APP}/Contents/Info.plist")"
if [[ "${host_id}" != "local.msl.QuotaButton.MockHost" || "${button_id}" != "local.msl.QuotaButton.Mock" ]]; then
  echo "Unexpected mock identities: host=${host_id} button=${button_id}" >&2
  exit 1
fi

for pid_file in "${HOST_PID_FILE}" "${BUTTON_PID_FILE}"; do
  if [[ -f "${pid_file}" ]]; then
    pid="$(cat "${pid_file}")"
    if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
      echo "Refusing to launch a duplicate a1-c1 process; PID file is active: ${pid_file} (${pid})" >&2
      exit 1
    fi
    rm -f "${pid_file}"
  fi
done

/usr/bin/open -n "${HOST_APP}"
for attempt in {1..40}; do
  [[ -s "${HOST_PID_FILE}" ]] && break
  sleep 0.25
done
if [[ ! -s "${HOST_PID_FILE}" ]]; then
  echo "Mock host did not publish its runtime PID: ${HOST_PID_FILE}" >&2
  exit 1
fi

/usr/bin/open -n "${BUTTON_APP}"
for attempt in {1..40}; do
  [[ -s "${BUTTON_PID_FILE}" ]] && break
  sleep 0.25
done
if [[ ! -s "${BUTTON_PID_FILE}" ]]; then
  echo "Mock button candidate did not publish its runtime PID: ${BUTTON_PID_FILE}" >&2
  exit 1
fi

{
  echo "host_pid=$(cat "${HOST_PID_FILE}")"
  echo "button_pid=$(cat "${BUTTON_PID_FILE}")"
  echo "host_bundle_id=${host_id}"
  echo "button_bundle_id=${button_id}"
  echo "target=mock-host-only"
} > "${REVISION_ROOT}/mock-run-result.txt"
cat "${REVISION_ROOT}/mock-run-result.txt"
