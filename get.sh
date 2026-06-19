#!/bin/sh
#
# sHway2 引导脚本 — 自动拉取最新 Release 并执行安装
# 用法：curl -fsSL URL | sudo sh
#
set -eu

REPO_OWNER="FunMaximum"
REPO_NAME="sHway2"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '%s\n' "$*"; }
die()   { red "错误：$*"; exit 1; }

[ "$(id -u)" = "0" ] || die "请使用 root 运行：curl -fsSL ... | sudo sh"

# 检查必备工具
for tool in curl tar; do
  command -v "$tool" >/dev/null 2>&1 || die "缺少 $tool，请先安装：apt-get install $tool 或 apk add $tool"
done

info "sHway2 引导 — 正在查找最新版本..."

# ── 1. 获取最新 Release tag ──
tag=""
if command -v jq >/dev/null 2>&1; then
  tag="$(curl -fsSL --max-time 15 \
    "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest" \
    | jq -r '.tag_name // empty')"
else
  tag="$(curl -fsSL --max-time 15 \
    "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest" \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
fi

[ -n "$tag" ] || die "无法获取最新版本信息，请检查网络连接"

green "最新版本：$tag"

# ── 2. 下载 Release tarball ──
# GitHub 自动生成源码归档：refs/tags/v1.0.tar.gz → 解压为 sHway2-1.0/
tarball_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/tags/${tag}.tar.gz"
tmp_dir="/tmp/sHway2-bootstrap.$$"
mkdir -p "$tmp_dir"
tarball="$tmp_dir/sHway2.tar.gz"

info "正在下载：$tarball_url"
curl -fL --retry 3 --connect-timeout 15 -o "$tarball" "$tarball_url" \
  || die "下载失败：$tarball_url"

# ── 3. 解压 ──
info "正在解压..."
tar -xzf "$tarball" -C "$tmp_dir" || die "解压失败"

# GitHub tar 归档的顶层目录名：去掉 tag 的 v 前缀
dir_name="${REPO_NAME}-${tag#v}"

# 兼容处理：如果 tag 本身没有 v 前缀
extracted="$(find "$tmp_dir" -maxdepth 1 -type d -name "${REPO_NAME}-*" | head -1)"
[ -n "$extracted" ] || die "解压后未找到安装目录"

install_script="$extracted/sHway2.sh"
[ -r "$install_script" ] || die "未找到 sHway2.sh，请检查 Release 结构"

# ── 4. 执行安装 ──
green "引导完成，开始安装..."
exec sh "$install_script" install
