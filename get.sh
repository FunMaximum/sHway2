#!/bin/sh
#
# sHway2 引导脚本 — 自动拉取最新 Release 版本的完整安装脚本
# 用法：curl -fsSL URL | sudo sh
#

set -eu

REPO_OWNER="FunMaximum"
REPO_NAME="sHway2"
SCRIPT_NAME="sHway2.sh"
tmp=""

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

die() { red "错误：$*"; exit 1; }

cleanup() {
  [ -z "$tmp" ] || rm -f "$tmp"
}

trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[ "$(id -u)" = "0" ] || die "请使用 root 运行：curl -fsSL ... | sudo sh"

info() { printf '%s\n' "$*"; }
info "sHway2 引导 — 正在查找最新版本..."

# 1. 拿指定版本或最新 Release tag
tag="${SHWAY2_VERSION:-}"
if [ -n "$tag" ]; then
  case "$tag" in
    v*) ;;
    *) tag="v$tag" ;;
  esac
else
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    api="$(curl -fsSL --max-time 10 -H "Authorization: Bearer $GITHUB_TOKEN" \
      "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest")" || \
      die "无法获取最新版本；可设置 SHWAY2_VERSION 跳过 API 查询"
  else
    api="$(curl -fsSL --max-time 10 \
      "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest")" || \
      die "无法获取最新版本；GitHub 限流时请设置 SHWAY2_VERSION"
  fi
  if command -v jq >/dev/null 2>&1; then
    tag="$(printf '%s' "$api" | jq -r '.tag_name // empty')"
  else
    tag="$(printf '%s' "$api" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  fi
fi

[ -n "$tag" ] || die "无法获取最新版本 tag，请检查 GitHub API 可达性"
case "$tag" in
  v[0-9]*) ;;
  *) die "版本格式无效：$tag" ;;
esac
case "$tag" in
  *[!0-9A-Za-z.v-]*) die "版本格式无效：$tag" ;;
esac

green "最新版本：$tag"

# 2. 拉取安装脚本并执行
# 所有 Release 使用固定脚本名，版本由 tag 表示。
url="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/refs/tags/${tag}/${SCRIPT_NAME}"
info "正在下载：$url"

# 临时文件落盘，方便断线重试 / 审计
tmp="$(mktemp "/tmp/sHway2-${tag}.XXXXXX.sh")" || die "创建临时文件失败"
curl -fsSL --retry 3 --connect-timeout 10 -o "$tmp" "$url" || die "下载失败：$url"

chmod +x "$tmp"
sh "$tmp"
