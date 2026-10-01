# ---- LAN recovery path: a SECOND ingress, so the tunnel is not the only one --
#
# THE FAILURE THIS EXISTS FOR, measured 2026-10-01. The Cloudflare connector on
# nixpi died; Access stayed healthy (the gate still issued a login URL) and the
# zone was fine, but `snoringirl.com` answered HTTP 530 / Cloudflare 1033 and the
# SSH session timed out "during banner exchange". With sshd bound to loopback
# only and no port but Caddy's 80 open, a dead connector means the host is
# unreachable by EVERY route. Recovery was a physical SD reflash, ~40 minutes,
# with hands on the hardware — the one thing the remotely-managed design exists
# to avoid. uplink-watchdog.nix:118-121 already wrote this gap down from the
# other side ("sshd is loopback-bound and the Cloudflare tunnel needs working
# internet, so a dead uplink means no LAN path either"); this module closes it.
#
# WHY THE SCOPE IS AN INTERFACE AND NOT A SUBNET. nixpi is dual-homed onto one
# router (end0 wired, wlan0 on its SSID) and fails over to a PHONE HOTSPOT when
# that router loses its uplink — a different subnet, assigned by DHCP, unknown
# until it happens. A rule written against 10.0.0.0/24 is therefore dead in the
# state where it is needed most. Interface NAMES are stable across both states
# (end0 is the Pi 4's wired port; wlan0 is the radio the supplicant owns), so
# the firewall is scoped per interface — upstream's own
# `networking.firewall.interfaces.<iface>.allowedTCPPorts`, which
# firewall-iptables.nix:160-165 renders as `-i <iface>` while the `default`
# pseudo-interface renders with no `-i` at all. Nothing here names an address.
# The entry point is mDNS (`ssh ismail@nixpi.local`), already published by
# avahi with UDP 5353 already open in core.nix — so the recovery path needs no
# address written down anywhere, on either side.
#
# UPSTREAM FIRST (grepped the pinned nixpkgs 2026-10-01). OpenSSH has no
# bind-to-interface keyword, so the per-interface scope cannot live in sshd_config
# at all: sshd binds the wildcard and the kernel's packet filter is the gate.
# `systemd.sockets.sshd.socketConfig.BindToDevice` WAS considered and REJECTED —
# SO_BINDTODEVICE is a stronger scope than a filter rule, but one socket unit
# takes one device, so two interfaces mean forking sshd onto
# `startWhenNeeded` socket activation plus a second hand-written unit. That is a
# bigger change to the host's SSH lifecycle than the thing it protects, and the
# per-interface firewall option is upstream-supported for exactly this.
# `extraInputRules` (an RFC1918 source match) was also rejected: it exists only
# in firewall-nftables.nix and nixpi is on the iptables backend, so the only
# iptables route to a source match is `extraCommands` — raw shell, invisible to
# every leg of `nixpi-security-posture`. Both candidate segments are private
# already, so the interface IS the RFC1918 scope.
#
# WHAT THE EXPOSURE BECOMES. TCP 22 answers on the two LAN interfaces, keys-only
# (core.nix pins PasswordAuthentication/KbdInteractiveAuthentication off and
# PermitRootLogin no), to one operator ed25519 key. It is NOT internet-reachable:
# there is no port-forward and no public IP, and the tunnel is outbound-only. The
# real cost is honest and deliberate: a LAN connection does not traverse
# Cloudflare Access, so it is neither gated by the operator's identity nor
# logged there. That is accepted because the segment was never zero-exposure —
# `allowedTCPPorts = [ 80 ]` is the `default` pseudo-interface, i.e. no `-i`, so
# Caddy has always answered on the LAN. This adds a pubkey-gated service beside
# an already-LAN-reachable web server, and buys back the 40-minute reflash.
#
# WHAT IT DOES NOT DO. It cannot reach a host that is off, whose SD card is
# corrupt, or whose radio and wired port are both down — and it is no help from
# anywhere but the segment the Pi is actually on. The physical console (getty)
# stays the last break-glass path.
{
  config,
  lib,
  ...
}:
let
  cfg = config.local.lanRecovery;
in
{
  options.local.lanRecovery = {
    enable = lib.mkEnableOption ''
      a second SSH ingress on the LAN interfaces, so a dead tunnel connector is
      not a total loss of the host
    '';

    interfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "end0"
        "wlan0"
      ];
      description = ''
        Interfaces on which sshd's port is opened. Deliberately has NO default:
        interface names are hardware- and host-specific, and a wrong guess here
        fails open (the port simply never opens) rather than loudly. On nixpi the
        list is cross-checked against the interfaces the uplink watchdog and the
        wpa_supplicant instances actually name — see `nixpi-security-posture` in
        modules/parts/checks.nix, which fails the build if they drift apart.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # mkForce, not an append: core.nix pins the two loopback addresses as a plain
    # value, and listenAddresses is a LIST, so adding to it would leave sshd with
    # `127.0.0.1` AND `0.0.0.0` on the same port. sshd sets SO_REUSEADDR but not
    # SO_REUSEPORT (sshd.c:844), so the wildcard bind would then lose to the
    # already-bound specific address with EADDRINUSE — and a failed bind is fatal
    # only if EVERY bind fails (sshd.c:857-863 `continue`s), so the LAN path would
    # silently not exist. Replacing the list is the only correct merge.
    #
    # BOTH families are named explicitly, mirroring core.nix's loopback pair, and
    # they do not collide: sshd.c:851-853 sets IPV6_V6ONLY on every AF_INET6
    # listener (misc.c:2044-2056), so `0.0.0.0` and `::` are two disjoint sockets
    # rather than a dual-stack one plus a duplicate. An explicit pair is also
    # preferred over `listenAddresses = [ ]` — which would give the same binds via
    # sshd's default — because the empty list is the ACCIDENTAL wildcard this
    # fleet guards against, and a check cannot tell an intentional deletion from a
    # careless one. The wildcard covers loopback, so the connector's
    # `localhost:22` dial is unaffected.
    services.openssh.listenAddresses = lib.mkForce [
      { addr = "0.0.0.0"; }
      { addr = "::"; }
    ];

    # Derived from services.openssh.ports rather than a literal 22: the port is
    # already declared once, and a second copy of it here would be a copy that
    # can drift. The global allow-list is untouched on purpose — opening the port
    # there would render a rule with no `-i` and expose sshd on every interface,
    # which is the thing this module is careful NOT to do.
    networking.firewall.interfaces = lib.genAttrs cfg.interfaces (_: {
      allowedTCPPorts = config.services.openssh.ports;
    });
  };
}
