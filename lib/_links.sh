#!/bin/sh
# sHway2 - v2rayN 分享链接生成模块（sHway2.sh 和 sb 共用）

print_links() {
  # 读取节点信息
  [ -r "$META" ] || die "未找到节点信息：$META，请先运行安装脚本"
  . "$META"

  # 计算证书 SHA256 指纹
  CERT_SHA256="${CERT_SHA256:-}"
  if [ -z "$CERT_SHA256" ] && [ -s "$CERT" ] && command -v openssl >/dev/null 2>&1; then
    CERT_SHA256="$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 | sed 's/.*=//;s/://g' | tr '[:upper:]' '[:lower:]')"
  fi

  # URL 编码
  e_server="$(urlencode "$SERVER")"
  e_sni="$(urlencode "$SNI")"
  e_hy2_pass="$(urlencode "$HY2_PASS")"
  e_hy2_obfs="$(urlencode "$HY2_OBFS")"
  e_tuic_pass="$(urlencode "$TUIC_PASS")"
  e_anytls_pass="$(urlencode "$ANYTLS_PASS")"
  e_r_hy2="$(urlencode "$REMARK_PREFIX-HY2")"
  e_r_tuic="$(urlencode "$REMARK_PREFIX-TUIC5")"
  e_r_anytls="$(urlencode "$REMARK_PREFIX-AnyTLS")"

  # 证书钉扎参数
  pin_param=""
  if [ -n "$CERT_SHA256" ]; then
    pin_param="&pinSHA256=${CERT_SHA256}"
  fi

  # 端口跳跃
  hy2_extra=""
  if [ "${HY2_JUMP:-n}" = "y" ]; then
    hy2_extra="&mport=${HY2_JUMP_RANGE}"
  fi

  # 生成链接
  hy2_link="hysteria2://${e_hy2_pass}@${e_server}:${HY2_PORT}/?sni=${e_sni}&insecure=1${pin_param}&obfs=salamander&obfs-password=${e_hy2_obfs}${hy2_extra}#${e_r_hy2}"
  tuic_link="tuic://${TUIC_UUID}:${e_tuic_pass}@${e_server}:${TUIC_PORT}/?sni=${e_sni}&alpn=h3&allow_insecure=1${pin_param}&congestion_control=bbr&udp_relay_mode=native#${e_r_tuic}"
  anytls_link="anytls://${e_anytls_pass}@${e_server}:${ANYTLS_PORT}/?security=tls&sni=${e_sni}&insecure=1${pin_param}#${e_r_anytls}"

  # 写入文件
  umask 077
  cat > "$BASE_DIR/v2rayn-links.txt" <<EOL
$hy2_link
$tuic_link
$anytls_link
EOL

  green ""
  green "节点信息如下，可复制到 v2rayN 导入："
  info ""
  info "Hysteria2:"
  info "$hy2_link"
  info ""
  info "TUIC v5:"
  info "$tuic_link"
  info ""
  info "AnyTLS:"
  info "$anytls_link"
  info ""
  if [ -n "$CERT_SHA256" ]; then
    info "证书 SHA256 指纹：$CERT_SHA256"
    info "（链接已内嵌 pinSHA256，支持钉扎的客户端可自动匹配）"
    info ""
  fi
  info "链接已保存：$BASE_DIR/v2rayn-links.txt"
  info "服务端配置：$CONF"
  info ""
  yellow "注意：HY2/TUIC 使用 UDP，AnyTLS 使用 TCP。若 VPS 厂商有安全组，请放行对应端口。自签证书需要客户端允许不安全证书。"
}
