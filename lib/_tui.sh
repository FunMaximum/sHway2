#!/bin/sh
# sHway2 - 终端交互模块

read_tty() {
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    read -r ans </dev/tty || ans=""
  else
    die "当前没有可交互终端，请使用：curl -fsSL 脚本地址 -o /tmp/install.sh && sh /tmp/install.sh"
  fi
}

ask_var() {
  ASK_VAR_TARGET="$1"
  ASK_VAR_PROMPT="$2"
  ASK_VAR_DEFAULT="$3"
  printf '%s [%s]: ' "$ASK_VAR_PROMPT" "$ASK_VAR_DEFAULT" >/dev/tty
  read_tty
  [ -n "$ans" ] || ans="$ASK_VAR_DEFAULT"
  eval "$ASK_VAR_TARGET=\$ans"
}

ask_yes_no() {
  ASK_YN_PROMPT="$1"
  ASK_YN_DEFAULT="$2"
  while :; do
    printf '%s [%s]: ' "$ASK_YN_PROMPT" "$ASK_YN_DEFAULT" >/dev/tty
    read_tty
    [ -z "$ans" ] && ans="$ASK_YN_DEFAULT"
    case "$ans" in
      y|Y|yes|YES|是) return 0 ;;
      n|N|no|NO|否) return 1 ;;
      *) yellow "请输入 y 或 n" ;;
    esac
  done
}

ask_port_var() {
  ASK_PORT_TARGET="$1"
  ASK_PORT_NAME="$2"
  ASK_PORT_DEFAULT="$3"
  while :; do
    printf '%s [%s]: ' "$ASK_PORT_NAME" "$ASK_PORT_DEFAULT" >/dev/tty
    read_tty
    [ -n "$ans" ] || ans="$ASK_PORT_DEFAULT"
    if valid_port "$ans"; then
      eval "$ASK_PORT_TARGET=\$ans"
      return
    fi
    yellow "端口必须是 1-65535 的数字"
  done
}
