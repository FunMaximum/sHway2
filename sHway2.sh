#!/bin/sh
#
# sHway2 — Hysteria2 + TUIC v5 + AnyTLS 部署与管理入口
# 用法：sudo sh sHway2.sh [install|links|status|restart|log|update|version|help]
#
set -eu

# ── 定位自身和 lib/ ──
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

if [ ! -d "$LIB_DIR" ]; then
  echo "错误：未找到 lib/ 目录：$LIB_DIR" >&2
  exit 1
fi

# ── 加载公共模块 ──
. "$LIB_DIR/_common.sh"

# ── 子命令分发 ──
cmd="${1:-install}"

case "$cmd" in
  install)
    . "$LIB_DIR/_os.sh"
    . "$LIB_DIR/_utils.sh"
    . "$LIB_DIR/_tui.sh"
    . "$LIB_DIR/_deps.sh"
    . "$LIB_DIR/_singbox.sh"
    . "$LIB_DIR/_cert.sh"
    . "$LIB_DIR/_config.sh"
    . "$LIB_DIR/_service.sh"
    . "$LIB_DIR/_links.sh"
    . "$LIB_DIR/_update.sh"

    need_root
    detect_os
    detect_arch
    install_deps
    install_sing_box
    collect_inputs
    write_cert
    write_config
    check_config
    restart_service
    install_sb_and_lib
    print_links
    ;;

  links|show)
    . "$LIB_DIR/_utils.sh"
    . "$LIB_DIR/_links.sh"
    print_links
    ;;

  status)
    . "$LIB_DIR/_os.sh"
    . "$LIB_DIR/_service.sh"
    need_root
    detect_os
    show_status
    ;;

  restart)
    . "$LIB_DIR/_os.sh"
    . "$LIB_DIR/_service.sh"
    need_root
    detect_os
    restart_service
    ;;

  log)
    . "$LIB_DIR/_os.sh"
    . "$LIB_DIR/_service.sh"
    need_root
    detect_os
    show_log
    ;;

  update)
    . "$LIB_DIR/_update.sh"
    need_root
    do_update
    ;;

  uninstall)
    do_uninstall "$@"
    ;;

  version|-v|--version)
    info "sHway2 v$(load_version)"
    ;;

  help|-h|--help)
    usage
    ;;

  *)
    red "未知命令：$cmd"
    usage
    exit 1
    ;;
esac
