#!/bin/sh

set -eu

expect /workspace/docker/install-default.exp
sh /workspace/docker/verify-install.sh

