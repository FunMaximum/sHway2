#!/bin/sh
# sHway2 - sing-box 二进制安装与配置检查模块

install_sing_box() {
  if [ -x "$BIN" ]; then
    cur="$($BIN version 2>/dev/null | awk 'NR==1{print $3}' || true)"
    [ -n "$cur" ] && green "检测到已安装 sing-box $cur，将继续覆盖配置。" || green "检测到已安装 sing-box，将继续覆盖配置。"
    return
  fi

  info "正在下载 sing-box 最新版..."
  api="$(curl -fsSL --max-time 20 https://api.github.com/repos/SagerNet/sing-box/releases/latest)" || die "获取 sing-box 最新版本失败"
  tag="$(printf '%s' "$api" | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -n 1)"
  [ -n "$tag" ] || die "解析 sing-box 最新版本失败"

  case "$ARCH" in
    amd64) file_arch="amd64" ;;
    arm64) file_arch="arm64" ;;
    armv7) file_arch="armv7" ;;
  esac

  tmp="/tmp/sing-box-install.$$"
  mkdir -p "$tmp"
  if [ "$SINGBOX_FLAVOR" = "musl" ]; then
    url="https://github.com/SagerNet/sing-box/releases/download/v${tag}/sing-box-${tag}-linux-${file_arch}-musl.tar.gz"
  else
    url="https://github.com/SagerNet/sing-box/releases/download/v${tag}/sing-box-${tag}-linux-${file_arch}.tar.gz"
  fi
  curl -fL --retry 3 --connect-timeout 10 -o "$tmp/sing-box.tar.gz" "$url" || die "下载 sing-box 失败：$url"
  tar -xzf "$tmp/sing-box.tar.gz" -C "$tmp"
  found="$(find "$tmp" -type f -name sing-box | head -n 1)"
  [ -n "$found" ] || die "解压后未找到 sing-box"
  install -m 0755 "$found" "$BIN"
  rm -rf "$tmp"
  green "sing-box 安装完成：$($BIN version | awk 'NR==1{print $0}')"
}

check_config() {
  info "正在检查配置..."
  "$BIN" check -c "$CONF" || die "sing-box 配置检查失败"
}
