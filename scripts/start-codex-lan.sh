#!/bin/zsh
set -euo pipefail

PORT="${1:-4500}"
TOKEN_FILE="${TMPDIR:-/tmp}/codeanywhere-codex-token"

umask 077
printf '%s' 'codeanywhere-lan-v1' > "$TOKEN_FILE"

exec codex app-server \
  --listen "ws://0.0.0.0:${PORT}" \
  --ws-auth capability-token \
  --ws-token-file "$TOKEN_FILE"

