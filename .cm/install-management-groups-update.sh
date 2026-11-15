#!/usr/bin/env bash
# Install prebuilt artifacts only. Run as a detached systemd oneshot on production.
# This installer is intentionally limited to the additive management-groups migration.
set -Eeuo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
umask 077

readonly INSTALL_ROOT="${INSTALL_ROOT:-/opt/aether}"
readonly ENV_FILE="${AETHER_ENV_FILE:-/etc/aether/aether-gateway.env}"
readonly SERVICE="${AETHER_SERVICE:-aether-gateway}"
readonly BUNDLE="${AETHER_BUNDLE_ROOT:?AETHER_BUNDLE_ROOT must point to a verified remote bundle}"
readonly BUILD_SHA="${AETHER_EXPECTED_BUILD_SHA:?AETHER_EXPECTED_BUILD_SHA is required}"
readonly EXPECTED_GATEWAY_SHA="${AETHER_EXPECTED_GATEWAY_SHA256:?Trusted CI binary digest required}"
readonly EXPECTED_FRONTEND_SHA="${AETHER_EXPECTED_FRONTEND_SHA256:?Trusted CI frontend digest required}"
readonly EXPECTED_MIGRATION_CHECKSUM="${AETHER_EXPECTED_MIGRATION_CHECKSUM:?Trusted CI migration checksum required}"
readonly RUN_ID="$(date +%Y%m%d-%H%M%S-%N)-$$"
readonly BACKUP="/root/aether-backups/management-groups-${RUN_ID}"
readonly RELEASE="${INSTALL_ROOT}/releases/aether-cm-${BUILD_SHA}-linux-amd64-${RUN_ID}"
readonly OLD_TARGET="$(readlink -f "${INSTALL_ROOT}/current")"
readonly MIGRATION=20261115000000
readonly SCRIPT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CUTOVER=0
MIGRATION_ADDED=0

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }
[[ "$(id -u)" == 0 ]] || fail 'root required'
[[ "${BUILD_SHA}" =~ ^[0-9a-f]{40}$ ]] || fail 'invalid build SHA'
[[ "${EXPECTED_MIGRATION_CHECKSUM}" =~ ^[0-9a-f]{96}$ ]] || fail 'invalid migration checksum'
exec 9>/run/lock/aether-cm-install.lock
flock -n 9 || fail 'another deployment is running'

# Environment stays local and is never printed. Do not enable shell tracing.
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a
DATABASE_CONNECTION="${AETHER_DATABASE_URL:-${AETHER_GATEWAY_DATA_POSTGRES_URL:-${DATABASE_URL:-}}}"
[[ "${DATABASE_CONNECTION}" == postgres://* || "${DATABASE_CONNECTION}" == postgresql://* ]] || fail 'Postgres URL required'
APP_LISTEN_PORT="${APP_PORT:-8084}"
install -d -m 0700 "$(dirname "${BACKUP}")"
mkdir -m 0700 "${BACKUP}"
CONNECTION_FILE="${BACKUP}/postgres.service.conf"
trap 'rm -f -- "${CONNECTION_FILE}"' EXIT
AETHER_DEPLOY_DATABASE_CONNECTION="${DATABASE_CONNECTION}" python3 "${SCRIPT_ROOT}/prepare-deploy-postgres.py" "${CONNECTION_FILE}"
export PGSERVICEFILE="${CONNECTION_FILE}"
export PGSERVICE=aether_management_update
psql_app() { psql --dbname='service=aether_management_update' -X -v ON_ERROR_STOP=1 "$@"; }
health() {
  curl -fsS --max-time 5 "http://127.0.0.1:${APP_LISTEN_PORT}/health" >/dev/null 2>&1 &&
    curl -fsS --max-time 5 "http://127.0.0.1:${APP_LISTEN_PORT}/readyz" >/dev/null 2>&1
}
rollback() {
  local rc="${1:-1}"
  trap - ERR INT TERM
  if (( CUTOVER )); then
    log 'Deployment failed; restoring old binary and migration ledger automatically'
    systemctl stop "${SERVICE}" || true
    # This migration only inserted an independent configuration record. Keep it
    # (and any saved groups) while removing its ledger entry for the old binary.
    if (( MIGRATION_ADDED )); then
      # A failed --migrate may have committed or may have rolled back. Remove
      # only the marker matching the trusted migration bytes, then verify the
      # complete original ledger before starting the previous binary.
      if ! psql_app -qc "DELETE FROM public._sqlx_migrations WHERE version = ${MIGRATION} AND encode(checksum, 'hex')='${EXPECTED_MIGRATION_CHECKSUM}'" ||
         ! psql_app -Atqc "SELECT version, encode(checksum, 'hex'), success FROM public._sqlx_migrations ORDER BY version" > "${BACKUP}/ledger.rollback-check" ||
         ! cmp "${BACKUP}/ledger.before" "${BACKUP}/ledger.rollback-check"; then
        log 'CRITICAL: migration ledger rollback failed; keeping service stopped'
        printf 'rollback_failed\n' > "${BACKUP}/STATUS"
        exit 1
      fi
    fi
    if [[ ! -x "${OLD_TARGET}/bin/aether-gateway" ]] ||
       ! ln -s "${OLD_TARGET}" "${INSTALL_ROOT}/.rollback-${RUN_ID}" ||
       ! mv -Tf "${INSTALL_ROOT}/.rollback-${RUN_ID}" "${INSTALL_ROOT}/current"; then
      printf 'rollback_failed\n' > "${BACKUP}/STATUS"
      log "CRITICAL: release link rollback failed; backup: ${BACKUP}"
      exit 1
    fi
    systemctl start "${SERVICE}" || true
    for _ in $(seq 1 60); do
      if health; then
        printf 'rolled_back\n' > "${BACKUP}/STATUS"
        log "Old version healthy; backup: ${BACKUP}"
        exit "${rc}"
      fi
      sleep 2
    done
    printf 'rollback_unhealthy\n' > "${BACKUP}/STATUS"
    log "CRITICAL: old version health check failed; backup: ${BACKUP}"
  fi
  exit "${rc}"
}
trap 'rollback "$?"' ERR
trap 'rollback 130' INT TERM

log 'Verifying remote bundle, running service and migration preconditions'
[[ -d "${OLD_TARGET}" && -f "${BUNDLE}/frontend/index.html" ]]
systemctl is-active --quiet "${SERVICE}"
health
grep -qx "git_sha=${BUILD_SHA}" "${BUNDLE}/BUILD_INFO"
BUNDLE_BYTES="$(du -sb "${BUNDLE}" | awk '{print $1}')"
AVAILABLE_RELEASE="$(( $(df -Pk "${INSTALL_ROOT}" | awk 'NR==2 {print $4}') * 1024 ))"
(( AVAILABLE_RELEASE >= BUNDLE_BYTES + 256 * 1024 * 1024 )) || fail 'not enough release filesystem space before copying'
# Copy once into a unique root-owned release, reject links/special files, then
# verify externally supplied CI digests and execute only the immutable copy.
[[ -f "${BUNDLE}/bin/aether-gateway" && ! -L "${BUNDLE}/bin/aether-gateway" && ! -L "${BUNDLE}/frontend" ]]
[[ -z "$(find "${BUNDLE}/frontend" ! -type f ! -type d -print -quit)" ]]
install -d -m 0755 "${INSTALL_ROOT}/releases"
mkdir -m 0755 "${RELEASE}"
mkdir -m 0755 "${RELEASE}/bin" "${RELEASE}/frontend"
install -m 0555 "${BUNDLE}/bin/aether-gateway" "${RELEASE}/bin/aether-gateway"
cp -a "${BUNDLE}/frontend/." "${RELEASE}/frontend/"
chown -R root:root "${RELEASE}"
find "${RELEASE}/frontend" -type d -exec chmod 0555 {} +
find "${RELEASE}/frontend" -type f -exec chmod 0444 {} +

[[ "${EXPECTED_GATEWAY_SHA}" =~ ^[0-9a-f]{64}$ && "${EXPECTED_FRONTEND_SHA}" =~ ^[0-9a-f]{64}$ ]]
[[ "$(sha256sum "${RELEASE}/bin/aether-gateway" | awk '{print $1}')" == "${EXPECTED_GATEWAY_SHA}" ]] || fail 'binary differs from trusted CI artifact'
FRONTEND_SHA="$(cd "${RELEASE}/frontend" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
[[ "${FRONTEND_SHA}" == "${EXPECTED_FRONTEND_SHA}" ]] || fail 'frontend differs from trusted CI artifact'
# Read-only introspection from this exact verified binary catches missing old
# migrations and additional new migrations before anything is stopped or changed.
"${RELEASE}/bin/aether-gateway" db status > "${BACKUP}/preflight-db-status.log" 2>&1
grep -Fxq 'pending migrations: 1' "${BACKUP}/preflight-db-status.log" || fail 'expected exactly one pending migration'
grep -Fxq 'next migration: 20261115000000 (provider management groups)' "${BACKUP}/preflight-db-status.log" || fail 'unexpected pending migration'
"${RELEASE}/bin/aether-gateway" --help >/dev/null
# Refuse any database state that could cause other pending migrations to run.
[[ "$(psql_app -Atqc 'SELECT max(version) FROM public._sqlx_migrations WHERE success')" == 20261009000000 ]]
[[ "$(psql_app -Atqc 'SELECT count(*) FROM public._sqlx_migrations WHERE NOT success')" == 0 ]]
[[ "$(psql_app -Atqc "SELECT count(*) FROM public._sqlx_migrations WHERE version=${MIGRATION}")" == 0 ]]
DATABASE_NAME="$(psql_app -Atqc 'SELECT current_database()')"
[[ "${DATABASE_NAME}" =~ ^[A-Za-z_][A-Za-z0-9_\$]*$ ]]
DB_SERVER_PORT="$(psql_app -Atqc "SELECT current_setting('port')")"
IDENTITY_SQL="SELECT pg_postmaster_start_time()::text, current_setting('port'), oid FROM pg_database WHERE datname=current_database()"
APP_DB_IDENTITY="$(psql_app -Atqc "${IDENTITY_SQL}")"
PEER_DB_IDENTITY="$(runuser -u postgres -- psql -h /var/run/postgresql -p "${DB_SERVER_PORT}" -X -v ON_ERROR_STOP=1 -d "${DATABASE_NAME}" -Atqc "${IDENTITY_SQL}")"
[[ "${APP_DB_IDENTITY}" == "${PEER_DB_IDENTITY}" ]] || fail 'backup connection points to a different database instance'
DATABASE_BYTES="$(psql_app -Atqc 'SELECT pg_database_size(current_database())')"
BUNDLE_BYTES="$(du -sb "${BUNDLE}" | awk '{print $1}')"
AVAILABLE_BACKUP="$(( $(df -Pk "${BACKUP}" | awk 'NR==2 {print $4}') * 1024 ))"
AVAILABLE_RELEASE="$(( $(df -Pk "${INSTALL_ROOT}" | awk 'NR==2 {print $4}') * 1024 ))"
(( AVAILABLE_BACKUP >= DATABASE_BYTES + BUNDLE_BYTES + 512 * 1024 * 1024 )) || fail 'not enough backup filesystem space'
(( AVAILABLE_RELEASE >= BUNDLE_BYTES + 256 * 1024 * 1024 )) || fail 'not enough release filesystem space'

install -d -m 0700 "${BACKUP}"
cp -a "${ENV_FILE}" "${BACKUP}/environment.before"
printf '%s\n' "${OLD_TARGET}" > "${BACKUP}/old-release"
psql_app -Atqc 'SELECT version FROM public._sqlx_migrations ORDER BY version' > "${BACKUP}/migrations.before"
psql_app -Atqc "SELECT version, encode(checksum, 'hex'), success FROM public._sqlx_migrations ORDER BY version" > "${BACKUP}/ledger.before"

log 'Taking online database backup; existing service remains available'
runuser -u postgres -- pg_dump -h /var/run/postgresql -p "${DB_SERVER_PORT}" --format=custom --compress=6 --no-owner --no-acl --dbname="${DATABASE_NAME}" > "${BACKUP}/database.dump"
[[ -s "${BACKUP}/database.dump" ]]
pg_restore --list "${BACKUP}/database.dump" > "${BACKUP}/database.list"
(cd "${BACKUP}" && sha256sum database.dump > SHA256SUMS)

log 'Starting brief maintenance window; all following steps are autonomous'
CUTOVER=1
systemctl stop "${SERVICE}"
[[ "$(systemctl is-active "${SERVICE}" || true)" != active ]]
# Set before --migrate: rollback also covers a command that commits then fails.
MIGRATION_ADDED=1
"${RELEASE}/bin/aether-gateway" --migrate
psql_app -Atqc 'SELECT version FROM public._sqlx_migrations ORDER BY version' > "${BACKUP}/migrations.after"
{ cat "${BACKUP}/migrations.before"; printf '%s\n' "${MIGRATION}"; } > "${BACKUP}/migrations.expected"
diff -u "${BACKUP}/migrations.expected" "${BACKUP}/migrations.after"
[[ "$(psql_app -Atqc "SELECT count(*) FROM public._sqlx_migrations WHERE version=${MIGRATION} AND success")" == 1 ]]
psql_app -Atqc "SELECT version, encode(checksum, 'hex'), success FROM public._sqlx_migrations ORDER BY version" > "${BACKUP}/ledger.after"
psql_app -Atqc "SELECT row_to_json(m)::text FROM public._sqlx_migrations m WHERE version=${MIGRATION}" > "${BACKUP}/migration.record.json"
[[ "$(psql_app -Atqc "SELECT count(*) FROM system_configs WHERE key='provider_management_groups' AND json_typeof(value)='string'")" == 1 ]]
ln -s "${RELEASE}" "${INSTALL_ROOT}/.update-${RUN_ID}"
mv -Tf "${INSTALL_ROOT}/.update-${RUN_ID}" "${INSTALL_ROOT}/current"
systemctl start "${SERVICE}"

log 'Waiting for health, readiness and management route authentication checks'
HEALTHY=0
for _ in $(seq 1 90); do
  if health; then HEALTHY=1; break; fi
  sleep 2
done
[[ "${HEALTHY}" == 1 ]]
AUTH_STATUS="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${APP_LISTEN_PORT}/api/admin/provider-management-groups")"
[[ "${AUTH_STATUS}" == 401 || "${AUTH_STATUS}" == 403 ]]
STABLE_PID="$(systemctl show -p MainPID --value "${SERVICE}")"
[[ "${STABLE_PID}" =~ ^[1-9][0-9]*$ ]]
for attempt in $(seq 1 12); do
  sleep 5
  systemctl is-active --quiet "${SERVICE}"
  health
  [[ "$(systemctl show -p MainPID --value "${SERVICE}")" == "${STABLE_PID}" ]]
  log "Health observation ${attempt}/12"
done
MIGRATION_CHECKSUM="$(psql_app -Atqc "SELECT encode(checksum, 'hex') FROM public._sqlx_migrations WHERE version=${MIGRATION} AND success")"
[[ "${MIGRATION_CHECKSUM}" == "${EXPECTED_MIGRATION_CHECKSUM}" ]]
install -m 0500 "${SCRIPT_ROOT}/rollback-management-groups-update.sh" /root/aether-management-groups-rollback.sh
install -m 0500 "${SCRIPT_ROOT}/prepare-deploy-postgres.py" "${BACKUP}/prepare-deploy-postgres.py"
{
  printf 'INSTALL_ROOT=%q\n' "${INSTALL_ROOT}"
  printf 'ENV_FILE=%q\n' "${ENV_FILE}"
  printf 'SERVICE=%q\n' "${SERVICE}"
  printf 'PREVIOUS_RELEASE=%q\n' "${OLD_TARGET}"
  printf 'NEW_RELEASE=%q\n' "${RELEASE}"
  printf 'MIGRATION_CHECKSUM=%q\n' "${MIGRATION_CHECKSUM}"
  printf 'BACKUP=%q\n' "${BACKUP}"
} > /root/aether-management-groups-last-success.env.new
chmod 0600 /root/aether-management-groups-last-success.env.new
mv -Tf /root/aether-management-groups-last-success.env.new /root/aether-management-groups-last-success.env
printf 'success\n' > "${BACKUP}/STATUS"
printf 'release=%s\nprevious=%s\nbuild_sha=%s\n' "${RELEASE}" "${OLD_TARGET}" "${BUILD_SHA}" > "${BACKUP}/RESULT"
CUTOVER=0
trap - ERR INT TERM
log "Deployment succeeded; old release and database backup retained: ${BACKUP}"
