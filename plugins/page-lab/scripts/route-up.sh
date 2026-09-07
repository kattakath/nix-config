#!/usr/bin/env bash
# route-up.sh — OPEN a pick route's gate, not just name it.
#
# WHY THIS EXISTS. page-route.sh reports a dark gate; a report is not a fix. Tier 1's gate
# is one command with two traps in it, and both are silent: the debugging port is a STARTUP
# flag, so a Chromium already running without it ignores the flag on a second `open` and
# nothing anywhere says so; and the flag can never be declarative on this fleet, because the
# browser is a Homebrew cask and home-manager's assertion forbids commandLineArgs when
# programs.chromium.package is null [F-CASK-NOFLAG]. Tiers 2-4 have gates NO script can
# open — a human clicks them — so this prints the exact click instead of pretending.
#
#   usage: route-up.sh --tier <1|2|3|4|5> [--yes] [--isolated] [--port 9222]
#
#   --yes        actually run tier 1's launch command (without it, the command is printed)
#   --isolated   tier 1 into a throwaway profile: no logins, NO Violentmonkey. Correct for
#                diagnosing a public site, WRONG for authoring a userscript — the element
#                that annoys the operator lives in their logged-in browser.
#
# Exit 0 the gate is now open (RE-PROBED, never assumed) · 1 not open · 2 blocked by a
# precondition (a browser already running without the flag, no bundle found, not darwin).
#
# SECURITY, and it is not negotiable: an open debugging port is an UNAUTHENTICATED control
# channel — any local process can drive that browser and act as the signed-in user. This
# script is hand-run only. It will never propose a launchd agent, a login item, or any other
# way to make the port survive a reboot, and neither should you.

set -uo pipefail

tier=''
assume_yes=0
isolated=0
port=9222

die_usage() {
  printf 'usage: route-up.sh --tier <1|2|3|4|5> [--yes] [--isolated] [--port 9222]\n' >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tier)
      shift
      [ "$#" -gt 0 ] || die_usage
      tier="$1"
      ;;
    --yes) assume_yes=1 ;;
    --isolated) isolated=1 ;;
    --port)
      shift
      [ "$#" -gt 0 ] || die_usage
      port="$1"
      ;;
    -h | --help) die_usage ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      die_usage
      ;;
  esac
  shift
done

case "$tier" in 1 | 2 | 3 | 4 | 5) ;; *) die_usage ;; esac

have() { command -v "$1" >/dev/null 2>&1; }
say() { printf '%s\n' "$1"; }
step() { printf '  %s\n' "$1"; }

URL="http://127.0.0.1:$port"

# Liveness is a TCP question, not an HTTP one. /json/version used to stand in for it,
# but a browser switched on from chrome://inspect/#remote-debugging 404s every /json/*
# path while its CDP WebSocket is perfectly alive [F-NO-JSON-HTTP] — that made a live
# endpoint read as down. The socket check is true in both modes.
port_answers() {
  (exec 3<>"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1 && exec 3>&-
}

# Chromium's main process, helpers excluded: every helper carries --type=. pgrep cannot
# express that exclusion, and a helper match would report the browser as running when the
# main process has already quit.
chromium_mains() {
  # shellcheck disable=SC2009
  ps -ax -o command= 2>/dev/null |
    grep -E '/(Chromium|Google Chrome|Google Chrome for Testing)\.app/Contents/MacOS/' |
    grep -v -- '--type=' |
    grep -v -- 'route-up.sh'
}

bundle_of() { printf '%s' "$1" | sed -n 's|^\(.*\.app\)/Contents/MacOS/.*|\1|p' | head -1; }

resolve_bundle() {
  local line bundle
  line=$(chromium_mains | head -1)
  bundle=$(bundle_of "$line")
  if [ -n "$bundle" ] && [ -d "$bundle" ]; then
    printf '%s' "$bundle"
    return 0
  fi
  local candidate
  for candidate in \
    "/Applications/Chromium.app" \
    "$HOME/Applications/Chromium.app" \
    "/Applications/Google Chrome.app" \
    "/Applications/Google Chrome for Testing.app"; do
    [ -d "$candidate" ] && {
      printf '%s' "$candidate"
      return 0
    }
  done
  return 1
}

# ---------------------------------------------------------------------------- tier 1
tier_one() {
  if port_answers; then
    say "tier 1 gate is ALREADY OPEN — something answers on $URL"
    step "close it when the work ends; it is an unauthenticated control channel."
    return 0
  fi

  if [ "$(uname -s)" != Darwin ]; then
    say "tier 1: this launcher is darwin-only (it uses \`open -na\`)."
    step "Elsewhere, quit the browser fully and start it with:"
    step "  chromium --remote-debugging-port=$port"
    return 2
  fi

  # The already-running trap: the flag is read at STARTUP only, so a second `open` on a
  # live process is a no-op that looks like the flag being ignored.
  if [ -n "$(chromium_mains)" ]; then
    say "BLOCKED: a Chromium is already running WITHOUT --remote-debugging-port."
    step "The flag is read at startup only, so a second \`open\` is silently ignored."
    step "Quit it fully (Cmd-Q, not just the window), then re-run this command."
    step "Running now:"
    chromium_mains | sed 's/^/    /'
    return 1
  fi

  local bundle profile_args profile_note
  bundle=$(resolve_bundle) || {
    say "BLOCKED: no Chromium/Chrome .app bundle found in /Applications or ~/Applications."
    return 2
  }

  profile_args=''
  profile_note='the DAILY profile — logins and Violentmonkey present (right for authoring)'
  if [ "$isolated" = 1 ]; then
    profile_args="--user-data-dir=$(mktemp -d)"
    profile_note='a THROWAWAY profile — no logins, NO Violentmonkey (right for diagnosis only)'
  fi

  say "tier 1 — open the debugging port on $profile_note"
  if [ -n "$profile_args" ]; then
    step "open -na \"$bundle\" --args --remote-debugging-port=$port $profile_args"
  else
    step "open -na \"$bundle\" --args --remote-debugging-port=$port"
  fi

  if [ "$assume_yes" != 1 ]; then
    say ""
    step "not run — re-invoke with --yes to execute it."
    return 1
  fi

  if [ -n "$profile_args" ]; then
    open -na "$bundle" --args "--remote-debugging-port=$port" "$profile_args"
  else
    open -na "$bundle" --args "--remote-debugging-port=$port"
  fi

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    port_answers && {
      say ""
      say "  1  cdp-overlay  UP  $URL answered after ${i}s"
      step "close it when the work ends; it is an unauthenticated control channel."
      return 0
    }
    sleep 1
  done
  say ""
  say "  1  cdp-overlay  DOWN  nothing answered on $URL within 10s"
  step "check that the browser actually launched, and that no other profile held the port."
  return 1
}

# ---------------------------------------------------------------------------- tier 2
tier_two() {
  say "tier 2 — Kapture. This gate is a HUMAN CLICK; no script can open it."
  step "1. Open the tab you want to pick from."
  step "2. Click the Kapture toolbar icon and connect this tab from the popup."
  step "   (The toolbar popup, not DevTools — DevTools is not required [F-KAPTURE-POPUP].)"
  say ""
  if have curl && curl -sf --max-time 2 http://127.0.0.1:61822/tabs >/dev/null 2>&1; then
    local body
    body=$(curl -sf --max-time 2 http://127.0.0.1:61822/tabs 2>/dev/null | tr -d '[:space:]')
    if [ "$body" = '[]' ] || [ -z "$body" ]; then
      # Bridge up with zero tabs is DARK, and is a different problem from bridge down
      # [F-KAPTURE-COLD].
      say "  2  kapture  DARK  bridge is up, ZERO tabs connected — do the two steps above"
      return 1
    fi
    say "  2  kapture  UP  at least one tab is connected"
    return 0
  fi
  say "  2  kapture  DOWN  the bridge itself is not listening on 127.0.0.1:61822"
  step "that is a different problem: the MCP server half is not running."
  return 1
}

# ---------------------------------------------------------------------------- tier 3
tier_three() {
  say "tier 3 — Kapture with evaluate. Two gates, both human."
  step "1. Everything in tier 2 (a connected tab)."
  step "2. In the same popup, flip 'Allow JavaScript Execution' ON."
  say ""
  step "It is in-memory and RESETS on disconnect, so it must be re-asked every session."
  step "Confirm by NAME PRESENCE — is mcp__kapture__evaluate in the tool list? The server"
  step "filters it out entirely until the toggle is on, so calling it to find out only"
  step "proves it is absent [F-KAPTURE-EVAL-GATE]."
  say ""
  say "  3  kapture-eval  ASK  only the agent can see the session tool list"
  return 1
}

# ---------------------------------------------------------------------------- tier 4
tier_four() {
  say "tier 4 — claude-in-chrome. Not shell-probeable: native messaging transport."
  step "1. Call mcp__claude-in-chrome__tabs_context_mcp."
  step "2. If it answers 'Browser extension is not connected', the operator opens the"
  step "   extension and connects it [F-CIC-COLD]."
  step "3. The first JS call on a new domain raises a per-domain permission prompt; that"
  step "   click is the operator's too."
  say ""
  say "  4  cic-armed  ASK  only the agent can answer this one"
  return 1
}

tier_five() {
  say "tier 5 — the in-app browser pane. Not shell-probeable: an in-session MCP tool."
  step "1. Is mcp__Claude_Browser__javascript_tool in this session's tool list? Name"
  step "   presence only — do not call it to find out."
  step "2. It refuses with 'No preview is open' until a pane exists. Call"
  step "   mcp__Claude_Browser__navigate with a url; that OPENS the pane [F-INAPP-COLD]."
  step "3. Before reading any geometry, give the pane a real size: a collapsed pane runs"
  step "   JS but lays out nothing and reports a 0x0 viewport [F-INAPP-ZERO-VIEWPORT]."
  step "   mcp__Claude_Browser__resize_window {width,height}, then reload. Reset it after."
  say ""
  say "  Read the ceiling before you use it: this is a DIFFERENT PROFILE. No Violentmonkey,"
  say "  no logins. It measures the SITE. It can never run assertEffect(), and it can never"
  say "  host a pick — the operator is not pointing at anything in it."
  say ""
  say "  5  inapp-eval  ASK  only the agent can answer this one"
  return 1
}

case "$tier" in
  1) tier_one ;;
  2) tier_two ;;
  3) tier_three ;;
  4) tier_four ;;
  5) tier_five ;;
esac
rc=$?

printf '\n'
printf 'Standing rule: the debugging port is hand-run and short-lived. Never a launchd agent,\n'
printf 'never a login item — any local process that reaches it acts as the signed-in user.\n'
exit "$rc"
