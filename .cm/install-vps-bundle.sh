#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_ROOT="${INSTALL_ROOT:-/opt/aether}"
ENV_FILE="${AETHER_ENV_FILE:-/etc/aether/aether-gateway.env}"
SERVICE="${AETHER_SERVICE:-aether-gateway}"
BUNDLE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
VERSION_NAME="$(basename "${BUNDLE_ROOT}")"
RELEASE="${INSTALL_ROOT}/releases/${VERSION_NAME}-${RUN_ID}"
BACKUP_DIR="/root/aether-backups/pre-${VERSION_NAME}-${RUN_ID}"
OLD_TARGET="$(readlink -f "${INSTALL_ROOT}/current")"
CUTOVER_STARTED=0

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

rollback() {
  local exit_code=$?
  trap - ERR
  log "Install failed with exit code ${exit_code}"

  if [[ "${CUTOVER_STARTED}" == "1" ]]; then
    log "Rolling back to ${OLD_TARGET}"
    systemctl stop "${SERVICE}" || true
    ln -sfn "${OLD_TARGET}" "${INSTALL_ROOT}/current.rollback"
    mv -Tf "${INSTALL_ROOT}/current.rollback" "${INSTALL_ROOT}/current"
    systemctl start "${SERVICE}" || true
  fi

  log "Database backup retained at ${BACKUP_DIR}"
  exit "${exit_code}"
}

trap rollback ERR

exec 9>/run/lock/aether-cm-install.lock
flock -n 9 || {
  log 'Another Aether install is already running.'
  exit 1
}

[[ "$(id -u)" == "0" ]]
[[ "$(uname -m)" == "x86_64" ]]
[[ -x "${BUNDLE_ROOT}/bin/aether-gateway" ]]
[[ -f "${BUNDLE_ROOT}/frontend/index.html" ]]
[[ -f "${ENV_FILE}" ]]
[[ -d "${OLD_TARGET}" ]]
systemctl is-active --quiet "${SERVICE}"

set -a
source "${ENV_FILE}"
set +a
: "${DATABASE_URL:?DATABASE_URL is not configured}"
APP_PORT="${APP_PORT:-8084}"

log "Backing up PostgreSQL and environment configuration"
install -d -m 0700 "${BACKUP_DIR}"
install -m 0600 "${ENV_FILE}" "${BACKUP_DIR}/aether-gateway.env"
pg_dump \
  --format=custom \
  --compress=6 \
  --no-owner \
  --no-acl \
  --file="${BACKUP_DIR}/aether-postgres.dump" \
  "${DATABASE_URL}"
chmod 0600 "${BACKUP_DIR}/aether-postgres.dump"
pg_restore --list "${BACKUP_DIR}/aether-postgres.dump" >/dev/null

log "Installing bundle into ${RELEASE}"
install -d -m 2775 -o root -g aether "${RELEASE}/bin" "${RELEASE}/frontend"
install -m 0775 -o root -g aether \
  "${BUNDLE_ROOT}/bin/aether-gateway" \
  "${RELEASE}/bin/aether-gateway"
cp -a "${BUNDLE_ROOT}/frontend/." "${RELEASE}/frontend/"
chown -R root:aether "${RELEASE}"
find "${RELEASE}/frontend" -type d -exec chmod 0775 {} +
find "${RELEASE}/frontend" -type f -exec chmod 0664 {} +
"${RELEASE}/bin/aether-gateway" --help >/dev/null

log 'Stopping Aether and switching release'
CUTOVER_STARTED=1
systemctl stop "${SERVICE}"
ln -sfn "${RELEASE}" "${INSTALL_ROOT}/current.new"
mv -Tf "${INSTALL_ROOT}/current.new" "${INSTALL_ROOT}/current"
systemctl start "${SERVICE}"

log 'Waiting for health checks'
healthy=0
for attempt in $(seq 1 45); do
  if curl -fsS --max-time 3 "http://127.0.0.1:${APP_PORT}/health" >/dev/null 2>&1 && \
     curl -fsS --max-time 3 "http://127.0.0.1:${APP_PORT}/readyz" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  log "Waiting for Aether (${attempt}/45)"
  sleep 2
done

[[ "${healthy}" == "1" ]]
systemctl is-active --quiet "${SERVICE}"
[[ "$(readlink -f "${INSTALL_ROOT}/current")" == "${RELEASE}" ]]

CUTOVER_STARTED=0
log "Install complete: ${RELEASE}"
log "Database backup: ${BACKUP_DIR}"
log "Rollback release: ${OLD_TARGET}"

