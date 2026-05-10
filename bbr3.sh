#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-Miaocchi/Latest-Kernel-BBR3-UCP}"

exec bash <(curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/install.sh") "$@"
