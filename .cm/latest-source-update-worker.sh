#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

readonly REPO_DIR="${AETHER_SOURCE_DIR:-/root/aether-cm}"
readonly REPOSITORY="${AETHER_GITHUB_REPOSITORY:-luck7x/aether-cm}"
readonly TOKEN_FILE="${AETHER_GITHUB_TOKEN_FILE:-/root/.config/aether-cm/github-token}"
readonly WORK_ROOT="${AETHER_UPDATE_WORK_ROOT:-/root/aether-latest-source-work}"
readonly POLL_SECONDS="${AETHER_BUILD_POLL_SECONDS:-30}"
readonly MAX_WAIT_SECONDS="${AETHER_BUILD_MAX_WAIT_SECONDS:-14400}"

progress() { printf '[%s] [%3s%%] %s\n' "$(date '+%F %T')" "$1" "$2"; }
fail() { progress 100 "失败：$*" >&2; exit 1; }

[[ "$(id -u)" == "0" ]] || fail '必须使用 root 执行'
for command_name in curl git jq sha256sum systemctl tar; do
  command -v "${command_name}" >/dev/null 2>&1 || fail "缺少命令：${command_name}"
done
[[ "$(git -C "${REPO_DIR}" rev-parse --is-inside-work-tree 2>/dev/null || true)" == "true" ]] || \
  fail "源码仓库不存在或不是有效 worktree：${REPO_DIR}"
[[ -s "${TOKEN_FILE}" ]] || fail "GitHub Token 文件不存在或为空：${TOKEN_FILE}"
[[ "$(stat -c '%a' "${TOKEN_FILE}")" =~ ^(400|600)$ ]] || fail 'GitHub Token 文件权限必须为 0400 或 0600'

auth_header_file="$(mktemp /root/.aether-github-header.XXXXXX)"
askpass=""
cleanup() { rm -f "${auth_header_file:-}" "${askpass:-}"; }
trap cleanup EXIT
chmod 0600 "${auth_header_file}"
printf 'Authorization: Bearer %s\n' "$(< "${TOKEN_FILE}")" > "${auth_header_file}"

exec 9>/run/lock/aether-latest-source-update.lock
flock -n 9 || fail '已有最新源码更新任务运行中'

progress 2 '检查源码分支、提交和工作区；此阶段不影响在线服务'
[[ -z "$(git -C "${REPO_DIR}" status --porcelain --untracked-files=normal)" ]] || fail '源码工作区不干净'
[[ "$(git -C "${REPO_DIR}" branch --show-current)" == "cm/main" ]] || fail '当前源码分支必须是 cm/main'
BUILD_SHA="$(git -C "${REPO_DIR}" rev-parse HEAD)"
[[ "${BUILD_SHA}" =~ ^[0-9a-f]{40}$ ]] || fail '无法确定待发布提交'
git -C "${REPO_DIR}" fetch --quiet origin main
git -C "${REPO_DIR}" merge-base --is-ancestor origin/main "${BUILD_SHA}" || fail '当前提交未包含已获取的官方 main'

API_ROOT="https://api.github.com/repos/${REPOSITORY}"
api_get() {
  curl --fail --silent --show-error --retry 3 --connect-timeout 10 --max-time 90 \
    --header "@${auth_header_file}" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' "$1"
}

diagnose_failed_run() {
  local failed_run_id="$1"
  local jobs_json
  jobs_json="$(api_get "${API_ROOT}/actions/runs/${failed_run_id}/jobs?per_page=100")" || return 0
  progress 100 'GitHub Actions 失败步骤摘要：'
  while IFS=$'\t' read -r job_id job_name job_url; do
    [[ -n "${job_id}" ]] || continue
    printf '  - %s\n    %s\n' "${job_name}" "${job_url}"
    {
      curl --fail --location --silent --show-error --connect-timeout 10 --max-time 90 \
        --header "@${auth_header_file}" \
        "${API_ROOT}/actions/jobs/${job_id}/logs" |
        sed -E $'s/\\x1b\\[[0-9;]*[[:alpha:]]//g' |
        grep -Ei 'panicked at|fatal runtime error|stack overflow|assertion .* failed|could not compile|test result: FAILED|##\[error\]' |
        tail -n 12
    } || true
  done < <(jq -r '.jobs[] | select(.conclusion == "failure") | [.id,.name,.html_url] | @tsv' <<<"${jobs_json}")
}

progress 5 "推送锁定提交到 ${REPOSITORY} main：${BUILD_SHA}"
askpass="$(mktemp /root/.aether-git-askpass.XXXXXX)"
cat > "${askpass}" <<'ASKPASS'
#!/usr/bin/env bash
case "$1" in
  *Username*) printf '%s\n' x-access-token ;;
  *Password*) cat "${AETHER_GITHUB_TOKEN_FILE}" ;;
  *) exit 1 ;;
esac
ASKPASS
chmod 0700 "${askpass}"
GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="${askpass}" AETHER_GITHUB_TOKEN_FILE="${TOKEN_FILE}" \
  git -C "${REPO_DIR}" push cm "${BUILD_SHA}:refs/heads/main"
rm -f "${askpass}"
askpass=""

remote_sha="$(api_get "${API_ROOT}/commits/main" | jq -r '.sha // empty')"
[[ "${remote_sha}" == "${BUILD_SHA}" ]] || fail "远端 main 不是锁定提交：${remote_sha:-unknown}"

progress 8 '等待同一提交的完整 GitHub Actions 测试、构建和不可变 Release'
started_epoch="$(date +%s)"
last_summary=""
run_id=""
while true; do
  runs_json="$(api_get "${API_ROOT}/actions/runs?head_sha=${BUILD_SHA}&per_page=100")"
  run_id="$(jq -r --arg sha "${BUILD_SHA}" \
    '[.workflow_runs[] | select(.name == "CM Build Linux amd64" and .head_sha == $sha)][0].id // empty' \
    <<<"${runs_json}")"
  if [[ -z "${run_id}" ]]; then
    status=waiting
    conclusion=''
  else
    run_json="$(api_get "${API_ROOT}/actions/runs/${run_id}")"
    status="$(jq -r '.status // "unknown"' <<<"${run_json}")"
    conclusion="$(jq -r '.conclusion // ""' <<<"${run_json}")"
  fi
  summary="${status}/${conclusion:-none}/run-${run_id:-pending}"
  if [[ "${summary}" != "${last_summary}" ]]; then
    progress 8 "Actions：${summary}"
    last_summary="${summary}"
  fi
  if [[ "${status}" == "completed" ]]; then
    if [[ "${conclusion}" != "success" ]]; then
      diagnose_failed_run "${run_id}"
      fail "GitHub Actions 未通过：${conclusion:-unknown}"
    fi
    [[ "$(jq -r '.event' <<<"${run_json}")" == "push" ]] || fail 'Actions 不是由 main push 触发'
    [[ "$(jq -r '.path' <<<"${run_json}")" == ".github/workflows/cm-build-linux-amd64.yml" ]] || \
      fail 'Actions workflow 路径不匹配'
    break
  fi
  (( $(date +%s) - started_epoch < MAX_WAIT_SECONDS )) || fail '等待 GitHub Actions 超时，生产未变更'
  sleep "${POLL_SECONDS}"
done

progress 20 '校验 Release 标签、目标提交和唯一构建资产'
release_json="$(api_get "${API_ROOT}/releases/tags/cm-${BUILD_SHA}")"
[[ "$(jq -r '.tag_name' <<<"${release_json}")" == "cm-${BUILD_SHA}" ]] || fail 'Release 标签不匹配'
[[ "$(jq -r '.target_commitish' <<<"${release_json}")" == "${BUILD_SHA}" ]] || fail 'Release 目标提交不匹配'
[[ "$(jq -r '.draft' <<<"${release_json}")" == "false" ]] || fail 'Release 仍处于 draft 状态'
tag_json="$(api_get "${API_ROOT}/git/ref/tags/cm-${BUILD_SHA}")"
[[ "$(jq -r '.object.type' <<<"${tag_json}")" == "commit" ]] || fail 'Release tag 不是轻量 commit tag'
[[ "$(jq -r '.object.sha' <<<"${tag_json}")" == "${BUILD_SHA}" ]] || fail 'Release tag 实际提交不匹配'
archive_name="aether-cm-${BUILD_SHA}-linux-amd64.tar.gz"
checksum_name="${archive_name}.sha256"
archive_url="$(jq -r --arg n "${archive_name}" '[.assets[] | select(.name == $n)][0].browser_download_url // empty' <<<"${release_json}")"
checksum_url="$(jq -r --arg n "${checksum_name}" '[.assets[] | select(.name == $n)][0].browser_download_url // empty' <<<"${release_json}")"
[[ -n "${archive_url}" && -n "${checksum_url}" ]] || fail 'Release 缺少唯一构建包或校验文件'
[[ "$(jq -r --arg n "${archive_name}" '[.assets[] | select(.name == $n)] | length' <<<"${release_json}")" == 1 ]] || fail '构建包数量异常'
[[ "$(jq -r --arg n "${checksum_name}" '[.assets[] | select(.name == $n)] | length' <<<"${release_json}")" == 1 ]] || fail '校验文件数量异常'

rm -rf "${WORK_ROOT}"
install -d -m 0700 "${WORK_ROOT}"
progress 25 '下载 GitHub 构建包（显示传输进度）'
curl --fail --location --show-error --retry 5 --connect-timeout 15 \
  --header "@${auth_header_file}" \
  -o "${WORK_ROOT}/${archive_name}" "${archive_url}"
curl --fail --location --silent --show-error --retry 5 --connect-timeout 15 \
  --header "@${auth_header_file}" \
  -o "${WORK_ROOT}/${checksum_name}" "${checksum_url}"

progress 32 '验证 SHA256、压缩包路径和 BUILD_INFO'
(cd "${WORK_ROOT}" && sha256sum --check "${checksum_name}")
tar -tzf "${WORK_ROOT}/${archive_name}" > "${WORK_ROOT}/archive.list"
if grep -Eq '(^/|(^|/)\.\.(/|$))' "${WORK_ROOT}/archive.list"; then
  fail '压缩包包含不安全路径'
fi
if grep -Evq "^aether-cm-${BUILD_SHA}-linux-amd64(/|$)" "${WORK_ROOT}/archive.list"; then
  fail '压缩包包含预期顶层目录之外的内容'
fi
tar -xzf "${WORK_ROOT}/${archive_name}" -C "${WORK_ROOT}"
bundle_dir="${WORK_ROOT}/aether-cm-${BUILD_SHA}-linux-amd64"
[[ -x "${bundle_dir}/install-vps-bundle.sh" ]] || fail '构建包缺少安装器'
grep -qx "git_sha=${BUILD_SHA}" "${bundle_dir}/BUILD_INFO" || fail 'BUILD_INFO 与锁定提交不一致'
(cd "${bundle_dir}" && sha256sum --check bin/aether-gateway.sha256)

progress 40 '构建和下载验证全部通过；开始数据库演练，演练通过后才进入短暂停服切换'
AETHER_PROGRESS_BASE=40 AETHER_PROGRESS_SPAN=60 "${bundle_dir}/install-vps-bundle.sh"
progress 100 "最新源码升级成功：${BUILD_SHA}"
