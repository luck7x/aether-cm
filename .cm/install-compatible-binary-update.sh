#!/usr/bin/env bash
# Install an already verified CI binary and optional matching frontend.
# One service, the existing database,
# no builds, database backups, migrations, rehearsal instance, or blue-green.
set -Eeuo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
umask 077

readonly INSTALL_ROOT="${INSTALL_ROOT:-/opt/aether}"
readonly SERVICE="${AETHER_SERVICE:-aether-gateway}"
readonly ENV_FILE="${AETHER_ENV_FILE:-/etc/aether/aether-gateway.env}"
readonly STATE_ROOT="${AETHER_UPDATE_STATE_ROOT:-/root/aether-compatible-update}"
readonly BINARY="${AETHER_VERIFIED_BINARY:?Verified remote binary required}"
readonly BUILD_SHA="${AETHER_EXPECTED_BUILD_SHA:?Expected commit SHA required}"
readonly BINARY_SHA="${AETHER_EXPECTED_GATEWAY_SHA256:?Trusted binary digest required}"
readonly FRONTEND="${AETHER_VERIFIED_FRONTEND:-}"
readonly FRONTEND_SHA="${AETHER_EXPECTED_FRONTEND_SHA256:-}"
readonly RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
readonly STATE="${STATE_ROOT}/${RUN_ID}"
readonly OLD_TARGET="$(readlink -f "${INSTALL_ROOT}/current")"
readonly RELEASE="${INSTALL_ROOT}/releases/aether-compatible-${BUILD_SHA}-${RUN_ID}"
readonly SCRIPT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CUTOVER=0

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }
frontend_digest() (
  export LC_ALL=C
  cd -- "$1"
  find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d ' ' -f 1
)
health() {
  curl -fsS --max-time 3 "http://127.0.0.1:${APP_LISTEN_PORT}/health" >/dev/null 2>&1 &&
    curl -fsS --max-time 3 "http://127.0.0.1:${APP_LISTEN_PORT}/readyz" >/dev/null 2>&1
}
switch_to() {
  local temporary="${INSTALL_ROOT}/.compatible-switch-${RUN_ID}"
  ln -s "$1" "${temporary}"
  mv -Tf "${temporary}" "${INSTALL_ROOT}/current"
}
wait_healthy() {
  for _ in $(seq 1 45); do
    if systemctl is-active --quiet "${SERVICE}" && health; then return 0; fi
    sleep 2
  done
  return 1
}
rollback() {
  local result="${1:-1}"
  trap - ERR INT TERM
  if (( CUTOVER )); then
    log 'Update failed; restoring previous program automatically'
    if ! systemctl stop "${SERVICE}" || ! switch_to "${OLD_TARGET}"; then
      printf 'rollback_failed\n' > "${STATE}/STATUS"
      exit 1
    fi
    if systemctl start "${SERVICE}" && wait_healthy; then
      printf 'rolled_back\n' > "${STATE}/STATUS"
      log 'Previous program restored and healthy'
    else
      printf 'rollback_unhealthy\n' > "${STATE}/STATUS"
      log 'ERROR: previous program could not become healthy'
    fi
  fi
  exit "${result}"
}

[[ "$(id -u)" == 0 ]] || fail 'root required'
[[ "${BUILD_SHA}" =~ ^[0-9a-f]{40}$ && "${BINARY_SHA}" =~ ^[0-9a-f]{64}$ ]] || fail 'invalid provenance'
if [[ -n "${FRONTEND}${FRONTEND_SHA}" ]]; then
  [[ "${FRONTEND_SHA}" =~ ^[0-9a-f]{64}$ ]] || fail 'invalid frontend provenance'
  [[ -d "${FRONTEND}" && ! -L "${FRONTEND}" && -f "${FRONTEND}/index.html" ]] || fail 'invalid frontend directory'
  [[ -z "$(find "${FRONTEND}" ! -type f ! -type d -print -quit)" ]] || fail 'unexpected frontend entry'
  [[ "$(frontend_digest "${FRONTEND}")" == "${FRONTEND_SHA}" ]] || fail 'frontend checksum mismatch'
fi
exec 9>"${AETHER_INSTALL_LOCK:-/run/lock/aether-cm-install.lock}"
flock -n 9 || fail 'another deployment is running'
[[ -f "${ENV_FILE}" && -d "${OLD_TARGET}/frontend" && -x "${OLD_TARGET}/bin/aether-gateway" ]]
[[ -f "${BINARY}" && ! -L "${BINARY}" ]]
[[ -x "${SCRIPT_ROOT}/rollback-compatible-binary-update.sh" ]]

# The environment remains private. Never enable shell tracing.
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a
readonly APP_LISTEN_PORT="${APP_PORT:-8084}"
[[ "${APP_LISTEN_PORT}" =~ ^[0-9]+$ ]] || fail 'invalid listen port'
systemctl is-active --quiet "${SERVICE}"
health || fail 'current service is unhealthy'
[[ "$(sha256sum "${BINARY}" | cut -d ' ' -f 1)" == "${BINARY_SHA}" ]] || fail 'binary checksum mismatch'
readonly AVAILABLE_BYTES="$(( $(df -Pk "${INSTALL_ROOT}" | awk 'NR==2 {print $4}') * 1024 ))"
readonly BINARY_BYTES="$(stat -c %s "${BINARY}")"
frontend_bytes=0
if [[ -n "${FRONTEND}" ]]; then
  frontend_bytes="$(du -sb -- "${FRONTEND}" | cut -f1)"
fi
(( AVAILABLE_BYTES > BINARY_BYTES + frontend_bytes + 256 * 1024 * 1024 )) || fail 'insufficient free disk'
install -d -m 0700 "${STATE_ROOT}" "${STATE}"
install -d -m 0755 "${INSTALL_ROOT}/releases"
mkdir -m 0755 "${RELEASE}"
mkdir -m 0755 "${RELEASE}/bin"
install -m 0555 "${BINARY}" "${RELEASE}/bin/aether-gateway"
[[ "$(sha256sum "${RELEASE}/bin/aether-gateway" | cut -d ' ' -f 1)" == "${BINARY_SHA}" ]]
if [[ -n "${FRONTEND}" ]]; then
  mkdir -m 0755 "${RELEASE}/frontend"
  cp -R -- "${FRONTEND}/." "${RELEASE}/frontend/"
  find "${RELEASE}/frontend" -type d -exec chmod 0555 {} +
  find "${RELEASE}/frontend" -type f -exec chmod 0444 {} +
  [[ "$(frontend_digest "${RELEASE}/frontend")" == "${FRONTEND_SHA}" ]] || fail 'copied frontend checksum mismatch'
else
  ln -s "${OLD_TARGET}/frontend" "${RELEASE}/frontend"
fi
printf 'git_sha=%s\n' "${BUILD_SHA}" > "${RELEASE}/BUILD_INFO"

log 'Checking database compatibility without migrations or a database backup'
"${RELEASE}/bin/aether-gateway" db status > "${STATE}/db-status.log" 2>&1
grep -Fxq 'database postgres: ready (schema and backfills are current)' "${STATE}/db-status.log" || fail 'this installer requires current migrations and backfills'
[[ "$(readlink -f "${INSTALL_ROOT}/current")" == "${OLD_TARGET}" ]]
{
  printf 'INSTALL_ROOT=%q\n' "${INSTALL_ROOT}"
  printf 'SERVICE=%q\n' "${SERVICE}"
  printf 'APP_LISTEN_PORT=%q\n' "${APP_LISTEN_PORT}"
  printf 'OLD_TARGET=%q\n' "${OLD_TARGET}"
  printf 'NEW_TARGET=%q\n' "${RELEASE}"
  printf 'BUILD_SHA=%q\n' "${BUILD_SHA}"
} > "${STATE}/rollback.env"
install -m 0700 "${SCRIPT_ROOT}/rollback-compatible-binary-update.sh" "${STATE}/rollback.sh"
trap 'rollback "$?"' ERR
trap 'rollback 130' INT TERM

log 'Restarting the single service with the verified binary'
CUTOVER=1
systemctl stop "${SERVICE}"
switch_to "${RELEASE}"
systemctl start "${SERVICE}"
wait_healthy
for _ in 1 2 3; do
  systemctl is-active --quiet "${SERVICE}"
  health
  sleep 2
done
if [[ -n "${FRONTEND}" ]]; then
  log 'Verifying the new release serves its frontend'
  curl -fsS --max-time 5 "http://127.0.0.1:${APP_LISTEN_PORT}/" |
    cmp -s "${RELEASE}/frontend/index.html" -
fi
[[ "$(readlink -f "${INSTALL_ROOT}/current")" == "${RELEASE}" ]]
readonly NEW_PID="$(systemctl show "${SERVICE}" -p MainPID --value)"
[[ "${NEW_PID}" =~ ^[1-9][0-9]*$ ]]
[[ "$(sha256sum "/proc/${NEW_PID}/exe" | cut -d ' ' -f 1)" == "${BINARY_SHA}" ]]
printf 'success\n' > "${STATE}/STATUS"
printf '%s\n' "${STATE}" > "${STATE_ROOT}/last-success.new"
mv -Tf "${STATE_ROOT}/last-success.new" "${STATE_ROOT}/last-success"
trap - ERR INT TERM
log "Update healthy; previous program retained. Rollback: ${STATE}/rollback.sh"
