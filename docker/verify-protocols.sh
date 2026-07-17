#!/bin/sh

set -eu

BIN="/usr/local/bin/sing-box"
SERVER_CONF="/etc/sing-box/config.json"
REALITY_PUBLIC_FILE="/etc/sing-box/reality-public.key"
TEST_DIR=""
CLIENT_PID=""
HTTP_PID=""
HTTP_PORT="18080"
XRAY_VERSION="26.3.27"
XRAY_BIN=""

fail() {
  printf '协议验证失败：%s\n' "$*" >&2
  exit 1
}

cleanup() {
  [ -z "$CLIENT_PID" ] || kill "$CLIENT_PID" 2>/dev/null || true
  [ -z "$HTTP_PID" ] || kill "$HTTP_PID" 2>/dev/null || true
  [ -z "$TEST_DIR" ] || rm -rf "$TEST_DIR"
}

trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

json_value() {
  filter="$1"
  jq -er "$filter" "$SERVER_CONF"
}

base_config() {
  outbound_json="$1"
  socks_port="$2"
  jq -n --argjson outbound "$outbound_json" --argjson socks_port "$socks_port" '
    {
      log: { level: "warn" },
      inbounds: [
        {
          type: "mixed",
          tag: "mixed-in",
          listen: "127.0.0.1",
          listen_port: $socks_port
        }
      ],
      outbounds: [$outbound],
      route: {
        final: "test-out",
        auto_detect_interface: true
      }
    }
  '
}

hy2_outbound() {
  jq -n \
    --argjson port "$(json_value '.inbounds[] | select(.tag == "hy2-in") | .listen_port')" \
    --arg password "$(json_value '.inbounds[] | select(.tag == "hy2-in") | .users[0].password')" \
    --arg obfs "$(json_value '.inbounds[] | select(.tag == "hy2-in") | .obfs.password')" \
    --arg sni "$(json_value '.inbounds[] | select(.tag == "hy2-in") | .tls.server_name')" '
    {
      type: "hysteria2",
      tag: "test-out",
      server: "127.0.0.1",
      server_port: $port,
      password: $password,
      obfs: { type: "salamander", password: $obfs },
      tls: { enabled: true, server_name: $sni, insecure: true, alpn: ["h3"] }
    }
  '
}

tuic_outbound() {
  jq -n \
    --argjson port "$(json_value '.inbounds[] | select(.tag == "tuic-in") | .listen_port')" \
    --arg uuid "$(json_value '.inbounds[] | select(.tag == "tuic-in") | .users[0].uuid')" \
    --arg password "$(json_value '.inbounds[] | select(.tag == "tuic-in") | .users[0].password')" \
    --arg sni "$(json_value '.inbounds[] | select(.tag == "tuic-in") | .tls.server_name')" '
    {
      type: "tuic",
      tag: "test-out",
      server: "127.0.0.1",
      server_port: $port,
      uuid: $uuid,
      password: $password,
      congestion_control: "bbr",
      udp_relay_mode: "native",
      tls: { enabled: true, server_name: $sni, insecure: true, alpn: ["h3"] }
    }
  '
}

anytls_outbound() {
  jq -n \
    --argjson port "$(json_value '.inbounds[] | select(.tag == "anytls-in") | .listen_port')" \
    --arg password "$(json_value '.inbounds[] | select(.tag == "anytls-in") | .users[0].password')" \
    --arg sni "$(json_value '.inbounds[] | select(.tag == "anytls-in") | .tls.server_name')" '
    {
      type: "anytls",
      tag: "test-out",
      server: "127.0.0.1",
      server_port: $port,
      password: $password,
      tls: { enabled: true, server_name: $sni, insecure: true }
    }
  '
}

wait_for_socks() {
  socks_port="$1"
  wait_count=0
  while ! ss -H -ltn 2>/dev/null | awk -v suffix=":$socks_port" '
    $4 ~ suffix "$" { found = 1 }
    END { exit found ? 0 : 1 }
  '; do
    wait_count=$((wait_count + 1))
    if [ "$wait_count" -ge 50 ]; then
      return 1
    fi
    sleep 0.1
  done
}

run_protocol_test() {
  protocol_name="$1"
  socks_port="$2"
  outbound_json="$3"
  client_conf="$TEST_DIR/$protocol_name.json"
  client_log="$TEST_DIR/$protocol_name.log"
  base_config "$outbound_json" "$socks_port" > "$client_conf"
  "$BIN" check -c "$client_conf" || fail "$protocol_name 客户端配置检查失败"
  "$BIN" run -c "$client_conf" > "$client_log" 2>&1 &
  CLIENT_PID=$!
  if ! wait_for_socks "$socks_port"; then
    cat "$client_log" >&2
    fail "$protocol_name 客户端未开始监听"
  fi

  (
    printf 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK'
  ) | nc -l 127.0.0.1 "$HTTP_PORT" >/dev/null &
  HTTP_PID=$!
  response="$(curl -fsS --max-time 30 --noproxy '' \
    --socks5-hostname "127.0.0.1:$socks_port" "http://127.0.0.1:$HTTP_PORT/")" || {
    cat "$client_log" >&2
    fail "$protocol_name 代理请求失败"
  }
  [ "$response" = "OK" ] || fail "$protocol_name 返回内容不正确"
  wait "$HTTP_PID" || true
  HTTP_PID=""
  kill "$CLIENT_PID" 2>/dev/null || true
  wait "$CLIENT_PID" 2>/dev/null || true
  CLIENT_PID=""
  printf '[通过] %s 完成真实代理请求\n' "$protocol_name"
}

prepare_xray() {
  command -v unzip >/dev/null 2>&1 || fail "缺少 unzip，请重建测试镜像"
  case "$(uname -m)" in
    x86_64|amd64) xray_asset="Xray-linux-64.zip" ;;
    aarch64|arm64) xray_asset="Xray-linux-arm64-v8a.zip" ;;
    *) fail "Xray 测试不支持当前架构：$(uname -m)" ;;
  esac
  xray_archive="$TEST_DIR/$xray_asset"
  xray_url="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/${xray_asset}"
  curl -fL --retry 3 --connect-timeout 10 -o "$xray_archive" "$xray_url" || \
    fail "下载 Xray 测试客户端失败"
  mkdir -p "$TEST_DIR/xray"
  unzip -q "$xray_archive" -d "$TEST_DIR/xray" || fail "解压 Xray 测试客户端失败"
  XRAY_BIN="$TEST_DIR/xray/xray"
  [ -x "$XRAY_BIN" ] || fail "Xray 测试客户端不存在"
}

write_xray_reality_config() {
  xray_config="$1"
  [ -s "$REALITY_PUBLIC_FILE" ] || fail "缺少 Reality 公钥文件"
  jq -n \
    --argjson server_port "$(json_value '.inbounds[] | select(.tag == "reality-in") | .listen_port')" \
    --arg uuid "$(json_value '.inbounds[] | select(.tag == "reality-in") | .users[0].uuid')" \
    --arg flow "$(json_value '.inbounds[] | select(.tag == "reality-in") | .users[0].flow')" \
    --arg sni "$(json_value '.inbounds[] | select(.tag == "reality-in") | .tls.reality.handshake.server')" \
    --arg public_key "$(sed -n '1p' "$REALITY_PUBLIC_FILE")" \
    --arg short_id "$(json_value '.inbounds[] | select(.tag == "reality-in") | .tls.reality.short_id[0]')" '
    {
      log: { loglevel: "warning" },
      inbounds: [
        {
          listen: "127.0.0.1",
          port: 21004,
          protocol: "socks",
          settings: { auth: "noauth", udp: true }
        }
      ],
      outbounds: [
        {
          protocol: "vless",
          settings: {
            vnext: [
              {
                address: "127.0.0.1",
                port: $server_port,
                users: [
                  { id: $uuid, encryption: "none", flow: $flow }
                ]
              }
            ]
          },
          streamSettings: {
            network: "tcp",
            security: "reality",
            realitySettings: {
              serverName: $sni,
              fingerprint: "chrome",
              show: false,
              publicKey: $public_key,
              shortId: $short_id,
              spiderX: "/"
            }
          }
        }
      ]
    }
  ' > "$xray_config"
}

run_reality_test() {
  prepare_xray
  xray_config="$TEST_DIR/reality-xray.json"
  xray_log="$TEST_DIR/reality-xray.log"
  write_xray_reality_config "$xray_config"
  "$XRAY_BIN" run -test -config "$xray_config" >/dev/null || fail "Xray Reality 客户端配置检查失败"
  "$XRAY_BIN" run -config "$xray_config" > "$xray_log" 2>&1 &
  CLIENT_PID=$!
  if ! wait_for_socks 21004; then
    cat "$xray_log" >&2
    fail "Xray Reality 客户端未开始监听"
  fi

  (
    printf 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK'
  ) | nc -l 127.0.0.1 "$HTTP_PORT" >/dev/null &
  HTTP_PID=$!
  response="$(curl -fsS --max-time 30 --noproxy '' \
    --socks5-hostname 127.0.0.1:21004 "http://127.0.0.1:$HTTP_PORT/")" || {
    cat "$xray_log" >&2
    fail "Reality 代理请求失败"
  }
  [ "$response" = "OK" ] || fail "Reality 返回内容不正确"
  wait "$HTTP_PID" || true
  HTTP_PID=""
  kill "$CLIENT_PID" 2>/dev/null || true
  wait "$CLIENT_PID" 2>/dev/null || true
  CLIENT_PID=""
  printf '[通过] Reality 使用 Xray 客户端完成真实代理请求\n'
}

command -v nc >/dev/null 2>&1 || fail "缺少 nc，请重建测试镜像"
[ -x "$BIN" ] || fail "sing-box 未安装"
[ -r "$SERVER_CONF" ] || fail "服务端配置不存在"
systemctl is-active --quiet sing-box || fail "sing-box 服务未运行"

TEST_DIR="$(mktemp -d /tmp/shway2-protocols.XXXXXX)"
run_protocol_test Hysteria2 21001 "$(hy2_outbound)"
run_protocol_test TUIC 21002 "$(tuic_outbound)"
run_protocol_test AnyTLS 21003 "$(anytls_outbound)"
run_reality_test

printf '四种协议端到端验证通过。\n'
