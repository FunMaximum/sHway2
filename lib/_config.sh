#!/bin/sh
# sHway2 - 配置收集与写入模块

collect_inputs() {
  server_addr="$(get_ip)"
  info ""
  info "sHway2 v$(load_version) — sing-box 一键部署"
  info "请按提示填写配置，直接回车使用默认值。"
  ask_var SERVER "服务器地址/IP（用于客户端导入）" "$server_addr"
  ask_var SNI "TLS SNI/证书域名（自签可随意，建议填域名）" "www.bing.com"
  ask_port_var HY2_PORT "Hysteria2 UDP 端口" "11451"
  ask_port_var TUIC_PORT "TUIC v5 UDP 端口" "11452"
  ask_port_var ANYTLS_PORT "AnyTLS TCP 端口" "11453"
  ask_var HY2_UP "Hysteria2 上行 Mbps（小鸡建议 50）" "50"
  ask_var HY2_DOWN "Hysteria2 下行 Mbps（小鸡建议 200）" "200"
  ask_var REMARK_PREFIX "节点名称前缀" "SB"

  HY2_JUMP="n"
  HY2_JUMP_RANGE=""
  if ask_yes_no "是否开启 Hysteria2 端口跳跃（UDP 端口段转发到 HY2 主端口）" "n"; then
    HY2_JUMP="y"
    ask_var HY2_JUMP_RANGE "请输入跳跃端口范围，例如 20000:30000" "20000:30000"
    case "$HY2_JUMP_RANGE" in
      *:*) : ;;
      *) die "端口跳跃范围格式错误，应类似 20000:30000" ;;
    esac
  fi

  HY2_PASS="$(rand_hex 16)"
  HY2_OBFS="$(rand_hex 8)"
  TUIC_UUID="$(rand_uuid)"
  TUIC_PASS="$(rand_hex 16)"
  ANYTLS_PASS="$(rand_hex 16)"
}

write_config() {
  info "正在写入 sing-box 配置..."
  cat > "$CONF" <<JSON
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
JSON

  cat > "$META" <<EOF
SERVER='$SERVER'
SNI='$SNI'
HY2_PORT='$HY2_PORT'
TUIC_PORT='$TUIC_PORT'
ANYTLS_PORT='$ANYTLS_PORT'
HY2_PASS='$HY2_PASS'
HY2_OBFS='$HY2_OBFS'
TUIC_UUID='$TUIC_UUID'
TUIC_PASS='$TUIC_PASS'
ANYTLS_PASS='$ANYTLS_PASS'
REMARK_PREFIX='$REMARK_PREFIX'
HY2_JUMP='$HY2_JUMP'
HY2_JUMP_RANGE='$HY2_JUMP_RANGE'
CERT_SHA256='$CERT_SHA256'
EOF
  chmod 600 "$CONF" "$META"
}
