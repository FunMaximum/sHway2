#!/bin/sh
#
# sHway2
# Hysteria2 + TUIC v5 + AnyTLS 一键部署脚本
# 支持系统：Debian 12 / Ubuntu 22.04 / Ubuntu 24.04 / Alpine
#
# 功能：
#   - 自动安装或复用兼容的 sing-box
#   - 自签 TLS 证书 / 交互式端口配置
#   - Hysteria2 端口跳跃（iptables NAT）
#   - 输出 v2rayN 兼容分享链接
#   - 生成 sb 管理脚本

set -eu

BASE_DIR="/etc/sing-box"
CONF="$BASE_DIR/config.json"
META="$BASE_DIR/client-info.env"
CERT="$BASE_DIR/server.crt"
KEY="$BASE_DIR/server.key"
BIN="/usr/local/bin/sing-box"
SERVICE_NAME="sing-box"
INSTALLER_VERSION="1.0"
MIN_SING_BOX_VERSION="1.12.0"
TMP_DIR=""
CERT_TMP=""
KEY_TMP=""

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
info() { printf '%s\n' "$*"; }

die() {
  red "错误：$*"
  exit 1
}

cleanup() {
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
  [ -z "$CERT_TMP" ] || rm -f "$CERT_TMP"
  [ -z "$KEY_TMP" ] || rm -f "$KEY_TMP"
}

trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

need_root() {
  [ "$(id -u)" = "0" ] || die "请使用 root 用户运行：sudo sh $0"
}

detect_os() {
  [ -r /etc/os-release ] || die "无法识别系统，仅支持 Debian 12 / Ubuntu 22.04 / Ubuntu 24.04 / Alpine"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_VER="${VERSION_ID:-}"

  # 规范化为小写，兼容 Ubuntu 的 ID 也可能为 "Ubuntu"
  OS_ID_LOWER="$(printf '%s' "$OS_ID" | tr '[:upper:]' '[:lower:]')"

  case "$OS_ID_LOWER" in
    debian)
      case "$OS_VER" in
        12*|bookworm*) : ;;
        *) yellow "提示：当前 Debian 版本为 $OS_VER，脚本按 Debian 12 方式继续。" ;;
      esac
      INIT="systemd"
      SINGBOX_FLAVOR="glibc"
      PKG_TYPE="apt"
      ;;
    ubuntu)
      case "$OS_VER" in
        22.04|22.04.*|jammy*) : ;;
        24.04|24.04.*|noble*) : ;;
        *) yellow "提示：当前 Ubuntu 版本为 $OS_VER，脚本按 Ubuntu 22.04/24.04 方式继续。" ;;
      esac
      INIT="systemd"
      SINGBOX_FLAVOR="glibc"
      PKG_TYPE="apt"
      ;;
    alpine)
      INIT="openrc"
      SINGBOX_FLAVOR="musl"
      PKG_TYPE="apk"
      ;;
    *)
      die "当前系统 $OS_ID 暂不支持，仅支持 Debian 12 / Ubuntu 22.04 / Ubuntu 24.04 / Alpine"
      ;;
  esac

  green "检测到系统：$OS_ID $OS_VER → 初始化 $INIT，sing-box $SINGBOX_FLAVOR 版本"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l|armv7*) ARCH="armv7" ;;
    *) die "不支持的 CPU 架构：$(uname -m)" ;;
  esac
}

rand_hex() {
  openssl rand -hex "$1"
}

rand_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    h="$(openssl rand -hex 16)"
    printf '%s-%s-%s-%s-%s\n' \
      "$(printf '%s' "$h" | cut -c1-8)" \
      "$(printf '%s' "$h" | cut -c9-12)" \
      "$(printf '%s' "$h" | cut -c13-16)" \
      "$(printf '%s' "$h" | cut -c17-20)" \
      "$(printf '%s' "$h" | cut -c21-32)"
  fi
}

read_tty() {
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    read -r ans </dev/tty || ans=""
  else
    die "当前没有可交互终端，请使用：curl -fsSL 脚本地址 -o /tmp/install.sh && sh /tmp/install.sh"
  fi
}

ask_value() {
  ASK_VALUE_PROMPT="$1"
  ASK_VALUE_DEFAULT="$2"
  printf '%s [%s]: ' "$ASK_VALUE_PROMPT" "$ASK_VALUE_DEFAULT" >/dev/tty
  read_tty
  [ -n "$ans" ] || ans="$ASK_VALUE_DEFAULT"
  ANSWER="$ans"
}

ask_yes_no() {
  ASK_YN_PROMPT="$1"
  ASK_YN_DEFAULT="$2"
  while :; do
    printf '%s [%s]: ' "$ASK_YN_PROMPT" "$ASK_YN_DEFAULT" >/dev/tty
    read_tty
    [ -z "$ans" ] && ans="$ASK_YN_DEFAULT"
    case "$ans" in
      y|Y|yes|YES|是) return 0 ;;
      n|N|no|NO|否) return 1 ;;
      *) yellow "请输入 y 或 n" ;;
    esac
  done
}

valid_port() {
  p="$1"
  case "$p" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$p" -ge 1 ] 2>/dev/null && [ "$p" -le 65535 ] 2>/dev/null
}

ask_port_var() {
  ASK_PORT_NAME="$1"
  ASK_PORT_DEFAULT="$2"
  while :; do
    printf '%s [%s]: ' "$ASK_PORT_NAME" "$ASK_PORT_DEFAULT" >/dev/tty
    read_tty
    [ -n "$ans" ] || ans="$ASK_PORT_DEFAULT"
    if valid_port "$ans"; then
      ANSWER="$ans"
      return
    fi
    yellow "端口必须是 1-65535 的数字"
  done
}

valid_safe_text() {
  value="$1"
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

ask_safe_value() {
  ASK_SAFE_PROMPT="$1"
  ASK_SAFE_DEFAULT="$2"
  while :; do
    ask_value "$ASK_SAFE_PROMPT" "$ASK_SAFE_DEFAULT"
    if valid_safe_text "$ANSWER"; then
      return
    fi
    yellow "仅允许字母、数字、点、下划线和连字符，且不能为空"
  done
}

valid_positive_int() {
  value="$1"
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$value" -ge 1 ] 2>/dev/null
}

ask_positive_int() {
  ASK_INT_PROMPT="$1"
  ASK_INT_DEFAULT="$2"
  while :; do
    ask_value "$ASK_INT_PROMPT" "$ASK_INT_DEFAULT"
    if valid_positive_int "$ANSWER"; then
      return
    fi
    yellow "请输入大于 0 的整数"
  done
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

port_in_use() {
  protocol="$1"
  port="$2"
  case "$protocol" in
    udp) flags="-H-lunp" ;;
    tcp) flags="-H-ltnp" ;;
    *) return 1 ;;
  esac
  ss "$flags" 2>/dev/null | awk -v suffix=":$port" '
    $5 ~ suffix "$" && $0 !~ /sing-box/ { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

check_ports() {
  [ "$HY2_PORT" != "$TUIC_PORT" ] || die "Hysteria2 与 TUIC 的 UDP 端口不能相同"
  [ "$HY2_PORT" != "$ANYTLS_PORT" ] || die "Hysteria2 与 AnyTLS 的端口不能相同"
  [ "$TUIC_PORT" != "$ANYTLS_PORT" ] || die "TUIC 与 AnyTLS 的端口不能相同"

  port_in_use udp "$HY2_PORT" && die "UDP 端口 $HY2_PORT 已被其他进程占用"
  port_in_use udp "$TUIC_PORT" && die "UDP 端口 $TUIC_PORT 已被其他进程占用"
  port_in_use tcp "$ANYTLS_PORT" && die "TCP 端口 $ANYTLS_PORT 已被其他进程占用"
  return 0
}

version_at_least() {
  current="$1"
  minimum="$2"
  awk -v current="$current" -v minimum="$minimum" 'BEGIN {
    split(current, a, /[^0-9]+/)
    split(minimum, b, /[^0-9]+/)
    for (i = 1; i <= 3; i++) {
      av = a[i] + 0
      bv = b[i] + 0
      if (av > bv) exit 0
      if (av < bv) exit 1
    }
    exit 0
  }'
}

urlencode() {
  s="$1"
  out=""
  i=1
  len=${#s}
  while [ "$i" -le "$len" ]; do
    c=$(printf '%s' "$s" | cut -c "$i")
    case "$c" in
      [a-zA-Z0-9.~_-]) out="$out$c" ;;
      ' ') out="$out%20" ;;
      *) out="$out$(printf '%%%02X' "'${c}")" ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$out"
}

get_ip() {
  ip=""
  ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [ -n "$ip" ] || ip="$(curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  printf '%s' "$ip"
}

install_deps() {
  info "正在安装基础依赖..."
  case "$PKG_TYPE" in
    apt)
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl tar openssl iptables iproute2
      ;;
    apk)
      apk add --no-cache ca-certificates curl tar openssl iptables iproute2
      ;;
    *)
      die "未知包管理器：$PKG_TYPE"
      ;;
  esac
}

install_sing_box() {
  if [ -x "$BIN" ]; then
    cur="$($BIN version 2>/dev/null | awk 'NR==1{print $3}' || true)"
    if [ -n "$cur" ] && version_at_least "$cur" "$MIN_SING_BOX_VERSION"; then
      green "检测到兼容的 sing-box $cur，将继续覆盖配置。"
      return
    fi
    yellow "已安装的 sing-box 版本未知或低于 $MIN_SING_BOX_VERSION，将下载兼容版本。"
  fi

  tag="${SING_BOX_VERSION:-}"
  tag="${tag#v}"
  if [ -z "$tag" ]; then
    info "正在查询 sing-box 最新版..."
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      api="$(curl -fsSL --max-time 20 -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/repos/SagerNet/sing-box/releases/latest)" || \
        die "获取 sing-box 最新版本失败；可设置 SING_BOX_VERSION 跳过 API 查询"
    else
      api="$(curl -fsSL --max-time 20 https://api.github.com/repos/SagerNet/sing-box/releases/latest)" || \
        die "获取 sing-box 最新版本失败；GitHub 限流时请设置 SING_BOX_VERSION"
    fi
    tag="$(printf '%s' "$api" | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -n 1)"
    [ -n "$tag" ] || die "解析 sing-box 最新版本失败"
  fi
  case "$tag" in
    ''|*[!0-9A-Za-z.-]*) die "sing-box 版本格式无效：$tag" ;;
  esac
  version_at_least "$tag" "$MIN_SING_BOX_VERSION" || die "sing-box $tag 低于最低兼容版本 $MIN_SING_BOX_VERSION"

  case "$ARCH" in
    amd64) file_arch="amd64" ;;
    arm64) file_arch="arm64" ;;
    armv7) file_arch="armv7" ;;
  esac

  TMP_DIR="$(mktemp -d /tmp/sing-box-install.XXXXXX)" || die "创建临时目录失败"
  if [ "$SINGBOX_FLAVOR" = "musl" ]; then
    url="https://github.com/SagerNet/sing-box/releases/download/v${tag}/sing-box-${tag}-linux-${file_arch}-musl.tar.gz"
  else
    url="https://github.com/SagerNet/sing-box/releases/download/v${tag}/sing-box-${tag}-linux-${file_arch}.tar.gz"
  fi
  curl -fL --retry 3 --connect-timeout 10 -o "$TMP_DIR/sing-box.tar.gz" "$url" || die "下载 sing-box 失败：$url"
  tar -xzf "$TMP_DIR/sing-box.tar.gz" -C "$TMP_DIR"
  found="$(find "$TMP_DIR" -type f -name sing-box | head -n 1)"
  [ -n "$found" ] || die "解压后未找到 sing-box"
  install -m 0755 "$found" "$BIN"
  rm -rf "$TMP_DIR"
  TMP_DIR=""
  green "sing-box 安装完成：$($BIN version | awk 'NR==1{print $0}')"
}

collect_inputs() {
  server_addr="$(get_ip)"
  info ""
  info "sHway2 v${INSTALLER_VERSION} — sing-box 一键部署"
  info "请按提示填写配置，直接回车使用默认值。"
  ask_safe_value "服务器地址/IP（用于客户端导入）" "$server_addr"
  SERVER="$ANSWER"
  ask_safe_value "TLS SNI/证书域名（自签可随意，建议填域名）" "www.bing.com"
  SNI="$ANSWER"
  ask_port_var "Hysteria2 UDP 端口" "11451"
  HY2_PORT="$ANSWER"
  ask_port_var "TUIC v5 UDP 端口" "11452"
  TUIC_PORT="$ANSWER"
  ask_port_var "AnyTLS TCP 端口" "11453"
  ANYTLS_PORT="$ANSWER"
  ask_positive_int "Hysteria2 上行 Mbps（小鸡建议 50）" "50"
  HY2_UP="$ANSWER"
  ask_positive_int "Hysteria2 下行 Mbps（小鸡建议 200）" "200"
  HY2_DOWN="$ANSWER"
  ask_safe_value "节点名称前缀" "SB"
  REMARK_PREFIX="$ANSWER"
  check_ports

  HY2_JUMP="n"
  HY2_JUMP_RANGE=""
  if ask_yes_no "是否开启 Hysteria2 端口跳跃（UDP 端口段转发到 HY2 主端口）" "n"; then
    HY2_JUMP="y"
    while :; do
      ask_value "请输入跳跃端口范围，例如 20000:30000" "20000:30000"
      HY2_JUMP_RANGE="$ANSWER"
      if valid_port_range "$HY2_JUMP_RANGE"; then
        jump_start=${HY2_JUMP_RANGE%%:*}
        jump_end=${HY2_JUMP_RANGE#*:}
        if { [ "$HY2_PORT" -ge "$jump_start" ] && [ "$HY2_PORT" -le "$jump_end" ]; } || \
           { [ "$TUIC_PORT" -ge "$jump_start" ] && [ "$TUIC_PORT" -le "$jump_end" ]; } || \
           { [ "$ANYTLS_PORT" -ge "$jump_start" ] && [ "$ANYTLS_PORT" -le "$jump_end" ]; }; then
          yellow "跳跃范围不能包含三个主服务端口"
        else
          break
        fi
      else
        yellow "端口跳跃范围必须是合法的 起始端口:结束端口，且起始端口不大于结束端口"
      fi
    done
  fi

  HY2_PASS="$(rand_hex 16)"
  HY2_OBFS="$(rand_hex 8)"
  TUIC_UUID="$(rand_uuid)"
  TUIC_PASS="$(rand_hex 16)"
  ANYTLS_PASS="$(rand_hex 16)"
}

write_cert() {
  mkdir -p "$BASE_DIR"
  chmod 700 "$BASE_DIR"
  cert_cn=""
  if [ -s "$CERT" ]; then
    cert_cn="$(openssl x509 -in "$CERT" -noout -subject -nameopt RFC2253 2>/dev/null | sed -n 's/^subject=CN=//p' || true)"
  fi
  if [ ! -s "$CERT" ] || [ ! -s "$KEY" ] || [ "$cert_cn" != "$SNI" ]; then
    info "正在生成自签 TLS 证书..."
    CERT_TMP="$BASE_DIR/.server.crt.$$"
    KEY_TMP="$BASE_DIR/.server.key.$$"
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -keyout "$KEY_TMP" -out "$CERT_TMP" -subj "/CN=$SNI" >/dev/null 2>&1 || {
        rm -f "$CERT_TMP" "$KEY_TMP"
        CERT_TMP=""
        KEY_TMP=""
        die "生成 TLS 证书失败"
      }
    chmod 600 "$KEY_TMP"
    mv "$KEY_TMP" "$KEY"
    KEY_TMP=""
    mv "$CERT_TMP" "$CERT"
    CERT_TMP=""
    chmod 600 "$KEY"
  fi
}

write_config() {
  info "正在写入 sing-box 配置..."
  cat > "$CONF" <<EOF
{
  "log": {
    "disabled": false,
    "level": "warn",
    "timestamp": false
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "0.0.0.0",
      "listen_port": $HY2_PORT,
      "up_mbps": $HY2_UP,
      "down_mbps": $HY2_DOWN,
      "obfs": {
        "type": "salamander",
        "password": "$HY2_OBFS"
      },
      "users": [
        {
          "name": "hy2",
          "password": "$HY2_PASS"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "alpn": [
          "h3"
        ],
        "certificate_path": "$CERT",
        "key_path": "$KEY"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "0.0.0.0",
      "listen_port": $TUIC_PORT,
      "users": [
        {
          "name": "tuic",
          "uuid": "$TUIC_UUID",
          "password": "$TUIC_PASS"
        }
      ],
      "congestion_control": "bbr",
      "auth_timeout": "3s",
      "zero_rtt_handshake": false,
      "heartbeat": "10s",
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "alpn": [
          "h3"
        ],
        "certificate_path": "$CERT",
        "key_path": "$KEY"
      }
    },
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "0.0.0.0",
      "listen_port": $ANYTLS_PORT,
      "users": [
        {
          "name": "anytls",
          "password": "$ANYTLS_PASS"
        }
      ],
      "padding_scheme": [],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "certificate_path": "$CERT",
        "key_path": "$KEY"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

  cat > "$META" <<EOF
SERVER=$SERVER
SNI=$SNI
HY2_PORT=$HY2_PORT
TUIC_PORT=$TUIC_PORT
ANYTLS_PORT=$ANYTLS_PORT
HY2_PASS=$HY2_PASS
HY2_OBFS=$HY2_OBFS
TUIC_UUID=$TUIC_UUID
TUIC_PASS=$TUIC_PASS
ANYTLS_PASS=$ANYTLS_PASS
REMARK_PREFIX=$REMARK_PREFIX
HY2_JUMP=$HY2_JUMP
HY2_JUMP_RANGE=$HY2_JUMP_RANGE
EOF
  chmod 600 "$CONF" "$META"
}

read_old_jump() {
  OLD_HY2_JUMP="n"
  OLD_HY2_JUMP_RANGE=""
  OLD_HY2_PORT=""
  [ -r "$META" ] || return 0

  OLD_HY2_JUMP="$(sed -n 's/^HY2_JUMP=//p' "$META" | head -n 1)"
  OLD_HY2_JUMP_RANGE="$(sed -n 's/^HY2_JUMP_RANGE=//p' "$META" | head -n 1)"
  OLD_HY2_PORT="$(sed -n 's/^HY2_PORT=//p' "$META" | head -n 1)"
  OLD_HY2_JUMP="${OLD_HY2_JUMP#\'}"
  OLD_HY2_JUMP="${OLD_HY2_JUMP%\'}"
  OLD_HY2_JUMP_RANGE="${OLD_HY2_JUMP_RANGE#\'}"
  OLD_HY2_JUMP_RANGE="${OLD_HY2_JUMP_RANGE%\'}"
  OLD_HY2_PORT="${OLD_HY2_PORT#\'}"
  OLD_HY2_PORT="${OLD_HY2_PORT%\'}"
}

cleanup_old_jump_rule() {
  if [ "$OLD_HY2_JUMP" = "y" ] && valid_port_range "$OLD_HY2_JUMP_RANGE" && valid_port "$OLD_HY2_PORT"; then
    iptables -t nat -D PREROUTING -p udp --dport "$OLD_HY2_JUMP_RANGE" \
      -j REDIRECT --to-ports "$OLD_HY2_PORT" 2>/dev/null || true
  fi
}

write_systemd_service() {
  pre=""
  if [ "$HY2_JUMP" = "y" ]; then
    pre="ExecStartPre=-/usr/sbin/iptables -t nat -D PREROUTING -p udp --dport $HY2_JUMP_RANGE -j REDIRECT --to-ports $HY2_PORT\nExecStartPre=/usr/sbin/iptables -t nat -A PREROUTING -p udp --dport $HY2_JUMP_RANGE -j REDIRECT --to-ports $HY2_PORT\nExecStopPost=-/usr/sbin/iptables -t nat -D PREROUTING -p udp --dport $HY2_JUMP_RANGE -j REDIRECT --to-ports $HY2_PORT"
  fi

  cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
LimitNOFILE=65535
$(printf '%b' "$pre")
ExecStart=$BIN run -c $CONF
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
}

write_openrc_service() {
  cat > /etc/init.d/${SERVICE_NAME} <<EOF
#!/sbin/openrc-run

name="sing-box"
description="sing-box service"
command="$BIN"
command_args="run -c $CONF"
command_background="yes"
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"

depend() {
  need net
  after firewall
}

start_pre() {
  :
EOF
  if [ "$HY2_JUMP" = "y" ]; then
    cat >> /etc/init.d/${SERVICE_NAME} <<EOF
  iptables -t nat -D PREROUTING -p udp --dport $HY2_JUMP_RANGE -j REDIRECT --to-ports $HY2_PORT 2>/dev/null || true
  iptables -t nat -A PREROUTING -p udp --dport $HY2_JUMP_RANGE -j REDIRECT --to-ports $HY2_PORT
EOF
  fi
  cat >> /etc/init.d/${SERVICE_NAME} <<EOF
}

stop_post() {
  :
EOF
  if [ "$HY2_JUMP" = "y" ]; then
    cat >> /etc/init.d/${SERVICE_NAME} <<EOF
  iptables -t nat -D PREROUTING -p udp --dport $HY2_JUMP_RANGE -j REDIRECT --to-ports $HY2_PORT 2>/dev/null || true
EOF
  fi
  cat >> /etc/init.d/${SERVICE_NAME} <<EOF
}
EOF
  chmod +x /etc/init.d/${SERVICE_NAME}
  rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
  rc-service "$SERVICE_NAME" restart
}

check_config() {
  info "正在检查配置..."
  "$BIN" check -c "$CONF" || die "sing-box 配置检查失败"
}

restart_service() {
  cleanup_old_jump_rule
  if [ "$INIT" = "systemd" ]; then
    write_systemd_service
    systemctl restart "$SERVICE_NAME"
    systemctl is-active --quiet "$SERVICE_NAME" || die "sing-box 启动失败，请查看：journalctl -u sing-box -e"
  else
    write_openrc_service
    rc-service "$SERVICE_NAME" status >/dev/null 2>&1 || die "sing-box 启动失败，请查看：cat /var/log/sing-box.log"
  fi
}

print_links() {
  e_server="$(urlencode "$SERVER")"
  e_sni="$(urlencode "$SNI")"
  e_hy2_pass="$(urlencode "$HY2_PASS")"
  e_hy2_obfs="$(urlencode "$HY2_OBFS")"
  e_tuic_pass="$(urlencode "$TUIC_PASS")"
  e_anytls_pass="$(urlencode "$ANYTLS_PASS")"
  e_r_hy2="$(urlencode "$REMARK_PREFIX-HY2")"
  e_r_tuic="$(urlencode "$REMARK_PREFIX-TUIC5")"
  e_r_anytls="$(urlencode "$REMARK_PREFIX-AnyTLS")"

  hy2_extra=""
  if [ "$HY2_JUMP" = "y" ]; then
    hy2_extra="&mport=$(urlencode "$HY2_JUMP_RANGE")"
  fi

  hy2_link="hysteria2://${e_hy2_pass}@${e_server}:${HY2_PORT}/?sni=${e_sni}&insecure=1&obfs=salamander&obfs-password=${e_hy2_obfs}${hy2_extra}#${e_r_hy2}"
  tuic_link="tuic://${TUIC_UUID}:${e_tuic_pass}@${e_server}:${TUIC_PORT}/?sni=${e_sni}&alpn=h3&allow_insecure=1&congestion_control=bbr&udp_relay_mode=native#${e_r_tuic}"
  anytls_link="anytls://${e_anytls_pass}@${e_server}:${ANYTLS_PORT}/?security=tls&sni=${e_sni}&insecure=1#${e_r_anytls}"

  cat > "$BASE_DIR/v2rayn-links.txt" <<EOF
$hy2_link
$tuic_link
$anytls_link
EOF
  chmod 600 "$BASE_DIR/v2rayn-links.txt"

  green ""
  green "安装完成。以下链接可复制到 v2rayN 导入："
  info ""
  info "Hysteria2:"
  info "$hy2_link"
  info ""
  info "TUIC v5:"
  info "$tuic_link"
  info ""
  info "AnyTLS:"
  info "$anytls_link"
  info ""
  info "链接已保存：$BASE_DIR/v2rayn-links.txt"
  info "服务端配置：$CONF"
  info ""
  yellow "注意：HY2/TUIC 使用 UDP，AnyTLS 使用 TCP。若 VPS 厂商有安全组，请放行对应端口。自签证书需要客户端允许不安全证书。"
}

write_manager() {
  cat > /usr/local/bin/sb <<'EOF'
#!/bin/sh

set -eu

BASE_DIR="/etc/sing-box"
META="$BASE_DIR/client-info.env"
LINKS="$BASE_DIR/v2rayn-links.txt"
SERVICE_NAME="sing-box"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info() { printf '%s\n' "$*"; }

die() {
  red "错误：$*"
  exit 1
}

detect_init() {
  if command -v systemctl >/dev/null 2>&1; then
    INIT="systemd"
  elif command -v rc-service >/dev/null 2>&1; then
    INIT="openrc"
  else
    die "无法识别服务管理器，仅支持 systemd / OpenRC"
  fi
}

usage() {
  cat <<EOL
用法：sb [命令]

可用命令：
  show       显示 v2rayN 导入链接，默认命令
  status     查看 sing-box 运行状态
  restart    重启 sing-box 服务
  log        查看 sing-box 日志
  help       显示此帮助

示例：
  sb
  sb show
  sb status
  sb restart
  sb log
EOL
}

urlencode() {
  s="$1"
  out=""
  i=1
  len=${#s}
  while [ "$i" -le "$len" ]; do
    c=$(printf '%s' "$s" | cut -c "$i")
    case "$c" in
      [a-zA-Z0-9.~_-]) out="$out$c" ;;
      ' ') out="$out%20" ;;
      *) out="$out$(printf '%%%02X' "'${c}")" ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$out"
}

load_meta() {
  SERVER=""
  SNI=""
  HY2_PORT=""
  TUIC_PORT=""
  ANYTLS_PORT=""
  HY2_PASS=""
  HY2_OBFS=""
  TUIC_UUID=""
  TUIC_PASS=""
  ANYTLS_PASS=""
  REMARK_PREFIX=""
  HY2_JUMP="n"
  HY2_JUMP_RANGE=""

  while IFS='=' read -r key value; do
    case "$key" in
      SERVER) SERVER="$value" ;;
      SNI) SNI="$value" ;;
      HY2_PORT) HY2_PORT="$value" ;;
      TUIC_PORT) TUIC_PORT="$value" ;;
      ANYTLS_PORT) ANYTLS_PORT="$value" ;;
      HY2_PASS) HY2_PASS="$value" ;;
      HY2_OBFS) HY2_OBFS="$value" ;;
      TUIC_UUID) TUIC_UUID="$value" ;;
      TUIC_PASS) TUIC_PASS="$value" ;;
      ANYTLS_PASS) ANYTLS_PASS="$value" ;;
      REMARK_PREFIX) REMARK_PREFIX="$value" ;;
      HY2_JUMP) HY2_JUMP="$value" ;;
      HY2_JUMP_RANGE) HY2_JUMP_RANGE="$value" ;;
    esac
  done < "$META"

  [ -n "$SERVER" ] && [ -n "$SNI" ] && [ -n "$HY2_PORT" ] && \
    [ -n "$TUIC_PORT" ] && [ -n "$ANYTLS_PORT" ] && [ -n "$HY2_PASS" ] && \
    [ -n "$HY2_OBFS" ] && [ -n "$TUIC_UUID" ] && [ -n "$TUIC_PASS" ] && \
    [ -n "$ANYTLS_PASS" ] && [ -n "$REMARK_PREFIX" ] || \
    die "节点信息不完整或格式错误：$META"
}

print_links() {
  [ -r "$META" ] || die "未找到节点信息：$META，请先运行安装脚本"
  load_meta

  e_server="$(urlencode "$SERVER")"
  e_sni="$(urlencode "$SNI")"
  e_hy2_pass="$(urlencode "$HY2_PASS")"
  e_hy2_obfs="$(urlencode "$HY2_OBFS")"
  e_tuic_pass="$(urlencode "$TUIC_PASS")"
  e_anytls_pass="$(urlencode "$ANYTLS_PASS")"
  e_r_hy2="$(urlencode "$REMARK_PREFIX-HY2")"
  e_r_tuic="$(urlencode "$REMARK_PREFIX-TUIC5")"
  e_r_anytls="$(urlencode "$REMARK_PREFIX-AnyTLS")"

  hy2_extra=""
  if [ "${HY2_JUMP:-n}" = "y" ]; then
    hy2_extra="&mport=$(urlencode "$HY2_JUMP_RANGE")"
  fi

  hy2_link="hysteria2://${e_hy2_pass}@${e_server}:${HY2_PORT}/?sni=${e_sni}&insecure=1&obfs=salamander&obfs-password=${e_hy2_obfs}${hy2_extra}#${e_r_hy2}"
  tuic_link="tuic://${TUIC_UUID}:${e_tuic_pass}@${e_server}:${TUIC_PORT}/?sni=${e_sni}&alpn=h3&allow_insecure=1&congestion_control=bbr&udp_relay_mode=native#${e_r_tuic}"
  anytls_link="anytls://${e_anytls_pass}@${e_server}:${ANYTLS_PORT}/?security=tls&sni=${e_sni}&insecure=1#${e_r_anytls}"

  umask 077
  cat > "$LINKS" <<EOL
$hy2_link
$tuic_link
$anytls_link
EOL

  green "节点信息如下，可复制到 v2rayN 导入："
  info ""
  info "Hysteria2:"
  info "$hy2_link"
  info ""
  info "TUIC v5:"
  info "$tuic_link"
  info ""
  info "AnyTLS:"
  info "$anytls_link"
  info ""
  info "链接已保存：$LINKS"
}

show_status() {
  detect_init
  if [ "$INIT" = "systemd" ]; then
    systemctl status "$SERVICE_NAME" --no-pager
  else
    rc-service "$SERVICE_NAME" status
  fi
}

restart_service() {
  detect_init
  if [ "$INIT" = "systemd" ]; then
    systemctl restart "$SERVICE_NAME"
    systemctl status "$SERVICE_NAME" --no-pager
  else
    rc-service "$SERVICE_NAME" restart
    rc-service "$SERVICE_NAME" status
  fi
}

show_log() {
  detect_init
  if [ "$INIT" = "systemd" ]; then
    journalctl -u "$SERVICE_NAME" -e --no-pager
  else
    if [ -s /var/log/sing-box.log ]; then
      cat /var/log/sing-box.log
    else
      die "未找到日志文件：/var/log/sing-box.log"
    fi
  fi
}

cmd="${1:-show}"
case "$cmd" in
  show) print_links ;;
  status) show_status ;;
  restart) restart_service ;;
  log) show_log ;;
  help|-h|--help) usage ;;
  *)
    red "未知命令：$cmd"
    usage
    exit 1
    ;;
esac
EOF
  chmod 755 /usr/local/bin/sb
}

main() {
  need_root
  detect_os
  detect_arch
  install_deps
  install_sing_box
  read_old_jump
  collect_inputs
  write_cert
  write_config
  check_config
  restart_service
  write_manager
  print_links
}

main "$@"
