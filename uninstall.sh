#!/bin/sh

set -eu

BASE_DIR="/etc/sing-box"
META="$BASE_DIR/client-info.env"
BIN="/usr/local/bin/sing-box"
MANAGER="/usr/local/bin/sb"
SERVICE_NAME="sing-box"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

die() {
  red "错误：$*"
  exit 1
}

valid_port() {
  port="$1"
  case "$port" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null
}

valid_port_range() {
  range="$1"
  case "$range" in
    *:*) ;;
    *) return 1 ;;
  esac
  start=${range%%:*}
  end=${range#*:}
  [ "$end" = "${end#*:}" ] || return 1
  valid_port "$start" && valid_port "$end" && [ "$start" -le "$end" ]
}

read_meta_value() {
  key="$1"
  value="$(sed -n "s/^${key}=//p" "$META" 2>/dev/null | head -n 1)"
  value="${value#\'}"
  value="${value%\'}"
  printf '%s' "$value"
}

remove_jump_rule() {
  [ -r "$META" ] || return 0
  jump="$(read_meta_value HY2_JUMP)"
  range="$(read_meta_value HY2_JUMP_RANGE)"
  port="$(read_meta_value HY2_PORT)"

  if [ "$jump" = "y" ] && valid_port_range "$range" && valid_port "$port" && command -v iptables >/dev/null 2>&1; then
    while iptables -t nat -C PREROUTING -p udp --dport "$range" \
      -j REDIRECT --to-ports "$port" 2>/dev/null; do
      iptables -t nat -D PREROUTING -p udp --dport "$range" \
        -j REDIRECT --to-ports "$port" 2>/dev/null || break
    done
  fi
}

stop_and_remove_service() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi

  if command -v rc-service >/dev/null 2>&1; then
    rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
    rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
    rm -f "/etc/init.d/${SERVICE_NAME}"
  fi
}

confirm() {
  [ "${1:-}" = "--yes" ] && return 0
  if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
    die "当前没有交互终端；确认卸载请使用：sudo sh $0 --yes"
  fi
  printf '将删除 sHway2 配置、服务注册和 sb 命令，但保留 sing-box 内核。继续？[y/N]: ' >/dev/tty
  read -r answer </dev/tty || answer=""
  case "$answer" in
    y|Y|yes|YES|是) ;;
    *) yellow "已取消卸载。"; exit 0 ;;
  esac
}

main() {
  [ "$(id -u)" = "0" ] || die "请使用 root 用户运行：sudo sh $0"
  case "${1:-}" in
    ''|--yes) ;;
    *) die "未知参数：$1；可用参数：--yes" ;;
  esac
  confirm "${1:-}"

  remove_jump_rule
  stop_and_remove_service
  rm -f "$MANAGER" /var/log/sing-box.log
  rm -rf "$BASE_DIR"

  green "sHway2 已卸载：配置、服务注册和 sb 命令已删除。"
  if [ -x "$BIN" ]; then
    green "sing-box 内核已保留：$BIN"
  else
    yellow "未发现 sing-box 内核；未执行任何内核删除操作。"
  fi
  green "现在可以更新仓库并重新运行 sHway2.sh。"
}

main "$@"
