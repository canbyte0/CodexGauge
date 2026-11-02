#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
REVISION_ROOT="${PROJECT_ROOT}/build/independent-quota-window/revisions/w1-c2"
CANDIDATE_ROOT="${QUOTA_WINDOW_CANDIDATE_ROOT:-${REVISION_ROOT}/candidates}"
BUNDLE_ID="local.msl.QuotaWindow.Demo"
EXPECTED_VERSION="0.1.0-w1-c2"

if [[ ! -d "${CANDIDATE_ROOT}" ]]; then
  echo "W1 candidate directory not found: ${CANDIDATE_ROOT}" >&2
  exit 1
fi
CANDIDATE_ROOT="$(cd "${CANDIDATE_ROOT}" && pwd -P)"
APP_PATH="${CANDIDATE_ROOT}/QuotaWindowDemo.app"
EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/QuotaWindowDemo"
if [[ ! -d "${APP_PATH}" || ! -x "${EXECUTABLE_PATH}" ]]; then
  echo "W1 candidate is incomplete: ${APP_PATH}" >&2
  exit 1
fi

ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP_PATH}/Contents/Info.plist")"
ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist")"
RUNTIME_DIRECTORY_NAME="$(/usr/libexec/PlistBuddy -c 'Print :OverlayRuntimeDirectoryName' "${APP_PATH}/Contents/Info.plist")"
if [[ "${ACTUAL_BUNDLE_ID}" != "${BUNDLE_ID}" || "${ACTUAL_VERSION}" != "${EXPECTED_VERSION}" || ! "${RUNTIME_DIRECTORY_NAME}" =~ ^[A-Za-z0-9._-]+$ || "${RUNTIME_DIRECTORY_NAME}" == "." || "${RUNTIME_DIRECTORY_NAME}" == ".." ]]; then
  echo "Candidate identity or runtime directory is invalid; refusing to signal." >&2
  exit 1
fi

REVISION_ROOT="$(cd "${CANDIDATE_ROOT}/.." && pwd -P)"
PID_FILE="${REVISION_ROOT}/${RUNTIME_DIRECTORY_NAME}/${BUNDLE_ID}/quota-window.pid"
if [[ ! -f "${PID_FILE}" ]]; then
  echo "No W1 PID file; nothing was signaled: ${PID_FILE}"
  exit 0
fi

PID="$(tr -d '\r\n' < "${PID_FILE}")"
if [[ ! "${PID}" =~ ^[0-9]+$ ]] || (( PID <= 1 )); then
  echo "Invalid PID file; retained without signaling: ${PID_FILE}" >&2
  exit 1
fi

process_command() {
  /bin/ps -p "$1" -o command= 2>/dev/null || true
}

COMMAND="$(process_command "${PID}")"
if [[ "${COMMAND}" != "${EXECUTABLE_PATH}" && "${COMMAND}" != "${EXECUTABLE_PATH} "* ]]; then
  echo "PID ${PID} does not resolve to this exact candidate; retained without signaling." >&2
  exit 1
fi

if ! kill -TERM "${PID}"; then
  echo "Could not send TERM to verified W1 PID ${PID}; PID file retained." >&2
  exit 1
fi

for ((attempt = 0; attempt < 50; attempt++)); do
  if [[ -z "$(process_command "${PID}")" ]]; then
    for ((cleanup_attempt = 0; cleanup_attempt < 20; cleanup_attempt++)); do
      if [[ ! -e "${PID_FILE}" ]]; then
        echo "W1 PID ${PID} exited and removed its own PID file."
        exit 0
      fi
      sleep 0.1
    done
    echo "W1 PID ${PID} exited but its PID file remains; the script will not remove it." >&2
    exit 1
  fi
  sleep 0.1
done

echo "W1 PID ${PID} did not exit within five seconds after TERM." >&2
exit 1
