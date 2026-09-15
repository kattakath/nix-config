#!/usr/bin/env bash
# Cheap change-detection. Decides whether this run deserves a model call at all.
#
# WHY THIS EXISTS — measured, and it is the difference between a toy and a bill.
# A default-environment `claude -p` on this machine builds a 344,828-token system
# prompt (97% of it MCP tool schemas the run never calls) and costs $3.45. At
# three runs an hour that is ~$248/day. Most 20-minute windows contain no new
# signal whatsoever, so the overwhelming majority of that was spent re-deciding
# an unchanged corpus.
#
# So: probe first, for ~1 quota unit per mailbox and zero for GitHub, and exit
# non-zero when nothing moved. run.sh then leaves the existing card alone.
#
# QUOTA ARITHMETIC (Gmail's published costs, per user per minute limit = 6,000):
#   users.getProfile   1     <- what this uses
#   messages.list      5
#   messages.get      20
#   threads.list      10
#   threads.get       40     <- list_inbox_threads at 50 results = ~2,010
# One getProfile per mailbox is a ~1,000x saving over a search, and its historyId
# changes on ANY mailbox mutation, which is exactly the signal wanted.
#
# Secrets: refresh tokens and access tokens are read and used, never printed,
# never written anywhere but the file they already live in.
set -euo pipefail

GMAIL_DIR="${NRT_GMAIL_DIR:-$HOME/.gmail-mcp}"
STATE="${NRT_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/next-right-thing/state.json}"
ACCOUNTS="${NRT_GMAIL_ACCOUNTS:-ismail_kattakath_com izzy_silvercreek_ai ismailkattakath_gmail_com aloshyakasoto_gmail_com}"

mkdir -p "$(dirname "$STATE")"
[ -s "$STATE" ] || printf '{"sources":{}}\n' > "$STATE"
prev="$(cat "$STATE")"

changed=0
degraded=()
new_sources='{}'

note_source() { # name, value, ok(1/0)
  new_sources="$(printf '%s' "$new_sources" | jq -c --arg n "$1" --arg v "$2" '.[$n]=$v')"
}

# --- Gmail: one getProfile per mailbox -------------------------------------
client_id="$(jq -r '.installed.client_id // empty' "$GMAIL_DIR/gcp-oauth.keys.json" 2>/dev/null || true)"
client_secret="$(jq -r '.installed.client_secret // empty' "$GMAIL_DIR/gcp-oauth.keys.json" 2>/dev/null || true)"

for acct in $ACCOUNTS; do
  cred="$GMAIL_DIR/credentials-$acct.json"
  [ -s "$cred" ] || { degraded+=("gmail $acct: no credential file"); continue; }
  [ -n "$client_id" ] || { degraded+=("gmail $acct: no oauth client"); continue; }

  refresh="$(jq -r '.tokens.refresh_token // empty' "$cred" 2>/dev/null || true)"
  [ -n "$refresh" ] || { degraded+=("gmail $acct: no refresh token"); continue; }

  # --data-urlencode keeps the secret out of argv-visible URL and off the log.
  tok_resp="$(curl -sS -m 20 https://oauth2.googleapis.com/token \
    --data-urlencode "client_id=$client_id" \
    --data-urlencode "client_secret=$client_secret" \
    --data-urlencode "refresh_token=$refresh" \
    --data-urlencode "grant_type=refresh_token" 2>/dev/null || true)"

  err="$(printf '%s' "$tok_resp" | jq -r '.error // empty' 2>/dev/null || true)"
  if [ -n "$err" ]; then
    # invalid_grant is PERSISTENT by definition (revoked/expired refresh token);
    # everything else here is transient and will clear on its own.
    degraded+=("gmail $acct: $err")
    continue
  fi

  access="$(printf '%s' "$tok_resp" | jq -r '.access_token // empty' 2>/dev/null || true)"
  [ -n "$access" ] || { degraded+=("gmail $acct: no access token"); continue; }

  hid="$(curl -sS -m 20 -H "Authorization: Bearer $access" \
    'https://gmail.googleapis.com/gmail/v1/users/me/profile' 2>/dev/null \
    | jq -r '.historyId // empty' 2>/dev/null || true)"
  [ -n "$hid" ] || { degraded+=("gmail $acct: profile probe failed"); continue; }

  note_source "gmail:$acct" "$hid"
  [ "$(printf '%s' "$prev" | jq -r --arg n "gmail:$acct" '.sources[$n] // ""')" = "$hid" ] || changed=1
done

# --- GitHub: conditional request, 304 costs zero rate limit ----------------
gh_etag="$(printf '%s' "$prev" | jq -r '.sources["github:etag"] // ""')"
gh_hdr="$(mktemp "${TMPDIR:-/tmp}/nrt-gh.XXXXXX")"
trap 'rm -f "$gh_hdr"' EXIT
gh_code="$(curl -sS -m 20 -o /dev/null -D "$gh_hdr" -w '%{http_code}' \
  -H "Authorization: Bearer $(gh auth token 2>/dev/null)" \
  -H "Accept: application/vnd.github+json" \
  ${gh_etag:+-H "If-None-Match: $gh_etag"} \
  'https://api.github.com/notifications?all=false&per_page=50' 2>/dev/null || echo 000)"

case "$gh_code" in
  304) note_source "github:etag" "$gh_etag" ;;                 # unchanged, free
  200) changed=1
       note_source "github:etag" "$(grep -i '^etag:' "$gh_hdr" | tr -d '\r' | cut -d' ' -f2- || true)" ;;
  *)   degraded+=("github: probe HTTP $gh_code") ;;
esac

# --- publish state, atomically, next to itself -----------------------------
new_degraded="$(printf '%s\n' "${degraded[@]+"${degraded[@]}"}" | jq -R . | jq -sc 'map(select(length>0))')"

tmp="$(mktemp "$(dirname "$STATE")/.state.XXXXXX")"
printf '%s' "$prev" | jq -c \
  --argjson s "$new_sources" \
  --argjson d "$new_degraded" \
  '.sources = (.sources + $s) | .degraded = $d | .probed_at = now' > "$tmp"
chmod 600 "$tmp"; mv -f "$tmp" "$STATE"

# A source that JUST died must force a run so the card can say coverage shrank.
# But a source that has been dead for days is steady state, not news — and three
# permanently-dead OAuth grants would otherwise pin `changed=1` forever and
# defeat this whole file. So compare the degraded SET to last run's, not its size.
prev_deg="$(printf '%s' "$prev" | jq -c '(.degraded // []) | sort')"
now_deg="$(printf '%s' "$new_degraded" | jq -c 'sort')"
[ "$prev_deg" = "$now_deg" ] || changed=1

printf '%s\n' "$changed"
[ "$changed" = "1" ] || exit 9   # 9 = nothing moved; run.sh treats it as "skip"
