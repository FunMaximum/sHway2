#!/bin/sh

set -eu

expect /workspace/docker/install-default.exp
sh /workspace/docker/verify-install.sh
sh /workspace/docker/verify-protocols.sh
sh /workspace/docker/verify-lifecycle.sh
