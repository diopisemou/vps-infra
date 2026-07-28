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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"

# Role scripts need this to fetch siblings (compose files, etc.) when this script
# was piped in from curl and there is no local checkout to resolve paths against.
export REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/diopisemou/vps-infra/main}"

fetch_role() {
  local name="$1"
  local local_path="$SCRIPT_DIR/roles/${name}.sh"
  if [[ -n "$SCRIPT_DIR" && -f "$local_path" ]]; then
    bash "$local_path"
  else
    curl -fsSL "$REPO_RAW_BASE/scripts/roles/${name}.sh" | bash
  fi
}

echo "==> [1/2] common (hardening + docker)"
fetch_role common

if [[ "$ROLE" != "common" ]]; then
  echo "==> [2/2] role: $ROLE"
  fetch_role "$ROLE"
fi

echo "==> Done. Role '$ROLE' applied on $(hostname)."
