#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

readonly BUILD_SHA="${1:-}"
readonly REPO_DIR="${AETHER_SOURCE_DIR:-/root/aether-cm}"
readonly REPOSITORY="${AETHER_GITHUB_REPOSITORY:-luck7x/aether-cm}"
readonly TOKEN_FILE="${AETHER_GITHUB_TOKEN_FILE:-/root/.config/aether-cm/github-token}"
readonly WORK_ROOT="${AETHER_REUSE_WORK_ROOT:-/root/aether-verified-build-work}"
readonly INSTALLER="${REPO_DIR}/.cm/install-vps-bundle.sh"

progress() { printf '[%s] [%3s%%] %s\n' "$(date '+%F %T')" "$1" "$2"; }
fail() { progress 100 "失败：$*" >&2; exit 1; }

[[ "$(id -u)" == "0" ]] || fail '必须使用 root 执行'
[[ "${BUILD_SHA}" =~ ^[0-9a-f]{40}$ ]] || fail '必须提供已通过 Actions 的 40 位应用构建 SHA'
for command_name in curl git jq sha256sum tar; do
  command -v "${command_name}" >/dev/null 2>&1 || fail "缺少命令：${command_name}"
done
[[ -x "${INSTALLER}" ]] || fail "本机蓝绿安装器不存在：${INSTALLER}"
[[ -s "${TOKEN_FILE}" ]] || fail "GitHub Token 文件不存在：${TOKEN_FILE}"
[[ "$(stat -c '%a' "${TOKEN_FILE}")" =~ ^(400|600)$ ]] || fail 'Token 文件权限必须为 0400 或 0600'
[[ -z "$(git -C "${REPO_DIR}" status --porcelain --untracked-files=normal)" ]] || fail '本机源码工作区不干净'
git -C "${REPO_DIR}" cat-file -e "${BUILD_SHA}^{commit}" 2>/dev/null || fail '本机不存在指定构建提交'

# 复用旧应用包仅允许部署工具变化；任何应用、前端、依赖或构建脚本变化都必须重新 Actions。
if git -C "${REPO_DIR}" diff --quiet "${BUILD_SHA}"..HEAD -- \
  apps crates frontend aether-vscodex Cargo.toml Cargo.lock rust-toolchain.toml \
  .cargo .config .cm/build-linux-amd64.sh; then
  progress 2 "确认应用源码未变化；仅复用已验证构建：${BUILD_SHA}"
else
  fail '指定构建之后应用源码或构建输入已变化，禁止复用；必须走完整 Actions'
fi

exec 9>/run/lock/aether-verified-build-deploy.lock
flock -n 9 || fail '已有复用构建部署任务运行中'

header_file="$(mktemp /root/.aether-github-header.XXXXXX)"
cleanup() { unlink "${header_file}" 2>/dev/null || true; }
trap cleanup EXIT
chmod 0600 "${header_file}"
printf 'Authorization: Bearer %s\n' "$(< "${TOKEN_FILE}")" > "${header_file}"
api_get() {
  curl --fail --silent --show-error --retry 3 --connect-timeout 10 --max-time 90 \
    --header "@${header_file}" -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' "$1"
}

readonly API_ROOT="https://api.github.com/repos/${REPOSITORY}"
progress 8 '验证原应用提交的 Actions、Release 和实际 tag'
runs_json="$(api_get "${API_ROOT}/actions/runs?head_sha=${BUILD_SHA}&per_page=100")"
run_ok="$(jq -r --arg sha "${BUILD_SHA}" '[.workflow_runs[] | select(.name == "CM Build Linux amd64" and .head_sha == $sha and .status == "completed" and .conclusion == "success")] | length' <<<"${runs_json}")"
(( run_ok >= 1 )) || fail '指定提交没有成功的 CM Build Actions'
release_json="$(api_get "${API_ROOT}/releases/tags/cm-${BUILD_SHA}")"
[[ "$(jq -r '.target_commitish' <<<"${release_json}")" == "${BUILD_SHA}" ]] || fail 'Release 目标提交不匹配'
[[ "$(jq -r '.draft' <<<"${release_json}")" == false ]] || fail 'Release 尚未发布'
tag_json="$(api_get "${API_ROOT}/git/ref/tags/cm-${BUILD_SHA}")"
[[ "$(jq -r '.object.type' <<<"${tag_json}")" == commit ]] || fail 'tag 不是轻量 commit tag'
[[ "$(jq -r '.object.sha' <<<"${tag_json}")" == "${BUILD_SHA}" ]] || fail 'tag 实际提交不匹配'

archive_name="aether-cm-${BUILD_SHA}-linux-amd64.tar.gz"
checksum_name="${archive_name}.sha256"
archive_url="$(jq -r --arg n "${archive_name}" '[.assets[] | select(.name == $n)][0].browser_download_url // empty' <<<"${release_json}")"
checksum_url="$(jq -r --arg n "${checksum_name}" '[.assets[] | select(.name == $n)][0].browser_download_url // empty' <<<"${release_json}")"
[[ -n "${archive_url}" && -n "${checksum_url}" ]] || fail 'Release 资产不完整'

find "${WORK_ROOT}" -depth -delete 2>/dev/null || true
install -d -m 0700 "${WORK_ROOT}"
progress 15 '下载已验证应用构建包'
curl --fail --location --show-error --retry 5 --connect-timeout 15 \
  --header "@${header_file}" -o "${WORK_ROOT}/${archive_name}" "${archive_url}"
curl --fail --location --silent --show-error --retry 5 --connect-timeout 15 \
  --header "@${header_file}" -o "${WORK_ROOT}/${checksum_name}" "${checksum_url}"
(cd "${WORK_ROOT}" && sha256sum --check "${checksum_name}")

tar -tzf "${WORK_ROOT}/${archive_name}" > "${WORK_ROOT}/archive.list"
grep -Eq '(^/|(^|/)\.\.(/|$))' "${WORK_ROOT}/archive.list" && fail '压缩包包含不安全路径'
grep -Evq "^aether-cm-${BUILD_SHA}-linux-amd64(/|$)" "${WORK_ROOT}/archive.list" && fail '压缩包顶层目录异常'
tar -xzf "${WORK_ROOT}/${archive_name}" -C "${WORK_ROOT}"
bundle_dir="${WORK_ROOT}/aether-cm-${BUILD_SHA}-linux-amd64"
grep -qx "git_sha=${BUILD_SHA}" "${bundle_dir}/BUILD_INFO" || fail 'BUILD_INFO 不匹配'
(cd "${bundle_dir}" && sha256sum --check bin/aether-gateway.sha256)

progress 25 "应用包验证完成；使用本机蓝绿安装器：$(git -C "${REPO_DIR}" rev-parse HEAD)"
AETHER_BUNDLE_ROOT="${bundle_dir}" AETHER_PROGRESS_BASE=25 AETHER_PROGRESS_SPAN=75 \
  "${INSTALLER}"
progress 100 '已验证应用构建与独立蓝绿安装器部署完成'
