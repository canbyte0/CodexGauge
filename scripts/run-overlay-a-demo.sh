#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CANDIDATE_ROOT="${OVERLAY_A_CANDIDATE_ROOT:-${PROJECT_ROOT}/build/overlay-a/candidates}"

if [[ ! -d "${CANDIDATE_ROOT}/OverlayADemoHost.app" || ! -d "${CANDIDATE_ROOT}/OverlayADemo.app" ]]; then
  echo "候选不存在；先运行 ./scripts/build-overlay-a.sh" >&2
  exit 1
fi
CANDIDATE_ROOT="$(cd "${CANDIDATE_ROOT}" && pwd -P)"

/usr/bin/open -n "${CANDIDATE_ROOT}/OverlayADemoHost.app"
/usr/bin/open -n "${CANDIDATE_ROOT}/OverlayADemo.app"
echo "已启动空白模拟宿主和 Overlay A 模拟候选；不连接真实额度。"
