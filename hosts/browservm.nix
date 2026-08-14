# browservm — an EPHEMERAL headless-Chromium automation guest, booted via
# microvm.nix's `vfkit` hypervisor backend (Apple's Virtualization Framework
# directly, native acceleration, no nested virtualization — same tier as Tart's
# macvm and Determinate's native Linux builder). See docs/browservm-runbook.md.
#
#   nix run .#browservm-vfkit-start   # boot fresh (whole guest OS rebuilt from
#                                      # the Nix store every time — no persistent
#                                      # disk at all)
#   nix run .#browservm-vfkit-ssh     # SSH in directly, no port-forward needed
#                                      # (host and guest share the same macOS
#                                      # vmnet shared subnet — 192.168.64.0/24,
#                                      # the same one Tart's macvm already uses;
#                                      # verified empirically: direct ICMP/IP
#                                      # reachability). CDP (9222) is different —
#                                      # loopback-only in the guest, needs an SSH
#                                      # -L tunnel; see docs/browservm-runbook.md.
#   nix run .#browservm-vfkit-stop    # tear down
#
# Chromium is NOT auto-started (no systemd service, and `start` only boots the
# VM) — launch it yourself over SSH once the guest is up, same scope-boundary
# as macvm-tart.nix (host control-plane owns the VM, not what runs inside it).
# See docs/browservm-runbook.md for the exact launch + CDP-tunnel commands.
{ pkgs, ... }:
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
  # No firewall port opened for CDP (9222): verified live that Chromium binds
  # DevTools to 127.0.0.1 only regardless of --remote-debugging-address (a
  # deliberate hardening — an exposed debug port is a known RCE vector). Reach
  # it via `browservm-vfkit-ssh -- -L 9222:127.0.0.1:9222 -N`, not the network.

  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = [ pkgs.ungoogled-chromium ];

  # SSH is already wired by modules/nixos/core.nix (every mkNixos host): the
  # single operator key, keys-only, PasswordAuthentication off. Nothing extra
  # needed here beyond what mkNixos already provides.
}
