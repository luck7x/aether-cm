#!/usr/bin/env bash
# Restore the previous program only. Never restore or modify the database.
set -Eeuo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
umask 077
readonly STATE="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
[[ "$(id -u)" == 0 && -f "${STATE}/rollback.env" ]]
exec 9>"${AETHER_INSTALL_LOCK:-/run/lock/aether-cm-install.lock}"
flock -n 9
# shellcheck disable=SC1091
source "${STATE}/rollback.env"
[[ "$(readlink -f "${INSTALL_ROOT}/current")" == "${NEW_TARGET}" ]]
[[ -x "${OLD_TARGET}/bin/aether-gateway" && -d "${OLD_TARGET}/frontend" ]]
temporary="${INSTALL_ROOT}/.compatible-rollback-$$"
ln -s "${OLD_TARGET}" "${temporary}"
systemctl stop "${SERVICE}"
mv -Tf "${temporary}" "${INSTALL_ROOT}/current"
systemctl start "${SERVICE}"
for _ in $(seq 1 45); do
  if systemctl is-active --quiet "${SERVICE}" &&
     curl -fsS --max-time 3 "http://127.0.0.1:${APP_LISTEN_PORT}/health" >/dev/null 2>&1 &&
     curl -fsS --max-time 3 "http://127.0.0.1:${APP_LISTEN_PORT}/readyz" >/dev/null 2>&1; then
    printf 'manually_rolled_back\n' > "${STATE}/STATUS"
    echo 'Previous program restored; database unchanged.'
    exit 0
  fi
  sleep 2
done
echo 'Previous program did not become healthy' >&2
exit 1
