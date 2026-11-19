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
wait_healthy() {
  for _ in $(seq 1 45); do
    if systemctl is-active --quiet "${SERVICE}" &&
       curl -fsS --max-time 3 "http://127.0.0.1:${APP_LISTEN_PORT}/health" >/dev/null 2>&1 &&
       curl -fsS --max-time 3 "http://127.0.0.1:${APP_LISTEN_PORT}/readyz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}
recover_new() {
  local result="${1:-1}"
  trap - ERR INT TERM
  echo 'Rollback failed; recovering the newer program' >&2
  local recovery="${INSTALL_ROOT}/.compatible-recover-$$"
  if systemctl stop "${SERVICE}" &&
     ln -s "${NEW_TARGET}" "${recovery}" &&
     mv -Tf "${recovery}" "${INSTALL_ROOT}/current" &&
     systemctl start "${SERVICE}" && wait_healthy; then
    printf 'rollback_failed_recovered_new\n' > "${STATE}/STATUS"
  else
    printf 'rollback_recovery_failed\n' > "${STATE}/STATUS"
    echo 'ERROR: recovery of the newer program failed' >&2
  fi
  exit "${result}"
}
temporary="${INSTALL_ROOT}/.compatible-rollback-$$"
ln -s "${OLD_TARGET}" "${temporary}"
trap 'recover_new "$?"' ERR
trap 'recover_new 130' INT TERM
systemctl stop "${SERVICE}"
mv -Tf "${temporary}" "${INSTALL_ROOT}/current"
systemctl start "${SERVICE}"
wait_healthy
printf 'manually_rolled_back\n' > "${STATE}/STATUS"
trap - ERR INT TERM
echo 'Previous program restored; database unchanged.'
