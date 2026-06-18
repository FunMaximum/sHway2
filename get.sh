#!/bin/sh
#
# sHway2 引导脚本 — 自动拉取最新 Release 版本的完整安装脚本
# 用法：curl -fsSL URL | sudo sh
#

set -eu

REPO_OWNER="<用户名>"
REPO_NAME="<仓库名>"
SCRIPT_NAME="sHway2-v1.0.sh"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

die() { red "错误：$*"; exit 1; }

[ "$(id -u)" = "0" ] || die "请使用 root 运行：curl -fsSL ... | sudo sh"

info() { printf '%s\n' "$*"; }
info "sHway2 引导 — 正在查找最新版本..."

# 1. 拿最新的 Release tag
tag=""
if command -v jq >/dev/null 2>&1; then
  tag="$(curl -fsSL --max-time 10 \
    "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest" \
    | jq -r '.tag_name // empty')"
else
  # 不用 jq，纯 shell 解析
  tag="$(curl -fsSL --max-time 10 \
    "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest" \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
fi

[ -n "$tag" ] || die "无法获取最新版本 tag，请检查 GitHub API 可达性"

green "最新版本：$tag"

# 2. 拉取安装脚本并执行
# 如果各版本脚本名一致，直接用固定名；否则可从 Release assets 里找
url="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/refs/tags/${tag}/${SCRIPT_NAME}"
info "正在下载：$url"

# 临时文件落盘，方便断线重试 / 审计
tmp="/tmp/sHway2-${tag}.sh"
curl -fsSL --retry 3 --connect-timeout 10 -o "$tmp" "$url" || die "下载失败：$url"

chmod +x "$tmp"
exec sh "$tmp"
