# Cloudflare Tunnel — boot-time, LOGINLESS token connector for macOS hosts.
#
# Mirrors modules/nixos/cloudflared.nix, but macOS has no agenix (agenix is a
# NixOS activation-time mechanism; the Macs have no host-scoped age identity in
# this repo). So the connector token is provisioned OUT-OF-BAND as a root-only
# file and read at launch by a wrapper — it never appears in the launchd plist
# (plists live under /Library/LaunchDaemons, world-readable) nor on argv.
#
# TOKEN FILE (provision manually, once, per Mac):
#   sudo install -m 0600 -o root -g wheel /dev/null /var/root/.cloudflared/tunnel-token
#   # then write one line — the connector token from scripts/cf-one-provision.sh:
#   #   TUNNEL_TOKEN=<token>
#   # (the wrapper `source`s the file, so use the KEY=VALUE form, not a bare token)
#   sudo chmod 0600 /var/root/.cloudflared/tunnel-token
#   sudo chown root:wheel /var/root/.cloudflared/tunnel-token
#
# WHY a wrapper (not launchd EnvironmentVariables): keeping the token out of the
# plist requires reading it at runtime. The wrapper sources the 0600 root file,
# exports TUNNEL_TOKEN, and exec's cloudflared — token via env, never argv/plist.
{ pkgs, ... }:
let
  tokenFile = "/var/root/.cloudflared/tunnel-token";
  connector = pkgs.writeShellScript "cloudflared-connector" ''
    set -euo pipefail
    if [ ! -r "${tokenFile}" ]; then
      echo "cloudflared-connector: token file ${tokenFile} missing/unreadable" >&2
      exit 1
    fi
    # Source the 0600 root file: expects a single line `TUNNEL_TOKEN=…`.
    # shellcheck disable=SC1091
    . "${tokenFile}"
    export TUNNEL_TOKEN
    # Token via env — never on argv. `tunnel run` with no UUID uses TUNNEL_TOKEN.
    exec ${pkgs.cloudflared}/bin/cloudflared --no-autoupdate tunnel run
  '';
in
{
  launchd.daemons.cloudflared-connector = {
    script = "exec ${connector}";
    serviceConfig = {
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
      StandardOutPath = "/var/log/cloudflared.log";
      StandardErrorPath = "/var/log/cloudflared.log";
    };
  };
}
