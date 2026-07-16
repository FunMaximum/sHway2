#!/bin/sh

set -eu

BASE_DIR="/etc/sing-box"
CONF="$BASE_DIR/config.json"

fail() {
  printf '验证失败：%s\n' "$*" >&2
  exit 1
}

printf '检查项目脚本语法与 ShellCheck...\n'
sh -n /workspace/get.sh /workspace/sHway2.sh
shellcheck \
  /workspace/get.sh \
  /workspace/sHway2.sh \
  /workspace/docker/test-default.sh \
  /workspace/docker/verify-install.sh

printf '检查生成文件与 sing-box 配置...\n'
for file in \
  "$CONF" \
  "$BASE_DIR/client-info.env" \
  "$BASE_DIR/server.crt" \
  "$BASE_DIR/server.key" \
  "$BASE_DIR/v2rayn-links.txt"
do
  [ -s "$file" ] || fail "文件不存在或为空：$file"
done

[ "$(stat -c '%a' "$BASE_DIR")" = "700" ] || fail "$BASE_DIR 权限不是 700"
for file in "$CONF" "$BASE_DIR/client-info.env" "$BASE_DIR/server.key" "$BASE_DIR/v2rayn-links.txt"
do
  [ "$(stat -c '%a' "$file")" = "600" ] || fail "$file 权限不是 600"
done

jq empty "$CONF"
/usr/local/bin/sing-box check -c "$CONF"
openssl x509 -in "$BASE_DIR/server.crt" -noout -checkend 0 >/dev/null

printf '检查 systemd 服务与监听端口...\n'
systemctl is-active --quiet sing-box || fail "sing-box.service 未运行"
ss -lun | grep -Eq '[:.]11451[[:space:]]' || fail "Hysteria2 UDP 11451 未监听"
ss -lun | grep -Eq '[:.]11452[[:space:]]' || fail "TUIC UDP 11452 未监听"
ss -ltn | grep -Eq '[:.]11453[[:space:]]' || fail "AnyTLS TCP 11453 未监听"

printf '检查 sb 管理命令...\n'
/usr/local/bin/sb show >/dev/null
/usr/local/bin/sb status >/dev/null
/usr/local/bin/sb restart >/dev/null
systemctl is-active --quiet sing-box || fail "sb restart 后服务未运行"
/usr/local/bin/sb log >/dev/null

printf '全部容器内验证通过。\n'
