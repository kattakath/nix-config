# Optional lightweight desktop for the nixvm dev VM — X11 + XFCE with passwordless
# autologin and QEMU/SPICE guest integration. Opt-in via `local.desktopVm.enable`;
# hosts/nixvm.nix enables it ONLY inside `virtualisation.vmVariant`, so the XFCE
# desktop materialises for the graphical `build-vm` / `nix run .#nixvm` path,
# while the base nixvm toplevel (which exists only as the build-vm eval substrate,
# see hosts/nixvm.nix) stays headless/minimal.
#
# XFCE is the VM-friendliest DE: it runs on X11 (renders on QEMU's virtio-gpu
# via the `modesetting` driver with no host GPU passthrough) and is light enough
# to stay responsive under emulation. Wayland is deliberately avoided — its
# QEMU display-driver story is fussier. Swap the DE by editing the two xfce lines
# below (e.g. `desktopManager.plasma6.enable`); as the sole enabled session it is
# auto-selected for autologin, so no `defaultSession` is needed.
{
  config,
  lib,
  pkgs,
  loginName,
  ...
}:
let
  cfg = config.local.desktopVm;
in
{
  # `local.*`, not `services.*`: this is a fleet-private aggregate, not an
  # upstream service. NixOS owns the `services.*` namespace, and a future
  # upstream `services.desktopVm` would collide with this declaration. Matches
  # the in-fleet convention already set by `local.folders`
  # (modules/darwin/user-folders.nix) and `local.wireguardConfigs`
  # (modules/home/wireguard-configs.nix). Renamed 2026-09-06.
  options.local.desktopVm.enable = lib.mkEnableOption "lightweight XFCE desktop + guest integration for the nixvm sandbox";

  config = lib.mkIf cfg.enable {
    # ---- tor-browser on aarch64-linux, from the ALPHA channel --------------
    # SCOPED ON PURPOSE: this overlay sits inside `mkIf cfg.enable`, and
    # `local.desktopVm.enable` is set ONLY inside hosts/nixvm.nix's
    # `virtualisation.vmVariant`. So it reaches neither `nixpi` (the live Pi,
    # whose closure must stay lean) nor `macos`, nor even nixvm's base toplevel.
    #
    # WHY an overlay at all: the pinned nixpkgs' tor-browser THROWS at eval on
    # aarch64-linux — `src = sources.${stdenv.hostPlatform.system} or (throw
    # "unsupported system: ...")` — because upstream STABLE (15.0.23 here) ships
    # no aarch64 Linux tarball. `tor-browser-bundle-bin` is a hard alias throw,
    # not an alternative. nixpkgs will not package the aarch64 build until
    # 16.0 goes stable (NixOS/nixpkgs#491286, still open), so there is no
    # upstream option, package or flake to prefer — this is the one lane.
    #
    # WHY overrideAttrs and NOT `.override { sources = ...; }`: `sources` is a
    # `let` binding inside package.nix, not a function argument, so it is not
    # overridable. Replacing `src` directly is the only reachable surface — and
    # it means `meta.platforms` (`lib.attrNames sources`) must be widened by
    # hand or nixpkgs refuses the host platform.
    #
    # THE ALPHA MOVED torrc-defaults. 16.0a13's tarball has
    # `TorBrowser/Tor/torrc-defaults` and `TorBrowser/Tor/geoip{,6}` where 15.x
    # had `TorBrowser/Data/Tor/...` (verified by `tar tf` on the fetched
    # tarball). The stock buildPhase's `--replace-fail` would abort on the
    # missing file, so the path prefix is rewritten in the phase text — one
    # substitution covers all four uses (substituteInPlace, the
    # torrc-defaults_path lockPref, and both GeoIP lines).
    #
    # Everything else in that derivation is arch-generic (autoPatchelfHook +
    # a makeWrapper LD_LIBRARY_PATH), which is why this works at all.
    #
    # KNOWN COSMETIC ROT: `meta.changelog` is baked from the let-bound 15.0.x
    # version and still points at the maint-15.0 branch.
    #
    # BUMPING: alpha releases are short-lived and dist.torproject.org keeps only
    # the current one, so a stale pin here becomes a 404 fetch. Re-point version
    # + hash from https://dist.torproject.org/torbrowser/ when that happens, and
    # DELETE this whole block once nixpkgs ships 16.0 stable with aarch64.
    nixpkgs.overlays = [
      (_final: prev: {
        tor-browser = prev.tor-browser.overrideAttrs (old: {
          version = "16.0a13";
          src = prev.fetchurl {
            urls = [
              "https://dist.torproject.org/torbrowser/16.0a13/tor-browser-linux-aarch64-16.0a13.tar.xz"
              "https://archive.torproject.org/tor-package-archive/torbrowser/16.0a13/tor-browser-linux-aarch64-16.0a13.tar.xz"
            ];
            hash = "sha256-TboDPnxfsA+NI/tUEqCCXNE67lZdMfyEsynQknrGzPc=";
          };
          buildPhase =
            builtins.replaceStrings [ "TorBrowser/Data/Tor/" ] [ "TorBrowser/Tor/" ]
              old.buildPhase;
          meta = old.meta // {
            platforms = old.meta.platforms ++ [ "aarch64-linux" ];
          };
        });
      })
    ];

    # X11 + XFCE. modesetting binds QEMU's virtio-gpu with no host GPU needed.
    services.xserver = {
      enable = true;
      desktopManager.xfce.enable = true;
      displayManager.lightdm.enable = true;

      # ONE OF THREE DISPLAY LAYERS — hosts/nixvm.nix's
      # `virtualisation.resolution` block carries the full derivation and the
      # measurements. Short version: qemu's Cocoa UI divides the framebuffer by
      # the Mac's Retina factor of 2 (ui/cocoa.m:503) and multiplies back for
      # the framebuffer (:564-565), so one guest pixel is one Mac DEVICE pixel
      # at every resolution.
      #
      # THAT IS WHY 192 IS NOT TIED TO THE RESOLUTION, and why it did not change
      # when the mode dropped from 2880x1800 to 1920x1200 (2026-10-06). A 12pt
      # font at dpi D occupies 12*D/72 device pixels; native macOS puts 12pt at
      # 32 device pixels on a 2x screen, so D = 192 regardless of the mode. The
      # resolution buys desktop AREA, not text size. Scaling DPI with the
      # resolution is the intuitive move and it is wrong — it under-sizes text.
      #
      # It lives HERE rather than in hosts/nixvm.nix because this module
      # already owns the whole `services.xserver` block and is gated on
      # `local.desktopVm.enable`, which only nixvm's vmVariant sets — so the
      # knob sits with the X server it configures and reaches nothing else.
      #
      # 192 = 2 x Xorg's 96 dpi default. This covers the X server and anything
      # that reads its DPI; INDIVIDUAL APPS that still render small need the
      # one remaining lever, which is MANUAL — XFCE Settings -> Appearance ->
      # Fonts -> Custom DPI, or `xfconf-query -c xsettings -p /Xft/DPI -s 192`.
      # There is no declarative per-key xfconf surface at this pin: nixpkgs'
      # xfce.nix only flips `programs.xfconf.enable`.
      dpi = 192;

      # ---- NO LOCKSCREEN. THIS IS A LOCKOUT TRAP, NOT A PREFERENCE ----------
      # XFCE's screensaver is ON by default upstream
      # (nixos/modules/services/x11/desktop-managers/xfce.nix:79-83,
      # `default = true`), which installs `xfce4-screensaver` (:166) AND sets
      # `security.pam.services.xfce4-screensaver.unixAuth = cfg.enableScreensaver`
      # (:249). That PAM line is what makes the unlock prompt demand a Unix
      # password.
      #
      # THE TRAP: autologin (services.displayManager.autoLogin, below) + a
      # PAM-backed locker + NO PASSWORD. Nothing in modules/nixos/ sets
      # hashedPassword, initialPassword or mutableUsers for this account, so the
      # guest logs itself in and then holds no credential it could unlock with.
      # Once that screen appears with `ismail` prefilled, the session is
      # UNPASSABLE — the only exit is killing QEMU from the host, which is a
      # power-pull for a guest whose root qcow2 is DURABLE (hosts/nixvm.nix).
      # Measured the hard way on 2026-10-06.
      #
      # TWO WAYS OUT, for whoever reads this next. Do not flip the option back
      # on without picking one:
      #   1. Keep the locker disabled — CHOSEN. A hand-booted local VM in a
      #      QEMU window on an already-locked Mac gains nothing from a second
      #      lock screen.
      #   2. If a locker is ever genuinely wanted, SET A PASSWORD FIRST
      #      (users.users.<n>.hashedPassword). A locker without a credential is
      #      not security, it is a one-way door.
      #
      # `security.sudo.wheelNeedsPassword = false` (modules/nixos/core.nix) is
      # UNRELATED and must stay — sudo is how the operator works in here.
      desktopManager.xfce.enableScreensaver = false;

      # SCREEN BLANKING / DPMS OFF TOO — and this one is the AGENT'S CALL, not
      # the operator's ask; object and delete these four lines if unwanted. A VM
      # has no battery to save, and a screen that blanks black looks exactly
      # like the lock screen above, which is the same user-facing problem.
      #
      # `serverFlagsSection` is the pinned option surface for this, not a shim:
      # grepped nixos/modules/services/x11/xserver.nix — it is a real option
      # (:705, types.lines) whose own EXAMPLE (:708-712) is these four lines.
      # There is no narrower upstream knob; no `services.xserver.blanking`
      # exists anywhere in the pinned nixos/modules.
      #
      # HONEST LIMIT: this zeroes the X SERVER's own timers. `xfce4-power-manager`
      # is still installed (xfce.nix:149, via powerManagement.enable = true, which
      # evaluates TRUE here) and can drive DPMS from its own settings, which no
      # declarative option at this pin reaches. If the screen still blanks, that
      # is the thing to look at — in its GUI, by hand.
      serverFlagsSection = ''
        Option "BlankTime" "0"
        Option "StandbyTime" "0"
        Option "SuspendTime" "0"
        Option "OffTime" "0"
      '';
    };

    # Boot straight into the session with no credential prompt — this VM is
    # hand-booted from a local QEMU window and is reachable from no network.
    # It is NOT a stateless sandbox: /home lives on the root qcow2, which is
    # created once and reused (see hosts/nixvm.nix), so that image is durable
    # unencrypted local state rather than a scratch buffer. autoLogin lives at
    # the top level in current nixpkgs (moved out of
    # services.xserver.displayManager). With XFCE as the sole session, nixpkgs
    # auto-selects it, so `defaultSession` is unnecessary.
    services.displayManager.autoLogin = {
      enable = true;
      user = loginName;
    };

    # Guest integrations: qemu-guest-agent (host<->guest control) and
    # spice-vdagent — CLIPBOARD ONLY.
    #
    # CORRECTED 2026-10-06. This comment used to claim spice-vdagent also gave
    # "auto display-resize when the QEMU window is resized". It does not, with
    # the `qemu-vdagent` chardev this VM uses (hosts/nixvm.nix's qemu.options).
    # Read in the pinned qemu 11.1.1 source, `ui/vdagent.c`:
    # `vdagent_chr_recv_msg` (:732) switches on exactly SIX message types —
    # `VD_AGENT_ANNOUNCE_CAPABILITIES` (:737) and the four
    # `VD_AGENT_CLIPBOARD{,_GRAB,_REQUEST,_RELEASE}` (:740-743) — and ends
    # `default: break;` (:748). `VD_AGENT_MONITORS_CONFIG` and
    # `VD_AGENT_DISPLAY_CONFIG` appear ONLY in the `msg_name[]` trace table
    # (:95, :98) and are never a case, so they fall through unhandled.
    #
    # CONSEQUENCE, stated plainly: dragging or fullscreening the QEMU window
    # will NEVER reflow the guest desktop. The guest keeps whatever mode Xorg
    # was given at start. That is precisely why the fix for a too-small desktop
    # is the declarative resolution/DPI pair above and in hosts/nixvm.nix, not
    # a resize gesture that nothing on either side implements.
    #
    # The per-session CLIENT (`spice-vdagent`, no trailing d) needs no wiring
    # here: the pinned services.spice-vdagentd module puts `pkgs.spice-vdagent`
    # in environment.systemPackages, that package ships
    # `etc/xdg/autostart/spice-vdagent.desktop`, config/system-path.nix links
    # `/etc/xdg` into the system profile unconditionally, and `xdg.autostart`
    # defaults to true — so xfce4-session starts it from XDG_CONFIG_DIRS.
    # Operator's tell inside the guest: `ps aux | grep spice-vdagent` shows BOTH
    # processes. Only one means the client did not start.
    services.qemuGuest.enable = true;
    services.spice-vdagentd.enable = true;

    # ---- AUDIO, GUEST HALF. The host half is hosts/nixvm.nix's qemu.options --
    # BOTH HALVES OR SILENCE, and a green build proves neither. This stack with
    # no QEMU audio device is silence (nothing to open); the device with no stack
    # is silence too. Fourth two-layer feature in this VM after the clipboard,
    # the display and SSH — the host file's audio comment carries that list.
    #
    # Nothing in this fleet configured audio before: `grep -rn
    # "pipewire\|pulseaudio\|rtkit" modules/ hosts/` returned ZERO hits, and
    # the guest had no card at all (`/proc/asound/cards` absent).
    #
    # `pipewire.service` shows as MASKED in a guest with this disabled — that is
    # NixOS's normal representation of `services.pipewire.enable = false` when
    # some package in the XFCE closure ships the units. It is not a fault and
    # nothing should be unmasked by hand.
    #
    # DO NOT reach for `hardware.pulseaudio`/`services.pulseaudio`: it is renamed
    # at this pin (mkRenamedOptionModule, pulseaudio.nix:95) and is mutually
    # exclusive with PipeWire's pulse emulation.
    #
    # NO HAND-ADDED xfce4-pulseaudio-plugin OR pavucontrol. xfce.nix:150-157 adds
    # BOTH automatically once `services.pipewire.pulse.enable` is true (it picks
    # xfce4-pulseaudio-plugin over xfce4-volumed-pulse because this is not a
    # noDesktop config). Verified in the built closure rather than assumed.
    #
    # rtkit grants realtime scheduling priority THROUGH POLKIT
    # (org.freedesktop.RealtimeKit1). That interacts with the credential-prompt
    # class above and comes out fine: the wheel-YES polkit rule in
    # hosts/nixvm.nix means the request is authorised without a challenge, so
    # this adds no new unanswerable prompt.
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      pulse.enable = true;
      wireplumber.enable = true;
    };
    security.rtkit.enable = true;

    # ---- THE CREDENTIAL-PROMPT CLASS. READ THIS BEFORE ADDING A PACKAGE -----
    # This VM autologins (above) and the account has NO PASSWORD — nothing in
    # modules/nixos/ sets hashedPassword, initialPassword or mutableUsers. So
    # ANY component that wants to store a secret, unlock a keyring, or
    # authenticate an action will prompt for a credential that CANNOT EXIST,
    # and a modal dialog with no valid answer is a dead end whose only exit is
    # killing QEMU from the host — a power-pull for a durable qcow2.
    #
    # It is a CLASS, not a list of bugs. Two instances hit so far, both from
    # upstream defaults nobody opted into:
    #   1. xfce4-screensaver  -> lock screen, no password to unlock.
    #      FIX SHAPE: turn the component off (enableScreensaver = false, above).
    #   2. gnome-keyring      -> Chromium found a Secret Service and asked to
    #      "Choose password for new keyring".
    #      FIX SHAPE: turn the component off AND make the consumer explicit,
    #      because auto-detection means the prompt returns the moment anything
    #      re-provides the service.
    #
    # WHEN ADDING A DESKTOP PACKAGE HERE, ask: can it prompt for a password,
    # PIN or passphrase? If yes, either disable it or configure it to a
    # credential-free mode. Grep the closure, not the option list — a package
    # that is absent cannot prompt, and a PAM stanza with no binary is inert.
    #
    #   3. polkit's auth agent -> `polkit_gnome` (XFCE installs it,
    #      xfce.nix:126-127) asks for a password on a privileged desktop
    #      action.
    #      FIX SHAPE: LEAVE IT ON and tell it not to challenge — a
    #      `security.polkit.extraConfig` rule returning YES for the wheel
    #      group, which MIRRORS the sudo posture already set by
    #      security.sudo.wheelNeedsPassword = false in modules/nixos/core.nix.
    #      It lives in hosts/nixvm.nix's `virtualisation.vmVariant`, NOT here,
    #      precisely because this module is reusable: another consumer enabling
    #      `local.desktopVm` must not silently inherit a security posture
    #      chosen for a disposable VM. The full rationale and its cost are at
    #      that code site.
    #
    # THAT THIRD FIX SHAPE IS THE LESSON. "Disable it" is the right reflex for
    # a locker or a keyring and the WRONG one for an authorisation component:
    # removing an auth agent does not make privileged actions succeed, it makes
    # them fail SILENTLY, with no dialog and no error to act on.
    #
    # upstream option services.gnome.gnome-keyring.enable exists -> using it
    # (xfce.nix:230 sets it `mkDefault true`, so a plain `false` here wins on
    # priority — verified by evaluating it, not assumed, so no mkForce needed).
    services.gnome.gnome-keyring.enable = false;

    # ---- OpenPGP: gpa + gpg-agent. NOT a fourth instance of the class above --
    # A GPG KEY PASSPHRASE PROMPT HAS A VALID ANSWER. That is the whole
    # distinction, and it is why this does not belong in the list above: the
    # locker, the keyring and the polkit agent all demanded the Unix password of
    # an account that HAS none. A passphrase is a credential the operator
    # deliberately sets at key generation, so the prompt is answerable and
    # wanted. Do not "fix" this by disabling the agent.
    #
    # gcr-3 COMES BACK, AND THAT IS ACCEPTED — NOT OVERLOOKED. Enabling the
    # agent pulls `pinentry-gnome3`, whose closure carries `gcr-3` + `libsecret`
    # (measured: 129 paths, gcr-3 = 1). gcr-3 left this VM with gnome-keyring
    # because the KEYRING DAEMON produced the unanswerable dialog — not because
    # the library is unwanted. As a pinentry dependency it renders an answerable
    # passphrase prompt, so it fails the test above and stays. (`gcr-4` was
    # already in the closure for unrelated reasons and never went anywhere.)
    # A hygiene pass that sees gcr-3 and removes it will break the only way to
    # type a passphrase in this desktop.
    #
    # NO `pinentryPackage` ASSIGNMENT ON PURPOSE. `xfce.nix:169` already sets
    # `programs.gnupg.agent.pinentryPackage = mkDefault pkgs.pinentry-gnome3`,
    # and it resolves to exactly that here (verified: `pinentryPackage.pname` is
    # `pinentry-gnome3` even with the agent still disabled). A redundant
    # assignment would only hide where the value comes from. NOTE
    # `pkgs.pinentry-gtk2` IS NOT AN OPTION — the attribute still exists in
    # `attrNames` but THROWS ("removed as it depended on the deprecated GTK2
    # engine"), so a probe that only lists names will wrongly report it present.
    # Measured alternatives, all GUI-capable: pinentry-qt 181 paths (+Qt),
    # pinentry-egui 22 paths (gcr-free, but unverified under XFCE);
    # pinentry-curses/-tty need a tty and cannot prompt in a desktop session.
    #
    # WHY gpa — MEASURED, both closures the same way, 2026-10-06:
    #   gpa       126 paths   avahi=1 openldap=1 gtk+3=1
    #   seahorse  145 paths   avahi=1 openldap=1 gtk+3=1 libsecret=1
    # The usual story that seahorse is heavy because of Avahi/OpenLDAP keyserver
    # lookups is WRONG — gpa carries both too (gpgme pulls them). gpa wins on
    # two measured grounds instead: 19 fewer paths, and it is not a libsecret
    # front-end. seahorse's reason to exist is browsing the Secret Service,
    # which is exactly what `gnome-keyring.enable = false` above removed, so
    # half of it would be dead here. `kleopatra` was rejected separately and
    # that one does stand on weight: KF6/Qt6 plus akonadi, which defaults to
    # MariaDB.
    #
    # THE OPERATOR'S SSH KEY IS NOT HIS PGP KEY, and cannot become one. A fresh
    # keypair is generated in the guest. There is no conversion path at this pin:
    # `pem2openpgp` is RSA-only (his key is ed25519), no `ssh2openpgp` binary
    # exists, and Sequoia's `sq` has no SSH-import subcommand. Do not copy the
    # SSH key anywhere.
    #
    # `~/.gnupg` LIVES ON THE DURABLE, UNENCRYPTED qcow2 (hosts/nixvm.nix), so
    # it survives reboots and DIES WITH A WIPE — and it is not encrypted at
    # rest. The operator must export/back up any key he cares about.
    programs.gnupg.agent.enable = true;

    # A couple of niceties so the desktop isn't bare on first boot. Both
    # browsers substitute for aarch64-linux, so neither is ever built on the
    # 1-CPU Linux builder. `chromium` and NOT `ungoogled-chromium`: ungoogled
    # patches out the Chrome Web Store and rewrites the Google search engine
    # into a "No Search" stub (both measured in modules/home/chromium.nix),
    # and nixpkgs enables Widevine only for plain chromium (common.nix:913) —
    # all three cut against a desktop whose point is signing into Google.
    # `opera` is not a choice at all: nixpkgs removed it 2025-05-19
    # (aliases.nix:1932), so the name throws at eval on every system.
    environment.systemPackages = with pkgs; [
      # OpenPGP GUI — key generation, signing, keyring browsing. Chosen over
      # seahorse and kleopatra on measured closures; see the gpg-agent block
      # above for both numbers and the reasoning.
      gpa
      # `--password-store=basic` is BELT AND BRACES with the keyring being off
      # above, and both are wanted. Chromium AUTO-DETECTS its backend: with no
      # Secret Service present it already falls back to plaintext, but the
      # moment anything re-provides one — a package added here, an upstream
      # default changing — the "Choose password for new keyring" dialog comes
      # straight back. The flag pins the behaviour instead of inferring it.
      #
      # NO UPSTREAM OPTION OWNS THIS. Grepped the pinned nixos/modules:
      # `programs.chromium` is POLICY-only (extraOpts / extraOptsRecommended /
      # initialPrefs write JSON into chromium/policies/, chromium.nix:166-188)
      # and `--password-store` is a command-line switch with no policy
      # equivalent. `commandLineArgs` exists only on `programs.google-chrome`
      # (google-chrome.nix:26), a different package. So the package override is
      # the lane — and unlike tor-browser at the top of this file, `.override`
      # IS reachable here: `commandLineArgs ? ""` is a real argument of
      # chromium's default.nix (:34), appended with `--add-flags` (:142).
      #
      # COST: this is a distinct derivation from the cached `chromium`, but
      # only the makeWrapper phase differs, so it is a cheap rebuild of the
      # wrapper rather than of the browser.
      (chromium.override { commandLineArgs = "--password-store=basic"; })
      firefox
      xfce4-terminal
      # Alpha-channel aarch64 build, supplied by the overlay at the top of this
      # module. Unlike the other two it does NOT substitute — the derivation
      # sets preferLocalBuild/allowSubstitutes=false — so it is built on
      # Determinate's native Linux builder on every store-image rebuild.
      tor-browser
    ];
  };
}
