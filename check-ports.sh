#!/bin/sh

set -eu

BASE_DIR="/etc/sing-box"
META="$BASE_DIR/client-info.env"
CONF="$BASE_DIR/config.json"
BIN="/usr/local/bin/sing-box"
SERVICE_NAME="sing-box"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
info() { printf '%s\n' "$*"; }

die() {
  red "错误：$*"
  exit 1
}

usage() {
  cat <<EOF
用法：
  sh check-ports.sh server
  sudo sh check-ports.sh remote <服务器IP或域名> [HY2端口] [TUIC端口] [AnyTLS端口]

示例：
  sh check-ports.sh server
  sudo sh check-ports.sh remote 203.0.113.10 11451 11452 11453
EOF
}

valid_port() {
  port="$1"
  case "$port" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null
}

read_meta_value() {
  key="$1"
  value="$(sed -n "s/^${key}=//p" "$META" 2>/dev/null | head -n 1)"
  value="${value#\'}"
  value="${value%\'}"
  printf '%s' "$value"
}

load_ports() {
  [ -r "$META" ] || die "未找到节点信息：$META"
  HY2_PORT="$(read_meta_value HY2_PORT)"
  TUIC_PORT="$(read_meta_value TUIC_PORT)"
  ANYTLS_PORT="$(read_meta_value ANYTLS_PORT)"
  valid_port "$HY2_PORT" || die "Hysteria2 端口无效：$HY2_PORT"
  valid_port "$TUIC_PORT" || die "TUIC 端口无效：$TUIC_PORT"
  valid_port "$ANYTLS_PORT" || die "AnyTLS 端口无效：$ANYTLS_PORT"
}

service_is_active() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet "$SERVICE_NAME"
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service "$SERVICE_NAME" status >/dev/null 2>&1
  else
    return 1
  fi
}

udp_is_listening() {
  port="$1"
  ss -H -lun 2>/dev/null | awk -v suffix=":$port" '$4 ~ suffix "$" { found = 1 } END { exit found ? 0 : 1 }'
}

tcp_is_listening() {
  port="$1"
  ss -H -ltn 2>/dev/null | awk -v suffix=":$port" '$4 ~ suffix "$" { found = 1 } END { exit found ? 0 : 1 }'
}

show_firewall() {
  info ""
  info "=== 本机防火墙摘要 ==="
  if command -v ufw >/dev/null 2>&1; then
    ufw status verbose 2>/dev/null || true
  else
    info "未安装 ufw。"
  fi

  if command -v iptables >/dev/null 2>&1; then
    info ""
    info "iptables INPUT 默认策略与相关规则："
    iptables -S INPUT 2>/dev/null | awk -v h="$HY2_PORT" -v t="$TUIC_PORT" -v a="$ANYTLS_PORT" '
      NR == 1 || index($0, "--dport " h) || index($0, "--dport " t) || index($0, "--dport " a)
    ' || true
  else
    info "未安装 iptables。"
  fi

  if command -v nft >/dev/null 2>&1; then
    info ""
    info "nftables 中包含相关端口的规则："
    nft list ruleset 2>/dev/null | awk -v h="$HY2_PORT" -v t="$TUIC_PORT" -v a="$ANYTLS_PORT" '
      index($0, h) || index($0, t) || index($0, a)
    ' || true
  fi

  yellow "云安全组规则无法从普通 VPS 内可靠读取，必须从另一台机器执行 remote 模式。"
}

server_check() {
  command -v ss >/dev/null 2>&1 || die "缺少 ss，请安装 iproute2"
  load_ports
  failed=0

  info "=== sing-box 服务端检查 ==="
  info "Hysteria2: UDP $HY2_PORT"
  info "TUIC:      UDP $TUIC_PORT"
  info "AnyTLS:   TCP $ANYTLS_PORT"
  info ""

  if service_is_active; then
    green "[通过] sing-box 服务正在运行"
  else
    red "[失败] sing-box 服务未运行"
    failed=1
  fi

  if [ -x "$BIN" ] && [ -r "$CONF" ] && "$BIN" check -c "$CONF" >/dev/null 2>&1; then
    green "[通过] sing-box 配置检查成功"
  else
    red "[失败] sing-box 配置检查失败"
    failed=1
  fi

  if udp_is_listening "$HY2_PORT"; then
    green "[通过] Hysteria2 UDP $HY2_PORT 正在本机监听"
  else
    red "[失败] Hysteria2 UDP $HY2_PORT 未监听"
    failed=1
  fi

  if udp_is_listening "$TUIC_PORT"; then
    green "[通过] TUIC UDP $TUIC_PORT 正在本机监听"
  else
    red "[失败] TUIC UDP $TUIC_PORT 未监听"
    failed=1
  fi

  if tcp_is_listening "$ANYTLS_PORT"; then
    green "[通过] AnyTLS TCP $ANYTLS_PORT 正在本机监听"
  else
    red "[失败] AnyTLS TCP $ANYTLS_PORT 未监听"
    failed=1
  fi

  show_firewall
  [ "$failed" -eq 0 ] || exit 1
}

remote_check() {
  host="${1:-}"
  HY2_PORT="${2:-11451}"
  TUIC_PORT="${3:-11452}"
  ANYTLS_PORT="${4:-11453}"
  [ -n "$host" ] || die "缺少服务器 IP 或域名"
  valid_port "$HY2_PORT" || die "Hysteria2 端口无效：$HY2_PORT"
  valid_port "$TUIC_PORT" || die "TUIC 端口无效：$TUIC_PORT"
  valid_port "$ANYTLS_PORT" || die "AnyTLS 端口无效：$ANYTLS_PORT"
  command -v nmap >/dev/null 2>&1 || die "remote 模式需要 nmap，请先安装 nmap"

  info "=== 从当前机器探测 $host ==="
  info ""
  info "TCP/AnyTLS 探测："
  nmap -Pn -sT -p "$ANYTLS_PORT" "$host"
  info ""
  info "UDP/Hysteria2 与 TUIC 探测："
  nmap -Pn -sU -p "$HY2_PORT,$TUIC_PORT" "$host"
  info ""
  yellow "TCP 显示 open 才能确认端口可达。UDP 的 open|filtered 表示未收到拒绝，不能单独证明协议可用；closed 则说明端口或路径明确不可达。"
}

case "${1:-server}" in
  server) server_check ;;
  remote) shift; remote_check "$@" ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
