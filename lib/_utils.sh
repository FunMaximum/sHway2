#!/bin/sh
# sHway2 - 工具函数模块（随机数、URL编码、公网IP）

rand_hex() {
  openssl rand -hex "$1"
}

rand_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    h="$(openssl rand -hex 16)"
    printf '%s-%s-%s-%s-%s\n' \
      "$(printf '%s' "$h" | cut -c1-8)" \
      "$(printf '%s' "$h" | cut -c9-12)" \
      "$(printf '%s' "$h" | cut -c13-16)" \
      "$(printf '%s' "$h" | cut -c17-20)" \
      "$(printf '%s' "$h" | cut -c21-32)"
  fi
}

urlencode() {
  s="$1"
  out=""
  i=1
  len=${#s}
  while [ "$i" -le "$len" ]; do
    c=$(printf '%s' "$s" | cut -c "$i")
    case "$c" in
      [a-zA-Z0-9.~_-]) out="$out$c" ;;
      ' ') out="$out%20" ;;
      *) out="$out$(printf '%%%02X' "'${c}")" ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$out"
}

get_ip() {
  ip=""
  ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [ -n "$ip" ] || ip="$(curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  [ -n "$ip" ] || ip="请手动替换为服务器IP或域名"
  printf '%s' "$ip"
}

valid_port() {
  p="$1"
  case "$p" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$p" -ge 1 ] 2>/dev/null && [ "$p" -le 65535 ] 2>/dev/null
}
