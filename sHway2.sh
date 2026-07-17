#!/bin/sh
#
# sHway2 - lightweight single-user sing-box manager
# Supported: Debian 12 / Ubuntu 22.04 / Ubuntu 24.04 / Alpine

set -eu

BASE_DIR="/etc/sing-box"
CONF="$BASE_DIR/config.json"
META="$BASE_DIR/client-info.env"
CERT="$BASE_DIR/server.crt"
KEY="$BASE_DIR/server.key"
LINKS="$BASE_DIR/v2rayn-links.txt"
REALITY_PUBLIC_FILE="$BASE_DIR/reality-public.key"
BIN="/usr/local/bin/sing-box"
SB_BIN="/usr/local/bin/sb"
RUNTIME_DIR="/usr/local/lib/shway2"
MANAGER="$RUNTIME_DIR/manager.sh"
STATE_DIR="/var/lib/shway2"
BACKUP_DIR="$STATE_DIR/backups"
SERVICE_NAME="sing-box"
FIREWALL_CHAIN="SHWAY2_INPUT"
INSTALLER_VERSION="1.3"
STATE_FORMAT_VERSION="2"
MIN_SING_BOX_VERSION="1.12.0"
REPO_OWNER="FunMaximum"
REPO_NAME="sHway2"
SCRIPT_NAME="sHway2.sh"

TMP_DIR=""
STAGE_DIR=""
ROLLBACK_ARCHIVE=""
TRANSACTION_ACTIVE="n"
TRANSACTION_RESTORING="n"
BACKUP_RESULT=""

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
info() { printf '%s\n' "$*"; }

die() {
  red "错误：$*"
  exit 1
}

cleanup_paths() {
  [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
  [ -z "$STAGE_DIR" ] || rm -rf "$STAGE_DIR"
  TMP_DIR=""
  STAGE_DIR=""
}

cleanup() {
  status=$?
  trap - 0
  cleanup_paths
  if [ "$status" -ne 0 ] && [ "$TRANSACTION_ACTIVE" = "y" ] && \
     [ "$TRANSACTION_RESTORING" = "n" ]; then
    TRANSACTION_RESTORING="y"
    yellow "检测到安装或更新失败，正在恢复旧运行状态..."
    if [ -n "$ROLLBACK_ARCHIVE" ] && [ -s "$ROLLBACK_ARCHIVE" ]; then
      restore_archive_internal "$ROLLBACK_ARCHIVE" >/dev/null 2>&1 || \
        red "自动恢复失败，请手动执行：sudo sh $0 --restore $ROLLBACK_ARCHIVE"
    else
      stop_and_remove_service >/dev/null 2>&1 || true
      firewall_stop >/dev/null 2>&1 || true
      rm -rf "$BASE_DIR" "$RUNTIME_DIR"
      rm -f "$SB_BIN"
    fi
  fi
  exit "$status"
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
        22.04|22.04.*|jammy*|24.04|24.04.*|noble*) : ;;
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
    random_hex="$(openssl rand -hex 16)"
    printf '%s-%s-%s-%s-%s\n' \
      "$(printf '%s' "$random_hex" | cut -c1-8)" \
      "$(printf '%s' "$random_hex" | cut -c9-12)" \
      "$(printf '%s' "$random_hex" | cut -c13-16)" \
      "$(printf '%s' "$random_hex" | cut -c17-20)" \
      "$(printf '%s' "$random_hex" | cut -c21-32)"
  fi
}

valid_port() {
  port_value="$1"
  case "$port_value" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$port_value" -ge 1 ] 2>/dev/null && [ "$port_value" -le 65535 ] 2>/dev/null
}

valid_port_range() {
  port_range="$1"
  case "$port_range" in
    *:*) ;;
    *) return 1 ;;
  esac
  range_start=${port_range%%:*}
  range_end=${port_range#*:}
  [ "$range_end" = "${range_end#*:}" ] || return 1
  valid_port "$range_start" && valid_port "$range_end" && [ "$range_start" -le "$range_end" ]
}

valid_safe_text() {
  safe_value="$1"
  case "$safe_value" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

valid_positive_int() {
  int_value="$1"
  case "$int_value" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$int_value" -ge 1 ] 2>/dev/null
}

version_at_least() {
  current_version="$1"
  minimum_version="$2"
  awk -v current="$current_version" -v minimum="$minimum_version" 'BEGIN {
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
  url_value="$1"
  url_out=""
  url_index=1
  url_length=${#url_value}
  while [ "$url_index" -le "$url_length" ]; do
    url_char=$(printf '%s' "$url_value" | cut -c "$url_index")
    case "$url_char" in
      [a-zA-Z0-9.~_-]) url_out="$url_out$url_char" ;;
      ' ') url_out="$url_out%20" ;;
      *) url_out="$url_out$(printf '%%%02X' "'$url_char")" ;;
    esac
    url_index=$((url_index + 1))
  done
  printf '%s' "$url_out"
}

read_tty() {
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    read -r TTY_ANSWER </dev/tty || TTY_ANSWER=""
  else
    die "当前没有可交互终端，请先下载脚本后在终端中运行"
  fi
}

ask_value() {
  ask_prompt="$1"
  ask_default="$2"
  printf '%s [%s]: ' "$ask_prompt" "$ask_default" >/dev/tty
  read_tty
  [ -n "$TTY_ANSWER" ] || TTY_ANSWER="$ask_default"
  ANSWER="$TTY_ANSWER"
}

ask_yes_no() {
  yn_prompt="$1"
  yn_default="$2"
  while :; do
    printf '%s [%s]: ' "$yn_prompt" "$yn_default" >/dev/tty
    read_tty
    [ -n "$TTY_ANSWER" ] || TTY_ANSWER="$yn_default"
    case "$TTY_ANSWER" in
      y|Y|yes|YES|是) return 0 ;;
      n|N|no|NO|否) return 1 ;;
      *) yellow "请输入 y 或 n" ;;
    esac
  done
}

ask_safe_value() {
  safe_prompt="$1"
  safe_default="$2"
  while :; do
    ask_value "$safe_prompt" "$safe_default"
    valid_safe_text "$ANSWER" && return
    yellow "仅允许字母、数字、点、下划线和连字符，且不能为空"
  done
}

ask_port() {
  port_prompt="$1"
  port_default="$2"
  while :; do
    ask_value "$port_prompt" "$port_default"
    valid_port "$ANSWER" && return
    yellow "端口必须是 1-65535 的数字"
  done
}

ask_positive_int() {
  int_prompt="$1"
  int_default="$2"
  while :; do
    ask_value "$int_prompt" "$int_default"
    valid_positive_int "$ANSWER" && return
    yellow "请输入大于 0 的整数"
  done
}

get_ip() {
  detected_ip=""
  detected_ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [ -n "$detected_ip" ] || detected_ip="$(curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  printf '%s' "$detected_ip"
}

install_deps() {
  info "正在安装基础依赖..."
  case "$PKG_TYPE" in
    apt)
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ca-certificates curl tar openssl iptables iproute2 jq
      ;;
    apk)
      apk add --no-cache ca-certificates curl tar openssl iptables iproute2 jq
      ;;
    *) die "未知包管理器：$PKG_TYPE" ;;
  esac
}

install_sing_box() {
  if [ -x "$BIN" ]; then
    current_core="$($BIN version 2>/dev/null | awk 'NR==1{print $3}' || true)"
    if [ -n "$current_core" ] && version_at_least "$current_core" "$MIN_SING_BOX_VERSION"; then
      green "检测到兼容的 sing-box $current_core，将继续复用。"
      return
    fi
    yellow "已安装的 sing-box 版本未知或低于 $MIN_SING_BOX_VERSION，将下载兼容版本。"
  fi

  core_version="${SING_BOX_VERSION:-}"
  core_version="${core_version#v}"
  if [ -z "$core_version" ]; then
    info "正在查询 sing-box 最新版..."
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      core_api="$(curl -fsSL --max-time 20 -H "Authorization: Bearer $GITHUB_TOKEN" \
        https://api.github.com/repos/SagerNet/sing-box/releases/latest)" || \
        die "获取 sing-box 最新版本失败；可设置 SING_BOX_VERSION 跳过 API 查询"
    else
      core_api="$(curl -fsSL --max-time 20 \
        https://api.github.com/repos/SagerNet/sing-box/releases/latest)" || \
        die "获取 sing-box 最新版本失败；GitHub 限流时请设置 SING_BOX_VERSION"
    fi
    core_version="$(printf '%s' "$core_api" | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -n 1)"
    [ -n "$core_version" ] || die "解析 sing-box 最新版本失败"
  fi
  case "$core_version" in
    ''|*[!0-9A-Za-z.-]*) die "sing-box 版本格式无效：$core_version" ;;
  esac
  version_at_least "$core_version" "$MIN_SING_BOX_VERSION" || \
    die "sing-box $core_version 低于最低兼容版本 $MIN_SING_BOX_VERSION"

  TMP_DIR="$(mktemp -d /tmp/sing-box-install.XXXXXX)" || die "创建临时目录失败"
  if [ "$SINGBOX_FLAVOR" = "musl" ]; then
    core_url="https://github.com/SagerNet/sing-box/releases/download/v${core_version}/sing-box-${core_version}-linux-${ARCH}-musl.tar.gz"
  else
    core_url="https://github.com/SagerNet/sing-box/releases/download/v${core_version}/sing-box-${core_version}-linux-${ARCH}.tar.gz"
  fi
  curl -fL --retry 3 --connect-timeout 10 -o "$TMP_DIR/sing-box.tar.gz" "$core_url" || \
    die "下载 sing-box 失败：$core_url"
  tar -xzf "$TMP_DIR/sing-box.tar.gz" -C "$TMP_DIR"
  found_core="$(find "$TMP_DIR" -type f -name sing-box | head -n 1)"
  [ -n "$found_core" ] || die "解压后未找到 sing-box"
  install -m 0755 "$found_core" "$BIN"
  rm -rf "$TMP_DIR"
  TMP_DIR=""
  green "sing-box 安装完成：$($BIN version | awk 'NR==1{print $0}')"
}

state_defaults() {
  STATE_VERSION="1"
  PROTOCOL_SET="hysteria2,tuic,anytls"
  SERVER=""
  SNI=""
  HY2_PORT=""
  TUIC_PORT=""
  ANYTLS_PORT=""
  HY2_UP="50"
  HY2_DOWN="200"
  HY2_PASS=""
  HY2_OBFS=""
  TUIC_UUID=""
  TUIC_PASS=""
  ANYTLS_PASS=""
  REMARK_PREFIX="SB"
  HY2_JUMP="n"
  HY2_JUMP_RANGE=""
  FIREWALL_MANAGED="n"
  REALITY_ENABLED="n"
  REALITY_PORT=""
  REALITY_SNI=""
  REALITY_UUID=""
  REALITY_PRIVATE_KEY=""
  REALITY_PUBLIC_KEY=""
  REALITY_SHORT_ID=""
}

load_state() {
  state_file="${1:-$META}"
  [ -r "$state_file" ] || return 1
  state_defaults
  while IFS='=' read -r state_key state_value; do
    case "$state_key" in
      STATE_VERSION) STATE_VERSION="$state_value" ;;
      INSTALLER_VERSION) : ;;
      PROTOCOL_SET) PROTOCOL_SET="$state_value" ;;
      SERVER) SERVER="$state_value" ;;
      SNI) SNI="$state_value" ;;
      HY2_PORT) HY2_PORT="$state_value" ;;
      TUIC_PORT) TUIC_PORT="$state_value" ;;
      ANYTLS_PORT) ANYTLS_PORT="$state_value" ;;
      HY2_UP) HY2_UP="$state_value" ;;
      HY2_DOWN) HY2_DOWN="$state_value" ;;
      HY2_PASS) HY2_PASS="$state_value" ;;
      HY2_OBFS) HY2_OBFS="$state_value" ;;
      TUIC_UUID) TUIC_UUID="$state_value" ;;
      TUIC_PASS) TUIC_PASS="$state_value" ;;
      ANYTLS_PASS) ANYTLS_PASS="$state_value" ;;
      REMARK_PREFIX) REMARK_PREFIX="$state_value" ;;
      HY2_JUMP) HY2_JUMP="$state_value" ;;
      HY2_JUMP_RANGE) HY2_JUMP_RANGE="$state_value" ;;
      FIREWALL_MANAGED) FIREWALL_MANAGED="$state_value" ;;
      REALITY_ENABLED) REALITY_ENABLED="$state_value" ;;
      REALITY_PORT) REALITY_PORT="$state_value" ;;
      REALITY_SNI) REALITY_SNI="$state_value" ;;
      REALITY_UUID) REALITY_UUID="$state_value" ;;
      REALITY_PRIVATE_KEY) REALITY_PRIVATE_KEY="$state_value" ;;
      REALITY_PUBLIC_KEY) REALITY_PUBLIC_KEY="$state_value" ;;
      REALITY_SHORT_ID) REALITY_SHORT_ID="$state_value" ;;
    esac
  done < "$state_file"
  return 0
}

migrate_state() {
  case "$STATE_VERSION" in
    ''|1)
      STATE_VERSION="$STATE_FORMAT_VERSION"
      PROTOCOL_SET="hysteria2,tuic,anytls"
      REALITY_ENABLED="n"
      FIREWALL_MANAGED="${FIREWALL_MANAGED:-n}"
      ;;
    "$STATE_FORMAT_VERSION") : ;;
    *) die "状态文件版本 $STATE_VERSION 高于当前脚本支持版本 $STATE_FORMAT_VERSION" ;;
  esac
}

validate_state() {
  valid_safe_text "$SERVER" || die "服务器地址无效：$SERVER"
  valid_safe_text "$SNI" || die "TLS SNI 无效：$SNI"
  valid_safe_text "$REMARK_PREFIX" || die "节点名称前缀无效：$REMARK_PREFIX"
  valid_port "$HY2_PORT" || die "Hysteria2 端口无效：$HY2_PORT"
  valid_port "$TUIC_PORT" || die "TUIC 端口无效：$TUIC_PORT"
  valid_port "$ANYTLS_PORT" || die "AnyTLS 端口无效：$ANYTLS_PORT"
  valid_positive_int "$HY2_UP" || die "Hysteria2 上行带宽无效：$HY2_UP"
  valid_positive_int "$HY2_DOWN" || die "Hysteria2 下行带宽无效：$HY2_DOWN"
  if ! { [ -n "$HY2_PASS" ] && [ -n "$HY2_OBFS" ] && [ -n "$TUIC_UUID" ] && \
    [ -n "$TUIC_PASS" ] && [ -n "$ANYTLS_PASS" ]; }; then
    die "协议凭据不完整"
  fi
  case "$HY2_JUMP" in y|n) ;; *) die "HY2_JUMP 必须为 y 或 n" ;; esac
  if [ "$HY2_JUMP" = "y" ]; then
    valid_port_range "$HY2_JUMP_RANGE" || die "Hysteria2 跳跃范围无效：$HY2_JUMP_RANGE"
  fi
  case "$FIREWALL_MANAGED" in y|n) ;; *) die "FIREWALL_MANAGED 必须为 y 或 n" ;; esac
  case "$REALITY_ENABLED" in y|n) ;; *) die "REALITY_ENABLED 必须为 y 或 n" ;; esac
  if [ "$REALITY_ENABLED" = "y" ]; then
    valid_port "$REALITY_PORT" || die "Reality 端口无效：$REALITY_PORT"
    valid_safe_text "$REALITY_SNI" || die "Reality SNI 无效：$REALITY_SNI"
    if ! { [ -n "$REALITY_UUID" ] && [ -n "$REALITY_PRIVATE_KEY" ] && \
      [ -n "$REALITY_PUBLIC_KEY" ] && [ -n "$REALITY_SHORT_ID" ]; }; then
      die "Reality 凭据不完整"
    fi
  fi
}

port_in_use() {
  port_protocol="$1"
  checked_port="$2"
  case "$port_protocol" in
    udp) ss_flags="-lunp" ;;
    tcp) ss_flags="-ltnp" ;;
    *) return 1 ;;
  esac
  ss -H "$ss_flags" 2>/dev/null | awk -v suffix=":$checked_port" '
    $4 ~ suffix "$" && $0 !~ /sing-box/ { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

check_ports() {
  port_list="$HY2_PORT $TUIC_PORT $ANYTLS_PORT"
  [ "$REALITY_ENABLED" = "n" ] || port_list="$port_list $REALITY_PORT"
  seen_ports=""
  for checked_port in $port_list; do
    case " $seen_ports " in
      *" $checked_port "*) die "主服务端口不能重复：$checked_port" ;;
    esac
    seen_ports="$seen_ports $checked_port"
  done

  port_in_use udp "$HY2_PORT" && die "UDP 端口 $HY2_PORT 已被其他进程占用"
  port_in_use udp "$TUIC_PORT" && die "UDP 端口 $TUIC_PORT 已被其他进程占用"
  port_in_use tcp "$ANYTLS_PORT" && die "TCP 端口 $ANYTLS_PORT 已被其他进程占用"
  if [ "$REALITY_ENABLED" = "y" ]; then
    port_in_use tcp "$REALITY_PORT" && die "TCP 端口 $REALITY_PORT 已被其他进程占用"
  fi

  if [ "$HY2_JUMP" = "y" ]; then
    jump_start=${HY2_JUMP_RANGE%%:*}
    jump_end=${HY2_JUMP_RANGE#*:}
    for checked_port in $port_list; do
      if [ "$checked_port" -ge "$jump_start" ] && [ "$checked_port" -le "$jump_end" ]; then
        die "跳跃范围不能包含主服务端口 $checked_port"
      fi
    done
  fi
}

generate_reality_credentials() {
  reality_pair="$($BIN generate reality-keypair)" || die "生成 Reality 密钥失败"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "$reality_pair" | sed -n 's/^PrivateKey: //p' | head -n 1)"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "$reality_pair" | sed -n 's/^PublicKey: //p' | head -n 1)"
  REALITY_SHORT_ID="$($BIN generate rand 8 --hex)" || die "生成 Reality short ID 失败"
  REALITY_UUID="$(rand_uuid)"
  if ! { [ -n "$REALITY_PRIVATE_KEY" ] && [ -n "$REALITY_PUBLIC_KEY" ]; }; then
    die "解析 Reality 密钥失败"
  fi
}

collect_inputs() {
  state_defaults
  STATE_VERSION="$STATE_FORMAT_VERSION"
  PROTOCOL_SET="hysteria2,tuic,anytls,reality"
  REALITY_ENABLED="y"
  detected_server="$(get_ip)"
  info ""
  info "sHway2 v${INSTALLER_VERSION} — 轻量 sing-box 管理器"
  info "请按提示填写配置，直接回车使用默认值。"
  ask_safe_value "服务器地址/IP（用于客户端导入）" "$detected_server"
  SERVER="$ANSWER"
  ask_safe_value "TLS SNI/证书域名" "www.bing.com"
  SNI="$ANSWER"
  ask_port "Hysteria2 UDP 端口" "11451"
  HY2_PORT="$ANSWER"
  ask_port "TUIC v5 UDP 端口" "11452"
  TUIC_PORT="$ANSWER"
  ask_port "AnyTLS TCP 端口" "11453"
  ANYTLS_PORT="$ANSWER"
  ask_port "VLESS Reality TCP 端口" "11454"
  REALITY_PORT="$ANSWER"
  ask_safe_value "Reality 握手目标域名" "www.microsoft.com"
  REALITY_SNI="$ANSWER"
  ask_positive_int "Hysteria2 上行 Mbps（小鸡建议 50）" "50"
  HY2_UP="$ANSWER"
  ask_positive_int "Hysteria2 下行 Mbps（小鸡建议 200）" "200"
  HY2_DOWN="$ANSWER"
  ask_safe_value "节点名称前缀" "SB"
  REMARK_PREFIX="$ANSWER"

  HY2_JUMP="n"
  HY2_JUMP_RANGE=""
  if ask_yes_no "是否开启 Hysteria2 端口跳跃" "n"; then
    HY2_JUMP="y"
    while :; do
      ask_value "请输入跳跃端口范围，例如 20000:30000" "20000:30000"
      HY2_JUMP_RANGE="$ANSWER"
      valid_port_range "$HY2_JUMP_RANGE" || {
        yellow "端口跳跃范围必须是合法的 起始端口:结束端口"
        continue
      }
      break
    done
  fi

  FIREWALL_MANAGED="n"
  if ask_yes_no "是否自动放行本机防火墙端口" "n"; then
    FIREWALL_MANAGED="y"
  fi

  HY2_PASS="$(rand_hex 16)"
  HY2_OBFS="$(rand_hex 8)"
  TUIC_UUID="$(rand_uuid)"
  TUIC_PASS="$(rand_hex 16)"
  ANYTLS_PASS="$(rand_hex 16)"
  generate_reality_credentials
  validate_state
  check_ports
}

write_state_file() {
  state_output="$1"
  umask 077
  cat > "$state_output" <<EOF
STATE_VERSION=$STATE_FORMAT_VERSION
INSTALLER_VERSION=$INSTALLER_VERSION
PROTOCOL_SET=$PROTOCOL_SET
SERVER=$SERVER
SNI=$SNI
HY2_PORT=$HY2_PORT
TUIC_PORT=$TUIC_PORT
ANYTLS_PORT=$ANYTLS_PORT
HY2_UP=$HY2_UP
HY2_DOWN=$HY2_DOWN
HY2_PASS=$HY2_PASS
HY2_OBFS=$HY2_OBFS
TUIC_UUID=$TUIC_UUID
TUIC_PASS=$TUIC_PASS
ANYTLS_PASS=$ANYTLS_PASS
REMARK_PREFIX=$REMARK_PREFIX
HY2_JUMP=$HY2_JUMP
HY2_JUMP_RANGE=$HY2_JUMP_RANGE
FIREWALL_MANAGED=$FIREWALL_MANAGED
REALITY_ENABLED=$REALITY_ENABLED
REALITY_PORT=$REALITY_PORT
REALITY_SNI=$REALITY_SNI
REALITY_UUID=$REALITY_UUID
REALITY_PRIVATE_KEY=$REALITY_PRIVATE_KEY
REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY
REALITY_SHORT_ID=$REALITY_SHORT_ID
EOF
  chmod 600 "$state_output"
}

write_config_file() {
  config_output="$1"
  config_cert="$2"
  config_key="$3"
  umask 077
  cat > "$config_output" <<EOF
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
        "alpn": ["h3"],
        "certificate_path": "$config_cert",
        "key_path": "$config_key"
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
        "alpn": ["h3"],
        "certificate_path": "$config_cert",
        "key_path": "$config_key"
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
        "certificate_path": "$config_cert",
        "key_path": "$config_key"
      }
    }
EOF
  if [ "$REALITY_ENABLED" = "y" ]; then
    cat >> "$config_output" <<EOF
    ,{
      "type": "vless",
      "tag": "reality-in",
      "listen": "0.0.0.0",
      "listen_port": $REALITY_PORT,
      "users": [
        {
          "name": "reality",
          "uuid": "$REALITY_UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_SNI",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$REALITY_SNI",
            "server_port": 443
          },
          "private_key": "$REALITY_PRIVATE_KEY",
          "short_id": ["$REALITY_SHORT_ID"]
        }
      }
    }
EOF
  fi
  cat >> "$config_output" <<EOF
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
  chmod 600 "$config_output"
}

write_links_file() {
  links_output="$1"
  encoded_server="$(urlencode "$SERVER")"
  encoded_sni="$(urlencode "$SNI")"
  encoded_hy2_pass="$(urlencode "$HY2_PASS")"
  encoded_hy2_obfs="$(urlencode "$HY2_OBFS")"
  encoded_tuic_pass="$(urlencode "$TUIC_PASS")"
  encoded_anytls_pass="$(urlencode "$ANYTLS_PASS")"
  encoded_hy2_name="$(urlencode "$REMARK_PREFIX-HY2")"
  encoded_tuic_name="$(urlencode "$REMARK_PREFIX-TUIC5")"
  encoded_anytls_name="$(urlencode "$REMARK_PREFIX-AnyTLS")"
  hy2_extra=""
  if [ "$HY2_JUMP" = "y" ]; then
    hy2_extra="&mport=$(urlencode "$HY2_JUMP_RANGE")"
  fi
  HY2_LINK="hysteria2://${encoded_hy2_pass}@${encoded_server}:${HY2_PORT}/?sni=${encoded_sni}&insecure=1&obfs=salamander&obfs-password=${encoded_hy2_obfs}${hy2_extra}#${encoded_hy2_name}"
  TUIC_LINK="tuic://${TUIC_UUID}:${encoded_tuic_pass}@${encoded_server}:${TUIC_PORT}/?sni=${encoded_sni}&alpn=h3&allow_insecure=1&congestion_control=bbr&udp_relay_mode=native#${encoded_tuic_name}"
  ANYTLS_LINK="anytls://${encoded_anytls_pass}@${encoded_server}:${ANYTLS_PORT}/?security=tls&sni=${encoded_sni}&insecure=1#${encoded_anytls_name}"
  REALITY_LINK=""
  if [ "$REALITY_ENABLED" = "y" ]; then
    encoded_reality_sni="$(urlencode "$REALITY_SNI")"
    encoded_reality_name="$(urlencode "$REMARK_PREFIX-Reality")"
    REALITY_LINK="vless://${REALITY_UUID}@${encoded_server}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${encoded_reality_sni}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none&spx=%2F#${encoded_reality_name}"
  fi
  umask 077
  {
    printf '%s\n' "$HY2_LINK"
    printf '%s\n' "$TUIC_LINK"
    printf '%s\n' "$ANYTLS_LINK"
    [ -z "$REALITY_LINK" ] || printf '%s\n' "$REALITY_LINK"
  } > "$links_output"
  chmod 600 "$links_output"
}

prepare_certificate() {
  cert_destination="$1"
  key_destination="$2"
  current_cn=""
  if [ -s "$CERT" ]; then
    current_cn="$(openssl x509 -in "$CERT" -noout -subject -nameopt RFC2253 2>/dev/null | \
      sed -n 's/^subject=CN=//p' || true)"
  fi
  if [ -s "$CERT" ] && [ -s "$KEY" ] && [ "$current_cn" = "$SNI" ]; then
    cp -p "$CERT" "$cert_destination"
    cp -p "$KEY" "$key_destination"
  else
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -keyout "$key_destination" -out "$cert_destination" -subj "/CN=$SNI" >/dev/null 2>&1 || \
      die "生成 TLS 证书失败"
  fi
  chmod 600 "$key_destination"
}

firewall_start() {
  load_state "$META" || return 0
  migrate_state
  if [ "$FIREWALL_MANAGED" = "y" ]; then
    iptables -N "$FIREWALL_CHAIN" 2>/dev/null || true
    iptables -F "$FIREWALL_CHAIN"
    iptables -A "$FIREWALL_CHAIN" -p udp --dport "$HY2_PORT" -j ACCEPT
    iptables -A "$FIREWALL_CHAIN" -p udp --dport "$TUIC_PORT" -j ACCEPT
    iptables -A "$FIREWALL_CHAIN" -p tcp --dport "$ANYTLS_PORT" -j ACCEPT
    if [ "$REALITY_ENABLED" = "y" ]; then
      iptables -A "$FIREWALL_CHAIN" -p tcp --dport "$REALITY_PORT" -j ACCEPT
    fi
    iptables -A "$FIREWALL_CHAIN" -j RETURN
    iptables -C INPUT -j "$FIREWALL_CHAIN" 2>/dev/null || \
      iptables -I INPUT 1 -j "$FIREWALL_CHAIN"
  fi
  if [ "$HY2_JUMP" = "y" ]; then
    iptables -t nat -D PREROUTING -p udp --dport "$HY2_JUMP_RANGE" \
      -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null || true
    iptables -t nat -A PREROUTING -p udp --dport "$HY2_JUMP_RANGE" \
      -j REDIRECT --to-ports "$HY2_PORT"
  fi
}

firewall_stop() {
  if load_state "$META"; then
    migrate_state
    if [ "$HY2_JUMP" = "y" ] && valid_port_range "$HY2_JUMP_RANGE" && valid_port "$HY2_PORT"; then
      while iptables -t nat -C PREROUTING -p udp --dport "$HY2_JUMP_RANGE" \
        -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null; do
        iptables -t nat -D PREROUTING -p udp --dport "$HY2_JUMP_RANGE" \
          -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null || break
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

write_systemd_service() {
  unit_tmp="/etc/systemd/system/.${SERVICE_NAME}.service.$$"
  cat > "$unit_tmp" <<EOF
[Unit]
Description=sing-box service managed by sHway2
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
LimitNOFILE=65535
ExecStartPre=$MANAGER internal-firewall start
ExecStart=$BIN run -c $CONF
ExecStopPost=-$MANAGER internal-firewall stop
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  mv "$unit_tmp" "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null
}

write_openrc_service() {
  init_tmp="/etc/init.d/.${SERVICE_NAME}.$$"
  cat > "$init_tmp" <<EOF
#!/sbin/openrc-run

name="sing-box"
description="sing-box service managed by sHway2"
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
  "$MANAGER" internal-firewall start
}

stop_post() {
  "$MANAGER" internal-firewall stop || true
}
EOF
  chmod 755 "$init_tmp"
  mv "$init_tmp" "/etc/init.d/${SERVICE_NAME}"
  rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
}

stop_service() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
  fi
}

start_service() {
  detect_init
  if [ "$INIT" = "systemd" ]; then
    write_systemd_service
    systemctl restart "$SERVICE_NAME" || return 1
    systemctl is-active --quiet "$SERVICE_NAME" || return 1
  else
    write_openrc_service
    rc-service "$SERVICE_NAME" restart || return 1
    rc-service "$SERVICE_NAME" status >/dev/null 2>&1 || return 1
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

install_runtime_manager() {
  mkdir -p "$RUNTIME_DIR"
  chmod 700 "$RUNTIME_DIR"
  install -m 0755 "$0" "$MANAGER"
  sb_tmp="${SB_BIN}.tmp.$$"
  cat > "$sb_tmp" <<EOF
#!/bin/sh
exec "$MANAGER" manage "\$@"
EOF
  chmod 755 "$sb_tmp"
  mv "$sb_tmp" "$SB_BIN"
}

create_backup() {
  backup_output="$1"
  backup_reason="${2:-manual}"
  backup_parent="$(dirname "$backup_output")"
  mkdir -p "$backup_parent"
  if [ "$backup_parent" = "$BACKUP_DIR" ]; then
    chmod 700 "$STATE_DIR" "$BACKUP_DIR" 2>/dev/null || true
  fi
  backup_tmp="$(mktemp -d /tmp/shway2-backup.XXXXXX)" || return 1
  backup_root="$backup_tmp/shway2-backup"
  mkdir -p "$backup_root"
  {
    printf 'FORMAT=1\n'
    printf 'REASON=%s\n' "$backup_reason"
    printf 'CREATED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'INSTALLER_VERSION=%s\n' "$INSTALLER_VERSION"
  } > "$backup_root/manifest.env"
  [ ! -d "$BASE_DIR" ] || cp -pR "$BASE_DIR" "$backup_root/etc-sing-box"
  [ ! -x "$BIN" ] || cp -p "$BIN" "$backup_root/sing-box"
  [ ! -d "$RUNTIME_DIR" ] || cp -pR "$RUNTIME_DIR" "$backup_root/runtime"
  [ ! -f "$SB_BIN" ] || cp -p "$SB_BIN" "$backup_root/sb"
  [ ! -f "/etc/systemd/system/${SERVICE_NAME}.service" ] || \
    cp -p "/etc/systemd/system/${SERVICE_NAME}.service" "$backup_root/systemd.service"
  [ ! -f "/etc/init.d/${SERVICE_NAME}" ] || \
    cp -p "/etc/init.d/${SERVICE_NAME}" "$backup_root/openrc.service"
  tar -czf "$backup_output.tmp.$$" -C "$backup_tmp" shway2-backup || {
    rm -rf "$backup_tmp" "$backup_output.tmp.$$"
    return 1
  }
  chmod 600 "$backup_output.tmp.$$"
  mv "$backup_output.tmp.$$" "$backup_output"
  rm -rf "$backup_tmp"
  BACKUP_RESULT="$backup_output"
}

validate_backup_archive() {
  archive_file="$1"
  [ -s "$archive_file" ] || return 1
  archive_list="$(mktemp /tmp/shway2-archive-list.XXXXXX)" || return 1
  if ! tar -tzf "$archive_file" > "$archive_list" 2>/dev/null; then
    rm -f "$archive_list"
    return 1
  fi
  invalid_entry="$(awk '
    /(^|\/)\.\.(\/|$)/ { print; exit }
    $0 != "shway2-backup/" &&
    $0 !~ /^shway2-backup\/(manifest\.env|etc-sing-box(\/.*)?|sing-box|runtime(\/.*)?|sb|systemd\.service|openrc\.service)$/ { print; exit }
  ' "$archive_list")"
  manifest_count="$(awk '$0 == "shway2-backup/manifest.env" { count++ } END { print count + 0 }' \
    "$archive_list")"
  rm -f "$archive_list"
  [ -z "$invalid_entry" ] && [ "$manifest_count" -eq 1 ]
}

restore_archive_internal() {
  restore_archive="$1"
  validate_backup_archive "$restore_archive" || return 1
  restore_tmp="$(mktemp -d /tmp/shway2-restore.XXXXXX)" || return 1
  tar -xzf "$restore_archive" -C "$restore_tmp" || {
    rm -rf "$restore_tmp"
    return 1
  }
  restore_root="$restore_tmp/shway2-backup"
  stop_service
  firewall_stop >/dev/null 2>&1 || true
  rm -rf "$BASE_DIR" "$RUNTIME_DIR"
  rm -f "$SB_BIN" "/etc/systemd/system/${SERVICE_NAME}.service" "/etc/init.d/${SERVICE_NAME}"
  [ ! -d "$restore_root/etc-sing-box" ] || cp -pR "$restore_root/etc-sing-box" "$BASE_DIR"
  [ ! -f "$restore_root/sing-box" ] || install -m 0755 "$restore_root/sing-box" "$BIN"
  [ ! -d "$restore_root/runtime" ] || cp -pR "$restore_root/runtime" "$RUNTIME_DIR"
  [ ! -f "$restore_root/sb" ] || install -m 0755 "$restore_root/sb" "$SB_BIN"
  [ ! -f "$restore_root/systemd.service" ] || \
    cp -p "$restore_root/systemd.service" "/etc/systemd/system/${SERVICE_NAME}.service"
  [ ! -f "$restore_root/openrc.service" ] || \
    cp -p "$restore_root/openrc.service" "/etc/init.d/${SERVICE_NAME}"
  rm -rf "$restore_tmp"
  if command -v systemctl >/dev/null 2>&1 && [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE_NAME" || return 1
    systemctl is-active --quiet "$SERVICE_NAME" || return 1
  elif command -v rc-service >/dev/null 2>&1 && [ -f "/etc/init.d/${SERVICE_NAME}" ]; then
    chmod 755 "/etc/init.d/${SERVICE_NAME}"
    rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
    rc-service "$SERVICE_NAME" restart || return 1
  fi
}

make_rollback_backup() {
  [ -d "$BASE_DIR" ] || return 0
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$STATE_DIR" "$BACKUP_DIR" 2>/dev/null || true
  rollback_name="$BACKUP_DIR/transaction-$(date +%Y%m%d-%H%M%S)-$$.tar.gz"
  create_backup "$rollback_name" transaction || die "创建事务备份失败"
  ROLLBACK_ARCHIVE="$BACKUP_RESULT"
}

prepare_stage() {
  STAGE_DIR="$(mktemp -d /tmp/shway2-stage.XXXXXX)" || die "创建配置暂存目录失败"
  chmod 700 "$STAGE_DIR"
  prepare_certificate "$STAGE_DIR/server.crt" "$STAGE_DIR/server.key"
  write_state_file "$STAGE_DIR/client-info.env"
  write_links_file "$STAGE_DIR/v2rayn-links.txt"
  if [ "$REALITY_ENABLED" = "y" ]; then
    printf '%s\n' "$REALITY_PUBLIC_KEY" > "$STAGE_DIR/reality-public.key"
    chmod 600 "$STAGE_DIR/reality-public.key"
  fi
  write_config_file "$STAGE_DIR/config.json" "$STAGE_DIR/server.crt" "$STAGE_DIR/server.key"
  "$BIN" check -c "$STAGE_DIR/config.json" || die "暂存 sing-box 配置检查失败"
}

commit_stage() {
  stop_service
  firewall_stop >/dev/null 2>&1 || true
  mkdir -p "$BASE_DIR"
  chmod 700 "$BASE_DIR"
  install -m 0600 "$STAGE_DIR/server.crt" "$CERT"
  install -m 0600 "$STAGE_DIR/server.key" "$KEY"
  install -m 0600 "$STAGE_DIR/client-info.env" "$META"
  install -m 0600 "$STAGE_DIR/v2rayn-links.txt" "$LINKS"
  if [ "$REALITY_ENABLED" = "y" ]; then
    install -m 0600 "$STAGE_DIR/reality-public.key" "$REALITY_PUBLIC_FILE"
  else
    rm -f "$REALITY_PUBLIC_FILE"
  fi
  write_config_file "$CONF" "$CERT" "$KEY"
  "$BIN" check -c "$CONF" || return 1
  install_runtime_manager
  start_service || return 1
}

run_install() {
  install_mode="$1"
  need_root
  detect_os
  detect_arch
  install_deps
  if [ "${SHWAY2_SKIP_BACKUP:-0}" != "1" ]; then
    make_rollback_backup
  fi
  TRANSACTION_ACTIVE="y"
  install_sing_box
  if [ "$install_mode" = "reuse" ]; then
    load_state "$META" || die "缺少状态文件：$META；请先执行 --repair-state"
    migrate_state
    validate_state
    check_ports
  else
    collect_inputs
  fi
  prepare_stage
  commit_stage || die "sing-box 配置提交或服务启动失败"
  TRANSACTION_ACTIVE="n"
  rm -rf "$STAGE_DIR"
  STAGE_DIR=""
  green ""
  green "sHway2 v$INSTALLER_VERSION 安装完成。"
  print_links
  yellow "云安全组仍需手工放行实际端口；本机防火墙是否管理以安装时选择为准。"
}

print_links() {
  load_state "$META" || die "未找到节点信息：$META，请先安装或修复状态"
  migrate_state
  validate_state
  write_links_file "$LINKS"
  info "Hysteria2:"
  info "$HY2_LINK"
  info ""
  info "TUIC v5:"
  info "$TUIC_LINK"
  info ""
  info "AnyTLS:"
  info "$ANYTLS_LINK"
  if [ "$REALITY_ENABLED" = "y" ]; then
    info ""
    info "VLESS Reality:"
    info "$REALITY_LINK"
  fi
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

restart_service_command() {
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
  elif [ -s /var/log/sing-box.log ]; then
    cat /var/log/sing-box.log
  else
    die "未找到日志文件：/var/log/sing-box.log"
  fi
}

socket_listening() {
  socket_protocol="$1"
  socket_port="$2"
  case "$socket_protocol" in
    udp) socket_flags="-lun" ;;
    tcp) socket_flags="-ltn" ;;
    *) return 1 ;;
  esac
  ss -H "$socket_flags" 2>/dev/null | awk -v suffix=":$socket_port" '
    $4 ~ suffix "$" { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

doctor_port_from_config() {
  doctor_tag="$1"
  jq -r --arg tag "$doctor_tag" '.inbounds[] | select(.tag == $tag) | .listen_port // empty' \
    "$CONF" 2>/dev/null | head -n 1
}

doctor() {
  doctor_failed=0
  info "=== sHway2 本机诊断 ==="
  if [ -x "$BIN" ]; then
    green "[通过] sing-box：$($BIN version | awk 'NR==1{print $3}')"
  else
    red "[失败] 未找到 sing-box：$BIN"
    doctor_failed=1
  fi
  if [ -r "$CONF" ] && jq empty "$CONF" >/dev/null 2>&1 && \
     [ -x "$BIN" ] && "$BIN" check -c "$CONF" >/dev/null 2>&1; then
    green "[通过] sing-box 配置有效"
  else
    red "[失败] sing-box 配置无效或缺失：$CONF"
    doctor_failed=1
  fi

  if load_state "$META"; then
    migrate_state
    green "[通过] 状态文件存在：$META"
  else
    yellow "[警告] 状态文件缺失，将从 config.json 读取端口；可执行 sb repair"
    state_defaults
    HY2_PORT="$(doctor_port_from_config hy2-in)"
    TUIC_PORT="$(doctor_port_from_config tuic-in)"
    ANYTLS_PORT="$(doctor_port_from_config anytls-in)"
    REALITY_PORT="$(doctor_port_from_config reality-in)"
    if valid_port "$REALITY_PORT"; then
      REALITY_ENABLED="y"
    fi
  fi

  detect_init
  if { [ "$INIT" = "systemd" ] && systemctl is-active --quiet "$SERVICE_NAME"; } || \
     { [ "$INIT" = "openrc" ] && rc-service "$SERVICE_NAME" status >/dev/null 2>&1; }; then
    green "[通过] sing-box 服务正在运行"
  else
    red "[失败] sing-box 服务未运行"
    doctor_failed=1
  fi

  for doctor_item in "udp:Hysteria2:$HY2_PORT" "udp:TUIC:$TUIC_PORT" "tcp:AnyTLS:$ANYTLS_PORT"; do
    doctor_protocol=${doctor_item%%:*}
    doctor_rest=${doctor_item#*:}
    doctor_name=${doctor_rest%%:*}
    doctor_port=${doctor_rest#*:}
    if valid_port "$doctor_port" && socket_listening "$doctor_protocol" "$doctor_port"; then
      green "[通过] $doctor_name $doctor_protocol/$doctor_port 正在监听"
    else
      red "[失败] $doctor_name $doctor_protocol/${doctor_port:-未知} 未监听"
      doctor_failed=1
    fi
  done
  if [ "$REALITY_ENABLED" = "y" ]; then
    if valid_port "$REALITY_PORT" && socket_listening tcp "$REALITY_PORT"; then
      green "[通过] Reality tcp/$REALITY_PORT 正在监听"
    else
      red "[失败] Reality tcp/${REALITY_PORT:-未知} 未监听"
      doctor_failed=1
    fi
  fi

  if [ -s "$CERT" ] && openssl x509 -in "$CERT" -noout -checkend 0 >/dev/null 2>&1; then
    green "[通过] 自签证书仍在有效期内"
  else
    red "[失败] 自签证书缺失、损坏或过期"
    doctor_failed=1
  fi
  if iptables -S "$FIREWALL_CHAIN" >/dev/null 2>&1; then
    info "本机防火墙：已发现 $FIREWALL_CHAIN 项目规则链"
  else
    info "本机防火墙：未发现项目规则链（安装时可能选择不管理）"
  fi
  if ip -6 route show default 2>/dev/null | grep -q .; then
    info "IPv6：存在默认路由"
  else
    yellow "[警告] IPv6 无默认路由；目标仅有 IPv6 时直连会失败"
  fi
  yellow "[提示] 本机诊断无法验证云安全组和真实公网客户端路径。"
  [ "$doctor_failed" -eq 0 ]
}

repair_state() {
  need_root
  detect_os
  install_deps
  [ -r "$CONF" ] || die "未找到配置：$CONF"
  jq empty "$CONF" >/dev/null 2>&1 || die "config.json 不是有效 JSON"
  state_defaults
  STATE_VERSION="$STATE_FORMAT_VERSION"
  HY2_PORT="$(doctor_port_from_config hy2-in)"
  TUIC_PORT="$(doctor_port_from_config tuic-in)"
  ANYTLS_PORT="$(doctor_port_from_config anytls-in)"
  HY2_UP="$(jq -r '.inbounds[] | select(.tag == "hy2-in") | .up_mbps // 50' "$CONF")"
  HY2_DOWN="$(jq -r '.inbounds[] | select(.tag == "hy2-in") | .down_mbps // 200' "$CONF")"
  HY2_PASS="$(jq -r '.inbounds[] | select(.tag == "hy2-in") | .users[0].password // empty' "$CONF")"
  HY2_OBFS="$(jq -r '.inbounds[] | select(.tag == "hy2-in") | .obfs.password // empty' "$CONF")"
  TUIC_UUID="$(jq -r '.inbounds[] | select(.tag == "tuic-in") | .users[0].uuid // empty' "$CONF")"
  TUIC_PASS="$(jq -r '.inbounds[] | select(.tag == "tuic-in") | .users[0].password // empty' "$CONF")"
  ANYTLS_PASS="$(jq -r '.inbounds[] | select(.tag == "anytls-in") | .users[0].password // empty' "$CONF")"
  SNI="$(jq -r '.inbounds[] | select(.tag == "hy2-in") | .tls.server_name // empty' "$CONF")"
  REALITY_PORT="$(doctor_port_from_config reality-in)"
  if valid_port "$REALITY_PORT"; then
    REALITY_ENABLED="y"
    PROTOCOL_SET="hysteria2,tuic,anytls,reality"
    REALITY_SNI="$(jq -r '.inbounds[] | select(.tag == "reality-in") | .tls.reality.handshake.server // empty' "$CONF")"
    REALITY_UUID="$(jq -r '.inbounds[] | select(.tag == "reality-in") | .users[0].uuid // empty' "$CONF")"
    REALITY_PRIVATE_KEY="$(jq -r '.inbounds[] | select(.tag == "reality-in") | .tls.reality.private_key // empty' "$CONF")"
    REALITY_SHORT_ID="$(jq -r '.inbounds[] | select(.tag == "reality-in") | .tls.reality.short_id[0] // empty' "$CONF")"
    [ -r "$REALITY_PUBLIC_FILE" ] || \
      die "缺少 Reality 公钥备份：$REALITY_PUBLIC_FILE，无法无损恢复节点链接"
    REALITY_PUBLIC_KEY="$(sed -n '1p' "$REALITY_PUBLIC_FILE")"
    [ -n "$REALITY_PUBLIC_KEY" ] || die "Reality 公钥备份为空"
  else
    REALITY_ENABLED="n"
    PROTOCOL_SET="hysteria2,tuic,anytls"
  fi
  detected_server="$(get_ip)"
  ask_safe_value "服务器地址/IP（用于客户端导入）" "$detected_server"
  SERVER="$ANSWER"
  ask_safe_value "节点名称前缀" "SB"
  REMARK_PREFIX="$ANSWER"
  HY2_JUMP="n"
  HY2_JUMP_RANGE=""
  recovered_range="$(iptables -t nat -S PREROUTING 2>/dev/null | awk -v port="$HY2_PORT" '
    index($0, "--to-ports " port) {
      for (i = 1; i <= NF; i++) if ($i == "--dport") { print $(i + 1); exit }
    }
  ')"
  if valid_port_range "$recovered_range"; then
    HY2_JUMP="y"
    HY2_JUMP_RANGE="$recovered_range"
  fi
  FIREWALL_MANAGED="n"
  iptables -S "$FIREWALL_CHAIN" >/dev/null 2>&1 && FIREWALL_MANAGED="y"
  validate_state
  state_tmp="$BASE_DIR/.client-info.env.$$"
  write_state_file "$state_tmp"
  mv "$state_tmp" "$META"
  write_links_file "$LINKS"
  green "状态文件已恢复：$META"
}

backup_command() {
  [ "$#" -le 1 ] || die "backup 最多接受一个输出文件"
  backup_output="${1:-$BACKUP_DIR/manual-$(date +%Y%m%d-%H%M%S).tar.gz}"
  create_backup "$backup_output" manual || die "创建备份失败"
  green "备份已创建：$BACKUP_RESULT"
}

rollback_command() {
  [ "$#" -le 1 ] || die "rollback 最多接受一个备份文件"
  rollback_target="${1:-}"
  if [ -z "$rollback_target" ]; then
    rollback_target="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'update-*.tar.gz' 2>/dev/null | \
      sort -r | head -n 1 || true)"
  fi
  [ -n "$rollback_target" ] || die "没有可用的回滚备份"
  pre_rollback="$BACKUP_DIR/pre-rollback-$(date +%Y%m%d-%H%M%S)-$$.tar.gz"
  create_backup "$pre_rollback" pre-rollback || die "创建回滚前备份失败"
  if restore_archive_internal "$rollback_target"; then
    green "已恢复备份：$rollback_target"
  else
    red "恢复目标备份失败，正在恢复回滚前状态..."
    restore_archive_internal "$pre_rollback" || die "回滚前状态也恢复失败：$pre_rollback"
    die "目标备份恢复失败"
  fi
}

latest_release_tag() {
  requested_version="${1:-${SHWAY2_VERSION:-}}"
  if [ -n "$requested_version" ]; then
    case "$requested_version" in v*) ;; *) requested_version="v$requested_version" ;; esac
    printf '%s' "$requested_version"
    return
  fi
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    release_api="$(curl -fsSL --max-time 15 -H "Authorization: Bearer $GITHUB_TOKEN" \
      "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest")" || return 1
  else
    release_api="$(curl -fsSL --max-time 15 \
      "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest")" || return 1
  fi
  printf '%s' "$release_api" | jq -r '.tag_name // empty'
}

prune_update_backups() {
  backup_number=0
  find "$BACKUP_DIR" -maxdepth 1 -type f -name 'update-*.tar.gz' 2>/dev/null | \
    sort -r | while IFS= read -r old_backup; do
    backup_number=$((backup_number + 1))
    [ "$backup_number" -le 3 ] || rm -f "$old_backup"
  done
}

update_command() {
  requested=""
  force_update="n"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force) force_update="y" ;;
      v*|[0-9]*) [ -z "$requested" ] || die "只能指定一个版本"; requested="$1" ;;
      *) die "未知 update 参数：$1" ;;
    esac
    shift
  done
  load_state "$META" || die "状态文件缺失，请先执行：sb repair"
  migrate_state
  target_tag="$(latest_release_tag "$requested")" || die "查询最新版本失败"
  [ -n "$target_tag" ] || die "无法解析目标版本"
  case "$target_tag" in
    v[0-9]*) : ;;
    *) die "目标版本格式无效：$target_tag" ;;
  esac
  case "$target_tag" in
    *[!0-9A-Za-z.v-]*|*..*) die "目标版本格式无效：$target_tag" ;;
  esac
  if [ "$force_update" = "n" ] && [ "v$INSTALLER_VERSION" = "$target_tag" ]; then
    green "当前已是 $target_tag，无需更新。"
    return
  fi
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$STATE_DIR" "$BACKUP_DIR" 2>/dev/null || true
  update_backup="$BACKUP_DIR/update-$(date +%Y%m%d-%H%M%S)-v${INSTALLER_VERSION}.tar.gz"
  create_backup "$update_backup" update || die "创建更新备份失败"
  update_tmp="$(mktemp /tmp/shway2-update.XXXXXX.sh)" || die "创建更新临时文件失败"
  if [ -n "${SHWAY2_INSTALLER_URL:-}" ]; then
    update_url="$SHWAY2_INSTALLER_URL"
  else
    update_url="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/refs/tags/${target_tag}/${SCRIPT_NAME}"
  fi
  curl -fsSL --retry 3 --connect-timeout 10 -o "$update_tmp" "$update_url" || {
    rm -f "$update_tmp"
    die "下载安装器失败：$update_url"
  }
  sh -n "$update_tmp" || {
    rm -f "$update_tmp"
    die "下载的安装器语法检查失败"
  }
  info "正在更新到 $target_tag..."
  if SHWAY2_SKIP_BACKUP=1 sh "$update_tmp" --reuse; then
    rm -f "$update_tmp"
    prune_update_backups
    green "更新完成：$target_tag"
  else
    rm -f "$update_tmp"
    red "更新失败，正在恢复旧版本..."
    restore_archive_internal "$update_backup" || die "自动恢复失败：$update_backup"
    die "更新失败，旧版本已恢复"
  fi
}

confirm_uninstall() {
  confirm_yes="$1"
  [ "$confirm_yes" = "y" ] && return 0
  if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
    die "当前没有交互终端；确认卸载请使用：sb uninstall --yes"
  fi
  printf '将卸载 sHway2 服务和配置，但保留 sing-box 内核。继续？[y/N]: ' >/dev/tty
  read_tty
  case "$TTY_ANSWER" in y|Y|yes|YES|是) ;; *) yellow "已取消卸载。"; return 1 ;; esac
}

uninstall_command() {
  uninstall_yes="n"
  uninstall_backup="y"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes) uninstall_yes="y" ;;
      --no-backup) uninstall_backup="n" ;;
      *) die "未知 uninstall 参数：$1" ;;
    esac
    shift
  done
  confirm_uninstall "$uninstall_yes" || return 0
  if [ "$uninstall_backup" = "y" ] && [ -d "$BASE_DIR" ]; then
    uninstall_archive="/root/sHway2-backup-$(date +%Y%m%d-%H%M%S)-$$.tar.gz"
    create_backup "$uninstall_archive" uninstall || die "卸载前备份失败"
    green "卸载备份：$BACKUP_RESULT"
  fi
  stop_service
  firewall_stop >/dev/null 2>&1 || true
  stop_and_remove_service
  rm -rf "$BASE_DIR" "$RUNTIME_DIR" "$STATE_DIR"
  rm -f "$SB_BIN" /var/log/sing-box.log
  green "sHway2 已卸载；sing-box 内核和系统依赖已保留。"
}

version_command() {
  info "sHway2: v$INSTALLER_VERSION"
  if [ -x "$BIN" ]; then
    info "sing-box: $($BIN version | awk 'NR==1{print $3}')"
  else
    info "sing-box: 未安装"
  fi
  if load_state "$META"; then
    migrate_state
    info "协议：$PROTOCOL_SET"
  else
    info "协议：状态文件缺失"
  fi
}

manager_usage() {
  cat <<EOF
用法：sb [命令]

  show                    显示节点链接（默认）
  status                  查看服务状态
  restart                 重启服务
  log                     查看日志
  doctor                  本机只读诊断
  repair                  修复缺失的状态文件
  version                 显示版本与协议集合
  update [v版本] [--force] 原地更新并保留节点
  backup [文件]           创建恢复备份
  rollback [备份文件]     恢复最近或指定备份
  uninstall [--yes] [--no-backup]
                          卸载服务，默认先备份
  help                    显示帮助
EOF
}

manage() {
  need_root
  manager_command="${1:-show}"
  [ "$#" -eq 0 ] || shift
  case "$manager_command" in
    show) print_links ;;
    status) show_status ;;
    restart) restart_service_command ;;
    log) show_log ;;
    doctor) doctor ;;
    repair) repair_state ;;
    version) version_command ;;
    update) update_command "$@" ;;
    backup) backup_command "$@" ;;
    rollback) rollback_command "$@" ;;
    uninstall) uninstall_command "$@" ;;
    help|-h|--help) manager_usage ;;
    *) manager_usage; die "未知命令：$manager_command" ;;
  esac
}

installer_usage() {
  cat <<EOF
用法：
  sudo sh sHway2.sh
  sudo sh sHway2.sh --reuse
  sudo sh sHway2.sh --repair-state
  sudo sh sHway2.sh --restore <备份文件>
EOF
}

restore_command() {
  restore_target="${1:-}"
  [ -n "$restore_target" ] || die "--restore 缺少备份文件"
  need_root
  detect_os
  install_deps
  restore_archive_internal "$restore_target" || die "恢复备份失败：$restore_target"
  green "备份恢复完成：$restore_target"
}

case "${1:-}" in
  manage)
    shift
    manage "$@"
    ;;
  internal-firewall)
    need_root
    case "${2:-}" in
      start) firewall_start ;;
      stop) firewall_stop ;;
      *) exit 2 ;;
    esac
    ;;
  --reuse)
    [ "$#" -eq 1 ] || die "--reuse 不接受其他参数"
    run_install reuse
    ;;
  --repair-state)
    [ "$#" -eq 1 ] || die "--repair-state 不接受其他参数"
    repair_state
    ;;
  --restore)
    [ "$#" -eq 2 ] || die "--restore 需要一个备份文件"
    restore_command "$2"
    ;;
  help|-h|--help)
    installer_usage
    ;;
  '')
    run_install fresh
    ;;
  *)
    installer_usage
    die "未知参数：$1"
    ;;
esac
