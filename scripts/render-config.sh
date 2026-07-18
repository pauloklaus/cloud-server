#!/usr/bin/env bash
# Render config files that cannot expand env vars by themselves (CoreDNS Corefile).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "missing $ENV_FILE — copy .env.template and fill values first" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${ADGUARD_IP:?ADGUARD_IP must be set in .env}"

CORE_TEMPLATE="$ROOT/wireguard/config/coredns/Corefile.template"
CORE_OUT="$ROOT/wireguard/config/coredns/Corefile"

if ! command -v envsubst >/dev/null 2>&1; then
  echo "envsubst not found (install gettext-base / gettext)" >&2
  exit 1
fi

# Only substitute listed vars — avoids eating unrelated `$` in templates.
envsubst '${ADGUARD_IP}' <"$CORE_TEMPLATE" >"$CORE_OUT"
echo "rendered $CORE_OUT (ADGUARD_IP=${ADGUARD_IP})"
