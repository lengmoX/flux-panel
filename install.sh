#!/bin/bash
set -euo pipefail

# ============================================================
# Flux Panel 节点端（gost）管理脚本（多面板 / 多实例）
#
# 目标：
# - 一台服务器可同时对接多个面板（每个面板=一个实例目录+一个 systemd 服务）
# - 安装一次后可直接使用 `flux` 命令打开管理面板
#
# 目录结构：
# - BASE_DIR=/etc/gost
# - 每个实例目录：/etc/gost/<实例名>（包括默认实例 default）
#
# 服务命名：
# - default 实例：gost
# - 其他实例：gost-<实例名>
#
# 快速用法：
#   ./install.sh                 # 交互式管理
#   ./install.sh -i a -a ip:port -s secret   # 直接安装实例 a
#
# 环境变量：
#   DOWNLOAD_URL=...     覆盖 gost 下载地址
#   NO_DELETE_SELF=1     不删除 install.sh（仅对 install.sh 生效；flux 永不自删）
# ============================================================

BASE_DIR="/etc/gost"
DEFAULT_INSTANCE="default"
FLUX_BIN="/usr/local/bin/flux"

SCRIPT_NAME="$(basename "$0" 2>/dev/null || echo "$0")"
IS_FLUX_CMD=0
if [[ "$SCRIPT_NAME" == "flux" ]]; then
  IS_FLUX_CMD=1
fi

get_architecture() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "amd64" ;;
  esac
}

build_download_url() {
  local arch
  arch="$(get_architecture)"
  echo "https://github.com/bqlpfy/flux-panel/releases/latest/download/gost-${arch}"
}

DOWNLOAD_URL="${DOWNLOAD_URL:-$(build_download_url)}"

COUNTRY="$(curl -s --max-time 3 https://ipinfo.io/country 2>/dev/null || true)"
COUNTRY="$(echo "$COUNTRY" | tr -d '\r\n ')"
if [[ "$COUNTRY" == "CN" && "$DOWNLOAD_URL" != https://ghfast.top/* ]]; then
  DOWNLOAD_URL="https://ghfast.top/${DOWNLOAD_URL}"
fi

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO_CMD="sudo"
  else
    echo "错误：需要 root 权限或安装 sudo。"
    exit 1
  fi
else
  SUDO_CMD=""
fi

require_systemd() {
  command -v systemctl >/dev/null 2>&1 || {
    echo "错误：未检测到 systemd(systemctl)，无法创建/管理服务。"
    exit 1
  }
}

pause() {
  read -r -p "按回车继续..." _ || true
}

delete_self() {
  if [[ "$IS_FLUX_CMD" == "1" ]]; then
    return 0
  fi
  if [[ "${NO_DELETE_SELF:-}" == "1" ]]; then
    return 0
  fi
  echo ""
  echo "操作已完成，正在清理脚本文件..."
  local script_path
  script_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
  sleep 1
  rm -f "$script_path" && echo "脚本文件已删除" || echo "删除脚本文件失败"
}

install_flux_command() {
  local src
  src="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
  if [[ -z "$src" || ! -f "$src" ]]; then
    echo "错误：无法定位当前脚本路径，无法安装 flux 命令。"
    return 1
  fi

  $SUDO_CMD mkdir -p "$(dirname "$FLUX_BIN")"
  if command -v install >/dev/null 2>&1; then
    $SUDO_CMD install -m 0755 "$src" "$FLUX_BIN"
  else
    $SUDO_CMD cp -f "$src" "$FLUX_BIN"
    $SUDO_CMD chmod +x "$FLUX_BIN"
  fi

  echo "已安装/更新命令：$FLUX_BIN"
  echo "现在可直接执行：flux"
}

ensure_flux_command() {
  if [[ "$IS_FLUX_CMD" == "1" ]]; then
    return 0
  fi
  if [[ -x "$FLUX_BIN" ]]; then
    return 0
  fi
  install_flux_command >/dev/null 2>&1 || true
}

check_and_install_tcpkill() {
  if command -v tcpkill &>/dev/null; then
    return 0
  fi

  local os_type
  os_type="$(uname -s)"

  if [[ "$os_type" == "Darwin" ]]; then
    if command -v brew &>/dev/null; then
      brew install dsniff &>/dev/null || true
    fi
    return 0
  fi

  local distro=""
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    distro="${ID:-}"
  elif [[ -f /etc/redhat-release ]]; then
    distro="rhel"
  elif [[ -f /etc/debian_version ]]; then
    distro="debian"
  else
    return 0
  fi

  case "$distro" in
    ubuntu|debian)
      $SUDO_CMD apt update -y &>/dev/null || true
      $SUDO_CMD apt install -y dsniff &>/dev/null || true
      ;;
    centos|rhel|fedora)
      if command -v dnf &>/dev/null; then
        $SUDO_CMD dnf install -y dsniff &>/dev/null || true
      elif command -v yum &>/dev/null; then
        $SUDO_CMD yum install -y dsniff &>/dev/null || true
      fi
      ;;
    alpine)
      $SUDO_CMD apk add --no-cache dsniff &>/dev/null || true
      ;;
    arch|manjaro)
      $SUDO_CMD pacman -S --noconfirm dsniff &>/dev/null || true
      ;;
    opensuse*|sles)
      $SUDO_CMD zypper install -y dsniff &>/dev/null || true
      ;;
    gentoo)
      $SUDO_CMD emerge --ask=n net-analyzer/dsniff &>/dev/null || true
      ;;
    void)
      $SUDO_CMD xbps-install -Sy dsniff &>/dev/null || true
      ;;
  esac

  return 0
}

INSTANCE_NAME=""
SERVER_ADDR=""
SECRET=""

usage() {
  echo "用法："
  echo "  $0 [-i <实例名>] -a <面板地址:端口> -s <密钥>"
  echo ""
  echo "示例："
  echo "  $0 -i default -a 1.2.3.4:8080 -s secretA"
  echo "  $0 -i panel2  -a 5.6.7.8:8080 -s secretB"
  echo ""
  echo "提示：运行一次后可直接执行 flux 打开管理面板。"
}

while getopts ":i:a:s:h" opt; do
  case "$opt" in
    i) INSTANCE_NAME="$OPTARG" ;;
    a) SERVER_ADDR="$OPTARG" ;;
    s) SECRET="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) echo "错误：无效参数"; usage; exit 1 ;;
  esac
done

normalize_instance_name() {
  if [[ -z "$INSTANCE_NAME" ]]; then
    INSTANCE_NAME="$DEFAULT_INSTANCE"
  fi

  if [[ ! "$INSTANCE_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "错误：实例名称不合法，只允许字母/数字/_/-"
    exit 1
  fi
}

service_name_for_instance() {
  local name="$1"
  if [[ "$name" == "$DEFAULT_INSTANCE" ]]; then
    echo "gost"
  else
    echo "gost-${name}"
  fi
}

service_file_for_service() {
  local svc="$1"
  echo "/etc/systemd/system/${svc}.service"
}

set_instance_paths() {
  local svc
  svc="$(service_name_for_instance "$INSTANCE_NAME")"
  INSTALL_DIR="${BASE_DIR}/${INSTANCE_NAME}"
  SERVICE_NAME="$svc"
  SERVICE_FILE="$(service_file_for_service "$svc")"
  GOST_BIN="${INSTALL_DIR}/gost"
  CONFIG_FILE="${INSTALL_DIR}/config.json"
  GOST_CONFIG="${INSTALL_DIR}/gost.json"
}

get_instance_name() {
  if [[ -n "$INSTANCE_NAME" ]]; then
    normalize_instance_name
    return 0
  fi
  echo ""
  echo "建议：先用“列出实例”查看已有列表。"
  read -r -p "实例名称（如 default / panel2）: " INSTANCE_NAME
  normalize_instance_name
}

get_config_params() {
  if [[ -z "$SERVER_ADDR" ]]; then
    read -r -p "对接地址(例如 1.2.3.4:8080): " SERVER_ADDR
  fi
  if [[ -z "$SECRET" ]]; then
    read -r -p "密钥: " SECRET
  fi
  if [[ -z "$SERVER_ADDR" || -z "$SECRET" ]]; then
    echo "错误：参数不完整，操作取消。"
    exit 1
  fi
}

download_gost() {
  local dest="$1"
  local tmp="${dest}.new"

  echo "使用下载地址: $DOWNLOAD_URL"
  echo "下载 gost 中..."
  $SUDO_CMD curl -fL --connect-timeout 5 --max-time 60 "$DOWNLOAD_URL" -o "$tmp"
  if [[ ! -f "$tmp" || ! -s "$tmp" ]]; then
    echo "错误：下载失败，请检查网络或下载链接。"
    exit 1
  fi
  $SUDO_CMD chmod +x "$tmp"
  $SUDO_CMD mv -f "$tmp" "$dest"
}

write_instance_config() {
  echo "写入配置: $CONFIG_FILE"
  $SUDO_CMD tee "$CONFIG_FILE" >/dev/null <<EOF
{
  "addr": "$SERVER_ADDR",
  "secret": "$SECRET"
}
EOF

  if [[ -f "$GOST_CONFIG" ]]; then
    echo "跳过配置文件: $GOST_CONFIG (已存在)"
  else
    echo "创建新配置: $GOST_CONFIG"
    $SUDO_CMD tee "$GOST_CONFIG" >/dev/null <<EOF
{}
EOF
  fi

  $SUDO_CMD chmod 600 "$INSTALL_DIR"/*.json 2>/dev/null || true
}

write_service_file() {
  echo "创建服务文件: $SERVICE_FILE"
  $SUDO_CMD tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=Flux Gost Proxy Service (${INSTANCE_NAME})
After=network.target

[Service]
WorkingDirectory=${INSTALL_DIR}
ExecStart=${GOST_BIN}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

install_instance() {
  echo "开始安装实例..."
  require_systemd
  ensure_flux_command
  get_instance_name
  set_instance_paths
  get_config_params

  check_and_install_tcpkill

  echo "实例名: $INSTANCE_NAME"
  echo "实例目录: $INSTALL_DIR"
  echo "服务名称: $SERVICE_NAME"

  $SUDO_CMD mkdir -p "$INSTALL_DIR"

  if [[ -f "$SERVICE_FILE" ]]; then
    echo "检测到已存在服务：$SERVICE_NAME（将覆盖该实例）"
    $SUDO_CMD systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    $SUDO_CMD systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  fi

  download_gost "$GOST_BIN"
  echo "gost 版本：$($GOST_BIN -V 2>/dev/null || echo unknown)"

  write_instance_config
  write_service_file

  $SUDO_CMD systemctl daemon-reload
  $SUDO_CMD systemctl enable "$SERVICE_NAME"
  $SUDO_CMD systemctl start "$SERVICE_NAME"

  echo "检查服务状态..."
  if $SUDO_CMD systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "安装完成：$SERVICE_NAME 已启动并设置为开机启动。"
    echo "实例目录：$INSTALL_DIR"
    echo "后续管理：flux"
  else
    echo "服务启动失败，请查看日志：journalctl -u $SERVICE_NAME -f"
    exit 1
  fi
}

update_instance() {
  echo "开始更新实例..."
  require_systemd
  get_instance_name
  set_instance_paths

  if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "错误：该实例未安装（目录不存在）：$INSTALL_DIR"
    return 1
  fi
  if [[ ! -f "$GOST_BIN" ]]; then
    echo "错误：未找到 gost 二进制：$GOST_BIN"
    return 1
  fi

  check_and_install_tcpkill

  echo "停止服务: $SERVICE_NAME"
  $SUDO_CMD systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  download_gost "$GOST_BIN"
  echo "新版本：$($GOST_BIN -V 2>/dev/null || echo unknown)"
  $SUDO_CMD systemctl start "$SERVICE_NAME"

  echo "更新完成：$SERVICE_NAME 已重新启动。"
}

remove_instance_dir() {
  if [[ -d "$INSTALL_DIR" ]]; then
    $SUDO_CMD rm -rf "$INSTALL_DIR"
    echo "已删除实例目录: $INSTALL_DIR"
  fi

  if [[ -d "$BASE_DIR" ]]; then
    set +e
    local remain_count
    remain_count="$($SUDO_CMD ls -A "$BASE_DIR" 2>/dev/null | wc -l | tr -d ' ')"
    set -e
    if [[ "${remain_count:-1}" == "0" ]]; then
      $SUDO_CMD rmdir "$BASE_DIR" 2>/dev/null || true
    fi
  fi
}

uninstall_instance() {
  echo "开始删除实例..."
  require_systemd
  get_instance_name
  set_instance_paths

  echo "将删除：实例 [$INSTANCE_NAME]"
  echo " - 服务：$SERVICE_NAME"
  echo " - 服务文件：$SERVICE_FILE"
  echo " - 目录：$INSTALL_DIR"
  read -r -p "确认继续？(y/N): " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "取消删除"
    return 0
  fi

  echo "停止并禁用服务: $SERVICE_NAME"
  $SUDO_CMD systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  $SUDO_CMD systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  $SUDO_CMD systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true

  if [[ -f "$SERVICE_FILE" ]]; then
    $SUDO_CMD rm -f "$SERVICE_FILE"
  fi

  remove_instance_dir
  $SUDO_CMD systemctl daemon-reload
  echo "删除完成：实例 [$INSTANCE_NAME]"
  echo "提示：面板端的“节点记录”如需清理，请在面板内删除（本地脚本无法直接清理远端 DB）。"
}

status_instance() {
  echo "查看实例状态..."
  require_systemd
  get_instance_name
  set_instance_paths

  echo "实例名: $INSTANCE_NAME"
  echo "服务名称: $SERVICE_NAME"
  echo "实例目录: $INSTALL_DIR"
  echo "Active: $($SUDO_CMD systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo unknown)"
  echo "Enabled: $($SUDO_CMD systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || echo unknown)"
  echo ""
  $SUDO_CMD systemctl status "$SERVICE_NAME" --no-pager || true
}

logs_instance() {
  echo "查看实例日志..."
  require_systemd
  get_instance_name
  set_instance_paths

  echo "服务名称: $SERVICE_NAME"
  echo "实例目录: $INSTALL_DIR"
  echo "-----------------------------------------------"
  $SUDO_CMD journalctl -u "$SERVICE_NAME" --no-pager -n 200 2>/dev/null || true
  echo "-----------------------------------------------"
  read -r -p "是否进入实时日志（Ctrl+C 退出）？(y/N): " follow
  if [[ "$follow" == "y" || "$follow" == "Y" ]]; then
    set +e
    $SUDO_CMD journalctl -u "$SERVICE_NAME" -f
    set -e
  fi
}

read_config_value() {
  local file="$1"
  local key="$2"
  if [[ ! -f "$file" ]]; then
    return 0
  fi
  # 简单解析：匹配 "key": "value"
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$file" | head -n 1
}

list_instances() {
  echo "已对接实例列表（扫描：$BASE_DIR）"
  require_systemd

  if [[ ! -d "$BASE_DIR" ]]; then
    echo "（暂无：$BASE_DIR 不存在）"
    return 0
  fi

  shopt -s nullglob
  local d
  local found=0
  for d in "$BASE_DIR"/*; do
    [[ -d "$d" ]] || continue
    local name svc active enabled addr
    name="$(basename "$d")"
    svc="$(service_name_for_instance "$name")"
    active="$($SUDO_CMD systemctl is-active "$svc" 2>/dev/null || echo unknown)"
    enabled="$($SUDO_CMD systemctl is-enabled "$svc" 2>/dev/null || echo unknown)"
    addr="$(read_config_value "$d/config.json" "addr")"
    if [[ -z "$addr" ]]; then
      addr="-"
    fi
    printf " - %-16s  service=%-18s  active=%-10s  enabled=%-10s  addr=%-22s  dir=%s\n" \
      "$name" "$svc" "$active" "$enabled" "$addr" "$d"
    found=1
  done
  shopt -u nullglob

  if [[ "$found" == "0" ]]; then
    echo "（暂无：未发现任何实例目录）"
  fi
}

show_menu() {
  echo "==============================================="
  echo "                 flux 节点管理"
  echo "==============================================="
  echo "下载地址: $DOWNLOAD_URL"
  echo "实例目录: $BASE_DIR/<实例名>"
  echo "-----------------------------------------------"
  echo "1. 新增/安装实例"
  echo "2. 列出实例"
  echo "3. 查看实例状态"
  echo "4. 查看实例日志"
  echo "5. 更新实例"
  echo "6. 删除实例"
  echo "7. 安装/更新 flux 命令"
  echo "8. 退出"
  echo "==============================================="
}

run_menu() {
  while true; do
    INSTANCE_NAME=""
    SERVER_ADDR=""
    SECRET=""

    show_menu
    read -r -p "请选择 (1-8): " choice
    echo ""

    case "$choice" in
      1) install_instance; pause ;;
      2) list_instances; pause ;;
      3) status_instance; pause ;;
      4) logs_instance; pause ;;
      5) update_instance; pause ;;
      6) uninstall_instance; pause ;;
      7) install_flux_command; pause ;;
      8) echo "退出"; break ;;
      *) echo "无效选项"; pause ;;
    esac
  done
}

main() {
  # 命令行直装：提供了 a+s（以及可选 i）
  if [[ -n "$SERVER_ADDR" && -n "$SECRET" ]]; then
    install_instance
    delete_self
    exit 0
  fi

  run_menu
  delete_self
}

main
