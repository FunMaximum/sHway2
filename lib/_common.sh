#!/bin/sh
# sHway2 - 公共基础模块（颜色、常量、工具函数）
# 所有入口脚本和 lib 模块的第一个 source 目标

# ── 颜色输出 ──
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
info()   { printf '%s\n' "$*"; }

# ── 错误处理 ──
die() {
  red "错误：$*"
  exit 1
}

# ── 权限检查 ──
need_root() {
  [ "$(id -u)" = "0" ] || die "请使用 root 用户运行：sudo sh $0"
}

# ── 常量 ──
BASE_DIR="/etc/sing-box"
CONF="$BASE_DIR/config.json"
META="$BASE_DIR/client-info.env"
CERT="$BASE_DIR/server.crt"
KEY="$BASE_DIR/server.key"
BIN="/usr/local/bin/sing-box"
SERVICE_NAME="sing-box"
SB_BIN="/usr/local/bin/sb"
SB_LIB="/usr/local/lib/sHway2"

# ── 版本读取 ──
load_version() {
  if [ -r "$SCRIPT_DIR/VERSION" ]; then
    cat "$SCRIPT_DIR/VERSION"
  elif [ -r "$SB_LIB/VERSION" ]; then
    cat "$SB_LIB/VERSION"
  else
    echo "unknown"
  fi
}

# ── 将 sb 和 lib/ 安装到系统路径 ──
install_sb_and_lib() {
  info "正在安装 sb 管理工具..."
  mkdir -p "$SB_LIB"
  for f in "$LIB_DIR"/*.sh; do
    [ -r "$f" ] && cp "$f" "$SB_LIB/"
  done
  [ -r "$SCRIPT_DIR/VERSION" ] && cp "$SCRIPT_DIR/VERSION" "$SB_LIB/VERSION"
  [ -r "$SCRIPT_DIR/sb.sh" ] && cp "$SCRIPT_DIR/sb.sh" "$SB_BIN" && chmod 755 "$SB_BIN"
  green "sb 管理脚本已安装到 $SB_BIN"
  info "可使用 sb show / sb status / sb restart / sb log / sb update / sb help"
}

# ── 卸载管理工具（保留 sing-box 服务和证书） ──
do_uninstall() {
  need_root

  # 跳过确认
  if [ "${1:-}" != "-y" ] && [ "${1:-}" != "--yes" ]; then
    printf "确认卸载 sHway2 管理工具？这将删除 sb 命令和所有 lib 文件。\n" >/dev/tty
    printf "保留内容：sing-box 服务、TLS 证书、config.json、节点信息\n" >/dev/tty
    printf "继续？[y/N]: " >/dev/tty
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
      read -r ans </dev/tty || ans="n"
    else
      ans="n"
    fi
    case "$ans" in
      y|Y|yes|YES|是) : ;;
      *) info "已取消"; exit 0 ;;
    esac
  fi

  info "正在卸载 sHway2 管理工具..."

  removed=0

  # 1. 删除 sb
  if [ -f "$SB_BIN" ]; then
    rm -f "$SB_BIN"
    info "已删除 $SB_BIN"
    removed=1
  fi

  # 2. 删除 lib
  if [ -d "$SB_LIB" ]; then
    rm -rf "$SB_LIB"
    info "已删除 $SB_LIB"
    removed=1
  fi

  # 3. 删除本地源码目录（如果从源码运行）
  #    注意：SCRIPT_DIR 由入口点在 source 之前设定
  if [ -n "${SCRIPT_DIR:-}" ] && [ -d "${SCRIPT_DIR}/lib" ]; then
    rm -rf "${SCRIPT_DIR}/lib"
    rm -f "${SCRIPT_DIR}/sHway2.sh" "${SCRIPT_DIR}/sb.sh" "${SCRIPT_DIR}/get.sh" "${SCRIPT_DIR}/VERSION"
    info "已删除本地源码"
    removed=1
  fi

  # 4. 清理临时文件
  rm -rf /tmp/sHway2-bootstrap.* /tmp/sHway2-update.* /tmp/sHway2-*.sh 2>/dev/null || true

  if [ "$removed" = "0" ]; then
    yellow "未找到已安装的 sHway2 管理工具"
  else
    green "卸载完成。保留内容："
  fi

  info "  - sing-box 二进制: $BIN"
  info "  - 服务配置: $BASE_DIR/"
  info "  - 服务文件: /etc/systemd/system/${SERVICE_NAME}.service (或 /etc/init.d/${SERVICE_NAME})"
  info ""
  info "重新安装：curl -fsSL https://raw.githubusercontent.com/FunMaximum/sHway2/master/get.sh | sudo sh"
}

# ── 使用说明 ──
usage() {
  cat <<EOL
sHway2 — Hysteria2 + TUIC v5 + AnyTLS 部署与管理

用法：$0 [命令]

命令：
  install     完整安装（默认）
  links       重新导出 v2rayN 分享链接
  status      查看 sing-box 运行状态
  restart     重启 sing-box 服务
  log         查看 sing-box 日志
  update      更新 sHway2 自身
  uninstall   卸载管理工具（保留 sing-box 服务和证书）
  version     显示版本号
  help        显示此帮助

示例：
  sudo sh sHway2.sh install
  sb show
  sb status
  sb update
  sb uninstall -y
EOL
}
