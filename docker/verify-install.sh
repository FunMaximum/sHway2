#!/bin/sh

set -eu

BASE_DIR="/etc/sing-box"
CONF="$BASE_DIR/config.json"
META="$BASE_DIR/client-info.env"
BACKUP_TEST="/tmp/shway2-verify-backup.tar.gz"

fail() {
  printf '验证失败：%s\n' "$*" >&2
  exit 1
}

printf '检查项目脚本语法与 ShellCheck...\n'
for script in \
  /workspace/get.sh \
  /workspace/sHway2.sh \
  /workspace/uninstall.sh \
  /workspace/check-ports.sh \
  /workspace/docker/test-default.sh \
  /workspace/docker/verify-install.sh \
  /workspace/docker/verify-protocols.sh \
  /workspace/docker/verify-lifecycle.sh
do
  sh -n "$script"
done
shellcheck \
  /workspace/get.sh \
  /workspace/sHway2.sh \
  /workspace/uninstall.sh \
  /workspace/check-ports.sh \
  /workspace/docker/test-default.sh \
  /workspace/docker/verify-install.sh \
  /workspace/docker/verify-protocols.sh \
  /workspace/docker/verify-lifecycle.sh

printf '检查生成文件、权限与 sing-box 配置...\n'
for file in \
  "$CONF" \
  "$META" \
  "$BASE_DIR/server.crt" \
  "$BASE_DIR/server.key" \
  "$BASE_DIR/reality-public.key" \
  "$BASE_DIR/v2rayn-links.txt" \
  /usr/local/lib/shway2/manager.sh \
  /usr/local/bin/sb
do
  [ -s "$file" ] || fail "文件不存在或为空：$file"
done

[ "$(stat -c '%a' "$BASE_DIR")" = "700" ] || fail "$BASE_DIR 权限不是 700"
[ "$(stat -c '%a' /usr/local/lib/shway2)" = "700" ] || fail "运行目录权限不是 700"
for file in \
  "$CONF" \
  "$META" \
  "$BASE_DIR/server.key" \
  "$BASE_DIR/reality-public.key" \
  "$BASE_DIR/v2rayn-links.txt"
do
  [ "$(stat -c '%a' "$file")" = "600" ] || fail "$file 权限不是 600"
done

jq empty "$CONF"
/usr/local/bin/sing-box check -c "$CONF"
openssl x509 -in "$BASE_DIR/server.crt" -noout -checkend 0 >/dev/null
[ "$(jq '[.inbounds[]] | length' "$CONF")" -eq 4 ] || fail "inbound 数量不是 4"
for tag in hy2-in tuic-in anytls-in reality-in; do
  [ "$(jq -r --arg tag "$tag" '[.inbounds[] | select(.tag == $tag)] | length' "$CONF")" -eq 1 ] || \
    fail "缺少或重复 inbound：$tag"
done
grep -q '^STATE_VERSION=2$' "$META" || fail "状态版本不是 2"
grep -q '^PROTOCOL_SET=hysteria2,tuic,anytls,reality$' "$META" || fail "协议集合不正确"
grep -q '^FIREWALL_MANAGED=n$' "$META" || fail "默认安装不应管理本机防火墙"
[ "$(wc -l < "$BASE_DIR/v2rayn-links.txt")" -eq 4 ] || fail "节点链接数量不是 4"
grep -q '^hysteria2://' "$BASE_DIR/v2rayn-links.txt" || fail "缺少 Hysteria2 链接"
grep -q '^tuic://' "$BASE_DIR/v2rayn-links.txt" || fail "缺少 TUIC 链接"
grep -q '^anytls://' "$BASE_DIR/v2rayn-links.txt" || fail "缺少 AnyTLS 链接"
grep -q '^vless://.*security=reality' "$BASE_DIR/v2rayn-links.txt" || fail "缺少 Reality 链接"

printf '检查 systemd 服务与四个监听端口...\n'
systemctl is-active --quiet sing-box || fail "sing-box.service 未运行"
ss -H -lun | awk '$4 ~ /:11451$/ { found = 1 } END { exit found ? 0 : 1 }' || \
  fail "Hysteria2 UDP 11451 未监听"
ss -H -lun | awk '$4 ~ /:11452$/ { found = 1 } END { exit found ? 0 : 1 }' || \
  fail "TUIC UDP 11452 未监听"
ss -H -ltn | awk '$4 ~ /:11453$/ { found = 1 } END { exit found ? 0 : 1 }' || \
  fail "AnyTLS TCP 11453 未监听"
ss -H -ltn | awk '$4 ~ /:11454$/ { found = 1 } END { exit found ? 0 : 1 }' || \
  fail "VLESS Reality TCP 11454 未监听"
if iptables -S SHWAY2_INPUT >/dev/null 2>&1; then
  fail "默认关闭防火墙管理时不应创建 SHWAY2_INPUT"
fi

printf '检查 sb 管理、诊断与备份命令...\n'
/usr/local/bin/sb show >/dev/null
/usr/local/bin/sb status >/dev/null
/usr/local/bin/sb restart >/dev/null
systemctl is-active --quiet sing-box || fail "sb restart 后服务未运行"
/usr/local/bin/sb log >/dev/null
/usr/local/bin/sb doctor >/dev/null
/usr/local/bin/sb version | grep -q '^sHway2: v1.3$' || fail "sb version 不正确"
sh /workspace/check-ports.sh server >/dev/null
rm -f "$BACKUP_TEST"
/usr/local/bin/sb backup "$BACKUP_TEST" >/dev/null
[ -s "$BACKUP_TEST" ] || fail "sb backup 未生成备份"
tar -tzf "$BACKUP_TEST" | grep -q '^shway2-backup/manifest.env$' || fail "备份格式不正确"
rm -f "$BACKUP_TEST"

printf '安装、状态与管理命令验证通过。\n'
