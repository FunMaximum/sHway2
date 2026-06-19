#!/bin/sh
# sHway2 - 系统/架构检测模块

detect_os() {
  [ -r /etc/os-release ] || die "无法识别系统，仅支持 Debian 12 / Ubuntu 22.04 / Ubuntu 24.04 / Alpine"
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_VER="${VERSION_ID:-}"

  OS_ID_LOWER="$(printf '%s' "$OS_ID" | tr '[:upper:]' '[:lower:]')"

  case "$OS_ID_LOWER" in
    debian)
      case "$OS_VER" in
        12*|bookworm*) : ;;
        *) yellow "提示：当前 Debian 版本为 $OS_VER，脚本按 Debian 12 方式继续。" ;;
      esac
      INIT="systemd"
      SINGBOX_FLAVOR="glibc"
      PKG_TYPE="apt"
      ;;
    ubuntu)
      case "$OS_VER" in
        22.04|22.04.*|jammy*) : ;;
        24.04|24.04.*|noble*) : ;;
        *) yellow "提示：当前 Ubuntu 版本为 $OS_VER，脚本按 Ubuntu 22.04/24.04 方式继续。" ;;
      esac
      INIT="systemd"
      SINGBOX_FLAVOR="glibc"
      PKG_TYPE="apt"
      ;;
    alpine)
      INIT="openrc"
      SINGBOX_FLAVOR="musl"
      PKG_TYPE="apk"
      ;;
    *)
      die "当前系统 $OS_ID 暂不支持，仅支持 Debian 12 / Ubuntu 22.04 / Ubuntu 24.04 / Alpine"
      ;;
  esac

  green "检测到系统：$OS_ID $OS_VER → 初始化 $INIT，sing-box $SINGBOX_FLAVOR 版本"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l|armv7*) ARCH="armv7" ;;
    *) die "不支持的 CPU 架构：$(uname -m)" ;;
  esac
}

# 运行时检测 init 系统（供 sb 等已安装环境使用）
detect_init() {
  if command -v systemctl >/dev/null 2>&1; then
    INIT="systemd"
  elif command -v rc-service >/dev/null 2>&1; then
    INIT="openrc"
  else
    die "无法识别服务管理器，仅支持 systemd / OpenRC"
  fi
}
