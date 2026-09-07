#!/usr/bin/env bash
# page-route.sh — the front door: which pick route is live RIGHT NOW, and what only the
# agent can answer.
#
# WHY THIS EXISTS. Four of the five routes have a gate, and three of them fail SILENTLY.
# A Kapture bridge with zero connected tabs still answers on its port [F-KAPTURE-COLD].
# A picker left armed by a previous run eats the operator's next click on every armed tab
# [F-ARMED-SWALLOWS], and looks like a broken mouse, not like a stale process.
# claude-in-chrome's transport is native messaging, so no shell can see it at all
# [F-CIC-COLD]. Guessing between those costs the operator a wasted click each time.
#
# This script therefore does two jobs: it SWEEPS a stale arm before anything else, and it
# reports what it probed AND what it cannot probe — a doctor that states its own blind spot.
#
#   usage: page-route.sh [--json] [--tools kapture-eval=yes|no,cic=yes|no] [--no-sweep]
#
# Output grammar (quoted verbatim by references/routes.md and both skills):
#   ROUTE_SHELL=cdp|kapture|none      always — what a shell can prove
#   AGENT-MUST-CHECK:<thing>          one line per model-side check, when --tools is absent
#   ROUTE=cdp|kapture-eval|kapture|cic|paste
#                                     only with --tools, once the agent has answered them
#
# Exit 0 at least one non-paste tier is UP · 1 only operator-paste · 2 a stale arm was found
# and could NOT be cleared (fix that first — every tab in that browser is eating clicks).

set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
STAMP="${TMPDIR:-/tmp}/page-lab-pick.arm.json"
CDP_URL="${PAGE_LAB_BROWSER_URL:-http://127.0.0.1:9222}"
CDP_HOST=127.0.0.1
CDP_PORT=9222
KAPTURE_URL="${PAGE_LAB_KAPTURE_URL:-http://127.0.0.1:61822}"
KAPTURE_HOST=127.0.0.1
KAPTURE_PORT=61822

json_out=0
sweep=1
tools_given=0
tool_kapture_eval=unknown
tool_cic=unknown

die_usage() {
  printf 'usage: page-route.sh [--json] [--tools kapture-eval=yes|no,cic=yes|no] [--no-sweep]\n' >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) json_out=1 ;;
    --no-sweep) sweep=0 ;;
    --tools)
      shift
      [ "$#" -gt 0 ] || die_usage
      tools_given=1
      IFS=',' read -r -a _pairs <<<"$1"
      for _p in "${_pairs[@]}"; do
        case "$_p" in
          kapture-eval=yes) tool_kapture_eval=yes ;;
          kapture-eval=no) tool_kapture_eval=no ;;
          cic=yes) tool_cic=yes ;;
          cic=no) tool_cic=no ;;
          '') ;;
          *)
            printf 'unknown --tools entry: %s\n' "$_p" >&2
            die_usage
            ;;
        esac
      done
      ;;
    -h | --help) die_usage ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      die_usage
      ;;
  esac
  shift
done

have() { command -v "$1" >/dev/null 2>&1; }

# A bare TCP connect, so that "no curl" degrades to "unknown", never to "down".
# Bash's /dev/tcp is the standard-library primitive here; nothing is installed for it.
tcp_open() { (exec 3<>"/dev/tcp/$1/$2") >/dev/null 2>&1; }

HTTP_BODY=''
# rc 0 body captured · 1 nothing listening · 2 something listens but the body is unreadable
http_get() {
  HTTP_BODY=''
  local url="$1" host="$2" port="$3"
  if have curl; then
    HTTP_BODY=$(curl -sf --max-time 2 "$url" 2>/dev/null) && return 0
    tcp_open "$host" "$port" && return 2
    return 1
  fi
  tcp_open "$host" "$port" && return 2
  return 1
}

count_pages() {
  if have jq; then
    printf '%s' "$1" | jq '[.[] | select(.type=="page")] | length' 2>/dev/null || printf '0'
  else
    printf '%s' "$1" | grep -o '"type"[[:space:]]*:[[:space:]]*"page"' | wc -l | tr -d ' '
  fi
}

# The build string cannot identify the browser — ungoogled-chromium reports Chrome/<ver>
# with no vendor field, so only the serving process path settles it [F-UGC-NO-VENDOR].
serving_app() {
  local out=''
  if have pgrep; then
    out=$(pgrep -fl -- '--remote-debugging-port' 2>/dev/null)
  else
    # shellcheck disable=SC2009  # this IS the no-pgrep fallback branch
    out=$(ps -ax -o command= 2>/dev/null | grep -- '--remote-debugging-port' | grep -v 'grep')
  fi
  printf '%s\n' "$out" | sed -n 's|.*/\([^/]*\.app\)/Contents.*|\1|p' | head -1
}

# ---------------------------------------------------------------- 1. stale-arm sweep
stale_state=none
if [ -e "$STAMP" ]; then
  stale_state=found
  printf '[stale-arm] FOUND %s — a previous pick may still be swallowing clicks in every armed tab.\n' "$STAMP" >&2
  if [ "$sweep" = 0 ]; then
    stale_state=left-armed
    printf '[stale-arm] --no-sweep given; NOT clearing. Run: pick-element.mjs --disarm-only\n' >&2
  else
    if have page-lab-pick; then
      page-lab-pick --disarm-only >/dev/null 2>&1
    elif have node && [ -f "$SCRIPT_DIR/pick-element.mjs" ]; then
      node "$SCRIPT_DIR/pick-element.mjs" --disarm-only >/dev/null 2>&1
    else
      printf '[stale-arm] no disarmer available (neither page-lab-pick on PATH nor node + pick-element.mjs)\n' >&2
    fi
    if [ -e "$STAMP" ]; then
      stale_state=not-cleared
      printf '[stale-arm] NOT CLEARED. Quit the browser to clear inspect mode, then delete %s\n' "$STAMP" >&2
    else
      stale_state=cleared
      printf '[stale-arm] cleared.\n' >&2
    fi
  fi
fi

# ---------------------------------------------------------------- 2. tier 1 — CDP
cdp_state=DOWN
cdp_pages=0
cdp_detail='nothing listening on the debugging port'
http_get "$CDP_URL/json/version" "$CDP_HOST" "$CDP_PORT"
case "$?" in
  0)
    cdp_state=UP
    http_get "$CDP_URL/json/list" "$CDP_HOST" "$CDP_PORT" && cdp_pages=$(count_pages "$HTTP_BODY")
    app=$(serving_app)
    if [ -n "$app" ]; then
      cdp_detail="$cdp_pages page target(s), served by $app"
    else
      cdp_detail="$cdp_pages page target(s), serving app unidentified"
    fi
    # 13 targets, 3 pages was the measured shape; only page targets are armable
    # [F-TARGETS-13-3].
    [ "$cdp_pages" -gt 0 ] 2>/dev/null || {
      cdp_state=DARK
      cdp_detail='endpoint answers but has ZERO page targets — nothing to arm'
    }
    ;;
  2)
    cdp_state=UNKNOWN
    cdp_detail='port accepts a connection but the body is unreadable (curl not on PATH)'
    ;;
  *) ;;
esac

# ---------------------------------------------------------------- 3. tier 2 — Kapture
kapture_state=DOWN
kapture_detail='bridge not listening — a different problem from a bridge with no tabs'
http_get "$KAPTURE_URL/tabs" "$KAPTURE_HOST" "$KAPTURE_PORT"
case "$?" in
  0)
    body=$(printf '%s' "$HTTP_BODY" | tr -d '[:space:]')
    if [ "$body" = '[]' ] || [ -z "$body" ]; then
      # A running bridge with zero tabs is DARK, not ready [F-KAPTURE-COLD].
      kapture_state=DARK
      kapture_detail='bridge UP but ZERO tabs connected — connect one from the toolbar popup'
    else
      kapture_state=UP
      if have jq; then
        n=$(printf '%s' "$HTTP_BODY" | jq 'length' 2>/dev/null || printf '?')
        kapture_detail="$n tab(s) connected"
      else
        kapture_detail='at least one tab connected (exact count needs jq)'
      fi
    fi
    ;;
  2)
    kapture_state=UNKNOWN
    kapture_detail='port accepts a connection but the body is unreadable (curl not on PATH)'
    ;;
  *) ;;
esac

# ---------------------------------------------------------------- 4. runtime
node_ver='absent'
have node && node_ver=$(node --version 2>/dev/null)
npx_state='absent'
have npx && npx_state='present'
wrapper_state='not on PATH'
have page-lab-pick && wrapper_state='on PATH'

# ---------------------------------------------------------------- 5. route resolution
route_shell=none
[ "$kapture_state" = UP ] && route_shell=kapture
[ "$cdp_state" = UP ] && route_shell=cdp

# kapture-eval outranks kapture: one blocking call on the human's click beats three
# sampled :hover round-trips. Its gate is the tier-2 gate plus a human toggle, so it can
# only ever be reached when tier 2 is already up.
route=''
if [ "$tools_given" = 1 ]; then
  if [ "$cdp_state" = UP ]; then
    route=cdp
  elif [ "$kapture_state" = UP ] && [ "$tool_kapture_eval" = yes ]; then
    route=kapture-eval
  elif [ "$kapture_state" = UP ]; then
    route=kapture
  elif [ "$tool_cic" = yes ]; then
    route=cic
  else
    route='paste'
  fi
fi

rc=1
if [ "$route_shell" != none ] || [ "$route" = kapture-eval ] || [ "$route" = cic ]; then rc=0; fi
case "$stale_state" in not-cleared | left-armed) rc=2 ;; esac

# ---------------------------------------------------------------- 6. output
if [ "$json_out" = 1 ]; then
  esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  printf '{'
  printf '"staleArm":"%s",' "$(esc "$stale_state")"
  printf '"cdp":{"state":"%s","pageTargets":%s,"detail":"%s"},' \
    "$(esc "$cdp_state")" "${cdp_pages:-0}" "$(esc "$cdp_detail")"
  printf '"kapture":{"state":"%s","detail":"%s"},' "$(esc "$kapture_state")" "$(esc "$kapture_detail")"
  printf '"node":"%s","npx":"%s","wrapper":"%s",' "$(esc "$node_ver")" "$(esc "$npx_state")" "$(esc "$wrapper_state")"
  printf '"routeShell":"%s",' "$(esc "$route_shell")"
  if [ "$tools_given" = 1 ]; then
    printf '"route":"%s",' "$(esc "$route")"
  else
    printf '"agentMustCheck":["kapture-eval","cic"],'
  fi
  printf '"cannotProbe":"MCP session tool list; claude-in-chrome (native messaging transport)"'
  printf '}\n'
  exit "$rc"
fi

printf 'page-lab route probe — %s\n\n' "$(date +%Y-%m-%d)"
printf '  tier  route           state     detail\n'
printf '  ----  --------------  --------  ---------------------------------------------------\n'
# ASK, not DOWN: an unprobed gate is unknown, and printing it as down is the lie this
# script exists to avoid.
tri_state() {
  case "$1" in
    yes) printf 'UP' ;;
    no) printf 'DOWN' ;;
    *) printf 'ASK' ;;
  esac
}

printf '  1     cdp-overlay     %-8s  %s\n' "$cdp_state" "$cdp_detail"
printf '  2     kapture         %-8s  %s\n' "$kapture_state" "$kapture_detail"
printf '  3     kapture-eval    %-8s  %s\n' "$(tri_state "$tool_kapture_eval")" \
  'tier-2 gate PLUS a human flipping Allow JavaScript Execution'
printf '  4     cic-armed       %-8s  %s\n' "$(tri_state "$tool_cic")" \
  'extension connected AND the domain permitted'
printf '  5     operator-paste  %-8s  %s\n' 'UP' 'no gate; always available'
printf '\n  runtime: node %s, npx %s, page-lab-pick %s\n' "$node_ver" "$npx_state" "$wrapper_state"
printf '  stale arm: %s\n\n' "$stale_state"

printf 'Blind spot, stated so it is not mistaken for a measurement: this script cannot see\n'
printf 'which MCP tools are loaded in this session, and cannot see claude-in-chrome at all\n'
printf '(native messaging transport). Tiers 3 and 4 are the agent'"'"'s to answer, never this\n'
printf 'script'"'"'s. Everything in the table above was probed.\n\n'

printf 'ROUTE_SHELL=%s\n' "$route_shell"

if [ "$tools_given" = 1 ]; then
  printf 'ROUTE=%s\n' "$route"
else
  printf 'AGENT-MUST-CHECK:kapture-eval — is mcp__kapture__evaluate present in this session'"'"'s tool list? Probe by NAME PRESENCE; never call it to find out [F-KAPTURE-EVAL-GATE].\n'
  printf 'AGENT-MUST-CHECK:cic — call mcp__claude-in-chrome__tabs_context_mcp; its transport is native messaging, so no shell can see it [F-CIC-COLD].\n'
  printf 'AGENT-MUST-CHECK:rerun — page-route.sh --tools kapture-eval=yes|no,cic=yes|no prints the final ROUTE=.\n'
fi

exit "$rc"
