#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CANDIDATE_ROOT="${OVERLAY_A_CANDIDATE_ROOT:-${PROJECT_ROOT}/build/overlay-a/candidates}"
CANDIDATE_ROOT="$(cd "${CANDIDATE_ROOT}" && pwd -P)"

OVERLAY_APP="${CANDIDATE_ROOT}/OverlayADemo.app"
HOST_APP="${CANDIDATE_ROOT}/OverlayADemoHost.app"
if [[ ! -d "${OVERLAY_APP}" || ! -d "${HOST_APP}" ]]; then
  echo "模拟候选不存在：${CANDIDATE_ROOT}" >&2
  exit 1
fi

OVERLAY_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${OVERLAY_APP}/Contents/Info.plist")"
HOST_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${HOST_APP}/Contents/Info.plist")"
if [[ "${OVERLAY_BUNDLE_ID}" != "org.openai.codex.QuotaOverlayA.Demo" || "${HOST_BUNDLE_ID}" != "org.openai.codex.QuotaOverlayA.DemoHost" ]]; then
  echo "候选 bundle ID 不匹配，拒绝停止：${OVERLAY_BUNDLE_ID} / ${HOST_BUNDLE_ID}" >&2
  exit 1
fi

RUNTIME_DIRECTORY_NAME="$(/usr/libexec/PlistBuddy -c 'Print :OverlayRuntimeDirectoryName' "${OVERLAY_APP}/Contents/Info.plist")"
HOST_RUNTIME_DIRECTORY_NAME="$(/usr/libexec/PlistBuddy -c 'Print :OverlayRuntimeDirectoryName' "${HOST_APP}/Contents/Info.plist")"
if [[ "${RUNTIME_DIRECTORY_NAME}" != "${HOST_RUNTIME_DIRECTORY_NAME}" || ! "${RUNTIME_DIRECTORY_NAME}" =~ ^[A-Za-z0-9._-]+$ || "${RUNTIME_DIRECTORY_NAME}" == "." || "${RUNTIME_DIRECTORY_NAME}" == ".." ]]; then
  echo "候选运行目录配置无效或不一致；拒绝停止。" >&2
  exit 1
fi

REVISION_ROOT="$(cd "${CANDIDATE_ROOT}/.." && pwd -P)"
RUNTIME_ROOT="${REVISION_ROOT}/${RUNTIME_DIRECTORY_NAME}"

stop_candidate() {
  local pid_file="$1"
  local expected_executable="$2"
  if [[ ! -f "${pid_file}" ]]; then
    echo "PID 文件不存在：${pid_file}"
    return 0
  fi
  local pid
  pid="$(tr -d '\r\n' < "${pid_file}")"
  if [[ ! "${pid}" =~ ^[0-9]+$ ]] || (( pid <= 1 )); then
    echo "PID 文件无效；保留文件且不发送信号：${pid_file}" >&2
    return 1
  fi
  local command
  command="$(ps -p "${pid}" -o command= 2>/dev/null || true)"
  if [[ "${command}" != "${expected_executable}" && "${command}" != "${expected_executable} "* ]]; then
    echo "PID ${pid} 的可执行路径与本候选不符；保留 PID 文件且不发送信号：${pid_file}" >&2
    return 1
  fi

  if ! kill -TERM "${pid}"; then
    echo "无法向本候选 PID ${pid} 发送 TERM；PID 文件保留。" >&2
    return 1
  fi

  local exit_attempt
  for ((exit_attempt = 0; exit_attempt < 50; exit_attempt++)); do
    if [[ -z "$(ps -p "${pid}" -o command= 2>/dev/null || true)" ]]; then
      local pid_cleanup_attempt
      for ((pid_cleanup_attempt = 0; pid_cleanup_attempt < 20; pid_cleanup_attempt++)); do
        [[ ! -e "${pid_file}" ]] && {
          echo "已停止本候选进程 PID ${pid}，进程已清理自己的 PID 文件。"
          return 0
        }
        sleep 0.1
      done
      echo "PID ${pid} 已退出但 PID 文件仍存在；脚本不会删除非进程所有者文件：${pid_file}" >&2
      return 1
    fi
    sleep 0.1
  done

  echo "本候选 PID ${pid} 收到 TERM 后未在 5 秒内退出。" >&2
  return 1
}

status=0
stop_candidate \
  "${RUNTIME_ROOT}/${OVERLAY_BUNDLE_ID}/overlay-a.pid" \
  "${OVERLAY_APP}/Contents/MacOS/OverlayA" || status=1
stop_candidate \
  "${RUNTIME_ROOT}/${HOST_BUNDLE_ID}/demo-host.pid" \
  "${HOST_APP}/Contents/MacOS/OverlayADemoHost" || status=1

if [[ "${status}" -eq 0 ]]; then
  echo "停止脚本仅按本 revision 的 PID 文件及精确候选可执行路径处理模拟 app；不会删除日志或 PID 文件。"
else
  echo "至少一个模拟进程未按预期停止；未清理任何 PID 文件或日志。" >&2
fi
exit "${status}"
