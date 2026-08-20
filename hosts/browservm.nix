# browservm — an EPHEMERAL headless-Chromium automation guest, booted via
# microvm.nix's `vfkit` hypervisor backend (Apple's Virtualization Framework
# directly, native acceleration, no nested virtualization — same tier as Tart's
# macvm and Determinate's native Linux builder). See docs/browservm-runbook.md.
#
#   nix run .#browservm-vfkit-up      # ONE-SHOT: boot (if needed) + wait for
#                                      # IP + open the CDP tunnel + block until
#                                      # Chromium answers. This is the primary
#                                      # entrypoint for automation jobs.
#   nix run .#browservm-vfkit-start   # boot fresh only (whole guest OS rebuilt
#                                      # from the Nix store every time — no
#                                      # persistent disk at all)
#   nix run .#browservm-vfkit-ssh     # SSH in directly, no port-forward needed
#                                      # (host and guest share the same macOS
#                                      # vmnet shared subnet — 192.168.64.0/24,
#                                      # the same one Tart's macvm already uses;
#                                      # verified empirically: direct ICMP/IP
#                                      # reachability).
#   nix run .#browservm-vfkit-status  # running state + guest IP + tunnel state
#   nix run .#browservm-vfkit-stop    # tear down (VM + tunnel)
#
# Chromium auto-starts in-guest as `browser-cdp.service`, headless, CDP bound
# to 127.0.0.1:9222 only (see the firewall note below) — `browservm-vfkit-up`
# opens the SSH -L tunnel to it, so there is no manual "SSH in and launch
# Chromium yourself" step anymore. The host control-plane still owns the VM
# lifecycle only (start/stop/ssh/status), same scope boundary as
# macvm-tart.nix — this service is the one deliberate exception, because
# without it every automation job needed a human/agent to reconstruct the
# launch command from docs each time.
{ pkgs, loginName, ... }:
{
  networking.hostName = "browservm";

  microvm = {
    vcpu = 2;
    mem = 2048;
    hypervisor = "vfkit";
    # NAT-mode virtio-net (vfkit's only implemented networking mode today) — on
    # macOS this rides the same `vmnet` shared subnet as Tart, so the host CAN
    # dial the guest directly by IP despite the "NAT" name (verified live).
    interfaces = [
      {
        type = "user";
        id = "eth0";
        mac = "02:00:00:00:be:ef";
      }
    ];
    # No microvm.volumes: fully ephemeral, in-memory root — nothing to wipe
    # between runs because nothing persists in the first place.
  };

  networking.useDHCP = true;
  # No firewall port opened for CDP (9222): Chromium binds DevTools to
  # 127.0.0.1 only regardless of --remote-debugging-address (a deliberate
  # hardening — an exposed debug port is a known RCE vector). Reached via
  # `browservm-vfkit-up`'s SSH -L tunnel, never the network.

  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = [ pkgs.ungoogled-chromium ];

  # Auto-started headless Chromium, CDP-only — the thing `automation-session`
  # and the `playwright` MCP actually drive. `--no-sandbox` is acceptable
  # specifically because the VM itself is the isolation boundary: ephemeral,
  # no persistent disk, torn down freely — there is nothing on the other side
  # of Chromium's sandbox worth protecting inside this guest.
  systemd.services.browser-cdp = {
    description = "Headless Chromium (CDP) for browser automation";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      ExecStart = ''
        ${pkgs.ungoogled-chromium}/bin/chromium \
          --headless=new \
          --remote-debugging-port=9222 \
          --remote-debugging-address=127.0.0.1 \
          --no-sandbox \
          --disable-gpu \
          --user-data-dir=/tmp/browservm-chromium \
          about:blank
      '';
      User = loginName;
      Restart = "on-failure";
      RestartSec = 2;
    };
  };

  # SSH is already wired by modules/nixos/core.nix (every mkNixos host): the
  # single operator key, keys-only, PasswordAuthentication off. Nothing extra
  # needed here beyond what mkNixos already provides.
}
