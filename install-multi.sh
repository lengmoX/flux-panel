#!/bin/bash
set -euo pipefail

# 兼容入口：install-multi.sh
# 当前 install.sh 已内置“多面板/多实例 + flux 命令管理”能力。
# 本脚本优先复用同目录 install.sh；若不存在，则尝试从 GitHub 下载（可用环境变量覆盖）。

SCRIPT_DIR="$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd -P || pwd)"
if [[ -x "${SCRIPT_DIR}/install.sh" ]]; then
  exec "${SCRIPT_DIR}/install.sh" "$@"
fi

INSTALL_SH_URL="${INSTALL_SH_URL:-https://raw.githubusercontent.com/bqlpfy/flux-panel/refs/heads/main/install.sh}"

COUNTRY="$(curl -s --max-time 3 https://ipinfo.io/country 2>/dev/null || true)"
COUNTRY="$(echo "$COUNTRY" | tr -d '\r\n ')"
if [[ "$COUNTRY" == "CN" && "$INSTALL_SH_URL" != https://ghfast.top/* ]]; then
  INSTALL_SH_URL="https://ghfast.top/${INSTALL_SH_URL}"
fi

TMP_INSTALL_SH="/tmp/flux-install.sh"
echo "未找到同目录 install.sh，尝试下载：$INSTALL_SH_URL"
curl -fL --connect-timeout 5 --max-time 60 "$INSTALL_SH_URL" -o "$TMP_INSTALL_SH"
chmod +x "$TMP_INSTALL_SH"
exec "$TMP_INSTALL_SH" "$@"
