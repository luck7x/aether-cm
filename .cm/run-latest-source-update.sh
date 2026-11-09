#!/usr/bin/env bash
set -Eeuo pipefail

readonly UNIT="aether-latest-source-update"
readonly WORKER="${AETHER_LATEST_SOURCE_WORKER:-/root/aether-cm/.cm/latest-source-update-worker.sh}"

usage() {
  echo "启动：$0"
  echo "日志：$0 logs"
  echo "状态：$0 status"
}

case "${1:-}" in
  logs) exec journalctl -fu "${UNIT}.service" -o cat ;;
  status) exec systemctl status "${UNIT}.service" --no-pager -l ;;
  '') ;;
  *) usage >&2; exit 2 ;;
esac

[[ "$(id -u)" == "0" ]] || { echo '必须使用 root 执行' >&2; exit 1; }
[[ -x "${WORKER}" ]] || { echo "worker 不存在：${WORKER}" >&2; exit 1; }
if systemctl is-active --quiet "${UNIT}.service"; then
  echo "更新已在运行。查看进度：$0 logs"
  exit 0
fi

systemctl reset-failed "${UNIT}.service" >/dev/null 2>&1 || true
systemd-run --unit="${UNIT}" --collect \
  --property=Type=oneshot \
  --property=TimeoutStartSec=infinity \
  --property=TimeoutStopSec=infinity \
  --property=Nice=5 \
  --property=IOSchedulingClass=best-effort \
  --property=IOSchedulingPriority=6 \
  "${WORKER}"
echo "任务已在后台启动，SSH 断开也会继续。"
exec journalctl -fu "${UNIT}.service" -o cat
