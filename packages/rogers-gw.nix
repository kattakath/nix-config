# Ad-hoc inspection CLI for the household's Rogers CGM4981 (RDK-B) gateway.
#
# THE CONTRACT IT SPEAKS is documented, with file:line citations against the
# Apache-2.0 firmware source (rdkcentral/webui — which IS this device's UI, see
# check.jst:128 branching on "CGM4981COM"), in docs/rdkb-gateway-contract.md.
# Read that before changing anything here.
#
# WHY A CLI AT ALL: the gateway exposes NO shell. SSH(22), telnet(23) are closed
# and SNMP(161) does not answer; only 80/443/53 are open (measured). Its web UI is
# the sole management surface, and its log table is populated by a JSON endpoint
# that the "Show Logs" button never even requests — that button is pure
# client-side show/hide. So a browser cannot be scripted into giving this up
# either; the JSON endpoint has to be called directly.
#
# WHY THIS IS INSPECTION-ONLY, and must stay that way:
#   * The customer-facing log carries ONLY OneWifi entries — no WAN, no DOCSIS
#     tier. There is nothing here worth polling on a timer.
#   * The fleet already has a strictly better "is the internet up" signal in the
#     Cloudflare tunnel to nixpi (infra/cloudflare/nixpi-tunnel.nix): tunnel down
#     IS WAN down, it is already declared, and it is observed from OUTSIDE the
#     house, so the alert can escape when the gateway cannot.
#   * check.jst:215-224 increments and PERSISTS NumOfFailedAttempts on every
#     failed login, against a lockout policy read at :111-115. A retry loop here
#     can lock the household out of its own gateway. Hence: authenticate once,
#     fail fast, NEVER retry credentials. Do not wire this into launchd.
#   * RDK-B WebUI carries a published check.jst DoS (oversized password) and a
#     multipart heap overflow (2026-08). Do not probe or fuzz this endpoint.
#
# SECRET HANDLING follows the house passwordCommand pattern: the password is read
# from the environment, which the caller populates with `secret exec`, so the
# value never reaches argv, the store, or a transcript:
#
#   secret exec ROGERS_GW_PASSWORD=rogers:cgm4981:admin-password -- rogers-gw status
#
# UPSTREAM-FIRST NOTE: pkgs.resholve would verify at BUILD time that every command
# this script calls resolves — the exact class of bug that broke an activation in
# this repo on 2026-09-23 (uplink-watchdog shipped without gawk in runtimeInputs
# and died with status=127 on first run). It is deliberately NOT adopted here:
# this repo has no resholve precedent, and introducing one is its own decision
# rather than a rider on this package. runtimeInputs below is instead verified by
# resolving every invoked command against the built wrapper's PATH.
{
  lib,
  stdenv,
  writeShellApplication,
  curl,
  jq,
  gnused,
  gawk,
  gnugrep,
  coreutils,
  iproute2,
}:
writeShellApplication {
  name = "rogers-gw";
  runtimeInputs = [
    curl
    jq
    gnused
    gawk
    gnugrep
    coreutils
  ]
  # Discovery reads the default route. Linux has ip(8); darwin has route(8) in
  # /sbin, which is outside the wrapper's pinned PATH and so is called by path.
  ++ lib.optionals stdenv.hostPlatform.isLinux [ iproute2 ];

  text = ''
    # ---- configuration -----------------------------------------------------
    # The gateway is the default route's gateway. Overridable for a second box
    # or a port-forward (e.g. reaching it through nixpi when off-LAN).
    discover_gw() {
      if command -v ip >/dev/null 2>&1; then
        ip route show default 2>/dev/null | awk '{print $3; exit}'
      elif [ -x /sbin/route ]; then
        /sbin/route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}'
      fi
    }
    GW="''${ROGERS_GW_HOST:-$(discover_gw)}"
    GW="''${GW:-10.0.0.1}"
    USER_NAME="''${ROGERS_GW_USER:-admin}"

    JAR=$(mktemp "''${TMPDIR:-/tmp}/rogers-gw.XXXXXX")
    chmod 600 "$JAR"
    trap 'rm -f "$JAR"' EXIT

    usage() {
      cat <<'U'
    usage: rogers-gw <command> [args]

      status              WAN / LAN / Wi-Fi connection status
      glance              at-a-glance summary
      devices             connected devices
      logs [TYPE] [WINDOW]
                          TYPE   = system | event | firewall   (default: system)
                          WINDOW = Today | Yesterday | 'Last week' | 'Last month' | 'Last 90 days'
      raw PAGE            any .jst page, as text
      rawhtml PAGE        any .jst page, unprocessed HTML
      ports               which management ports the gateway exposes (no auth)

    env:
      ROGERS_GW_PASSWORD  required for everything but `ports`. Inject it, never inline it:
                            secret exec ROGERS_GW_PASSWORD=rogers:cgm4981:admin-password -- rogers-gw status
      ROGERS_GW_HOST      default: the default route's gateway
      ROGERS_GW_USER      default: admin
      ROGERS_GW_FULL      set to keep the nav tree in page output

    This is an INSPECTION tool. It authenticates once and never retries credentials:
    a failed login increments a persisted server-side lockout counter. Do not poll it.
    Contract + citations: docs/rdkb-gateway-contract.md
    U
    }

    need_password() {
      if [ -z "''${ROGERS_GW_PASSWORD:-}" ]; then
        echo "rogers-gw: ROGERS_GW_PASSWORD is unset." >&2
        echo "  secret exec ROGERS_GW_PASSWORD=rogers:cgm4981:admin-password -- rogers-gw $*" >&2
        exit 2
      fi
    }

    # Single attempt, by design. A retry here feeds Device.Users.User.3.NumOfFailedAttempts.
    login() {
      curl -s -o /dev/null -c "$JAR" \
        --data-urlencode "username=$USER_NAME" \
        --data-urlencode "password=$ROGERS_GW_PASSWORD" \
        --data-urlencode "locale=false" \
        "http://$GW/check.jst"
    }

    fetch() { curl -s -b "$JAR" "http://$GW/$1"; }

    # Entity decode is BOUNDED, not a fixpoint. The endpoint runs htmlspecialchars
    # over the already-serialised payload and the call count differs per file
    # (at_a_glance 9, connected_devices 6, connection_status 5, ajax logs 3), so a
    # fixpoint cannot tell a server layer from entity text that was in the data --
    # and a DHCP hostname is attacker-chosen. Two passes covers what we measured.
    unent() {
      sed -e 's/&nbsp;/ /g' -e 's/&amp;/\&/g' -e 's/&lt;/</g' -e 's/&gt;/>/g' \
          -e "s/&#39;/'/g" -e 's/&quot;/"/g' -e 's/&#8226;/-/g'
    }

    # <script>/<style>/<head> must go as BLOCKS before tags are stripped: the pages
    # inline jQuery plus a full i18n bundle, which is ~33KB of noise otherwise.
    text() {
      awk '
        /<script/  {s=1} s {if (/<\/script>/) s=0; next}
        /<style/   {y=1} y {if (/<\/style>/)  y=0; next}
        /<head[ >]/{h=1} h {if (/<\/head>/)   h=0; next}
        {print}
      ' \
      | sed -e 's/<[^>]*>/\n/g' \
      | unent | unent \
      | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d'
    }

    # Every page repeats the whole nav tree first; start at the page heading.
    body() { awk 'f{print; next} /^[A-Z][A-Za-z ]+ > /{f=1; print}' | { grep . || cat; }; }

    # Auth is detected by CONTENT, never by status: every .jst returns 200 whether
    # authenticated or not, and the unauthenticated body is a byte-identical wall.
    page() {
      login
      out=$(fetch "$1")
      if grep -qi 'id="password"\|Please Login First' <<<"$out"; then
        echo "rogers-gw: not authenticated (check ROGERS_GW_PASSWORD / ROGERS_GW_USER)" >&2
        exit 1
      fi
      if [ -n "''${ROGERS_GW_FULL:-}" ]; then
        printf '%s\n' "$out" | text
      else
        printf '%s\n' "$out" | text | body
      fi
    }

    cmd="''${1:-}"
    shift || true
    case "$cmd" in
      status)  need_password "$cmd"; page connection_status.jst ;;
      glance)  need_password "$cmd"; page at_a_glance.jst ;;
      devices) need_password "$cmd"; page connected_devices_computers.jst ;;
      raw)     need_password "$cmd"; page "''${1:?usage: rogers-gw raw <page.jst>}" ;;
      rawhtml) need_password "$cmd"; login; fetch "''${1:?usage: rogers-gw rawhtml <page.jst>}" ;;
      logs)
        need_password "$cmd"
        mode="''${1:-system}"
        timef="''${2:-Today}"
        login
        # The per-session CSRF token is inlined in the page as `var token = "..."`
        # (troubleshooting_logs.jst:220) and sent as the csrfp_token header
        # (:240-243). Upstream's config suggests GET is not verified at all
        # (verifyGetFor empty), which would make this scrape unnecessary -- that is
        # UNCONFIRMED on this box, so we keep sending it. It is harmless.
        tok=$(fetch troubleshooting_logs.jst | sed -n 's/.*var token *= *"\([^"]*\)".*/\1/p' | head -1)
        if [ -z "$tok" ]; then
          echo "rogers-gw: no CSRF token in page (not authenticated?)" >&2
          exit 1
        fi
        curl -s -b "$JAR" -H "csrfp_token: $tok" \
          --get --data-urlencode "mode=$mode" --data-urlencode "timef=$timef" \
          "http://$GW/actionHandler/ajax_troubleshooting_logs.jst" \
        | jq -r '.[] | [(.time//"-"), (.Level//.Type//"-"), (.Des//"-")] | @tsv' \
        | sed -e 's/\\n//g' -e 's/[[:space:]]\{2,\}/ /g' -e 's/ *\t */\t/g'
        ;;
      ports)
        for p in 22 23 80 443 161 7547 8080 8443; do
          (timeout 2 bash -c "echo > /dev/tcp/$GW/$p" 2>/dev/null && echo "$p OPEN") || true
        done
        ;;
      "" | -h | --help) usage ;;
      *)
        echo "rogers-gw: unknown command '$cmd'" >&2
        usage
        exit 1
        ;;
    esac
  '';

  meta = {
    description = "Ad-hoc inspection CLI for the Rogers CGM4981 (RDK-B) gateway — status, devices and logs without the GUI";
    longDescription = ''
      Speaks the gateway's web UI contract documented in docs/rdkb-gateway-contract.md.
      Inspection only: it authenticates once and never retries, because a failed login
      increments a persisted server-side lockout counter. Not for polling or alerting —
      the Cloudflare tunnel to nixpi is the fleet's WAN-health signal.
    '';
    platforms = lib.platforms.unix;
    mainProgram = "rogers-gw";
  };
}
