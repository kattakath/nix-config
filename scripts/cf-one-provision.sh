#!/usr/bin/env bash
#
# cf-one-provision.sh — idempotently provision a remotely-managed (token)
# Cloudflare Tunnel for nixpi, with a public-hostname SSH ingress and a
# proxied CNAME, using the Cloudflare API only. NO interactive
# `cloudflared login`, NO cert.pem, NO Zero Trust org init, NO WARP.
#
# This fleet has exactly ONE tunnelled host: nixpi (the Raspberry Pi 4 LIVE
# server). macos is a client only (no tunnel); nixvm is a sandbox VM with no
# public ingress. The script still accepts a host-name argument so it can be
# reused if a future host ever needs a tunnel, but the default list is nixpi
# alone.
#
# For each host it:
#   (a) finds-or-creates a remotely-managed tunnel named "<host>"
#       (POST /accounts/{acct}/cfd_tunnel  {"name":..,"config_src":"cloudflare"});
#   (b) fetches the connector token (GET .../cfd_tunnel/{id}/token);
#   (c) sets the public-hostname ingress
#       (PUT .../cfd_tunnel/{id}/configurations
#         ingress: [{hostname:"<host>.kattakath.com", service:"ssh://localhost:22"},
#                   {service:"http_status:404"}]);
#   (d) UPSERTs a proxied CNAME  <host>.kattakath.com -> <id>.cfargotunnel.com.
#
# It PRINTS each host's connector token to STDOUT, clearly labeled, so the
# operator can place it in the plain, root-only secrets file the NixOS host
# reads at boot.
#
# !!! THE TOKEN IS A SECRET !!!  This script deliberately NEVER writes a token to
# any file in the repo. Do not redirect its output into a tracked file. Feed the
# token straight into `/etc/secrets/cloudflared-token` on the target NixOS host
# (content: `TUNNEL_TOKEN=<token>`, root-only, never committed — this repo has no
# agenix/encryption step, just a plain operator-placed file).
#
# USAGE:
#   CF_API_TOKEN=<token-with-Tunnels:Edit+DNS:Edit> ./scripts/cf-one-provision.sh [host...]
#
#   With no args, provisions the default HOSTS list. Pass host names to override,
#   e.g.  ./scripts/cf-one-provision.sh nixpi
#
# REQUIREMENTS: bash, curl, jq. The API token needs Account:Cloudflare Tunnel:Edit
# and Zone:DNS:Edit on kattakath.com.
set -euo pipefail

# ---- Constants --------------------------------------------------------------
ACCOUNT_ID="726e0b2aa2bc2c6944f96a042e3c461b"
ZONE_ID="6e28971881e488941d052bbbf50d69cd" # kattakath.com
ZONE_NAME="kattakath.com"
API="https://api.cloudflare.com/client/v4"

# Default host list (override via "$@"). Only nixpi runs a connector today —
# macos is a client only, nixvm is a sandbox with no public ingress.
DEFAULT_HOSTS=(nixpi)

# ---- Preconditions ----------------------------------------------------------
if [ "${CF_API_TOKEN:-}" = "" ]; then
  echo "ERROR: CF_API_TOKEN is unset. Export a token with Tunnels:Edit + DNS:Edit." >&2
  exit 1
fi
for bin in curl jq; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "ERROR: required tool '$bin' not found on PATH." >&2
    exit 1
  }
done

if [ "$#" -gt 0 ]; then
  HOSTS=("$@")
else
  HOSTS=("${DEFAULT_HOSTS[@]}")
fi

# ---- API helper -------------------------------------------------------------
# cf <METHOD> <path> [json-body]  → prints the `result` object on success.
cf() {
  local method="$1" path="$2" body="${3:-}"
  local resp
  if [ -n "$body" ]; then
    resp=$(curl -sS -X "$method" "${API}${path}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$body")
  else
    resp=$(curl -sS -X "$method" "${API}${path}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json")
  fi
  if [ "$(jq -r '.success' <<<"$resp")" != "true" ]; then
    echo "ERROR: ${method} ${path} failed:" >&2
    jq -r '.errors' <<<"$resp" >&2
    return 1
  fi
  jq -c '.result' <<<"$resp"
}

# ---- Per-host provisioning --------------------------------------------------
provision_host() {
  local host="$1"
  local fqdn="${host}.${ZONE_NAME}"
  echo "=== ${host} (${fqdn}) ===" >&2

  # (a) find-or-create a remotely-managed tunnel named "<host>".
  # List active (non-deleted) tunnels and match by exact name.
  local tunnel_id
  tunnel_id=$(cf GET "/accounts/${ACCOUNT_ID}/cfd_tunnel?name=${host}&is_deleted=false" \
    | jq -r --arg n "$host" '.[] | select(.name == $n) | .id' | head -n1)

  if [ -z "$tunnel_id" ] || [ "$tunnel_id" = "null" ]; then
    echo "  creating remotely-managed tunnel '${host}'..." >&2
    tunnel_id=$(cf POST "/accounts/${ACCOUNT_ID}/cfd_tunnel" \
      "$(jq -nc --arg n "$host" '{name:$n, config_src:"cloudflare"}')" \
      | jq -r '.id')
  else
    echo "  tunnel '${host}' already exists (${tunnel_id})" >&2
  fi

  # (b) fetch the connector token.
  local token
  token=$(cf GET "/accounts/${ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/token" | jq -r '.')

  # (c) set the public-hostname ingress (idempotent PUT — full config replace).
  echo "  setting ingress ${fqdn} -> ssh://localhost:22 ..." >&2
  local config_body
  config_body=$(jq -nc --arg h "$fqdn" '
    {config: {ingress: [
      {hostname: $h, service: "ssh://localhost:22"},
      {service: "http_status:404"}
    ]}}')
  cf PUT "/accounts/${ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/configurations" "$config_body" >/dev/null

  # (d) UPSERT proxied CNAME  <fqdn> -> <id>.cfargotunnel.com.
  local cname_target="${tunnel_id}.cfargotunnel.com"
  local record_id
  record_id=$(cf GET "/zones/${ZONE_ID}/dns_records?type=CNAME&name=${fqdn}" \
    | jq -r '.[0].id // empty')
  local dns_body
  dns_body=$(jq -nc --arg h "$fqdn" --arg c "$cname_target" \
    '{type:"CNAME", name:$h, content:$c, proxied:true, ttl:1}')
  if [ -z "$record_id" ]; then
    echo "  creating CNAME ${fqdn} -> ${cname_target} ..." >&2
    cf POST "/zones/${ZONE_ID}/dns_records" "$dns_body" >/dev/null
  else
    echo "  updating CNAME ${fqdn} -> ${cname_target} ..." >&2
    cf PUT "/zones/${ZONE_ID}/dns_records/${record_id}" "$dns_body" >/dev/null
  fi

  # Emit the token on STDOUT, clearly labeled. SECRET — do not persist to a repo file.
  echo "----- CONNECTOR TOKEN for ${host} (SECRET — place at /etc/secrets/cloudflared-token on the host) -----"
  echo "TUNNEL_TOKEN=${token}"
  echo "----- end ${host} -----"
}

for h in "${HOSTS[@]}"; do
  provision_host "$h"
done

echo "Done. Tokens above are SECRETS — never commit them." >&2
