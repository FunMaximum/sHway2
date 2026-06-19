#!/bin/sh
#
# sb — sHway2 管理脚本（安装到 /usr/local/bin/sb）
# 用法：sb [show|status|restart|log|update|version|help]
#
set -eu

# ── 定位 lib/（安装后路径） ──
SB_LIB="/usr/local/lib/sHway2"

[ -d "$SB_LIB" ] || {
  # 回退：如果还没安装，尝试从源码目录加载
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  if [ -d "$SCRIPT_DIR/lib" ]; then
    SB_LIB="$SCRIPT_DIR/lib"
  else
    echo "错误：未找到 sHway2 库文件，请先运行安装脚本" >&2
    exit 1
  fi
}

# ── 加载公共模块 ──
. "$SB_LIB/_common.sh"

# ── 子命令分发 ──
cmd="${1:-show}"

case "$cmd" in
  show|links)
    . "$SB_LIB/_utils.sh"
    . "$SB_LIB/_links.sh"
    print_links
    ;;

  status)
    . "$SB_LIB/_os.sh"
    . "$SB_LIB/_service.sh"
    need_root
    show_status
    ;;

  restart)
    . "$SB_LIB/_os.sh"
    . "$SB_LIB/_service.sh"
    need_root
    restart_service
    ;;

  log)
    . "$SB_LIB/_os.sh"
    . "$SB_LIB/_service.sh"
    need_root
    show_log
    ;;

  update)
    . "$SB_LIB/_update.sh"
    need_root
    do_update
    ;;

  uninstall)
    do_uninstall "$@"
    ;;

  version|-v|--version)
    info "sb v$(load_version)"
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
