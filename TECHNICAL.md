# sHway2 技术文档

本文档是项目架构、行为约束、已知风险和功能演进的长期事实来源。每次新增或修改功能前必须先阅读本文；实现完成后必须同步更新相关章节和变更记录。

## 1. 产品边界

sHway2 的生产交付物是 POSIX Shell 安装器，不是 Docker 镜像：

- `get.sh` 查询 GitHub 最新 Release，下载对应 tag 下的安装脚本并执行。
- `sHway2-v1.0.sh` 在 VPS 上安装 sing-box，写入服务端配置和管理命令，并注册 systemd 或 OpenRC 服务。
- `compose.yaml` 与 `docker/` 只在开发电脑上提供一次性 Ubuntu 22.04 测试环境，禁止作为真实服务器部署方案。
- 禁止在宿主开发机执行仓库内的任何文件。所有项目脚本、语法检查、ShellCheck 和集成测试必须在测试容器内运行；宿主机只允许读取/编辑仓库及调用 Docker/Compose。

`参考/` 是上游背景资料，不是生产实现。

## 2. 生产安装流程

主安装器按以下顺序执行：

1. 要求 root，读取 `/etc/os-release`，识别 Debian、Ubuntu 或 Alpine，并检测 CPU 架构。
2. 通过 apt 或 apk 安装依赖，从 SagerNet GitHub Release 下载 sing-box；若 `/usr/local/bin/sing-box` 已存在则跳过下载。
3. 从 `/dev/tty` 收集服务器地址、SNI、端口、带宽、节点前缀和端口跳跃选项，随后生成随机认证信息。
4. 在 `/etc/sing-box` 生成或复用自签证书，写入 `config.json` 与 `client-info.env`，再执行 `sing-box check`。
5. 写入 systemd/OpenRC 服务。端口跳跃通过 iptables NAT PREROUTING 将 UDP 范围重定向到 HY2 主端口。
6. 生成 `/usr/local/bin/sb` 和 `v2rayn-links.txt`，输出 Hysteria2、TUIC v5、AnyTLS 分享链接。

三种协议由同一个 sing-box 进程承载：Hysteria2 和 TUIC 使用 UDP，AnyTLS 使用 TCP。默认端口分别为 11451、11452、11453。

## 3. 数据、安全与不变量

- `/etc/sing-box` 应为 `0700`；配置、私钥、客户端元数据和分享链接应为 `0600`。
- 不得提交真实 IP、域名、UUID、密码、私钥、证书或节点链接。
- 自签证书默认有效期十年，客户端链接包含允许不安全证书参数。项目当前没有实现 ACME 或真实证书申请。
- 重新执行安装器会生成新的协议凭据并覆盖配置；现有证书文件存在时会被复用。
- Docker 测试仓库挂载必须是只读；安装产物只存在于容器可写层，删除容器即清除。
- Docker 测试需要 `privileged` 和宿主 cgroup 挂载，仅能在可信开发机运行。其目的是测试 systemd 和完整安装流程，不代表生产容器安全基线。

## 4. Docker 开发测试

测试环境以本地 `ubuntu:22.04` 为基础，派生镜像只预装 systemd、dbus、Expect、ShellCheck、jq 和诊断工具，运行时容器固定命名为 `sHway-ubuntu2204`。sing-box 及安装器声明的依赖仍由被测安装脚本安装。

标准流程：

```sh
docker compose build ubuntu2204
docker compose up -d --wait ubuntu2204
docker compose exec ubuntu2204 sh /workspace/docker/test-default.sh
docker compose down
```

`test-default.sh` 仅测试默认输入并明确关闭端口跳跃。它依次执行完整安装与以下验收：

- `sh -n`、ShellCheck、JSON 解析和 `sing-box check`。
- 证书有效性、敏感文件存在性和权限。
- systemd 服务状态及三个默认端口监听。
- `sb show/status/restart/log`。

自定义输入、重复安装、异常中断和端口跳跃需要进入容器手工测试。Compose 仅映射默认端口到宿主回环地址，自定义端口不会自动发布。

当前自动测试只覆盖 Ubuntu 22.04/systemd，不代表 Debian 12、Ubuntu 24.04 或 Alpine/OpenRC 已通过。

## 5. 功能审计

审计基于 v1.0 脚本。当前决定是记录问题，不在 Docker 测试环境变更中修复生产脚本。

### 已确认合理

- 单个 sing-box 进程运行三种 inbound，配置结构与当前 sing-box 的 Hysteria2、TUIC 和 AnyTLS inbound 结构一致。
- 使用 OpenSSL 生成高熵密码和 UUID，并限制主要敏感文件权限。
- 写配置后、启动服务前调用 `sing-box check`，能阻止无效配置进入服务启动阶段。
- systemd 和 OpenRC 分支结构清晰，`sb` 覆盖常用查看、状态、重启和日志操作。

### 高风险问题

1. `HY2_JUMP_RANGE` 只检查是否包含冒号，未验证两端为合法端口及顺序。该值会进入 systemd/OpenRC 文件和 iptables 命令，存在命令或 unit 内容注入风险。
2. SNI、服务器地址等输入直接插入 JSON，双引号、反斜杠或换行可破坏配置。
3. 输入直接以单引号形式写入 `client-info.env`，而 `sb` 会 source 此文件；包含单引号的输入可破坏赋值并形成代码执行风险。

### 中风险与一致性问题

1. 脚本声称支持端口检查，但实际只验证端口数值范围，没有检查占用、三个主端口是否重复或跳跃范围冲突。
2. HY2 上下行值没有验证为正整数，随后作为裸 JSON 数值写入。
3. 已有证书总被复用；重新安装时修改 SNI 会造成证书 CN 与新配置不一致。
4. 已有 sing-box 二进制时跳过版本检查和升级；AnyTLS 至少需要 sing-box 1.12，旧版本只能等到配置检查阶段失败。
5. `get.sh` 查询最新 tag，但下载文件名固定为 `sHway2-v1.0.sh`，未来版本改名后引导会失效。
6. 下载临时目录没有退出 trap；异常中断可能遗留文件。端口跳跃配置变化或异常退出也可能遗留旧 NAT 规则。
7. 公网 IP 获取失败时会把中文提示文本当作服务器地址继续生成不可直接使用的链接。
8. 分享链接按 v2rayN 兼容目标生成，但仓库没有自动导入测试；三个协议仍需真实客户端验收。
9. 安装器和引导脚本依赖匿名 GitHub Releases API；共享出口触发 API 限流时会收到 HTTP 403 并中止，目前没有认证、镜像源或版本回退机制。

### ShellCheck 基线

生产脚本当前存在三个已知告警，本次不修改生产代码：

- `SC1091`：动态加载系统提供的 `/etc/os-release`。
- `SC2015`：已安装 sing-box 的提示使用 `A && B || C` 结构。
- `SC2153`：ShellCheck 无法识别通过 `eval` 动态赋值的 `HY2_UP`；该动态赋值同时属于需重构的输入处理区域。

容器验收只对这三个生产脚本基线告警做显式排除；新增 Docker shell 脚本不得增加或排除告警。

## 6. 新功能工作流

新增功能必须先明确其生产脚本行为，再决定 Docker 测试如何覆盖；不得在 Docker 中另建一套与 `.sh` 不一致的生产配置逻辑。

每次变更至少更新：

- 目标和用户可见行为。
- 新增或变化的参数、文件、命令和默认值。
- 凭据、网络、证书、防火墙及权限影响。
- 重复安装、失败恢复和旧版本兼容行为。
- 容器内实际运行的测试，以及尚未覆盖的系统分支。

## 7. 变更记录

### Docker Ubuntu 22.04 测试环境

- 增加带 systemd 的特权测试容器、默认交互安装驱动和安装后验收脚本。
- 确立 `.sh` 为唯一生产部署方式、Docker 仅供开发测试的边界。
- 确立禁止在宿主机执行任何仓库文件的强制规则。
- 首次记录 v1.0 功能审计，未修改生产安装器。
- 首次完整容器测试到达 sing-box 下载阶段，但匿名 GitHub API 配额显示 `60/60` 已用尽并返回 HTTP 403；该外部阻塞已记录，不能据此宣称安装与服务验收通过。
