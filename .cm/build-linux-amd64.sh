#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "${ROOT}"

if [[ "$(uname -s)" != "Linux" || "$(uname -m)" != "x86_64" ]]; then
  echo "This script must run on Linux x86_64 (WSL2 Ubuntu is supported)." >&2
  exit 1
fi

for command_name in git node npm cargo tar sha256sum; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "Missing command: ${command_name}" >&2
    exit 1
  }
done

GIT_SHA="$(git rev-parse --short=12 HEAD)"
BUILD_VERSION="${AETHER_BUILD_VERSION:-cm-${GIT_SHA}}"
OUTPUT_ROOT="${CM_OUTPUT_ROOT:-${ROOT}/dist-cm}"
PACKAGE_NAME="aether-${BUILD_VERSION}-linux-amd64"
PACKAGE_ROOT="${OUTPUT_ROOT}/${PACKAGE_NAME}"
ARCHIVE="${OUTPUT_ROOT}/${PACKAGE_NAME}.tar.gz"

rm -rf "${PACKAGE_ROOT}"
mkdir -p "${PACKAGE_ROOT}/bin" "${PACKAGE_ROOT}/frontend"

echo '[1/7] Installing aether-vscodex web dependencies'
cd "${ROOT}/aether-vscodex/web"
npm ci

echo '[2/7] Installing Aether frontend dependencies'
cd "${ROOT}/frontend"
npm ci

echo '[3/7] Running model-permission regression test'
npm run test:run -- \
  src/features/providers/components/__tests__/KeyAllowedModelsEditDialog.loading.spec.ts

echo '[4/7] Building frontend (including embedded aether-vscodex web)'
NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=4096}" \
AETHER_BUILD_VERSION="${BUILD_VERSION}" \
  npm run build

echo '[5/7] Building Linux amd64 gateway'
cd "${ROOT}"
if [[ "${CM_LOW_MEMORY:-0}" == "1" ]]; then
  AETHER_BUILD_VERSION="${BUILD_VERSION}" \
  AETHER_BUILD_TYPE="source" \
  CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-1}" \
  CARGO_PROFILE_RELEASE_LTO="false" \
  CARGO_PROFILE_RELEASE_CODEGEN_UNITS="16" \
    cargo build --release --locked -p aether-gateway
else
  AETHER_BUILD_VERSION="${BUILD_VERSION}" \
  AETHER_BUILD_TYPE="source" \
    cargo build --release --locked -p aether-gateway
fi

echo '[6/7] Assembling release bundle'
install -m 0755 "${ROOT}/target/release/aether-gateway" "${PACKAGE_ROOT}/bin/aether-gateway"
cp -a "${ROOT}/frontend/dist/." "${PACKAGE_ROOT}/frontend/"
install -m 0755 "${ROOT}/.cm/install-vps-bundle.sh" "${PACKAGE_ROOT}/install-vps-bundle.sh"
install -m 0644 "${ROOT}/CM_README.md" "${PACKAGE_ROOT}/CM_README.md"

echo '[7/7] Packaging and checksumming release bundle'
tar -C "${OUTPUT_ROOT}" -czf "${ARCHIVE}" "${PACKAGE_NAME}"
(
  cd "$(dirname "${ARCHIVE}")"
  sha256sum "$(basename "${ARCHIVE}")" > "$(basename "${ARCHIVE}").sha256"
)

echo
echo "Build complete:"
echo "  ${ARCHIVE}"
echo "  ${ARCHIVE}.sha256"
