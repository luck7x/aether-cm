#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 USER@VPS /path/to/aether-*.tar.gz" >&2
  exit 1
fi

REMOTE="$1"
ARCHIVE="$(realpath "$2")"
ARCHIVE_NAME="$(basename "${ARCHIVE}")"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
REMOTE_DIR="/root/aether-cm-upload-${RUN_ID}"

[[ -f "${ARCHIVE}" ]]

echo '[1/3] Creating remote upload directory'
ssh "${REMOTE}" "install -d -m 0700 '${REMOTE_DIR}'"

echo '[2/3] Uploading bundle'
scp "${ARCHIVE}" "${REMOTE}:${REMOTE_DIR}/${ARCHIVE_NAME}"

echo '[3/3] Installing bundle on VPS'
ssh -t "${REMOTE}" "set -e; tar -xzf '${REMOTE_DIR}/${ARCHIVE_NAME}' -C '${REMOTE_DIR}'; installer=\$(find '${REMOTE_DIR}' -mindepth 2 -maxdepth 2 -name install-vps-bundle.sh -type f | head -n1); test -n \"\${installer}\"; chmod 0700 \"\${installer}\"; \"\${installer}\""

