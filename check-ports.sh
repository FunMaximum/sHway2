#!/bin/sh

set -eu

BASE_DIR="/etc/sing-box"
META="$BASE_DIR/client-info.env"
CONF="$BASE_DIR/config.json"
BIN="/usr/local/bin/sing-box"
SERVICE_NAME="sing-box"
FIREWALL_CHAIN="SHWAY2_INPUT"

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
  sudo sh check-ports.sh server
  sudo sh check-ports.sh remote <服务器IP或域名> [HY2端口] [TUIC端口] [AnyTLS端口] [Reality端口|-]

示例：
  sudo sh check-ports.sh server
  sudo sh check-ports.sh remote 203.0.113.10 11451 11452 11453 11454

remote 必须在目标服务器之外的机器执行；旧三协议节点可用 - 跳过 Reality。
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

config_port() {
  inbound_tag="$1"
  jq -r --arg tag "$inbound_tag" \
    '.inbounds[] | select(.tag == $tag) | .listen_port // empty' "$CONF" 2>/dev/null | head -n 1
}

load_ports_from_meta() {
  [ -r "$META" ] || return 1
  HY2_PORT="$(read_meta_value HY2_PORT)"
  TUIC_PORT="$(read_meta_value TUIC_PORT)"
  ANYTLS_PORT="$(read_meta_value ANYTLS_PORT)"
  REALITY_ENABLED="$(read_meta_value REALITY_ENABLED)"
  REALITY_PORT="$(read_meta_value REALITY_PORT)"
  valid_port "$HY2_PORT" && valid_port "$TUIC_PORT" && valid_port "$ANYTLS_PORT" || return 1
  case "$REALITY_ENABLED" in
    y) valid_port "$REALITY_PORT" || return 1 ;;
    *) REALITY_ENABLED="n"; REALITY_PORT="" ;;
  esac
}

load_ports_from_config() {
  [ -r "$CONF" ] || die "未找到配置：$CONF"
  command -v jq >/dev/null 2>&1 || die "从 config.json 恢复端口需要 jq"
  jq empty "$CONF" >/dev/null 2>&1 || die "config.json 不是有效 JSON"
  HY2_PORT="$(config_port hy2-in)"
  TUIC_PORT="$(config_port tuic-in)"
  ANYTLS_PORT="$(config_port anytls-in)"
  REALITY_PORT="$(config_port reality-in)"
  valid_port "$HY2_PORT" || die "config.json 中没有有效的 Hysteria2 端口"
  valid_port "$TUIC_PORT" || die "config.json 中没有有效的 TUIC 端口"
  valid_port "$ANYTLS_PORT" || die "config.json 中没有有效的 AnyTLS 端口"
  if valid_port "$REALITY_PORT"; then
    REALITY_ENABLED="y"
  else
    REALITY_ENABLED="n"
    REALITY_PORT=""
  fi
}

load_ports() {
  if load_ports_from_meta; then
    PORT_SOURCE="$META"
  else
    yellow "节点状态缺失或无效，改从 $CONF 读取监听端口。"
    load_ports_from_config
    PORT_SOURCE="$CONF"
  fi
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
  ss -H -lun 2>/dev/null | awk -v suffix=":$port" '
    $4 ~ suffix "$" { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

tcp_is_listening() {
  port="$1"
  ss -H -ltn 2>/dev/null | awk -v suffix=":$port" '
    $4 ~ suffix "$" { found = 1 }
    END { exit found ? 0 : 1 }
  '
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
    info "iptables INPUT 默认策略与项目规则："
    iptables -S INPUT 2>/dev/null | awk \
      -v h="$HY2_PORT" -v t="$TUIC_PORT" -v a="$ANYTLS_PORT" -v r="$REALITY_PORT" '
      NR == 1 || index($0, "SHWAY2_INPUT") || index($0, "--dport " h) ||
      index($0, "--dport " t) || index($0, "--dport " a) ||
      (r != "" && index($0, "--dport " r))
    ' || true
    iptables -S "$FIREWALL_CHAIN" 2>/dev/null || true
  else
    info "未安装 iptables。"
  fi

  if command -v nft >/dev/null 2>&1; then
    info ""
    info "nftables 中包含相关端口的规则："
    nft list ruleset 2>/dev/null | awk \
      -v h="$HY2_PORT" -v t="$TUIC_PORT" -v a="$ANYTLS_PORT" -v r="$REALITY_PORT" '
      index($0, h) || index($0, t) || index($0, a) || (r != "" && index($0, r))
    ' || true
  fi

  yellow "云安全组无法由 VPS 内部可靠读取，公网可达性必须在另一台机器执行 remote。"
}

server_check() {
  command -v ss >/dev/null 2>&1 || die "缺少 ss，请安装 iproute2"
  load_ports
  failed=0

  info "=== sing-box 服务端检查 ==="
  info "端口来源：$PORT_SOURCE"
  info "Hysteria2:   UDP $HY2_PORT"
  info "TUIC:        UDP $TUIC_PORT"
  info "AnyTLS:      TCP $ANYTLS_PORT"
  [ "$REALITY_ENABLED" = "n" ] || info "VLESS Reality: TCP $REALITY_PORT"
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

  if [ "$REALITY_ENABLED" = "y" ]; then
    if tcp_is_listening "$REALITY_PORT"; then
      green "[通过] VLESS Reality TCP $REALITY_PORT 正在本机监听"
    else
      red "[失败] VLESS Reality TCP $REALITY_PORT 未监听"
      failed=1
    fi
  fi

  show_firewall
  [ "$failed" -eq 0 ] || exit 1
}

refuse_self_scan() {
  target_host="$1"
  resolved_ips="$(getent ahostsv4 "$target_host" 2>/dev/null | awk '{ print $1 }' | sort -u || true)"
  [ -n "$resolved_ips" ] || return 0
  local_ips="$(ip -o -4 addr show 2>/dev/null | awk '{ split($4, a, "/"); print a[1] }')"
  public_ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  for resolved_ip in $resolved_ips; do
    if printf '%s\n%s\n' "$local_ips" "$public_ip" | awk -v target="$resolved_ip" '$0 == target { found = 1 } END { exit found ? 0 : 1 }'; then
      die "remote 目标 $target_host 指向本机地址 $resolved_ip；请在另一台机器执行公网探测"
    fi
  done
}

remote_check() {
  host="${1:-}"
  HY2_PORT="${2:-11451}"
  TUIC_PORT="${3:-11452}"
  ANYTLS_PORT="${4:-11453}"
  REALITY_PORT="${5:-11454}"
  [ -n "$host" ] || die "缺少服务器 IP 或域名"
  [ "$(id -u)" = "0" ] || die "UDP nmap 探测需要 root 权限"
  valid_port "$HY2_PORT" || die "Hysteria2 端口无效：$HY2_PORT"
  valid_port "$TUIC_PORT" || die "TUIC 端口无效：$TUIC_PORT"
  valid_port "$ANYTLS_PORT" || die "AnyTLS 端口无效：$ANYTLS_PORT"
  case "$REALITY_PORT" in
    -) REALITY_PORT="" ;;
    *) valid_port "$REALITY_PORT" || die "Reality 端口无效：$REALITY_PORT" ;;
  esac
  command -v nmap >/dev/null 2>&1 || die "remote 模式需要 nmap，请先安装 nmap"
  command -v getent >/dev/null 2>&1 || die "remote 模式需要 getent"
  refuse_self_scan "$host"

  tcp_ports="$ANYTLS_PORT"
  [ -z "$REALITY_PORT" ] || tcp_ports="$tcp_ports,$REALITY_PORT"
  info "=== 从当前机器探测 $host ==="
  info ""
  info "TCP/AnyTLS 与 Reality 探测："
  nmap -Pn -sT -p "$tcp_ports" "$host"
  info ""
  info "UDP/Hysteria2 与 TUIC 探测："
  nmap -Pn -sU -p "$HY2_PORT,$TUIC_PORT" "$host"
  info ""
  yellow "TCP 显示 open 才能确认端口可达。UDP 的 open|filtered 不能单独证明协议可用；closed 表示端口或路径明确不可达。"
}

case "${1:-server}" in
  server) server_check ;;
  remote) shift; remote_check "$@" ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
