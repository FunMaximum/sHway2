# sHway2 技术文档

本文档是项目架构、行为约束、已知风险和功能演进的长期事实来源。每次新增或修改功能前必须先阅读本文；实现完成后必须同步更新相关章节和变更记录。

## 1. 产品边界

sHway2 的生产交付物是 POSIX Shell 安装器，不是 Docker 镜像：

- `get.sh` 查询 GitHub 最新 Release，下载对应 tag 下的安装脚本并执行。
- `sHway2.sh` 在 VPS 上安装 sing-box，写入服务端配置和管理命令，并注册 systemd 或 OpenRC 服务。文件名保持固定，发布版本由 Git tag 表示。
- `uninstall.sh` 清除本项目的运行状态和服务注册，但保留 sing-box 内核、依赖、其他插件与 Git 仓库，用于更新后的快速干净重装。
- `compose.yaml` 与 `docker/` 只在开发电脑上提供一次性 Ubuntu 22.04 测试环境，禁止作为真实服务器部署方案。
- 禁止在宿主开发机执行仓库内的任何文件。所有项目脚本、语法检查、ShellCheck 和集成测试必须在测试容器内运行；宿主机只允许读取/编辑仓库及调用 Docker/Compose。

`参考/` 是上游背景资料，不是生产实现。

## 2. 生产安装流程

主安装器按以下顺序执行：

1. 要求 root，读取 `/etc/os-release`，识别 Debian、Ubuntu 或 Alpine，并检测 CPU 架构。
2. 通过 apt 或 apk 安装依赖。若现有 sing-box 不低于 1.12 则复用，否则从 SagerNet GitHub Release 下载兼容版本。
3. 从 `/dev/tty` 收集服务器地址、SNI、端口、带宽、节点前缀和端口跳跃选项，严格验证输入、占用和冲突后生成随机认证信息。
4. 在 `/etc/sing-box` 生成自签证书；仅当已有证书 CN 与当前 SNI 一致时复用。随后写入 `config.json` 与不可执行的键值元数据，再执行 `sing-box check`。
5. 写入 systemd/OpenRC 服务。端口跳跃通过 iptables NAT PREROUTING 将 UDP 范围重定向到 HY2 主端口。
6. 生成 `/usr/local/bin/sb` 和 `v2rayn-links.txt`，输出 Hysteria2、TUIC v5、AnyTLS 分享链接。

三种协议由同一个 sing-box 进程承载：Hysteria2 和 TUIC 使用 UDP，AnyTLS 使用 TCP。默认端口分别为 11451、11452、11453。

## 3. 数据、安全与不变量

- `/etc/sing-box` 应为 `0700`；配置、私钥、客户端元数据和分享链接应为 `0600`。
- 不得提交真实 IP、域名、UUID、密码、私钥、证书或节点链接。
- 自签证书默认有效期十年，客户端链接包含允许不安全证书参数。项目当前没有实现 ACME 或真实证书申请。
- 重新执行安装器会生成新的协议凭据并覆盖配置；证书只在 CN 与本次 SNI 相同时复用。
- `client-info.env` 是受限字符的 `KEY=value` 数据文件，`sb` 逐项解析允许的键，禁止将其作为 shell 脚本 source。
- 用户填写的服务器地址、SNI 和节点前缀仅允许 ASCII 字母、数字、点、下划线和连字符；带宽必须是正整数。
- `SING_BOX_VERSION` 可固定 sing-box 下载版本，`SHWAY2_VERSION` 可固定引导器下载的 Release tag；`GITHUB_TOKEN` 可提高 GitHub API 配额。
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

审计最初基于 v1.0 脚本。以下高风险与中风险问题已在生产脚本安全更新中处理。

### 已确认合理

- 单个 sing-box 进程运行三种 inbound，配置结构与当前 sing-box 的 Hysteria2、TUIC 和 AnyTLS inbound 结构一致。
- 使用 OpenSSL 生成高熵密码和 UUID，并限制主要敏感文件权限。
- 写配置后、启动服务前调用 `sing-box check`，能阻止无效配置进入服务启动阶段。
- systemd 和 OpenRC 分支结构清晰，`sb` 覆盖常用查看、状态、重启和日志操作。

### 已修复的高风险问题

1. 跳跃范围现在必须是两个合法端口、起点不大于终点且不能覆盖三个主端口，进入 unit 和 iptables 的值只能是数字与单个冒号。
2. JSON 中的用户字符串改为严格白名单输入，无法注入引号、反斜杠、换行或 JSON 结构。
3. 安装器移除 `eval`；元数据不再写 shell 引号，`sb` 使用允许键列表解析，不再 source 数据文件。

### 已修复的中风险与一致性问题

1. 主端口现在校验数值、重复和实际监听占用；重复安装时允许当前 sing-box 自身占用。
2. HY2 上下行必须是正整数。
3. SNI 改变、证书损坏或密钥缺失时会原子生成新证书和私钥。
4. 现有 sing-box 必须不低于 1.12；低版本重新下载，固定版本也必须满足最低版本。
5. 所有 Release 使用固定文件名 `sHway2.sh`，`get.sh` 根据 tag 下载同名脚本。
6. 下载目录、引导临时文件和证书临时文件均由 signal/exit trap 清理；重复安装前安全删除旧端口跳跃规则。
7. 公网 IP 获取失败时默认值为空，安装器要求用户输入合法服务器地址，不能再生成占位链接。
8. GitHub API 限流时可以使用显式版本变量跳过 API，也可以提供 `GITHUB_TOKEN`。

### 卸载与快速重装

- `uninstall.sh` 支持交互确认和 `--yes`，并且可重复执行。
- 卸载会删除已记录的跳跃 NAT 规则，停止并取消服务自启动，删除项目服务文件、`sb`、OpenRC 日志和 `/etc/sing-box`。
- `/usr/local/bin/sing-box`、apt/apk 依赖、其他插件和仓库文件不在卸载范围内。
- 更新仓库后重新运行 `sHway2.sh`，兼容内核会被复用，配置、证书、凭据和服务会重新创建。

### 仍需外部验证

- 分享链接按 v2rayN 兼容目标生成，但仓库无法自动执行真实客户端导入；三个协议仍需客户端验收。
- Ubuntu 22.04/systemd 已覆盖；Debian 12、Ubuntu 24.04 与 Alpine/OpenRC 仍需独立集成测试。

### ShellCheck 基线

生产脚本与测试 shell 脚本当前应在不排除告警的情况下通过 ShellCheck。`/etc/os-release` 的动态加载在对应代码处做了明确的单行说明。

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

### 生产脚本安全与一致性修复

- 主安装器改为固定文件名 `sHway2.sh`，Release tag 不再影响脚本文件名。
- 修复输入、JSON、元数据和端口跳跃命令注入风险。
- 增加端口/带宽/版本校验、证书 SNI 一致性、旧 NAT 规则和临时文件清理。
- 增加 GitHub API 限流时的固定版本路径；使用 `SING_BOX_VERSION=1.13.12` 在 Ubuntu 22.04 完成首次安装、重复安装、配置、权限、systemd、监听端口和 `sb` 命令验收。

### 卸载与快速更新

- 新增 `uninstall.sh`，清理项目配置、服务注册、`sb`、OpenRC 日志和端口跳跃规则。
- 保留 sing-box 内核、系统依赖、其他插件和仓库，支持更新代码后快速重新安装。
- Ubuntu 22.04/systemd 已验证真实卸载、第二次幂等卸载、内核保留，以及卸载后复用内核完成安装和全部标准验收。
