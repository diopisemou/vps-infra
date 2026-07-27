#!/usr/bin/env bash
# Entry point. Run on the target server itself as root:
#   curl -fsSL <raw-url>/scripts/bootstrap.sh | bash -s -- <role>
# roles: common | main-host | neobank | meet-sso-misc | monitoring
set -euo pipefail

ROLE="${1:-}"
if [[ -z "$ROLE" ]]; then
  echo "Usage: bootstrap.sh <common|main-host|neobank|meet-sso-misc|monitoring>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_RAW_BASE="${REPO_RAW_BASE:-}"  # set if piping from curl and role scripts aren't local yet

fetch_role() {
  local name="$1"
  local local_path="$SCRIPT_DIR/roles/${name}.sh"
  if [[ -f "$local_path" ]]; then
    bash "$local_path"
  elif [[ -n "$REPO_RAW_BASE" ]]; then
    curl -fsSL "$REPO_RAW_BASE/scripts/roles/${name}.sh" | bash
  else
    echo "Cannot find role script for '$name' locally and REPO_RAW_BASE is not set." >&2
    exit 1
  fi
}

echo "==> [1/2] common (hardening + docker)"
fetch_role common

if [[ "$ROLE" != "common" ]]; then
  echo "==> [2/2] role: $ROLE"
  fetch_role "$ROLE"
fi

echo "==> Done. Role '$ROLE' applied on $(hostname)."
