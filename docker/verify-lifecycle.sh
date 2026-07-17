#!/bin/sh

set -eu

BASE_DIR="/etc/sing-box"
CONF="$BASE_DIR/config.json"
META="$BASE_DIR/client-info.env"
LINKS="$BASE_DIR/v2rayn-links.txt"
BIN="/usr/local/bin/sing-box"
SB="/usr/local/bin/sb"
TEST_DIR=""

fail() {
  printf '生命周期验证失败：%s\n' "$*" >&2
  exit 1
}

cleanup() {
  [ -z "$TEST_DIR" ] || rm -rf "$TEST_DIR"
}

trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

meta_value() {
  meta_key="$1"
  sed -n "s/^${meta_key}=//p" "$META" | head -n 1
}

assert_four_protocols() {
  [ -s "$META" ] || fail "状态文件缺失"
  [ "$(jq '[.inbounds[]] | length' "$CONF")" -eq 4 ] || fail "inbound 数量不是 4"
  grep -q '^REALITY_ENABLED=y$' "$META" || fail "Reality 状态未启用"
  [ "$(wc -l < "$LINKS")" -eq 4 ] || fail "节点链接数量不是 4"
  systemctl is-active --quiet sing-box || fail "sing-box 服务未运行"
}

[ -x "$SB" ] || fail "sb 命令不存在"
[ -x "$BIN" ] || fail "sing-box 内核不存在"
assert_four_protocols
TEST_DIR="$(mktemp -d /tmp/shway2-lifecycle.XXXXXX)"

printf '验证原地更新保留状态...\n'
before_meta="$(sha256sum "$META" | awk '{ print $1 }')"
before_links="$(sha256sum "$LINKS" | awk '{ print $1 }')"
if ! SHWAY2_INSTALLER_URL="file:///workspace/sHway2.sh" \
  "$SB" update v1.3 --force > "$TEST_DIR/update.log" 2>&1; then
  cat "$TEST_DIR/update.log" >&2
  fail "本地原地更新失败"
fi
[ "$(sha256sum "$META" | awk '{ print $1 }')" = "$before_meta" ] || fail "更新改变了状态文件"
[ "$(sha256sum "$LINKS" | awk '{ print $1 }')" = "$before_links" ] || fail "更新改变了节点链接"
assert_four_protocols
find /var/lib/shway2/backups -maxdepth 1 -type f -name 'update-*.tar.gz' | grep -q . || \
  fail "更新没有创建回滚备份"

printf '验证更新失败自动恢复旧状态...\n'
printf '#!/bin/sh\nexit 1\n' > "$TEST_DIR/failing-installer.sh"
if SHWAY2_INSTALLER_URL="file://$TEST_DIR/failing-installer.sh" \
  "$SB" update v9.9 --force > "$TEST_DIR/update-failure.log" 2>&1; then
  fail "预期失败的更新却返回成功"
fi
[ "$(sha256sum "$META" | awk '{ print $1 }')" = "$before_meta" ] || fail "失败更新改变了状态文件"
[ "$(sha256sum "$LINKS" | awk '{ print $1 }')" = "$before_links" ] || fail "失败更新改变了节点链接"
assert_four_protocols

printf '验证自定义备份路径与指定回滚...\n'
rollback_archive="$TEST_DIR/rollback.tar.gz"
"$SB" backup "$rollback_archive" >/dev/null
[ "$(stat -c '%a' /tmp)" = "1777" ] || fail "自定义备份错误修改了 /tmp 权限"
printf 'temporary-test-value\n' > "$LINKS"
"$SB" rollback "$rollback_archive" >/dev/null
[ "$(sha256sum "$LINKS" | awk '{ print $1 }')" = "$before_links" ] || fail "指定回滚未恢复节点链接"
assert_four_protocols

printf '验证从 config.json 修复缺失状态...\n'
repair_server="$(meta_value SERVER)"
repair_prefix="$(meta_value REMARK_PREFIX)"
rm -f "$META" "$LINKS"
"$SB" doctor >/dev/null || fail "状态缺失时 doctor 未能从 config.json 诊断"
sh /workspace/check-ports.sh server >/dev/null || fail "端口脚本未能从 config.json 读取端口"
expect /workspace/docker/repair-state.exp "$repair_server" "$repair_prefix"
[ "$(sha256sum "$META" | awk '{ print $1 }')" = "$before_meta" ] || fail "修复后的状态与原状态不一致"
[ "$(sha256sum "$LINKS" | awk '{ print $1 }')" = "$before_links" ] || fail "修复后的节点链接与原链接不一致"
assert_four_protocols

printf '验证旧三协议状态原地迁移且不自动增加 Reality...\n'
four_protocol_archive="$TEST_DIR/four-protocol.tar.gz"
"$SB" backup "$four_protocol_archive" >/dev/null
jq '.inbounds |= map(select(.tag != "reality-in"))' "$CONF" > "$TEST_DIR/config-legacy.json"
install -m 0600 "$TEST_DIR/config-legacy.json" "$CONF"
awk '
  BEGIN {
    print "STATE_VERSION=1"
    print "INSTALLER_VERSION=1.2"
    print "PROTOCOL_SET=hysteria2,tuic,anytls"
  }
  $0 !~ /^(STATE_VERSION|INSTALLER_VERSION|PROTOCOL_SET|FIREWALL_MANAGED|REALITY_)/ { print }
' "$META" > "$TEST_DIR/meta-legacy.env"
install -m 0600 "$TEST_DIR/meta-legacy.env" "$META"
rm -f "$BASE_DIR/reality-public.key"
systemctl restart sing-box
SHWAY2_SKIP_BACKUP=1 sh /workspace/sHway2.sh --reuse > "$TEST_DIR/legacy-update.log" 2>&1 || {
  cat "$TEST_DIR/legacy-update.log" >&2
  fail "旧三协议状态迁移失败"
}
[ "$(jq '[.inbounds[]] | length' "$CONF")" -eq 3 ] || fail "旧安装被自动增加了 Reality"
grep -q '^REALITY_ENABLED=n$' "$META" || fail "旧安装 Reality 状态不正确"
[ "$(wc -l < "$LINKS")" -eq 3 ] || fail "旧安装链接数量不是 3"
sh /workspace/sHway2.sh --restore "$four_protocol_archive" > "$TEST_DIR/restore-four.log" 2>&1 || {
  cat "$TEST_DIR/restore-four.log" >&2
  fail "恢复四协议备份失败"
}
assert_four_protocols

printf '验证项目独立防火墙规则链的启停...\n'
sed 's/^FIREWALL_MANAGED=n$/FIREWALL_MANAGED=y/' "$META" > "$TEST_DIR/meta-firewall.env"
install -m 0600 "$TEST_DIR/meta-firewall.env" "$META"
systemctl restart sing-box
iptables -C INPUT -j SHWAY2_INPUT >/dev/null || fail "INPUT 未引用项目规则链"
iptables -C SHWAY2_INPUT -p udp --dport 11451 -j ACCEPT >/dev/null || fail "缺少 HY2 防火墙规则"
iptables -C SHWAY2_INPUT -p udp --dport 11452 -j ACCEPT >/dev/null || fail "缺少 TUIC 防火墙规则"
iptables -C SHWAY2_INPUT -p tcp --dport 11453 -j ACCEPT >/dev/null || fail "缺少 AnyTLS 防火墙规则"
iptables -C SHWAY2_INPUT -p tcp --dport 11454 -j ACCEPT >/dev/null || fail "缺少 Reality 防火墙规则"
sed 's/^FIREWALL_MANAGED=y$/FIREWALL_MANAGED=n/' "$META" > "$TEST_DIR/meta-no-firewall.env"
install -m 0600 "$TEST_DIR/meta-no-firewall.env" "$META"
systemctl restart sing-box
if iptables -S SHWAY2_INPUT >/dev/null 2>&1; then
  fail "关闭防火墙管理后项目规则链仍存在"
fi

printf '验证默认备份卸载与恢复...\n'
before_uninstall_count="$(find /root -maxdepth 1 -type f -name 'sHway2-backup-*.tar.gz' | wc -l)"
sh /workspace/uninstall.sh --yes > "$TEST_DIR/uninstall.log" 2>&1 || {
  cat "$TEST_DIR/uninstall.log" >&2
  fail "卸载失败"
}
[ ! -e "$BASE_DIR" ] || fail "卸载后配置目录仍存在"
[ ! -e /usr/local/lib/shway2 ] || fail "卸载后运行目录仍存在"
[ ! -e "$SB" ] || fail "卸载后 sb 仍存在"
[ -x "$BIN" ] || fail "卸载错误删除了 sing-box 内核"
after_uninstall_count="$(find /root -maxdepth 1 -type f -name 'sHway2-backup-*.tar.gz' | wc -l)"
[ "$after_uninstall_count" -eq $((before_uninstall_count + 1)) ] || fail "卸载没有生成默认备份"
uninstall_archive="$(find /root -maxdepth 1 -type f -name 'sHway2-backup-*.tar.gz' | sort -r | head -n 1)"
[ -s "$uninstall_archive" ] || fail "找不到卸载备份"
sh /workspace/sHway2.sh --restore "$uninstall_archive" > "$TEST_DIR/restore-uninstall.log" 2>&1 || {
  cat "$TEST_DIR/restore-uninstall.log" >&2
  fail "卸载备份恢复失败"
}
assert_four_protocols

printf '更新、备份、回滚、修复、兼容迁移、防火墙与卸载恢复验证通过。\n'
