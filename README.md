# sHway2

Hysteria2 + TUIC v5 + AnyTLS 一键部署脚本。使用单个 sing-box 进程同时运行三种协议，安装完成后输出可直接导入 v2rayN 的分享链接。

支持自动证书申请、端口检查、安装中断恢复、可交互选择配置。

### 支持系统

Debian 12 / Ubuntu 22.04 / Ubuntu 24.04 / Alpine

### 依赖细则

`ca-certificates` `curl` `tar` `openssl` `iptables`，脚本启动后自动安装。

---

## 一键安装

```bash
# 跟随最新 Release 版本（推荐）
curl -fsSL https://raw.githubusercontent.com/FunMaximum/sHway2/master/get.sh | sudo sh
```

```bash
# 跟随指定 tag 版本
curl -fsSL https://raw.githubusercontent.com/FunMaximum/sHway2/refs/tags/v1.0/sHway2-v1.0.sh | sudo sh
```

Alpine 如未安装 curl：

```sh
apk add --no-cache ca-certificates curl
```

---

## 涉及协议

| 协议      | 传输层 | 默认端口  | 特性                          |
| --------- | ------ | --------- | ----------------------------- |
| Hysteria2 | UDP    | `11451` | salamander 混淆、可选端口跳跃 |
| TUIC v5   | UDP    | `11452` | BBR 拥塞控制、QUIC 传输       |
| AnyTLS    | TCP    | `11453` | TLS 隧道                      |

## 默认配置

| 项目           | 默认值                  |
| -------------- | ----------------------- |
| Hysteria2 上行 | `50 Mbps`             |
| Hysteria2 下行 | `200 Mbps`            |
| TLS            | 自签证书（10 年有效期） |
| 证书域名 / SNI | `www.bing.com`        |

安装过程中可交互自定义：端口、带宽、节点名称前缀、是否开启 Hysteria2 端口跳跃。

---

## 管理命令

安装完成后使用 `sb` 管理服务：

```sh
sb          # 显示 v2rayN 导入链接（默认命令）
sb show     # 同上
sb status   # 查看 sing-box 运行状态
sb restart  # 重启 sing-box
sb log      # 查看 sing-box 日志
sb help     # 查看帮助
```

---

## 节点信息

安装完成后终端直接打印 v2rayN 可导入的分享链接，同时保存到：

```
/etc/sing-box/v2rayn-links.txt
```

再次查看：

```sh
sb
```

---

## 放行端口

请在 VPS 防火墙和云服务商安全组中放行：

- `11451/udp` — Hysteria2
- `11452/udp` — TUIC v5
- `11453/tcp` — AnyTLS

若修改了默认端口，请放行实际填写的端口。开启 Hysteria2 端口跳跃还需放行对应 UDP 端口段。

---

## 目录结构

```
/etc/sing-box/
├── config.json          # sing-box 服务端配置
├── client-info.env      # 节点参数（供 sb 读取）
├── server.crt           # 自签 TLS 证书
├── server.key           # TLS 私钥
└── v2rayn-links.txt     # v2rayN 分享链接
```

```
/usr/local/bin/
├── sing-box             # sing-box 二进制
└── sb                   # sHway2 管理脚本
```

---

## 注意事项

- 请勿公开分享安装后输出的节点链接。
- 如果怀疑链接泄露，重新运行脚本会生成新的密码和节点信息。
- 自签证书需要客户端启用「允许不安全证书」，如条件允许建议替换为真实域名证书。
- 不需要端口跳跃时建议不开启，减少端口暴露面。

---

## 协议

MIT

---

*感谢初始脚本提供者。*
