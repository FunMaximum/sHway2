#!/bin/sh
# sHway2 - 系统依赖安装模块

install_deps() {
  info "正在安装基础依赖..."
  case "$PKG_TYPE" in
    apt)
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl tar openssl iptables
      ;;
    apk)
      apk add --no-cache ca-certificates curl tar openssl iptables
      ;;
    *)
      die "未知包管理器：$PKG_TYPE"
      ;;
  esac
}
