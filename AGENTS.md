# Repository Guidelines

## Project Structure & Module Organization

- `get.sh` is the lightweight bootstrapper. It discovers the latest GitHub release, downloads the versioned installer, and executes it.
- `sHway2-v1.0.sh` is the main POSIX shell installer. It detects supported systems, installs sing-box, generates server/client configuration, and creates the `sb` management command.
- `README.md` documents supported platforms, defaults, installation, and operations.
- `TECHNICAL.md` is the persistent source of truth for architecture, invariants, audits, and feature history. Read it before planning or implementing a feature and update it when behavior changes.
- `compose.yaml` and `docker/` provide a disposable Ubuntu 22.04 integration-test VM. They are development tools, not a deployment path.
- `参考/` contains upstream/reference material. Treat it as background; make production changes in the root scripts unless intentionally refreshing the reference.

Keep reusable shell behavior in small functions. When adding a release, update script names and URLs consistently in the bootstrapper and documentation.

## Build, Test, and Development Commands

Do not execute any repository file directly on the host. Run all project scripts and checks inside the disposable container:

```sh
docker compose build ubuntu2204
docker compose up -d --wait ubuntu2204
docker compose exec ubuntu2204 sh /workspace/docker/test-default.sh
```

The test container runs syntax checks, ShellCheck, and a complete installer execution. Host commands are limited to repository inspection/editing and Docker/Compose lifecycle commands. Never source, invoke, or otherwise execute `get.sh`, `sHway2-v1.0.sh`, or files under `docker/` on the host.

## Coding Style & Naming Conventions

Target POSIX `/bin/sh`, not Bash. Preserve `set -eu`, use two-space indentation, quote variable expansions, and prefer `printf` over `echo`. Use `snake_case` for functions and lowercase local/helper variables; reserve uppercase names for configuration and environment-style values such as `BASE_DIR` and `ARCH`. Route fatal errors through `die` and use the existing color helpers for user-facing status messages. Keep prompts and operational messages in Chinese to match the current interface.

## Testing Guidelines

Every change must pass syntax and ShellCheck validation. Exercise affected branches on the relevant OS family: Debian/Ubuntu with systemd or Alpine with OpenRC. For network, certificate, port, or firewall changes, verify both default and custom interactive inputs, interrupted-install recovery, generated JSON, service startup, and `sb show/status/restart/log` behavior. Never test against a production VPS containing active sing-box configuration.

The Compose harness currently covers Ubuntu 22.04 only. Record untested Debian, Ubuntu 24.04, or Alpine branches explicitly in the handoff rather than claiming coverage.

## Commit & Pull Request Guidelines

Follow the existing history format: `feat : 简短说明`, `fix : 简短说明`, or `init : 简短说明`. Keep each commit focused. Pull requests should describe behavior changes, supported systems tested, commands run, and any generated-file or firewall impact. Link related issues and include terminal output for user-visible workflow changes; screenshots are optional for this CLI-only project.

## Security & Configuration Tips

Do not commit generated credentials, private keys, node links, IP addresses, or `/etc/sing-box/client-info.env`. Preserve restrictive permissions on secrets and avoid logging passwords or UUIDs.
