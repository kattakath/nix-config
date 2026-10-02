# NixOS host for Raspberry Pi 4 (aarch64-linux) — the fleet's LIVE server.
# raspberry-pi-nix handles the kernel, firmware, and boot configuration.
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
  lib,
  pkgs,
  hostedSites,
  cloudflaredConnectorModule,
  firmwareSecretsModule,
  raspberryPiNix,
  ...
}:
{
  imports = [
    # The Pi's own hardware: kernel, firmware, boot config and the sd-image
    # builder, from the pinned raspberry-pi-nix input threaded through mkNixos
    # specialArgs (modules/parts/compose.nix). Owned HERE so that nix-config
    # builds this host standalone and the private flake never has to name them.
    raspberryPiNix.nixosModules.raspberry-pi
    raspberryPiNix.nixosModules.sd-image
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

  # NixOS defaults to a VOLATILE journal (wiped on reboot). The uplink-watchdog's
  # probe/escalate/restore trail is the best timestamp source for dating a router
  # outage (nixpi's own clock, unlike the Rogers gateway's ~1h-off log) — but only
  # if it survives a reboot that a bad enough power event on the shared circuit
  # could also cause on nixpi itself.
  services.journald.settings.Journal.Storage = "persistent";

  networking.hostName = "nixpi";

  # nixpkgs enables systemd stage-1 by default (boot.initrd.systemd.enable), and
  # its TPM2 support (nixos/modules/system/boot/systemd/tpm2.nix) forces the
  # `tpm-tis` + `tpm-crb` kernel modules into boot.initrd.availableKernelModules.
  # The raspberry-pi-nix `linux-rpi` kernel builds neither as a loadable module,
  # and makeModulesClosure treats availableKernelModules as REQUIRED root modules
  # (boot.initrd.allowMissingModules defaults false) — so the missing module is a
  # FATAL `modprobe: Module tpm-crb not found`, failing linux-rpi-*-modules-shrunk.
  # The Pi 4 has no TPM, so disable initrd TPM2 support at the source (removes
  # both modules).
  boot.initrd.systemd.tpm2.enable = lib.mkForce false;

  # CONFIRMED BOOT FIX: use the SCRIPTED (bash) initrd, not systemd-initrd.
  # nixpkgs enables systemd stage-1 (boot.initrd.systemd.enable) by default, but on
  # the raspberry-pi-nix `linux-rpi` kernel it HANGS stage-1 mounting the real root
  # at /sysroot (the Pi never reaches stage-2 / a login). The classic scripted
  # initrd mounts /sysroot and hands off reliably on this kernel, so force it off.
  # mkForce because nixpkgs sets the default to true; keep this OFF forever — a
  # config that reintroduces systemd-initrd will not reboot on this hardware.
  boot.initrd.systemd.enable = lib.mkForce false;

  # Allow unfree packages (e.g. `claude-code` in the shared HM profile).
  nixpkgs.config.allowUnfree = true;

  networking.useDHCP = true;

  raspberry-pi-nix = {
    board = "bcm2711";
  };

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
  # 1. `fsck.repair=yes` WAS ALREADY SET AND INERT. It arrives from
  #    raspberry-pi-nix's sd-image module and says what to do IF a check runs — it
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
  # raspberry-pi-nix renders into cmdline.txt (verified: the evaluated list matched
  # the live card byte for byte), so this survives a reflash — unlike the hand-edit
  # that was needed to recover this incident.
  boot.kernelParams = [ "fsck.mode=force" ];
  fileSystems."/".options = [ "errors=remount-ro" ];

  # ── Extra bulk storage ──────────────────────────────────────────────────────
  # Two USB flash sticks combined into ONE ~18 GB btrfs volume (single data
  # profile ⇒ usable capacity is the SUM of both devices; NO redundancy — either
  # stick dying loses the whole volume). Mounted at /mnt/storage.
  #
  # SAFETY (nixpi is remote-only, reachable ONLY via the tunnel): `nofail` + a
  # short device timeout mean a dead, corrupt, or unplugged stick can NEVER block
  # boot. The Pi always comes up — and the tunnel with it — even if the volume is
  # absent, so a failed USB mount can't cause the reflash-style remote lockout.
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
      "nofail" # remote-only Pi: a missing/dead stick must never block boot
      "x-systemd.device-timeout=10s" # fail fast instead of hanging on an absent device
      "compress=zstd" # transparent compression — kinder to slow, low-endurance flash
      "noatime" # fewer metadata writes (endurance) on cheap USB flash
      # Name both members explicitly so btrfs assembles the multi-device volume
      # regardless of which sdX node udev happened to label first.
      "device=/dev/disk/by-id/usb-SanDisk_Cruzer_Blade_2004452693051B00F0C6-0:0"
      "device=/dev/disk/by-id/usb-SanDisk_Cruzer_Spark_4C530000040815117535-0:0"
    ];
  };

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
    virtualHosts = lib.listToAttrs (
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
    );
  };
}
