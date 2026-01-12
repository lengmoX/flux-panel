#!/bin/bash
set -euo pipefail

# ============================================================
# 兼容脚本：install-multi.sh
#
# 当前 install.sh 已内置“多面板/多实例”能力；本脚本保留同等功能，
# 方便仍在使用 install-multi.sh 的用户直接升级到新版本。
# ============================================================

BASE_DIR="/etc/gost"
DEFAULT_INSTANCE="default"

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

delete_self() {
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
  echo "  $0 -a 1.2.3.4:8080 -s secretA"
  echo "  $0 -i panel2 -a 5.6.7.8:8080 -s secretB"
  echo ""
  echo "环境变量："
  echo "  DOWNLOAD_URL=...     指定 gost 下载地址（覆盖默认）"
  echo "  NO_DELETE_SELF=1     不删除脚本文件"
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

  if [[ "$INSTANCE_NAME" != "$DEFAULT_INSTANCE" && ! "$INSTANCE_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "错误：实例名称不合法，只允许字母/数字/_/-"
    exit 1
  fi
}

set_instance_paths() {
  if [[ "$INSTANCE_NAME" == "$DEFAULT_INSTANCE" ]]; then
    INSTALL_DIR="$BASE_DIR"
    SERVICE_NAME="gost"
    SERVICE_FILE="/etc/systemd/system/gost.service"
  else
    INSTALL_DIR="${BASE_DIR}/${INSTANCE_NAME}"
    SERVICE_NAME="gost-${INSTANCE_NAME}"
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
  fi
  GOST_BIN="${INSTALL_DIR}/gost"
  CONFIG_FILE="${INSTALL_DIR}/config.json"
  GOST_CONFIG="${INSTALL_DIR}/gost.json"
}

get_instance_name() {
  if [[ -n "$INSTANCE_NAME" ]]; then
    normalize_instance_name
    return 0
  fi
  read -r -p "实例名称（默认 default；第二个面板可填 panel2 等）: " INSTANCE_NAME
  normalize_instance_name
}

get_config_params() {
  if [[ -z "$SERVER_ADDR" ]]; then
    read -r -p "面板地址(例如 1.2.3.4:8080): " SERVER_ADDR
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

install_gost() {
  echo "开始安装 GOST（多面板/多实例）..."
  require_systemd
  get_instance_name
  set_instance_paths
  get_config_params

  check_and_install_tcpkill

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
  else
    echo "服务启动失败，请查看日志：journalctl -u $SERVICE_NAME -f"
    exit 1
  fi
}

update_gost() {
  echo "开始更新 GOST（指定实例）..."
  require_systemd
  get_instance_name
  set_instance_paths

  if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "错误：该实例未安装（目录不存在）：$INSTALL_DIR"
    exit 1
  fi

  check_and_install_tcpkill

  echo "停止服务: $SERVICE_NAME"
  $SUDO_CMD systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  download_gost "$GOST_BIN"
  echo "新版本：$($GOST_BIN -V 2>/dev/null || echo unknown)"
  $SUDO_CMD systemctl start "$SERVICE_NAME"

  echo "更新完成：$SERVICE_NAME 已重新启动。"
}

uninstall_default_dir_safely() {
  local removed_any=false

  for f in "$BASE_DIR/gost" "$BASE_DIR/config.json" "$BASE_DIR/gost.json" "$BASE_DIR/gost.new"; do
    if [[ -e "$f" ]]; then
      $SUDO_CMD rm -f "$f"
      removed_any=true
    fi
  done

  if [[ -d "$BASE_DIR" ]]; then
    local remain_count
    set +e
    remain_count="$($SUDO_CMD ls -A "$BASE_DIR" 2>/dev/null | wc -l | tr -d ' ')"
    set -e
    if [[ "${remain_count:-1}" == "0" ]]; then
      $SUDO_CMD rmdir "$BASE_DIR" 2>/dev/null || true
    fi
  fi

  if [[ "$removed_any" == true ]]; then
    echo "已清理默认实例文件（保留可能存在的其它实例目录）：$BASE_DIR"
  fi
}

uninstall_gost() {
  echo "开始卸载 GOST（指定实例）..."
  require_systemd
  get_instance_name
  set_instance_paths

  read -r -p "确认卸载实例 [$INSTANCE_NAME] 吗？(y/N): " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "取消卸载"
    return 0
  fi

  echo "停止并禁用服务: $SERVICE_NAME"
  $SUDO_CMD systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  $SUDO_CMD systemctl disable "$SERVICE_NAME" 2>/dev/null || true

  if [[ -f "$SERVICE_FILE" ]]; then
    $SUDO_CMD rm -f "$SERVICE_FILE"
  fi

  if [[ "$INSTANCE_NAME" == "$DEFAULT_INSTANCE" ]]; then
    uninstall_default_dir_safely
  else
    if [[ -d "$INSTALL_DIR" ]]; then
      $SUDO_CMD rm -rf "$INSTALL_DIR"
      echo "已删除实例目录: $INSTALL_DIR"
    fi
  fi

  $SUDO_CMD systemctl daemon-reload
  echo "卸载完成：实例 [$INSTANCE_NAME]"
}

status_instance() {
  echo "查看实例状态..."
  require_systemd
  get_instance_name
  set_instance_paths

  echo "服务名称: $SERVICE_NAME"
  echo "实例目录: $INSTALL_DIR"
  echo "Active: $($SUDO_CMD systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo unknown)"
  echo "Enabled: $($SUDO_CMD systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || echo unknown)"
  echo ""
  $SUDO_CMD systemctl status "$SERVICE_NAME" --no-pager || true
  echo ""
  echo "实时日志：journalctl -u $SERVICE_NAME -f"
}

list_instances() {
  echo "已安装实例列表（扫描：$BASE_DIR）"
  require_systemd

  local default_active default_enabled
  default_active="$($SUDO_CMD systemctl is-active gost 2>/dev/null || echo unknown)"
  default_enabled="$($SUDO_CMD systemctl is-enabled gost 2>/dev/null || echo unknown)"
  if [[ -f "/etc/systemd/system/gost.service" || -f "$BASE_DIR/config.json" || -f "$BASE_DIR/gost" ]]; then
    printf " - %-20s  service=%-22s  active=%-10s  enabled=%-10s  dir=%s\n" \
      "$DEFAULT_INSTANCE" "gost" "$default_active" "$default_enabled" "$BASE_DIR"
  fi

  if [[ ! -d "$BASE_DIR" ]]; then
    return 0
  fi

  shopt -s nullglob
  local d
  for d in "$BASE_DIR"/*; do
    [[ -d "$d" ]] || continue
    local name
    name="$(basename "$d")"
    [[ "$name" == "$DEFAULT_INSTANCE" ]] && continue

    [[ -f "$d/config.json" ]] || continue

    local svc="gost-${name}"
    local active enabled
    active="$($SUDO_CMD systemctl is-active "$svc" 2>/dev/null || echo unknown)"
    enabled="$($SUDO_CMD systemctl is-enabled "$svc" 2>/dev/null || echo unknown)"

    printf " - %-20s  service=%-22s  active=%-10s  enabled=%-10s  dir=%s\n" \
      "$name" "$svc" "$active" "$enabled" "$d"
  done
  shopt -u nullglob
}

show_menu() {
  echo "==============================================="
  echo "        Flux Gost 多面板/多实例管理脚本"
  echo "==============================================="
  echo "下载地址: $DOWNLOAD_URL"
  echo "基础目录: $BASE_DIR"
  echo "-----------------------------------------------"
  echo "1. 安装（指定实例）"
  echo "2. 更新（指定实例）"
  echo "3. 卸载（指定实例）"
  echo "4. 查看实例状态（status）"
  echo "5. 列出已安装实例（list）"
  echo "6. 退出"
  echo "==============================================="
}

main() {
  if [[ -n "$SERVER_ADDR" && -n "$SECRET" ]]; then
    install_gost
    delete_self
    exit 0
  fi

  while true; do
    INSTANCE_NAME=""
    SERVER_ADDR=""
    SECRET=""

    show_menu
    read -r -p "请输入选项 (1-6): " choice

    case "$choice" in
      1) install_gost; delete_self; exit 0 ;;
      2) update_gost; delete_self; exit 0 ;;
      3) uninstall_gost; delete_self; exit 0 ;;
      4) status_instance; delete_self; exit 0 ;;
      5) list_instances; delete_self; exit 0 ;;
      6) echo "退出脚本"; delete_self; exit 0 ;;
      *) echo "无效选项，请输入 1-6"; echo "" ;;
    esac
  done
}

main
