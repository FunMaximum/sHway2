#!/bin/sh

set -eu

BASE_DIR="/etc/sing-box"
META="$BASE_DIR/client-info.env"
BIN="/usr/local/bin/sing-box"
SB_BIN="/usr/local/bin/sb"
RUNTIME_DIR="/usr/local/lib/shway2"
RUNTIME_MANAGER="$RUNTIME_DIR/manager.sh"
STATE_DIR="/var/lib/shway2"
SERVICE_NAME="sing-box"
FIREWALL_CHAIN="SHWAY2_INPUT"
BACKUP_TMP=""

if [ -x "$RUNTIME_MANAGER" ]; then
  exec "$RUNTIME_MANAGER" manage uninstall "$@"
fi

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

die() {
  red "错误：$*"
  exit 1
}

cleanup() {
  [ -z "$BACKUP_TMP" ] || rm -rf "$BACKUP_TMP"
}

trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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

remove_firewall_rules() {
  if [ -r "$META" ] && command -v iptables >/dev/null 2>&1; then
    jump="$(read_meta_value HY2_JUMP)"
    range="$(read_meta_value HY2_JUMP_RANGE)"
    port="$(read_meta_value HY2_PORT)"
    if [ "$jump" = "y" ] && valid_port_range "$range" && valid_port "$port"; then
      while iptables -t nat -C PREROUTING -p udp --dport "$range" \
        -j REDIRECT --to-ports "$port" 2>/dev/null; do
        iptables -t nat -D PREROUTING -p udp --dport "$range" \
          -j REDIRECT --to-ports "$port" 2>/dev/null || break
      done
    fi
  fi
  if command -v iptables >/dev/null 2>&1; then
    while iptables -C INPUT -j "$FIREWALL_CHAIN" 2>/dev/null; do
      iptables -D INPUT -j "$FIREWALL_CHAIN" 2>/dev/null || break
    done
    iptables -F "$FIREWALL_CHAIN" 2>/dev/null || true
    iptables -X "$FIREWALL_CHAIN" 2>/dev/null || true
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

create_legacy_backup() {
  backup_output="$1"
  BACKUP_TMP="$(mktemp -d /tmp/shway2-uninstall.XXXXXX)" || die "创建备份临时目录失败"
  backup_root="$BACKUP_TMP/shway2-backup"
  mkdir -p "$backup_root"
  {
    printf 'FORMAT=1\n'
    printf 'REASON=uninstall\n'
    printf 'CREATED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'INSTALLER_VERSION=legacy\n'
  } > "$backup_root/manifest.env"
  [ ! -d "$BASE_DIR" ] || cp -pR "$BASE_DIR" "$backup_root/etc-sing-box"
  [ ! -x "$BIN" ] || cp -p "$BIN" "$backup_root/sing-box"
  [ ! -d "$RUNTIME_DIR" ] || cp -pR "$RUNTIME_DIR" "$backup_root/runtime"
  [ ! -f "$SB_BIN" ] || cp -p "$SB_BIN" "$backup_root/sb"
  [ ! -f "/etc/systemd/system/${SERVICE_NAME}.service" ] || \
    cp -p "/etc/systemd/system/${SERVICE_NAME}.service" "$backup_root/systemd.service"
  [ ! -f "/etc/init.d/${SERVICE_NAME}" ] || \
    cp -p "/etc/init.d/${SERVICE_NAME}" "$backup_root/openrc.service"
  tar -czf "$backup_output.tmp.$$" -C "$BACKUP_TMP" shway2-backup || \
    die "创建卸载备份失败"
  chmod 600 "$backup_output.tmp.$$"
  mv "$backup_output.tmp.$$" "$backup_output"
  rm -rf "$BACKUP_TMP"
  BACKUP_TMP=""
}

confirm() {
  [ "$1" = "y" ] && return 0
  if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
    die "当前没有交互终端；确认卸载请使用：sudo sh $0 --yes"
  fi
  printf '将卸载 sHway2 服务和配置，但保留 sing-box 内核。继续？[y/N]: ' >/dev/tty
  read -r answer </dev/tty || answer=""
  case "$answer" in
    y|Y|yes|YES|是) ;;
    *) yellow "已取消卸载。"; exit 0 ;;
  esac
}

main() {
  [ "$(id -u)" = "0" ] || die "请使用 root 用户运行：sudo sh $0"
  uninstall_yes="n"
  uninstall_backup="y"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes) uninstall_yes="y" ;;
      --no-backup) uninstall_backup="n" ;;
      *) die "未知参数：$1；可用参数：--yes、--no-backup" ;;
    esac
    shift
  done
  confirm "$uninstall_yes"

  if [ "$uninstall_backup" = "y" ] && [ -d "$BASE_DIR" ]; then
    backup_output="/root/sHway2-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    create_legacy_backup "$backup_output"
    green "卸载备份：$backup_output"
  fi
  stop_and_remove_service
  remove_firewall_rules
  rm -f "$SB_BIN" /var/log/sing-box.log
  rm -rf "$BASE_DIR" "$RUNTIME_DIR" "$STATE_DIR"

  green "sHway2 已卸载；sing-box 内核和系统依赖已保留。"
  if [ -x "$BIN" ]; then
    green "sing-box 内核：$BIN"
  fi
}

main "$@"
