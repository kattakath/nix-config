#!/usr/bin/env bash
# Collect candidate signal as PLAIN TEXT, using no MCP and no model.
#
# WHY THIS EXISTS — this is the whole cost fix, and it is not a micro-optimisation.
# Measured on this machine: `claude -p` with MCP servers loaded costs $0.67 for a
# two-token prompt, because ~95k tokens of tool SCHEMAS are built into the system
# prompt before the model reads a word. `--allowedTools` does not help: it gates
# PERMISSION, not LOADING. The only way down is to give the model no MCP at all
# (`--strict-mcp-config`), which means the gathering must happen out here.
#   with MCP:    ~$0.67/run  -> ~$48/day
#   without:     ~$0.03/run  -> ~$2/day
#
# Quota discipline (Gmail limit = 6,000 units per user per minute):
#   messages.list  5     messages.get (metadata) 20
# 15 results per mailbox = 5 + 300 = 305 units. Four mailboxes = 1,220. Safe.
# `threads.get` is 40 each and is deliberately NOT used here.
#
# Tokens are read and used, never printed or persisted anywhere new.
set -euo pipefail

GMAIL_DIR="${NRT_GMAIL_DIR:-$HOME/.gmail-mcp}"
ACCOUNTS="${NRT_GMAIL_ACCOUNTS:-ismail_kattakath_com izzy_silvercreek_ai ismailkattakath_gmail_com aloshyakasoto_gmail_com}"
MAXMAIL="${NRT_MAX_MAIL:-15}"

client_id="$(jq -r '.installed.client_id // empty' "$GMAIL_DIR/gcp-oauth.keys.json" 2>/dev/null || true)"
client_secret="$(jq -r '.installed.client_secret // empty' "$GMAIL_DIR/gcp-oauth.keys.json" 2>/dev/null || true)"

hdr() { printf '\n## %s\n' "$1"; }

# --- GitHub: annunciated set first (it is the Stage-1 gate input) -----------
me="$(gh api /user --jq .login 2>/dev/null || echo ismailkattakath)"

hdr "ANNUNCIATED REPOS (already on a screen he opens — Stage 1 drops these)"
{
  gh api '/notifications?all=false&per_page=100' --jq '.[].repository.full_name' 2>/dev/null || true
  gh api "/users/$me/events?per_page=100" --jq '.[].repo.name' 2>/dev/null || true
} | sort -u | tr '\n' ' '
printf '\n'

hdr "GITHUB: open issues involving him where the LAST comment is NOT his"
gh api graphql -f query="{
  search(query: \"is:issue is:open involves:$me\", type: ISSUE, first: 40) {
    nodes { ... on Issue {
      number title url
      repository { nameWithOwner }
      labels(first: 5) { nodes { name } }
      comments(last: 1) { nodes { author { login } createdAt } }
    } }
  }
}" 2>/dev/null | jq -r --arg me "$me" '
  .data.search.nodes[]?
  # Parens are load-bearing: jq binds `//` LOOSER than `!=`, so the unbracketed
  # form parses as `.login // ("" != $me)` -> `.login // true` -> always truthy,
  # and the filter silently passes everything including his own comments.
  | select((.comments.nodes[0]?.author.login // "") != $me)
  | "- \(.repository.nameWithOwner)#\(.number) \(.title)"
    + "  [last: \(.comments.nodes[0]?.author.login // "none")"
    + "\(if (.labels.nodes|map(.name)|index("blocked")) then ", BLOCKED" else "" end)]"
    + "  \(.url)"
' 2>/dev/null | head -25 || echo "(github query failed)"

# --- Gmail: one narrow list + metadata-only gets ---------------------------
for acct in $ACCOUNTS; do
  cred="$GMAIL_DIR/credentials-$acct.json"
  [ -s "$cred" ] && [ -n "$client_id" ] || { hdr "GMAIL $acct"; echo "(unavailable)"; continue; }

  refresh="$(jq -r '.tokens.refresh_token // empty' "$cred" 2>/dev/null || true)"
  [ -n "$refresh" ] || { hdr "GMAIL $acct"; echo "(no refresh token)"; continue; }

  access="$(curl -sS -m 20 https://oauth2.googleapis.com/token \
    --data-urlencode "client_id=$client_id" \
    --data-urlencode "client_secret=$client_secret" \
    --data-urlencode "refresh_token=$refresh" \
    --data-urlencode "grant_type=refresh_token" 2>/dev/null \
    | jq -r '.access_token // empty' 2>/dev/null || true)"
  [ -n "$access" ] || { hdr "GMAIL $acct"; echo "(auth failed — grant is dead)"; continue; }

  hdr "GMAIL $acct (inbox, 60d, promotions/social/updates/forums excluded)"
  # Sender exclusions belong in the QUERY, not the prompt. Measured: without
  # them, all 15 newest messages were GitHub PR bot mail from the same morning,
  # and a 28-day-old human thread that was the actual top candidate never entered
  # the window at all. Telling the model to ignore noise it was never shown does
  # nothing. Gmail applies these server-side for free.
  q='in:inbox -category:promotions -category:social -category:updates'
  q="$q -category:forums newer_than:60d"
  q="$q -from:notifications@github.com -from:noreply -from:no-reply"
  q="$q -from:donotreply -from:jobalerts -from:mailer-daemon -from:alerts@"
  q="$q -from:updates@ -from:news@ -from:newsletter"''
  ids="$(curl -sS -m 25 -G -H "Authorization: Bearer $access" \
    --data-urlencode "q=$q" --data-urlencode "maxResults=$MAXMAIL" \
    'https://gmail.googleapis.com/gmail/v1/users/me/messages' 2>/dev/null \
    | jq -r '.messages[]?.id' 2>/dev/null || true)"

  [ -n "$ids" ] || { echo "(no matching mail)"; continue; }
  for id in $ids; do
    curl -sS -m 20 -G -H "Authorization: Bearer $access" \
      --data-urlencode "format=metadata" \
      --data-urlencode "metadataHeaders=From" \
      --data-urlencode "metadataHeaders=Subject" \
      --data-urlencode "metadataHeaders=Date" \
      "https://gmail.googleapis.com/gmail/v1/users/me/messages/$id" 2>/dev/null \
      | jq -r '
          (.payload.headers // []) as $h
          | ($h|map(select(.name=="From"))[0].value // "?") as $from
          | ($h|map(select(.name=="Subject"))[0].value // "(no subject)") as $subj
          | ($h|map(select(.name=="Date"))[0].value // "?") as $date
          | "- FROM: \($from)\n  SUBJ: \($subj)\n  DATE: \($date)\n  SNIP: \(.snippet // ""|.[0:180])"
        ' 2>/dev/null || true
  done
done
