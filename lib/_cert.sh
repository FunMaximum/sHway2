#!/bin/sh
# sHway2 - TLS 证书模块

write_cert() {
  mkdir -p "$BASE_DIR"
  chmod 700 "$BASE_DIR"

  # 若 SNI 变更，强制重建证书（避免 CN 与 SNI 不匹配）
  if [ -s "$CERT" ] && [ -s "$KEY" ]; then
    existing_cn="$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *//p')"
    if [ "$existing_cn" != "$SNI" ]; then
      info "SNI 变更为 $SNI（原证书 CN=$existing_cn），重新生成证书..."
      rm -f "$CERT" "$KEY"
    fi
  fi

  if [ ! -s "$CERT" ] || [ ! -s "$KEY" ]; then
    info "正在生成自签 TLS 证书..."
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -keyout "$KEY" -out "$CERT" -subj "/CN=$SNI" >/dev/null 2>&1 \
      || die "证书生成失败，请检查 openssl 安装"
    chmod 600 "$KEY"
  fi

  # 始终计算 SHA256 指纹（不依赖分支）
  CERT_SHA256="$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 | sed 's/.*=//;s/://g' | tr '[:upper:]' '[:lower:]')"
  [ -n "$CERT_SHA256" ] || die "无法计算证书 SHA256 指纹"
  info "证书 SHA256 指纹：$CERT_SHA256"
}
