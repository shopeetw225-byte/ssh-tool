#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
chmod +x ./remote-support.sh ./bore ./bore-arm64 ./bore-x86_64 2>/dev/null || true
./remote-support.sh start
