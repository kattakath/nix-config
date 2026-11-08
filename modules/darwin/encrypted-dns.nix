# System-wide encrypted DNS through macOS's OWN resolver. A `com.apple.dnsSettings.managed`
# configuration profile tells mDNSResponder to send every lookup as DoH (DNS over HTTPS)
# to Quad9. There is no local proxy and no listener on port 53.
#
# WHY NATIVE, NOT dnscrypt-proxy (which this module ran 2026-11-08, b3407417 → 5253fa47).
# MEASURED that day: mDNSResponder ITSELF binds UDP/TCP :53 to serve the vmnet guests' DNS
# (Tart CI VMs, any NAT VM), but only while a VM is up and the port is free. The kernel
# log: `in_pcbbind … :53 … EADDRINUSE caused by … interface: lo0 … process: mDNSResponder`.
# So a local proxy on 127.0.0.1:53 and the VM DNS proxy shut each other out:
#   - proxy up first → guests had no DNS, and every GitLab job failed at `git clone`;
#   - VM up first → dnscrypt-proxy crash-looped (EADDRINUSE) until the last VM stopped,
#     and the HOST had no DNS for that whole time.
# A managed DoH profile leaves port 53 to mDNSResponder, so there is nothing to collide.
# (The tart-vms capsule's guest-DNS step stays: it keeps CI independent of how the host
# resolves. Its packages/guest-dns.nix carries the dnscrypt measurements.)
#
# UPSTREAM-FIRST. Grepped the pinned nix-darwin and home-manager modules for
# mobileconfig / com.apple.dnsSettings / `profiles install`: no option exists, and a profile
# cannot be installed silently without MDM. So this renders the profile with nixpkgs'
# `lib.generators.toPlist`, puts it at /etc/encrypted-dns/quad9-doh.mobileconfig, and ships
# `encrypted-dns-install` to open it. The operator then clicks Install ONCE:
# System Settings → General → Device Management.
# Payload keys are from Apple's schema, apple/device-management @ 9e7fdbe2,
# mdm/profiles/com.apple.dnsSettings.managed.yaml:
#   - DNSProtocol "HTTPS" plus ServerURL (required for HTTPS) plus ServerAddresses. The
#     addresses mean no plaintext lookup of dns.quad9.net is needed to bootstrap.
#   - ProhibitDisablement: "only available on supervised devices". This Mac is not, so
#     it is omitted.
#   - AllowFailover (macOS 26+): left at its default, false. The system does NOT fall back
#     to the network's plaintext resolver.
#   - The schema notes that a manually installed profile also applies to cellular.
# The resolver is Quad9's filtered endpoint (malware blocklist, DNSSEC validated, no
# logs): https://dns.quad9.net/dns-query, at 9.9.9.9, 149.112.112.112, 2620:fe::fe and
# 2620:fe::9.
#
# REINSTALL UPDATES IN PLACE. Both PayloadIdentifier and PayloadUUID are fixed constants
# here. Apple's TopLevel schema says the system "uses this string [PayloadIdentifier] to
# determine whether to replace an existing profile or add it as a new profile". So
# installing a changed profile replaces the old one; it does not stack a second.
#
# NETWORK SERVICES: Wi-Fi and Thunderbolt Bridge (`networksetup -listallnetworkservices`).
# `networking.knownNetworkServices` with an EMPTY `networking.dns` makes every activation
# write `empty`, which is DHCP DNS. That is deliberate. It clears the 127.0.0.1 that the
# dnscrypt version set, and it keeps activation from ever fighting the profile. The
# profile, not the per-service DNS, makes queries encrypted. The WireGuard services
# (MANILA … TORONTO) stay out, so a tunnel keeps the DNS it pushes.
#
# CAPTIVE-PORTAL ESCAPE (hotel/airport Wi-Fi), with failover off: remove the profile.
#   sudo profiles remove -identifier com.kattakath.encrypted-dns
# Since macOS 11, profiles(1) cannot INSTALL a profile, but its man page still documents
# `remove -identifier`. Run `encrypted-dns-install` again once you are online.
# (UNVERIFIED until the first install: whether macOS 27 also offers an on/off toggle for
# DNS settings under Network → VPN & Filters.)
{
  config,
  lib,
  pkgs,
  domainName,
  ...
}:
let
  cfg = config.local.encryptedDns;

  # Reverse-DNS from the fleet's one domain (kattakath.com → com.kattakath), so the
  # identity lives once (modules/parts/identity.nix).
  reverseDomain = lib.concatStringsSep "." (lib.reverseList (lib.splitString "." domainName));
  profileId = "${reverseDomain}.encrypted-dns";

  profile = pkgs.writeText "quad9-doh.mobileconfig" (
    lib.generators.toPlist { escape = true; } {
      PayloadType = "Configuration";
      PayloadVersion = 1;
      PayloadIdentifier = profileId;
      # Fixed on purpose: a reinstall must REPLACE this profile (see the header).
      PayloadUUID = "0F4A395C-9033-40F8-94D1-101A4DDB309E";
      PayloadDisplayName = "Encrypted DNS (Quad9)";
      PayloadDescription = "System-wide DNS over HTTPS to Quad9 (filtered, DNSSEC, no logs). Declared in nix-config, modules/darwin/encrypted-dns.nix.";
      PayloadScope = "System";
      PayloadContent = [
        {
          PayloadType = "com.apple.dnsSettings.managed";
          PayloadVersion = 1;
          PayloadIdentifier = "${profileId}.quad9";
          PayloadUUID = "089E2E24-15D3-42DD-B5EB-979BBCCC8BA5";
          PayloadDisplayName = "Quad9 DoH";
          DNSSettings = {
            DNSProtocol = "HTTPS";
            ServerURL = "https://dns.quad9.net/dns-query";
            ServerAddresses = [
              "9.9.9.9"
              "149.112.112.112"
              "2620:fe::fe"
              "2620:fe::9"
            ];
          };
        }
      ];
    }
  );

  profilePath = "/etc/encrypted-dns/quad9-doh.mobileconfig";

  install = pkgs.writeShellApplication {
    name = "encrypted-dns-install";
    text = ''
      # Hands the profile to System Settings. macOS never installs a profile silently
      # without MDM: the operator still clicks Install there.
      /usr/bin/open ${lib.escapeShellArg profilePath}
      echo "encrypted-dns-install: profile handed to System Settings." >&2
      echo "  Next: System Settings → General → Device Management → \"Encrypted DNS (Quad9)\" → Install." >&2
      echo "  Reinstalling replaces it in place (same PayloadIdentifier: ${profileId})." >&2
    '';
  };
in
{
  options.local.encryptedDns = {
    enable = lib.mkEnableOption "system-wide encrypted DNS (a native macOS DoH profile for Quad9)";
    networkServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "Wi-Fi"
        "Thunderbolt Bridge"
      ];
      description = ''
        Network services (as `networksetup -listallnetworkservices` prints them) whose
        per-service DNS activation resets to DHCP (`empty`). This way no static resolver,
        such as the old 127.0.0.1, outranks the DoH profile. Leave VPN services out, so they
        keep the DNS their tunnel pushes.
      '';
    };
  };

  config = lib.mkMerge [
    { networking.knownNetworkServices = cfg.networkServices; }

    (lib.mkIf cfg.enable {
      environment.etc."encrypted-dns/quad9-doh.mobileconfig".source = profile;
      environment.systemPackages = [ install ];
    })
  ];
}
