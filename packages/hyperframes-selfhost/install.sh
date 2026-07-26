#!/usr/bin/env bash
# One-command installer for HyperFrames self-host on a Linux VM.
# Safe to re-run (idempotent compose up). Never prints secret values.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '→ %s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

bold "HyperFrames self-host installer"
info "Root: $ROOT"

# ---- Preflight ---------------------------------------------------------------
[[ "$(uname -s)" == "Linux" ]] || warn "This installer targets a Linux VM (you are on $(uname -s))"

need_cmd docker
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 required (docker compose)"

if [[ ! -f .env ]]; then
  info "Creating .env from .env.example"
  cp .env.example .env
fi

# shellcheck disable=SC1091
set -a
# shellcheck source=/dev/null
source .env
set +a

prompt_if_empty() {
  local var="$1" label="$2" secret="${3:-0}"
  local cur="${!var:-}"
  if [[ -n "$cur" && "$cur" != *REPLACE_ME* ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die "$var is empty; set it in .env for non-interactive install"
  fi
  if [[ "$secret" == "1" ]]; then
    read -r -s -p "$label: " cur
    echo
  else
    read -r -p "$label: " cur
  fi
  [[ -n "$cur" ]] || die "$var still empty"
  # Persist without echoing
  if grep -qE "^${var}=" .env; then
    # portable-ish in-place replace
    tmp="$(mktemp)"
    awk -v k="$var" -v v="$cur" 'BEGIN{FS=OFS="="} $1==k{$0=k"="v} {print}' .env >"$tmp"
    mv "$tmp" .env
  else
    printf '%s=%s\n' "$var" "$cur" >>.env
  fi
  export "$var=$cur"
}

prompt_if_empty TS_AUTHKEY "Tailscale auth key (tskey-auth-…)" 1
prompt_if_empty GOOGLE_CLIENT_ID "Google OAuth client ID"
prompt_if_empty GOOGLE_CLIENT_SECRET "Google OAuth client secret" 1
prompt_if_empty GOOGLE_ALLOWED_USERS "Allowlisted emails (comma-separated)"

TS_HOSTNAME="${TS_HOSTNAME:-hyperframes}"

# EXTERNAL_URL: prefer explicit; otherwise leave a placeholder until tailscale is up
if [[ -z "${EXTERNAL_URL:-}" ]]; then
  info "EXTERNAL_URL empty — will set after Tailscale joins the tailnet"
fi

mkdir -p "${WORKSPACE_DIR:-./workspace}" config

# ---- Build & start -----------------------------------------------------------
bold "Building images and starting stack"
docker compose pull tailscale caddy || true
docker compose up -d --build

# ---- Wait for Tailscale, resolve MagicDNS ------------------------------------
info "Waiting for Tailscale to come online…"
deadline=$((SECONDS + 120))
dns_name=""
while (( SECONDS < deadline )); do
  if dns_name="$(docker exec hf-tailscale tailscale status --json 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("Self",{}).get("DNSName","").rstrip("."))' 2>/dev/null)"; then
    if [[ -n "$dns_name" ]]; then
      break
    fi
  fi
  sleep 3
done

if [[ -z "$dns_name" ]]; then
  warn "Could not resolve MagicDNS name yet. Check: docker compose logs tailscale"
  warn "Once online, set EXTERNAL_URL=https://<node>.ts.net and: docker compose up -d mcp"
else
  url="https://${dns_name}"
  info "Tailscale DNS: $dns_name"
  if [[ -z "${EXTERNAL_URL:-}" || "$EXTERNAL_URL" != "$url" ]]; then
    tmp="$(mktemp)"
    if grep -qE '^EXTERNAL_URL=' .env; then
      awk -v v="$url" 'BEGIN{FS=OFS="="} $1=="EXTERNAL_URL"{$0="EXTERNAL_URL="v} {print}' .env >"$tmp"
    else
      cat .env >"$tmp"
      printf 'EXTERNAL_URL=%s\n' "$url" >>"$tmp"
    fi
    mv "$tmp" .env
    export EXTERNAL_URL="$url"
    info "Set EXTERNAL_URL=$url — restarting mcp"
    docker compose up -d mcp
  fi
fi

# ---- Funnel note -------------------------------------------------------------
info "Ensuring Funnel is advertised (serve config mounts AllowFunnel)…"
docker exec hf-tailscale tailscale funnel status 2>/dev/null || \
  warn "Funnel status unavailable yet — enable Funnel for your tailnet if needed: https://tailscale.com/docs/features/tailscale-funnel"

# ---- Summary -----------------------------------------------------------------
bold "Install complete"
cat <<EOF

Public MCP URL (after Funnel is active):
  ${EXTERNAL_URL:-https://<your-node>.ts.net}/mcp

Google OAuth redirect URI to register in Cloud Console (Web client):
  ${EXTERNAL_URL:-https://<your-node>.ts.net}/.auth/google/callback

Allowlisted emails:
  ${GOOGLE_ALLOWED_USERS}

Next steps:
  1. Confirm Google OAuth client is in Testing mode with those test users.
  2. Add the MCP connector in Claude/Grok with URL above.
  3. Complete Google login once; only allowlisted emails pass.

Ops:
  docker compose logs -f
  ./scripts/doctor.sh

EOF
