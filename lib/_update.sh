#!/bin/sh
# sHway2 - 自更新模块

REPO_OWNER="FunMaximum"
REPO_NAME="sHway2"

github_latest_tag() {
  tag=""
  if command -v jq >/dev/null 2>&1; then
    tag="$(curl -fsSL --max-time 10 \
      "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest" \
      | jq -r '.tag_name // empty')"
  else
    tag="$(curl -fsSL --max-time 10 \
      "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest" \
      | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  fi
  printf '%s' "$tag"
}

do_update() {
  current="$(load_version)"
  info "当前版本：$current"
  info "正在检查更新..."

  remote_tag="$(github_latest_tag)"
  [ -n "$remote_tag" ] || die "无法获取最新版本信息，请检查网络"

  # 去掉 tag 前缀 'v'
  remote_ver="${remote_tag#v}"

  if [ "$current" = "$remote_ver" ]; then
    green "已是最新版本 v$current"
    return 0
  fi

  green "发现新版本：$remote_tag（当前 v$current）"
  info "正在下载更新..."

  tmp="/tmp/sHway2-update.$$"
  mkdir -p "$tmp"

  # 下载 Release tarball
  tarball_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${remote_tag}/sHway2-${remote_ver}.tar.gz"
  curl -fL --retry 3 --connect-timeout 10 -o "$tmp/sHway2.tar.gz" "$tarball_url" \
    || die "下载更新失败：$tarball_url"

  # 解压
  tar -xzf "$tmp/sHway2.tar.gz" -C "$tmp" || die "解压更新包失败"

  # 找到解压后的根目录
  extracted="$(find "$tmp" -maxdepth 2 -name sHway2.sh -type f | head -1)"
  [ -n "$extracted" ] || die "更新包中未找到 sHway2.sh"
  extracted_dir="$(dirname "$extracted")"

  info "正在安装更新..."

  # 更新 sb 的 lib/（如果存在）
  if [ -d "$SB_LIB" ]; then
    for f in "$extracted_dir/lib"/*.sh; do
      [ -r "$f" ] && cp "$f" "$SB_LIB/"
    done
    [ -r "$extracted_dir/VERSION" ] && cp "$extracted_dir/VERSION" "$SB_LIB/VERSION"
    green "sb 库已更新"
  fi

  # 更新 sb 二进制
  if [ -r "$extracted_dir/sb.sh" ]; then
    cp "$extracted_dir/sb.sh" "$SB_BIN"
    chmod 755 "$SB_BIN"
    green "sb 已更新到 $SB_BIN"
  fi

  # 如果正在直接从源码目录运行，也更新自身
  if [ -n "${SCRIPT_DIR:-}" ] && [ -d "$SCRIPT_DIR/lib" ]; then
    for f in "$extracted_dir/lib"/*.sh; do
      [ -r "$f" ] && cp "$f" "$SCRIPT_DIR/lib/"
    done
    [ -r "$extracted_dir/VERSION" ] && cp "$extracted_dir/VERSION" "$SCRIPT_DIR/VERSION"
    [ -r "$extracted_dir/sHway2.sh" ] && cp "$extracted_dir/sHway2.sh" "$SCRIPT_DIR/sHway2.sh"
    green "本地源码已更新"
  fi

  rm -rf "$tmp"
  green "更新完成：v$current → v$remote_ver"
}
