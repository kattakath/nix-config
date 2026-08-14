# `chrome-automation` (macOS only) — launch the fleet's DEFACTO automation browser for agent
# browser control: **ungoogled-chromium** (Homebrew cask, hosts/macos.nix) on a throwaway
# profile + a CDP remote-debugging port that the Playwright MCP attaches to (`--cdp-endpoint`,
# modules/shared/mcp.nix).
#
#   chrome-automation            # or: nix run .#chrome-automation
#   → launches ungoogled-chromium on an EPHEMERAL --user-data-dir (wiped each launch) with
#     CDP on :9222. Idempotent: if the port already answers, it's already running.
#
# WHY ungoogled-chromium + ephemeral: this is a *disposable* automation browser, NOT your daily
# one and NOT a long-lived logged-in profile. Auth is NOT kept in the on-disk profile — it lives
# ENCRYPTED in the macOS Keychain as a Playwright `storageState`, and is injected into the live
# browser over CDP by `automation-session seed` (packages/automation-session.nix) AFTER launch,
# BEFORE the agent drives it. Capture refreshed cookies back with `automation-session capture`.
# So the on-disk profile can be nuked freely — the session of record is in the Keychain.
#
#   chrome-automation            # launch clean, CDP up on :9222
#   automation-session seed      # inject the Keychain storageState into the live browser
#   # …agent drives via the playwright MCP (:9222)…
#   automation-session capture   # save refreshed cookies back to the Keychain
#
# HEADED (default) vs HEADLESS:
#   chrome-automation                              # HEADED window (visible; use for the login flow)
#   CHROME_AUTOMATION_HEADLESS=1 chrome-automation # HEADLESS (no window) — unattended CDP runs
# Env knobs: CHROME_AUTOMATION_PORT (9222), CHROME_AUTOMATION_DIR (profile dir),
#   CHROME_AUTOMATION_PROFILE (Default — pinned so a multi-profile dir doesn't pop the picker),
#   CHROME_AUTOMATION_BROWSER (chromium|chrome — default chromium/ungoogled; `chrome` falls back
#   to Google Chrome), CHROME_AUTOMATION_PERSIST=1 (keep the profile across launches, don't wipe).
#
# Chromium refuses --remote-debugging-port on a browser's DEFAULT user-data-dir (security), which
# is exactly why this always uses a separate, disposable --user-data-dir. No extension, no
# foreground-tab hijack — the failure class that makes the kapture path flaky.
{
  writeShellApplication,
  curl,
  coreutils,
}:
writeShellApplication {
  name = "chrome-automation";
  runtimeInputs = [
    curl
    coreutils
  ];
  text = ''
    prog=chrome-automation
    port="''${CHROME_AUTOMATION_PORT:-9222}"
    headless="''${CHROME_AUTOMATION_HEADLESS:-}"
    persist="''${CHROME_AUTOMATION_PERSIST:-}"
    # Pin the profile so a --user-data-dir holding >1 profile doesn't pop the Chromium picker.
    profile="''${CHROME_AUTOMATION_PROFILE:-Default}"
    cdp="http://127.0.0.1:$port"

    die() { echo "$prog: error: $*" >&2; exit 1; }

    # Browser selection: ungoogled-chromium (default) or Google Chrome (fallback).
    case "''${CHROME_AUTOMATION_BROWSER:-chromium}" in
      chromium|ungoogled|ungoogled-chromium)
        app="/Applications/Chromium.app"; bin="$app/Contents/MacOS/Chromium"
        default_dir="$HOME/Library/Caches/chrome-automation-ug" ;;
      chrome|google|google-chrome)
        app="/Applications/Google Chrome.app"; bin="$app/Contents/MacOS/Google Chrome"
        default_dir="$HOME/Library/Caches/chrome-automation-gc" ;;
      *) die "unknown CHROME_AUTOMATION_BROWSER (use chromium|chrome)" ;;
    esac
    dir="''${CHROME_AUTOMATION_DIR:-$default_dir}"

    [ -d "$app" ] || die "$app not installed (ungoogled-chromium cask? run: darwin-rebuild switch)"

    # Idempotent: if the CDP endpoint already answers, it's already running.
    # (Deliberately NO `open -a` "focus" — without -n it launches the browser on its DEFAULT
    #  user-data-dir and pops the profile picker. Surface/seed the window via CDP instead.)
    if curl -fsS --max-time 2 "$cdp/json/version" >/dev/null 2>&1; then
      echo "$prog: automation browser already running on $cdp (profile: $dir → $profile)."
      exit 0
    fi

    # EPHEMERAL: wipe the throwaway profile each launch (auth comes from the Keychain via
    # `automation-session seed`, not this dir) unless CHROME_AUTOMATION_PERSIST=1. Guard the rm.
    if [ -z "$persist" ]; then
      case "$dir" in
        "" | "/" | "$HOME" | "$HOME/") die "refusing to wipe unsafe dir: '$dir'" ;;
        *) rm -rf -- "$dir" ;;
      esac
    fi
    mkdir -p "$dir"

    if [ -n "$headless" ]; then
      # HEADLESS: `open`/LaunchServices is GUI-oriented, so exec the binary directly and detach
      # (nohup + disown) so it outlives this shell/agent. Loopback debug port only.
      nohup "$bin" \
        --headless=new \
        --user-data-dir="$dir" \
        --profile-directory="$profile" \
        --remote-debugging-port="$port" \
        --no-first-run \
        --no-default-browser-check \
        >/dev/null 2>&1 &
      disown || true
      echo "$prog: launching HEADLESS (no window) on a clean profile."
    else
      # HEADED: a SEPARATE, detached instance. `open -na <app>` hands it to LaunchServices so it
      # persists independently of this shell/agent.
      /usr/bin/open -na "$app" --args \
        --user-data-dir="$dir" \
        --profile-directory="$profile" \
        --remote-debugging-port="$port" \
        --no-first-run \
        --no-default-browser-check \
        || die "failed to launch $app"
    fi

    # Wait for the CDP endpoint to come up so the caller knows it's attachable. A cold
    # launch (fresh cask install/Gatekeeper verification, first run after activation)
    # can take noticeably longer than a warm one — observed exceeding a 10s budget in
    # practice, so this polls longer (~25s) before reporting a false failure.
    for _ in $(seq 1 25); do
      if curl -fsS --max-time 2 "$cdp/json/version" >/dev/null 2>&1; then
        echo "$prog: automation browser up — CDP at $cdp (profile: $dir)."
        echo "$prog: next: 'automation-session seed' to inject your Keychain session, then drive it via the playwright MCP."
        exit 0
      fi
      sleep 1
    done
    echo "$prog: launched, but CDP $cdp did not answer within ~25s — check the browser window." >&2
    exit 0
  '';
}
