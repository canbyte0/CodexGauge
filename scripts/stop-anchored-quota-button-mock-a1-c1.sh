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

stop_one() {
  local pid_file="$1"
  local executable="$2"
  local label="$3"
  if [[ ! -f "${pid_file}" ]]; then
    echo "${label}=not-running"
    return 0
  fi

  local pid
  pid="$(cat "${pid_file}")"
  if [[ ! "${pid}" =~ ^[0-9]+$ ]]; then
    echo "${label}=invalid-pid-file:${pid_file}" >&2
    return 1
  fi
  if ! kill -0 "${pid}" 2>/dev/null; then
    rm -f "${pid_file}"
    echo "${label}=stale-pid-removed"
    return 0
  fi

  local command
  command="$(/bin/ps -p "${pid}" -o command= | sed 's/^[[:space:]]*//')"
  if [[ "${command}" != "${executable}" ]]; then
    echo "${label}=refused-pid-identity-mismatch pid=${pid} command=${command}" >&2
    return 1
  fi

  kill -TERM "${pid}"
  for attempt in {1..40}; do
    if ! kill -0 "${pid}" 2>/dev/null; then
      echo "${label}=stopped pid=${pid}"
      return 0
    fi
    sleep 0.25
  done
  echo "${label}=still-running-after-10s pid=${pid}" >&2
  return 1
}

stop_one "${REVISION_ROOT}/runtime/local.msl.QuotaButton.Mock/quota-button.pid" \
  "${REVISION_ROOT}/test-candidates/QuotaButtonMock.app/Contents/MacOS/QuotaButtonMock" \
  "mock-button"
stop_one "${REVISION_ROOT}/runtime/local.msl.QuotaButton.MockHost/mock-host.pid" \
  "${REVISION_ROOT}/mock-host/QuotaButtonMockHost.app/Contents/MacOS/QuotaButtonMockHost" \
  "mock-host"
