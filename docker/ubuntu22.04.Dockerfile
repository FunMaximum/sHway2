FROM ubuntu:22.04

ENV container=docker \
    DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    dbus \
    expect \
    iproute2 \
    jq \
    netcat-openbsd \
    procps \
    shellcheck \
    systemd \
    systemd-sysv \
    unzip \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/* \
  && systemctl mask \
    dev-hugepages.mount \
    sys-fs-fuse-connections.mount \
    systemd-remount-fs.service

STOPSIGNAL SIGRTMIN+3

CMD ["/sbin/init"]
