#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
chmod +x ./remote-support.sh 2>/dev/null || true
if ! ./remote-support.sh stop; then
  ./remote-support.sh recover
fi
