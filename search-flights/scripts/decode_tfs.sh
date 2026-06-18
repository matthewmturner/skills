#!/usr/bin/env bash
set -euo pipefail

TFS="${1:?Usage: decode_tfs.sh <tfs_param>}"
PAD=$(( (4 - ${#TFS} % 4) % 4 ))
printf "%s%s" "$TFS" "$(printf '=%.0s' $(seq 1 $PAD))" \
  | tr -- '-_' '+/' \
  | base64 -d \
  | protoc --decode_raw
