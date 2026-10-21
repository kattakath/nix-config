# NixOS host for Raspberry Pi 4 (aarch64-linux) — the fleet's LIVE server.
# nixos-hardware's raspberry-pi/4 handles the kernel, firmware and config.txt;
# nixpkgs' own sd-image module builds the card (see the BOOT CHAIN block below).
# Build a flashable SD card image:
#   nix build .#nixosConfigurations.nixpi.config.system.build.sdImage
#
# SSH ACCESS: TWO ingresses, deliberately. (1) Over the Cloudflare Tunnel
# connector below (remotely-managed, token-based — no port-forward, no public IP),
# which is the only INTERNET path and the only one Cloudflare Access gates.
# (2) `ssh ismail@nixpi.local` from the same LAN segment — `local.lanRecovery`
# (modules/nixos/lan-recovery.nix) opens sshd's port on end0/wlan0 only, so a dead
# connector is no longer a total loss of the host. Both are keys-only; the LAN one
# does NOT traverse Access and is not logged there, which the module header
# justifies. Wi-Fi is provisioned the same way as the token (a wpa_supplicant.conf
# planted on the FIRMWARE partition — see the wifi block below), so a headless nixpi
# reaches nixpi.kattakath.com over the tunnel from first boot with no LAN cable,
# keyboard, or monitor. The connector token is planted on the SD card's FAT FIRMWARE
# partition (re-planted by the operator after each flash — macOS can write FAT;
# see docs/nixpi-sd-flashing-runbook.md) and copied into a root-only /run file by
# a oneshot before the connector starts. This deliberately does NOT use agenix:
# agenix binds the token to nixpi's SSH host key, but a fresh SD flash mints a new
# host key, so the agenix ciphertext stops decrypting and the tunnel dies — and a
# token the host cannot decrypt is only fixable from the card or the LAN, which is
# the reflash lockout this file is shaped around. The connector unit retries on
# failure (Restart=on-failure) so a token refresh self-heals.
#
# NETWORK SSH is the operator's static key (modules/nixos/core.nix), reached either
# with `cloudflared access ssh --hostname nixpi.kattakath.com` over the tunnel or
# directly at `nixpi.local` from the LAN (keys-only, no password, both ways).
# Physical console (getty) is the independent break-glass path.
{
  config,
  lib,
  pkgs,
  loginName,
  hostedSites,
  cloudflaredConnectorModule,
  firmwareSecretsModule,
  nixosHardware,
  modulesPath,
  ...
}:
{
  imports = [
    # The Pi's own hardware: kernel, GPU firmware, config.txt and the
    # firmware-partition installer, from the pinned nixos-hardware input threaded
    # through mkNixos specialArgs (modules/parts/compose.nix). Owned HERE so that
    # nix-config builds this host standalone.
    nixosHardware.nixosModules.raspberry-pi-4
    # nixpkgs' generic SD-card image builder. NOT sd-image-aarch64.nix: that wrapper
    # also imports profiles/base.nix (installer tools, and ZFS in
    # boot.supportedFilesystems — a kernel module this vendor kernel need not
    # build) and writes its own config.txt, which nixos-hardware's firmware module
    # mkForce-overrides anyway. Its one useful line is populateRootCommands, copied
    # below.
    "${modulesPath}/installer/sd-card/sd-image.nix"
    # Both of these are IN-TREE CAPSULES
    # (modules/features/cloudflared-connector/ and modules/features/firmware-secrets/),
    # absorbed from standalone flakes by ADR-002 waves 3 and 4. Each arrives
    # already resolved to a MODULE, through the flake's own `flake.modules.nixos`
    # registry and mkNixos's specialArgs — a capsule is only ever entered through
    # its flake-module.nix, never imported by path from here. That is also why
    # neither name ends in `-secrets`/`-connector`: a leftover
    # `firmware-secrets.nixosModules.default` fails loudly rather than
    # half-resolving.
    cloudflaredConnectorModule
    firmwareSecretsModule
    # Imported by PATH, unlike the two capsules above, because both are plain
    # in-tree NixOS modules rather than capsules with their own flake-module.nix.
    ../modules/nixos/uplink-watchdog.nix
    ../modules/nixos/lan-recovery.nix
    ../modules/nixos/service-heartbeat.nix
  ];

  # The router this host is dual-homed onto keeps its LAN alive while losing its
  # uplink, and neither dhcpcd nor wpa_supplicant can see that: end0 keeps carrier
  # so it keeps the lower metric, and wlan0 stays associated to an AP that is
  # beaconing perfectly well with nothing behind it. Both paths are then dead and
  # the tunnel — the only route in — goes with them. The watchdog probes the
  # default route and escalates; the module header carries the full reasoning and
  # the upstream-first grep that justifies it being ours.
  local.uplinkWatchdog.enable = true;

  # SECOND INGRESS. The watchdog above can only ever hand the tunnel a working
  # uplink; it is powerless when the CONNECTOR itself dies, which is what happened
  # on 2026-10-01 (Access healthy and still issuing a login URL, zone healthy, the
  # site answering Cloudflare 1033 and SSH timing out at banner exchange). With
  # sshd loopback-bound that was a total loss of the host and a ~40-minute physical
  # reflash. This opens sshd's port on the two LAN interfaces — keys-only, not
  # internet-reachable — so the LAN becomes a real recovery path. The module header
  # carries the exposure analysis and the upstream-first grep; the interface list
  # is cross-checked by `nixpi-security-posture` against the two places these two
  # names are independently spelled, so a rename cannot leave this list stale.
  #
  #   end0  — the Pi 4's wired port (local.uplinkWatchdog.wiredInterface)
  #   wlan0 — the radio the supplicant instance below owns
  local.lanRecovery = {
    enable = true;
    interfaces = [
      "end0"
      "wlan0"
    ];
  };

  # ONE mDNS NAME: avahi publishes `nixpi.local` from the wired port ONLY. With
  # both interfaces on one LAN, avahi can lose a probe race against ITSELF and
  # rename the host — measured 2026-10-17: a router blip dropped both links, end0
  # (00:06:19Z) and wlan0 (00:06:22Z) re-joined and re-probed, and at 00:06:27Z it
  # logged "Host name conflict" twice and became `nixpi-3`. avahi never reverts, so
  # `nixpi.local` — the LAN ingress's entry point — stayed dead until a restart.
  # One event in 52 end0 re-joins since 2026-10-02: rare, but permanent.
  #
  # upstream-first: avahi#117 ("Spurious name conflicts", OPEN), whose maintainer
  # names `allow-interfaces` as the workaround; it is upstream's own
  # `services.avahi.allowInterfaces` (pinned nixpkgs avahi-daemon.nix:116). The
  # name comes from the watchdog's option, not a fourth literal, and
  # `nixpi-security-posture` pins the pairing.
  #
  # THE COST, accepted: with end0 down and wlan0 on the LAN, `nixpi.local` does not
  # resolve. sshd still answers on wlan0 (lanRecovery above), by its DHCP address.
  # The watchdog's failover moves wlan0, never end0, so the name stays up through it.
  services.avahi.allowInterfaces = [ config.local.uplinkWatchdog.wiredInterface ];

  # NixOS defaults to a VOLATILE journal (wiped on reboot). The uplink-watchdog's
  # probe/escalate/restore trail is the best timestamp source for dating a router
  # outage (nixpi's own clock, unlike the Rogers gateway's ~1h-off log) — but only
  # if it survives a reboot that a bad enough power event on the shared circuit
  # could also cause on nixpi itself.
  services.journald.settings.Journal.Storage = "persistent";

  networking.hostName = "nixpi";

  # ── BOOT CHAIN (nixos-hardware, since the raspberry-pi-nix exit) ─────────────
  # GPU firmware -> U-Boot (u-boot.bin on FIRMWARE) -> extlinux.conf on the ROOT
  # partition (/boot/extlinux, written by generic-extlinux-compatible, which
  # nixos-hardware raspberry-pi/4/default.nix enables) -> kernel + initrd of the
  # chosen generation. raspberry-pi-nix instead had the GPU firmware load
  # kernel.img/initrd/cmdline.txt straight off FIRMWARE and copied them there in a
  # boot-time oneshot.
  #
  # BOTH flags below are REQUIRED, and each failure is silent:
  #   uboot.enable — without it config.txt has no `kernel=` line, the firmware
  #     looks for kernel8.img, which nothing writes: a fresh image never boots.
  #   enable — without it a switch never touches FIRMWARE, so an in-place-switched
  #     Pi keeps booting the OLD kernel.img forever (nothing errors; the new
  #     generation just never becomes the booted one). The activation script it
  #     adds (common/firmware.nix) rewrites FIRMWARE on every switch, and skips
  #     when /boot/firmware is not mounted — hence the mount options below.
  hardware.raspberry-pi.firmware = {
    enable = true;
    uboot.enable = true;
  };

  # SD-card LAYOUT kept identical to the raspberry-pi-nix one this card was flashed
  # with (its sd-image/sd-image.nix vs nixpkgs installer/sd-card/sd-image.nix):
  # MBR, label-id 0x2178694e, FAT `FIRMWARE` then ext4 `NIXOS_SD` flagged
  # bootable (where U-Boot's distro boot finds extlinux). Same labels and id are
  # nixpkgs' defaults; only the size differs (nixpkgs 30 MB, raspberry-pi-nix 128).
  sdImage.firmwareSize = 128;
  # extlinux on the root partition — the line sd-image-aarch64.nix would add.
  sdImage.populateRootCommands = ''
    mkdir -p ./files/boot
    ${config.boot.loader.generic-extlinux-compatible.populateCmd} -c ${config.system.build.toplevel} -d ./files/boot
  '';
  # nixpi-flash and the installer-latest Release both select assets matching
  # `^nixos-sd-image-`, raspberry-pi-nix's filename. nixpkgs' default is
  # `nixos-image-…`, which would make `nixpi-flash --release` find nothing.
  image.baseName = "nixos-sd-image-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}";
  # nixpkgs' sd-image.nix sets enableAllHardware (an installer default), which
  # adds ~70 initrd modules — sata_*, pata_*, sun4i-drm, rockchip — that
  # bcm2711_defconfig does not build; makeModulesClosure treats every
  # availableKernelModules entry as required, so modules-shrunk would fail. The
  # Pi's own initrd modules come from nixos-hardware; its firmware we keep below.
  hardware.enableAllHardware = lib.mkForce false;
  hardware.enableRedistributableFirmware = true;
  # FIRMWARE is mounted at boot, as it was under raspberry-pi-nix. nixpkgs'
  # sd-image.nix marks it `noauto`, which would leave the firmware activation
  # script above skipping every switch. `nofail` keeps a bad FAT from blocking
  # boot (the firmware-secrets capsule already only Wants= this mount).
  fileSystems."/boot/firmware".options = lib.mkForce [ "nofail" ];

  # TPM2: no workaround here any more. nixos-hardware raspberry-pi/4/default.nix
  # sets `boot.initrd.systemd.tpm2.enable = false` itself ("Allow building kernel")
  # — the same tpm-tis/tpm-crb modules-shrunk failure this file used to mkForce
  # away on the old kernel. One copy, upstream's.

  # SCRIPTED initrd, KEPT. On the raspberry-pi-nix 6.6.51 kernel systemd stage-1
  # HUNG mounting /sysroot (the Pi never reached stage-2). Whether 6.18 + extlinux
  # still hangs is UNTESTED — and a boot-chain swap is the wrong moment to change a
  # second boot variable. Revisit only after this generation has booted clean
  # (`checks.<system>.nixpi-initrd-posture` guards the upstream removal deadline).
  boot.initrd.systemd.enable = lib.mkForce false;

  # The libbpf C23 patch (`kernelPatches.libbpf_C23_compat`) is GONE with the
  # 6.6.51 kernel: nixos-hardware's linux-rpi tag stable_20260911 already declares
  # `const char *next_path` in tools/lib/bpf/libbpf.c (fetched and read
  # 2026-10-21), which is exactly the line that patch changes.

  networking.useDHCP = true;

  # NO IPv6 TEMPORARY ADDRESSES. Privacy extensions (RFC 4941) hide a CLIENT from
  # tracking; a server named in DNS gains nothing from them — and here they piled up.
  # dhcpcd adds each interface's SLAAC address with `mngtmpaddr`, so the KERNEL mints
  # temporaries from it — on every re-add and on every pre-expiry regeneration — and
  # a temporary outlives its base being deleted unless the delete carries
  # IFA_F_MANAGETEMPADDR (Linux v6.6 addrconf.c:2583, :4594, :3063). So link churn
  # piles them up for their full valid lifetime (up to 7 days). Measured 2026-10-17:
  # wlan0 held 371 IPv6 addresses (369 temporary, 275 deprecated). Distinct new ones
  # per day tracked the churn: 10-15, 109 base re-adds -> 111; 10-16, 72 re-adds and
  # 1,073 carrier losses -> 181. That was during a watchdog storm that bounced wlan0
  # 2,417 times in two days, and every one of them was also an avahi record.
  #
  # The off switch is exact: ipv6_create_tempaddr() refuses when use_tempaddr <= 0
  # (addrconf.c:1349), and all three creation paths go through it.
  #
  # upstream-first: `networking.tempAddresses` (pinned nixpkgs
  # network-interfaces.nix:1700). It writes only `default.use_tempaddr` plus a udev
  # rule that fires on interface ADD, so it would not reach the LIVE end0/wlan0 until
  # a reboot. The per-interface keys below are what nixpkgs itself emits for a
  # DECLARED interface (network-interfaces.nix:1795-1804), and systemd-sysctl
  # re-applies them at switch (sysctl.nix:107 restartTriggers). Declaring
  # networking.interfaces instead would add scripted link units to a live host.
  # The names are the two this host spells for its watchdog and supplicant, the same
  # set `nixpi-security-posture` joins against.
  #
  # Cost: outbound IPv6 now leaves from the stable SLAAC address, which dhcpcd builds
  # from the MAC (EUI-64), or from the DHCPv6 /128. Temporaries already minted age out
  # within their valid lifetime, or at the next reboot.
  networking.tempAddresses = "disabled";
  boot.kernel.sysctl = lib.listToAttrs (
    map (i: lib.nameValuePair "net.ipv6.conf.${i}.use_tempaddr" 0) (
      [ config.local.uplinkWatchdog.wiredInterface ] ++ lib.attrNames config.networking.supplicant
    )
  );

  # SSH over the Cloudflare Tunnel — loginless, token-based connector. Both the
  # connector token AND the Wi-Fi credentials are delivered from the SD card's FAT
  # FIRMWARE partition via `local.firmwareProvisioning`
  # (the firmware-secrets capsule), NOT agenix. WHY NOT agenix: it
  # encrypts to nixpi's SSH HOST key, but a fresh SD flash mints a new host key, so
  # the ciphertext stops decrypting and the tunnel dies — and with SSH being
  # cert-only OVER that tunnel, unrecoverably (the reflash lockout). A file on the
  # macOS-writable FAT partition is immune to host-key rotation; the operator
  # re-plants it per flash (the `nixpi-provision` flake app — see
  # docs/nixpi-sd-flashing-runbook.md). Each planted file is copied into a root-only
  # /run file before its consumer starts, so the secret is never world-readable at
  # rest, on argv, or in the store.
  local.cloudflaredConnector.enable = true;
  local.cloudflaredConnector.tokenFile = "/run/cloudflared-token";

  # nixpi runs exactly ONE connector — the primary, above. dontsell.ai's second,
  # independent connector was hand-written HERE, then moved to the private
  # nix-personal composition, and is now RETIRED on both sides: the app formerly
  # at app.dontsell.ai moved to the dontsell.ai apex, which Cloudflare proxies
  # straight to Vercel, so the Pi serves nothing for that zone. Recorded because
  # the constraint recurs: a `cfargotunnel.com` CNAME only resolves inside the
  # SAME Cloudflare account as the tunnel it names, and dontsell.ai's zone lives
  # in a different account from the fleet's primary — so such a zone can never
  # share this host's tunnel; it needs its own connector again. See
  # docs/private-home-modules.md.

  local.firmwareProvisioning.files = {
    # Connector token (`TUNNEL_TOKEN=<token>`). REQUIRED — the connector cannot start
    # without it, so the install unit fails (and blocks the connector) when there is
    # genuinely no token to install. That is still true and still correct.
    #
    # WHAT CHANGED, and why the old wording here was dangerously wrong: it read
    # "fails (and blocks the connector) if it is absent" as if absence were the only
    # way to fail. An UNREADABLE firmware partition failed it too — via
    # RequiresMountsFor, as a DEPENDENCY failure, which no Restart= can retry — and
    # `requiredBy` then turned that into a PERMANENT loss of the only route in. The
    # connector's own module is explicitly built to survive a missing token
    # (Restart=on-failure, so a late plant self-heals without a rebuild); a hard
    # Requires= on a non-restarting oneshot silently overrode that design.
    #
    # `cache = true` is what makes `required = true` safe to keep: the last token that
    # installed cleanly is kept OFF this partition, so a FAT mount that stops working
    # degrades to "install from cache" instead of "no way in". The unit still fails
    # loudly on a Pi that was never provisioned, which is the case requiredBy is for.
    cloudflared-token = {
      source = "cloudflared-token";
      target = "/run/cloudflared-token";
      required = true;
      cache = true;
      before = [ "cloudflared-connector.service" ];
      requiredBy = [ "cloudflared-connector.service" ];
    };
    # Wi-Fi so a headless nixpi (no LAN/keyboard/monitor) associates and reaches
    # nixpi.kattakath.com from first boot. Plant a standard wpa_supplicant.conf that
    # carries `country=` (the Pi 4 radio is rfkill-blocked without a regulatory
    # domain) and a `network={ ssid=…; psk=… }` block. OPTIONAL: absent ⇒ the units
    # skip cleanly, leaving LAN-only (eth0 stays DHCP as a fallback). The Pi 4
    # brcmfmac driver + 43455 firmware/NVRAM already ship in the closure; only the
    # credentials are planted.
    wifi = {
      source = "wpa_supplicant.conf";
      target = "/run/wpa_supplicant-firmware.conf";
      before = [ "supplicant-wlan0.service" ];
      postInstall = "${pkgs.util-linux}/bin/rfkill unblock wifi || true";
    };
    # The heartbeat monitor's ping URL — one line, no trailing newline needed.
    #
    # OPTIONAL (`required = false`, the default) ON PURPOSE, and this is the whole
    # argument: aborting would brick a live server over a MONITORING credential,
    # which is the inverse of the failure the heartbeat exists to prevent. A Pi
    # flashed without it boots, serves, and does not heartbeat — which reads as "not
    # verified healthy", not "down". A fresh flash therefore alerts until the URL is
    # planted, and that is correct rather than a bug. Plant it in the same step as
    # the connector token if you want them to arrive together.
    #
    # NOT cached (`cache = false`, the default). The connector token caches because
    # losing it makes the host UNREACHABLE; losing this one merely stops the
    # heartbeat, and the capsule's own guidance is to leave caching off for a file
    # whose absence only degrades a feature. A second copy of a credential on disk
    # has to earn itself.
    #
    # No `before`/`requiredBy`: the consumer is a TIMER, not a boot-critical service,
    # so ordering buys nothing and `requiredBy` is precisely the mistake the
    # connector-token comment above records.
    heartbeat-url = {
      source = "heartbeat-url";
      target = "/run/heartbeat-url";
    };
  };

  # The dead man's switch. Pings only when a local self-test passes, so the ABSENCE
  # of a ping is the alert — and if userspace dies, systemd timers do not fire, so
  # absence is exactly what the 2026-09-23 outage would have produced.
  #
  # Complements the Cloudflare tunnel-health alert rather than duplicating it: that
  # one fires when the tunnel dies (which covers everything that kills userspace),
  # this one covers what leaves the tunnel UP — Caddy dead, rootfs read-only.
  # Port 80 is the one globally-open TCP port on this host (Caddy's origin), so the
  # loopback probe matches what the firewall already admits.
  local.serviceHeartbeat = {
    enable = true;
    urlFile = "/run/heartbeat-url";
    httpPort = 80;
    # NAMED units, not a blanket `is-system-running`. This host legitimately carries
    # a failing `mnt-storage.mount` — two USB sticks declared `nofail` on purpose —
    # so a blanket `degraded` check would alert forever and train everyone to ignore
    # the heartbeat. These two are the ones whose death means "not serving":
    # cloudflared is the only remote path in, Caddy serves the one hosted site.
    requireUnits = [
      "caddy.service"
      "cloudflared-connector.service"
    ];
  };

  # Wi-Fi consumer: associate wlan0 from the planted config; dhcpcd
  # (networking.useDHCP) then leases it.
  #
  # upstream option nixpkgs.networking.supplicant exists → using it
  # (nixos/modules/services/networking/supplicant.nix — `configFile.path` at
  # :108, the generated unit at :63-90, instantiation `supplicant-<iface>` at
  # :250, and a udev rule at :263 that adds SYSTEMD_WANTS when the interface
  # appears). This replaced a hand-written systemd unit whose ExecStart spelled
  # out `wpa_supplicant -c … -i wlan0` itself.
  #
  # WHAT UPSTREAM ADDS that the hand-rolled unit did not have: `bindsTo` + `after`
  # on the wlan0 DEVICE unit (sys-subsystem-net-devices-wlan0.device, :36-44 and
  # :68-70). The old unit had no device relationship at all — it raced the
  # brcmfmac probe and relied on Restart=on-failure to eventually win. It also
  # gets `-s` (syslog), `before = network.target`, and the dbus/systemPackages
  # wiring (:246-248) for free.
  #
  # THREE OVERRIDES ARE LOAD-BEARING, not preference:
  #   1. ConditionPathExists — upstream is UNCONDITIONALLY `wantedBy
  #      multi-user.target` (:67). Without this, a Pi flashed with no Wi-Fi
  #      credentials starts a supplicant with a missing -c file and restart-loops
  #      forever. The whole point of the firmware-planting design is that an
  #      absent conf skips cleanly and the host stays LAN-only.
  #   2. after/wants on firmware-file-wifi.service — the conf is COPIED off the
  #      FAT firmware partition at boot; upstream cannot know that.
  #   3. Restart=on-failure/RestartSec — upstream sets only ExecStart
  #      (:83), no restart policy.
  # All three merge cleanly: upstream declares no unitConfig and no Restart.
  networking.supplicant."wlan0".configFile.path = "/run/wpa_supplicant-firmware.conf";

  systemd.services."supplicant-wlan0" = {
    unitConfig.ConditionPathExists = "/run/wpa_supplicant-firmware.conf";
    after = [ "firmware-file-wifi.service" ];
    wants = [ "firmware-file-wifi.service" ];
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # ── Make a corrupt rootfs FAIL LOUD, and actually get checked ───────────────
  # WRITTEN AFTER IT HAPPENED, 2026-10-02. This host served for 23 HOURS on an
  # ext4 rootfs that was corrupt from its FIRST MOUNT, and nothing in this repo
  # noticed. What the card reported once someone finally looked:
  #
  #   Filesystem state:      clean with errors
  #   Last checked:          Tue Jan  1 00:00:00 1980     <- NEVER fsck'd, not once
  #   FS Error count:        82
  #   First error time:      Thu Jan  1 00:00:05 1970     <- epoch+5s = FIRST BOOT
  #   First error function:  ext4_validate_block_bitmap   EFSCORRUPTED
  #   Errors behavior:       Continue
  #
  # TWO INDEPENDENT KNOBS WERE WRONG, and each defeated the other's protection.
  #
  # 1. `fsck.repair=yes` WAS ALREADY SET AND INERT. It arrived from
  #    raspberry-pi-nix's sd-image module (declared below since that input left)
  #    and says what to do IF a check runs — it
  #    cannot cause one. systemd only fsck's a filesystem it believes is dirty, and
  #    this one marks itself `clean with errors`, so the check was skipped on every
  #    boot for the card's entire life. A knob that looks like protection and is
  #    not. `fsck.mode=force` is what makes it run.
  #
  #    It costs a check on every boot — slower, and worth it on a host whose only
  #    recovery path is a 40-minute reflash with hands on the hardware.
  #
  # 2. `Errors behavior: Continue` let 82 errors accumulate SILENTLY. ext4's
  #    default is to carry on and log, which is why a damaged filesystem kept
  #    serving a website while `/mnt` was already unreadable. `errors=remount-ro`
  #    makes the next error LOUD: the filesystem goes read-only, Caddy fails,
  #    `local.serviceHeartbeat`'s rootfs-writable test stops pinging, and the
  #    absence of that ping is the alert. Minutes instead of a day.
  #
  #    Chosen over `errors=panic` deliberately: a panic reboots into a host with no
  #    console, which is the state this fleet cannot recover from remotely.
  #    Read-only keeps SSH and the LAN path alive so the host can still be reached
  #    and read.
  #
  # Both are DECLARATIVE here on purpose. `boot.kernelParams` is what
  # generic-extlinux-compatible renders into each generation's extlinux.conf
  # APPEND line (raspberry-pi-nix rendered it into cmdline.txt), so this survives
  # a reflash — unlike the hand-edit that was needed to recover this incident.
  #
  # fsck.repair=yes and the two consoles were raspberry-pi-nix DEFAULTS (its
  # sd-image/default.nix and rpi/default.nix); nixos-hardware's raspberry-pi/4
  # sets no kernel params, so they are declared here or lost. Its root=PARTUUID,
  # rootwait and init=/sbin/init are NOT carried: stage-1 mounts / by label and
  # extlinux passes the generation's own init=.
  boot.kernelParams = [
    "fsck.mode=force"
    "fsck.repair=yes"
    "console=serial0,115200n8"
    "console=tty1"
  ];
  fileSystems."/".options = [ "errors=remount-ro" ];

  # ── Extra bulk storage ──────────────────────────────────────────────────────
  # Two USB flash sticks combined into ONE ~18 GB btrfs volume (single data
  # profile ⇒ usable capacity is the SUM of both devices; NO redundancy — either
  # stick dying loses the whole volume). Mounted at /mnt/storage. Both sticks
  # passed an f3 write/read of the whole volume on 2026-10-18 (17.78 GB OK, 0 lost)
  # — checked because this host's SD card turned out counterfeit.
  #
  # SAFETY (nixpi is headless; its ingresses are the tunnel and the LAN sshd):
  # `nofail` + a short device timeout mean a dead, corrupt, or unplugged stick can
  # NEVER block boot. The Pi always comes up — and both ingresses with it — even if
  # the volume is absent, so a failed USB mount can't cause a reflash-style lockout.
  # The volume is referenced by btrfs LABEL / by-id, never by sdX node, because
  # USB enumeration order is not stable across reboots (sda/sdb can swap).
  #
  # ONE-TIME format (wipes both drives), done out-of-band once after this deploys:
  #   sudo mkfs.btrfs -f -L nixpi-storage -d single -m single \
  #     /dev/disk/by-id/usb-SanDisk_Cruzer_Blade_2004452693051B00F0C6-0:0 \
  #     /dev/disk/by-id/usb-SanDisk_Cruzer_Spark_4C530000040815117535-0:0
  boot.supportedFilesystems = [ "btrfs" ];
  environment.systemPackages = [ pkgs.btrfs-progs ];

  fileSystems."/mnt/storage" = {
    device = "/dev/disk/by-label/nixpi-storage";
    fsType = "btrfs";
    options = [
      "nofail" # headless Pi: a missing/dead stick must never block boot
      "x-systemd.device-timeout=10s" # fail fast instead of hanging on an absent device
      "compress=zstd" # transparent compression — kinder to slow, low-endurance flash
      "noatime" # fewer metadata writes (endurance) on cheap USB flash
      # Name both members explicitly so btrfs assembles the multi-device volume
      # regardless of which sdX node udev happened to label first.
      "device=/dev/disk/by-id/usb-SanDisk_Cruzer_Blade_2004452693051B00F0C6-0:0"
      "device=/dev/disk/by-id/usb-SanDisk_Cruzer_Spark_4C530000040815117535-0:0"
    ];
  };

  # ── Audiobookshelf (LAN only) ───────────────────────────────────────────────
  # Upstream module, left at its defaults on purpose: it binds 127.0.0.1:8000 and
  # keeps its DATABASE (CONFIG_PATH) in /var/lib/audiobookshelf — on the SD card's
  # root partition, which sits inside the card's REAL capacity (the counterfeit
  # region is the unused p3). The books and the bulky, regenerable METADATA
  # (covers, logs, cache, backups) live on the USB volume — see `environment` below.
  #
  # No new firewall port: Caddy's `http://nixpi.local` vhost below proxies to the
  # loopback listener over :80, which is already open. Phones away from home would
  # need a tunnel route behind Access (infra/), a separate change.
  services.audiobookshelf.enable = true;

  # The library directory is created by the service itself, AFTER the mount, not
  # by tmpfiles: /mnt/storage is `nofail`, so local-fs.target does not wait for it
  # and a tmpfiles rule would race it and land on the SD card under the mount
  # point. RequiresMountsFor also keeps the server down while the volume is
  # missing, rather than letting an upload fill the SD card instead.
  systemd.services.audiobookshelf = {
    unitConfig.RequiresMountsFor = "/mnt/storage";
    # Parents are listed BEFORE their children: `install -d` creates missing parents
    # as root 0755, which would lock the service out of adding its own siblings.
    serviceConfig.ExecStartPre =
      map (d: "+${pkgs.coreutils}/bin/install -d -m 2775 -o audiobookshelf -g audiobookshelf ${d}")
        [
          "/mnt/storage/audiobooks"
          "/mnt/storage/audiobookshelf"
          "/mnt/storage/audiobookshelf/metadata"
          "/mnt/storage/audiobookshelf/metadata/backups"
          "/mnt/storage/audiobookshelf/metadata/items"
          "/mnt/storage/audiobookshelf/metadata/authors"
          "/mnt/storage/audiobookshelf/metadata/logs"
        ];
    # The metadata root re-roots items/, authors/, logs/, cache/ and streams/ (index.js;
    # every manager joins its dir onto global.MetadataPath). It MUST be the
    # `--metadata` FLAG: nixpkgs' bin/audiobookshelf launcher sets
    # `METADATA_PATH="$metadata"` itself (default `$(pwd)/metadata`), clobbering any
    # unit Environment= — measured 2026-10-18, the env var reached the unit and the
    # startup log still said /var/lib. The module has no extra-args option (its
    # ExecStart passes only --host/--port), hence mkForce, rebuilt from its own cfg.
    serviceConfig.ExecStart =
      let
        cfg = config.services.audiobookshelf;
      in
      lib.mkForce "${cfg.package}/bin/audiobookshelf --host ${cfg.host} --port ${toString cfg.port} --metadata /mnt/storage/audiobookshelf/metadata";
    # BACKUP_PATH stays an env var — the launcher passes it through untouched. It is
    # needed on top of --metadata: first-run setup PERSISTS backupPath in the
    # database, so a new metadata root alone leaves backups where they were; the env
    # var overrides the stored value and locks the UI field (ServerSettings.js,
    # `backupPathEnvSet`).
    environment.BACKUP_PATH = "/mnt/storage/audiobookshelf/metadata/backups";
  };
  # Group membership so books can be copied in over SSH (`scp … nixpi.local:/mnt/storage/audiobooks/<Author>/<Title>/`;
  # the Mac's /usr/bin/rsync is openrsync, which rejects `--mkpath`).
  users.users.${loginName}.extraGroups = [ "audiobookshelf" ];

  # Static landing page, served by upstream Caddy sitting BEHIND the Cloudflare
  # tunnel (tunnel → Caddy on :80). Future services add more `virtualHosts` here
  # rather than a new tunnel per-service; no public IP / port-forward is needed.
  # Widening this list fails `nixpi-security-posture` (modules/parts/checks.nix).
  networking.firewall.allowedTCPPorts = [ 80 ]; # 443 omitted: TLS terminates at Cloudflare's edge
  services.caddy = {
    enable = true;
    # One vhost per `hostedSites` entry (single source in modules/parts/identity.nix). Address each as
    # `http://<domain>` so Caddy serves plain HTTP and DISABLES automatic HTTPS — TLS
    # terminates at Cloudflare's edge, and an http→https redirect would loop back
    # through the tunnel forever. www is a 301 edge redirect (infra/cloudflare/nixpi-tunnel.nix),
    # not a vhost. Adding a site = one entry in modules/parts/identity.nix's hostedSites.
    virtualHosts =
      lib.listToAttrs (
        map (site: {
          name = "http://${site.domain}";
          value.extraConfig = ''
            root * ${site.root}
            file_server

            # Cache policy. Caddy set no Cache-Control, so Cloudflare applied its default
            # 4h Browser Cache TTL to css/js — which let a stale stylesheet orphan freshly
            # deployed markup (the mobile-nav regression). Cloudflare honours these origin
            # headers instead: by default everything revalidates (cheap ETag 304s) so a
            # deploy is picked up immediately; content-stable media caches for a day.
            # (Content-hash fingerprinting for long-immutable css/js caching is a later step.)
            @static path *.woff2 *.svg *.png *.ico *.webmanifest *.jpg *.webp
            @mutable not path *.woff2 *.svg *.png *.ico *.webmanifest *.jpg *.webp
            header @mutable Cache-Control "no-cache"
            header @static Cache-Control "public, max-age=86400"
          '';
        }) hostedSites
      )
      // {
        # LAN-only: the tunnel's ingress never forwards a `nixpi.local` Host header.
        # Caddy's reverse_proxy upgrades Audiobookshelf's websocket on its own.
        "http://nixpi.local".extraConfig = ''
          reverse_proxy ${config.services.audiobookshelf.host}:${toString config.services.audiobookshelf.port}
        '';
      };
  };
}
