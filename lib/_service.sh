#!/bin/sh
# sHway2 - 服务管理模块（systemd / OpenRC）

# ── 生成 systemd 服务文件（仅写文件 + daemon-reload） ──
#     依赖 install 上下文的 HY2_JUMP/HY2_JUMP_RANGE/HY2_PORT 变量
write_systemd_service() {
  pre=""
  if [ "$HY2_JUMP" = "y" ]; then
    pre="ExecStartPre=-/usr/sbin/iptables -t nat -D PREROUTING -p udp --dport $HY2_JUMP_RANGE -j REDIRECT --to-ports $HY2_PORT 2>/dev/null\nExecStartPre=/usr/sbin/iptables -t nat -A PREROUTING -p udp --dport $HY2_JUMP_RANGE -j REDIRECT --to-ports $HY2_PORT\nExecStopPost=-/usr/sbin/iptables -t nat -D PREROUTING -p udp --dport $HY2_JUMP_RANGE -j REDIRECT --to-ports $HY2_PORT 2>/dev/null"
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
  info "systemd 服务文件已写入"
}

# ── 生成 OpenRC 服务文件（仅写文件） ──
#     依赖 install 上下文的 HY2_JUMP/HY2_JUMP_RANGE/HY2_PORT 变量
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
  info "OpenRC 服务脚本已写入"
}

# ── 启用并启动服务（install 后首次拉起） ──
enable_and_start() {
  if [ "$INIT" = "systemd" ]; then
    systemctl enable --now "$SERVICE_NAME"
    systemctl is-active --quiet "$SERVICE_NAME" || die "sing-box 启动失败，请查看：journalctl -u sing-box -e"
  else
    rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
    rc-service "$SERVICE_NAME" start
    rc-service "$SERVICE_NAME" status >/dev/null 2>&1 || die "sing-box 启动失败，请查看：cat /var/log/sing-box.log"
  fi
  green "sing-box 服务已启动"
}

# ── 重启服务（不重新生成文件，供 sb 和日常使用） ──
restart_service() {
  [ -z "${INIT:-}" ] && detect_init
  if [ "$INIT" = "systemd" ]; then
    systemctl restart "$SERVICE_NAME"
    systemctl is-active --quiet "$SERVICE_NAME" || die "sing-box 重启失败，请查看：journalctl -u sing-box -e"
  else
    rc-service "$SERVICE_NAME" restart
    rc-service "$SERVICE_NAME" status >/dev/null 2>&1 || die "sing-box 重启失败，请查看：cat /var/log/sing-box.log"
  fi
  green "sing-box 已重启"
}

# ── 查看状态 ──
show_status() {
  detect_init
  if [ "$INIT" = "systemd" ]; then
    systemctl status "$SERVICE_NAME" --no-pager
  else
    rc-service "$SERVICE_NAME" status
  fi
}

# ── 查看日志 ──
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
