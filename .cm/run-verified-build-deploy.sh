#!/usr/bin/env bash
set -Eeuo pipefail

readonly UNIT="aether-verified-build-deploy"
readonly WORKER="/root/aether-cm/.cm/deploy-verified-build-worker.sh"
readonly DEFAULT_BUILD_SHA="42f5fcfb849930696bfc80bd932eed07225cdd3f"

case "${1:-}" in
  logs) exec journalctl -fu "${UNIT}.service" -o cat ;;
  status) exec systemctl status "${UNIT}.service" --no-pager -l ;;
esac

BUILD_SHA="${1:-${DEFAULT_BUILD_SHA}}"
[[ "${BUILD_SHA}" =~ ^[0-9a-f]{40}$ ]] || { echo "用法：$0 [40位已验证构建SHA|logs|status]" >&2; exit 2; }
[[ "$(id -u)" == 0 ]] || { echo '必须使用 root 执行' >&2; exit 1; }
[[ -x "${WORKER}" ]] || { echo "worker 不存在：${WORKER}" >&2; exit 1; }

systemctl reset-failed "${UNIT}.service" >/dev/null 2>&1 || true
systemd-run --unit="${UNIT}" --collect \
  --property=Type=oneshot --property=TimeoutStartSec=infinity --property=TimeoutStopSec=infinity \
  --property=Nice=5 --property=IOSchedulingClass=best-effort --property=IOSchedulingPriority=6 \
  "${WORKER}" "${BUILD_SHA}"
echo "已在后台启动；查看进度：$0 logs"
exec journalctl -fu "${UNIT}.service" -o cat
