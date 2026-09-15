#!/usr/bin/env bash
# Pick ONE thing from a pre-gathered corpus. Emits verdict JSON on stdout.
#
# THE MODEL GETS NO TOOLS AND NO MCP, AND THAT IS THE POINT.
# Measured on this machine: `claude -p` with the fleet's MCP servers loaded costs
# $0.67 for a two-token prompt — ~95k tokens of tool SCHEMAS are compiled into
# the system prompt before the model reads anything. `--allowedTools` does not
# help; it gates PERMISSION, not LOADING. So gather.sh collects the corpus with
# plain curl/gh, and this runs `--strict-mcp-config` against text.
#   with MCP:  ~$0.67/run -> ~$48/day        without: ~$0.03/run -> ~$2/day
# It also removes the tg_read footgun structurally: the model cannot call a tool
# that was never loaded.
#
# WHY A MODEL AT ALL: the signals that matter are semantic. "the team would love
# to move forward" is a high-stakes positive that decayed, and no keyword matches
# it. The strongest item found in testing had ZERO mechanical signal.
#
# WHY STAGE 1 IS A GATE, NOT A WEIGHT — fix for a measured miss. An earlier build
# ranked "red CI on dontsell-ai/app" above a 28-day-dead job offer, because it was
# told to hunt CI failures and given one prose sentence as counterweight. Prior
# art: Alertmanager `inhibit_rules` MUTES a target when a source alert exists, and
# ISA-18.2's "Is Unique" criterion rejects an alarm duplicating another's info.
set -euo pipefail

TIMEOUT="${NRT_TIMEOUT:-300}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

corpus="$("$HERE/gather.sh" 2>/dev/null || true)"
if [ -z "$corpus" ]; then
  printf '{"found":false,"degraded":["gather: produced nothing"]}\n'
  exit 0
fi

read -r -d '' RULES <<'RULES_END' || true
Pick the ONE thing Ismail should do next, from the corpus below. Output JSON
only — no prose, no code fences.

## Output contract
{"found":true,"action":"<one imperative sentence, <=110 chars>","source":"<short label>","why":"<<=22 chars>","urgency":"high"|"normal","url":"<link or empty>","candidates":[{"action":"...","dropped":"<reason or null>"}]}
or
{"found":false,"candidates":[...]}

`candidates` = everything you considered, including Stage-1 drops and why. It is
never displayed; it is the decision log. Without the rejected options nothing can
ever be replayed or improved.

## Stage 1 — DROP, do not down-rank
An ANNUNCIATOR is any indicator that re-renders itself whenever he opens the
tool: a red/green check badge, an unread count, a review-requested row, a
notification dot. For those P(he sees it anyway) ~ 1, so this widget adds
nothing. Score ZERO, drop before ranking.

Anything in the ANNUNCIATED REPOS list below is INELIGIBLE — with ONE exception.
A red CI badge on a repo he is working in is the canonical thing this must NEVER
show. It is furniture, not news.

THE EXCEPTION: a NAMED HUMAN explicitly waiting on him is never furniture, even
in an annunciated repo. A badge re-renders itself; a person does not. So an item
stays ELIGIBLE when a specific human has asked him for something and he has not
answered — e.g. `[last: <someone-not-him>]` combined with a BLOCKED label, a
review request, or a direct question. Bot and automation comments do NOT qualify;
the waiting party must be a person.

## Stage 2 — of what survives, rank by value x decay
Strong signals:
  - a thread ending inbound with no reply from him
  - a POSITIVE outcome left to rot ("let's move forward", "we'd like to offer")
    — worth more than anything labelled urgent
  - `blocked` label + a fresh comment from the blocker
  - buried in a noisy channel (a busy inbox hides a 4-week-old thread completely)
Known noise — never rank on these:
  - anything ANNUNCIATED. This widget exists to show what no other screen shows.
  - subject-line urgency words (action required / final notice / overdue):
    measured ~5% precision, almost all bank and KYC marketing
  - "I'm still waiting for your response" — a LinkedIn automated drip, always
  - senders matching noreply|no-reply|donotreply|notifications@|jobalerts
  - a number quoted inside issue prose (measured wrong by 200x once)

## Surfaceability — this renders on a MENU BAR and a WALLPAPER, both visible in
## screen shares. Allowlist; vague by category; silent by default.
  SUPPRESS entirely: credentials, OTP/2FA, password resets, account numbers, and
    anything touching dating, medical, debt collection, legal, immigration.
  FULL detail only for his own work (kattakath, dontsell-ai, silvercreek-ai,
    Infin8-Information-Technologies, his own infra). First name only — never
    "Full Name, Company, Role".
  VAGUE otherwise — no name, amount, date or count:
    finance -> "A money thing needs 15 minutes."
    job search -> "A reply is overdue."
    personal admin -> "One personal item is waiting."

## Say nothing rather than guess
With one card a wrong pick IS the product, and it spends the trust that makes the
next card get read. If nothing clears a real "worth interrupting him" bar, return
{"found":false}. That is a correct outcome, not a failure.

## CORPUS
RULES_END

# BOTH flags are required, measured — --strict-mcp-config alone is NOT enough:
#   default                        65,709 sys tokens   $0.52
#   --strict-mcp-config            (still high)        $0.52
#   + --safe-mode                   7,311 sys tokens   $0.087
# --safe-mode drops plugins/skills/customizations the ranker never uses. Together
# they are the cost fix; do not "simplify" either away.
raw="$(timeout "$TIMEOUT" claude -p "$RULES
$corpus" \
  --output-format json \
  --strict-mcp-config \
  --safe-mode \
  --max-budget-usd "${NRT_MAX_USD:-0.25}" \
  --no-session-persistence \
  < /dev/null 2>/dev/null || true)"

cost="$(printf '%s' "$raw" | jq -r '.total_cost_usd // 0' 2>/dev/null || echo 0)"
printf 'nrt: ranker cost_usd=%s corpus_bytes=%s\n' "$cost" "${#corpus}" >&2

inner="$(printf '%s' "$raw" | jq -r '.result // empty' 2>/dev/null || true)"
verdict="$(printf '%s' "$inner" | sed -e 's/^```json//' -e 's/^```//' \
  | grep -o '{.*}' | tail -1 || true)"

if [ -z "$verdict" ] || ! printf '%s' "$verdict" | jq -e . >/dev/null 2>&1; then
  printf '{"found":false,"degraded":["ranker: no parseable verdict"]}\n'
  exit 0
fi
printf '%s\n' "$verdict"
