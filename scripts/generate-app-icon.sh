#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
SOURCE_PNG="${PROJECT_ROOT}/Resources/AppIcon.png"
OUTPUT_ICNS="${PROJECT_ROOT}/Resources/AppIcon.icns"

if [[ ! -f "${SOURCE_PNG}" ]]; then
  echo "Approved app icon not found: ${SOURCE_PNG}" >&2
  exit 1
fi

ICON_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/quota-app-icon.XXXXXX")"
trap 'rm -rf "${ICON_TEMP}"' EXIT
ICONSET="${ICON_TEMP}/AppIcon.iconset"
mkdir -p "${ICONSET}"

for size in 16 32 128 256 512; do
  /usr/bin/sips -z "${size}" "${size}" "${SOURCE_PNG}" \
    --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  /usr/bin/sips -z "${retina_size}" "${retina_size}" "${SOURCE_PNG}" \
    --out "${ICONSET}/icon_${size}x${size}@2x.png" >/dev/null
done

/usr/bin/iconutil -c icns "${ICONSET}" -o "${ICON_TEMP}/AppIcon.icns"
cp "${ICON_TEMP}/AppIcon.icns" "${OUTPUT_ICNS}"
echo "app_icon=${OUTPUT_ICNS}"
/usr/bin/shasum -a 256 "${SOURCE_PNG}" "${OUTPUT_ICNS}"
