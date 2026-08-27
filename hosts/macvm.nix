# macvm — aarch64-darwin guest (sandbox analogue of nixvm).
#
# Host: Apple Virtualization.framework via Tart (IPSW create).
#   docs/macvm-tart-runbook.md  —  nix run .#macvm-tart-*
# Disk under ~/.tart/ — never in this flake.
#
# Identity: same operator (`ismail`) as every other host — no `identity` override
# in flake.nix. The guest login account MUST be `ismail`. Activate *inside* the
# VM (app handles sudo + root HOME):
#   nix run github:kattakath/nix-config#macvm
# Optional Grok CLI (once, not Homebrew): curl -fsSL https://x.ai/cli/install.sh | bash
{
  loginName,
  lib,
  pkgs,
  ...
}:
let
  # Operator ed25519 public key — sole network login credential (same as nixpi/nixvm).
  operatorSshKey = import ../secrets/operator-key.nix;

  # Single source for this guest's home path — everything below reads it instead
  # of re-typing "/Users/${loginName}".
  home = "/Users/${loginName}";

  # Clipboard sync + `tart exec`/`tart ip --resolver=agent` RPC (packages/tart-guest-agent.nix).
  # Apple's Virtualization.framework does NOT sync the pasteboard on its own for a
  # macOS guest — despite docs/macvm-tart-runbook.md's old "Tart enables clipboard
  # sharing by default" claim, clipboard needs this agent's in-house SPICE vdagent
  # (`--run-vdagent`, bundled into `--run-agent` alongside `--run-rpc`) actually
  # running inside the guest. Neither nixpkgs nor a Homebrew tap carries it, hence
  # the standalone fetchurl package.
  tartGuestAgent = pkgs.callPackage ../packages/tart-guest-agent.nix { };

  # BTM wrapper (fleet-wide nix-<activity> convention, modules/darwin/core.nix) —
  # ProgramArguments[0] must not be the raw vendored binary basename.
  nixTartGuestAgent = pkgs.writeShellScriptBin "nix-tart-guest-agent" ''
    exec ${lib.getExe tartGuestAgent} --run-agent
  '';

  # Single ensure script for launchd + activation (path shape = core.nix screengrabDir).
  # Tart mounts host Screengrab as /Volumes/My Shared Files/Screengrab (VirtioFS).
  screengrabShare = "/Volumes/My Shared Files/Screengrab";
  screengrabLocal = "${home}/Pictures/Screengrab";
  nixScreengrabShare = pkgs.writeShellScriptBin "nix-screengrab-share" ''
    set -euo pipefail
    shared="${screengrabShare}"
    local="${screengrabLocal}"
    log() { echo "nix-screengrab-share: $*" >&2; }

    ensure_symlink() {
      /bin/mkdir -p "$(/usr/bin/dirname "$local")"
      if [ -L "$local" ]; then
        cur="$(/usr/bin/readlink "$local" || true)"
        if [ "$cur" = "$shared" ] && [ -d "$shared" ]; then
          return 0
        fi
        /bin/rm -f "$local"
      elif [ -d "$local" ]; then
        count="$(/usr/bin/find "$local" -mindepth 1 ! -name '.DS_Store' 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
        if [ "''${count:-0}" -eq 0 ]; then
          /bin/rm -rf "$local"
        else
          /bin/mv "$local" "''${local}.local-backup.$(/bin/date +%Y%m%d%H%M%S)"
          log "backed up non-empty local dir"
        fi
      elif [ -e "$local" ]; then
        /bin/mv "$local" "''${local}.local-backup.$(/bin/date +%Y%m%d%H%M%S)"
      fi
      /bin/ln -sfn "$shared" "$local"
      log "$local -> $shared"
    }

    if [ -d "$shared" ]; then
      ensure_symlink
      probe="$shared/.nix-screengrab-share-probe"
      if /bin/echo ok >"$probe" 2>/dev/null; then
        /bin/rm -f "$probe"
        log "ok (writable)"
      else
        log "WARNING — share present but not writable"
        exit 1
      fi
      exit 0
    fi

    if [ -L "$local" ] && [ ! -d "$local" ]; then
      /bin/rm -f "$local"
      log "removed dangling symlink (waiting for VirtioFS)"
    fi
    log "waiting for $shared (host: macvm-tart-start with Screengrab dir share)"
    exit 0
  '';
in
{
  imports = [ ../modules/darwin/core.nix ];

  nixpkgs.config.allowUnfree = true;

  # Stable identity for host-gated modules (no macos login openers / RAG stack).
  networking.hostName = "macvm";

  # Dock: always visible at bottom (core.nix: right + autohide). static-only
  # off so pinned apps stay when not running. Note: macOS may still hide the
  # Dock in *fullscreen* app spaces — that is OS UI, not autohide.
  system.defaults.dock = {
    autohide = lib.mkForce false;
    autohide-delay = lib.mkForce 0.0;
    orientation = lib.mkForce "bottom";
    static-only = lib.mkForce false;
    persistent-apps = [
      "/System/Applications/Utilities/Terminal.app"
      "/Applications/CapCut.app"
      "/Applications/WhatsApp.app"
      "/Applications/Opera.app"
    ];
  };

  # ---- SSH: host → guest over Tart shared net (bridge100 ≈ 192.168.64.0/24) --
  # Apple's sshd via services.openssh (Remote Login). Keys-only; authorized_keys
  # + host keys from nix-darwin. Host entrypoint: `nix run .#macvm-tart-ssh`.
  services.openssh = {
    enable = true;
    extraConfig = ''
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      PubkeyAuthentication yes
      PermitRootLogin no
    '';
  };

  # nix-darwin only bootstraps com.openssh.sshd when getremotelogin is Off, and
  # uses a one-shot path that can leave the job unloaded. If the job is missing,
  # load it with modern launchctl (append after launchd activation so plists exist).
  # Do not kickstart every switch — that drops live SSH sessions.
  system.activationScripts.launchd.text = lib.mkAfter ''
    if ! /bin/launchctl print system/com.openssh.sshd >/dev/null 2>&1; then
      echo "macvm: loading com.openssh.sshd" >&2
      /bin/launchctl enable system/com.openssh.sshd 2>/dev/null || true
      /bin/launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null \
        || /bin/launchctl load -w /System/Library/LaunchDaemons/ssh.plist 2>/dev/null \
        || echo "macvm: WARNING — could not load com.openssh.sshd" >&2
    fi
  '';

  # Best-effort Apple Command Line Tools *before* Homebrew (mkBefore on the
  # homebrew activation script). Never aborts switch: headless catalog install
  # can fail (no UI, wrong label, offline). GUI fallback: xcode-select --install.
  # macvm keeps brews empty so activation does not *require* CLT; this is for
  # ad-hoc brew formulae / local compiles after first boot.
  system.activationScripts.homebrew.text = lib.mkBefore ''
    clt_ok() {
      /usr/bin/xcode-select -p >/dev/null 2>&1 \
        && [ -d "$(/usr/bin/xcode-select -p 2>/dev/null)" ]
    }

    if clt_ok; then
      echo "macvm: Xcode CLT present ($(/usr/bin/xcode-select -p))" >&2
    else
      echo "macvm: Xcode CLT missing — best-effort softwareupdate install…" >&2
      # Touch marker so softwareupdate lists the CLT product (Apple installondemand).
      /usr/bin/touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress 2>/dev/null || true
      # Labels look like: "Command Line Tools for Xcode-16.2" (changes every OS).
      label="$(
        /usr/sbin/softwareupdate -l 2>/dev/null \
          | /usr/bin/sed -n 's/^[* ]*Label: \(Command Line Tools.*\)/\1/p' \
          | /usr/bin/head -n 1
      )"
      if [ -z "''${label:-}" ]; then
        # Older softwareupdate list format (star + product name).
        label="$(
          /usr/sbin/softwareupdate -l 2>/dev/null \
            | /usr/bin/grep -F 'Command Line Tools' \
            | /usr/bin/head -n 1 \
            | /usr/bin/sed -E 's/^[[:space:]]*\*[[:space:]]*//' \
            | /usr/bin/sed -E 's/^Label:[[:space:]]*//'
        )"
      fi
      if [ -n "''${label:-}" ]; then
        echo "macvm: installing via softwareupdate: $label" >&2
        # --agree-to-license is ignored on older hosts; never fail activation.
        /usr/sbin/softwareupdate -i "$label" --agree-to-license 2>/dev/null \
          || /usr/sbin/softwareupdate -i "$label" 2>/dev/null \
          || echo "macvm: WARNING — softwareupdate CLT install failed (non-fatal)" >&2
      else
        echo "macvm: WARNING — no CLT package in softwareupdate catalog (non-fatal)" >&2
        echo "macvm:   GUI once: xcode-select --install  (or accept the System popup)" >&2
      fi
      /bin/rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress 2>/dev/null || true
      if clt_ok; then
        echo "macvm: Xcode CLT ready ($(/usr/bin/xcode-select -p))" >&2
      else
        echo "macvm: Xcode CLT still missing — brew formulae may fail until installed" >&2
      fi
    fi
  '';

  # core.nix enables Application Firewall + stealth on the real Mac; that blocks
  # host→guest SSH on the shared bridge. Sandbox: leave the wall open.
  networking.applicationFirewall = {
    enable = lib.mkForce false;
    enableStealthMode = lib.mkForce false;
  };

  users.users.${loginName} = {
    name = loginName;
    inherit home;
    openssh.authorizedKeys.keys = [ operatorSshKey ];
  };

  # Passwordless sudo for the guest admin: host agents activate via
  # `nix run .#macvm-tart-ssh -- nix run …#macvm` (app escalates; no interactive TTY).
  # Acceptable on this sandbox — keys-only SSH on the shared net, not the real Mac.
  security.sudo.extraConfig = ''
    ${loginName} ALL=(ALL) NOPASSWD: ALL
  '';

  # ---- Per-host home-manager (sandbox trims) ---------------------------------
  home-manager.users.${loginName} = {
    # MCP gateway (~17 servers) is macos-only weight; disable agent + client wiring.
    services.mcpGateway.enable = false;
    # Stock wallpaper + Terminal so the VM is visually distinct from macos.
    local.desktopAesthetics.enable = false;
  };

  # Red accent = fullscreen-safe tell (wallpaper/Dock may be hidden).
  system.defaults.CustomUserPreferences.NSGlobalDomain = {
    AppleAccentColor = 0; # red
    AppleHighlightColor = "1.000000 0.733333 0.721569 Red";
  };

  # WireGuard CLI from nixpkgs (not Homebrew). Brew formulae need Xcode CLT;
  # a fresh Tart guest often has none, and a failed brew bundle aborts
  # activation *before* home-manager runs. Casks below are prebuilt binaries.
  # Official WireGuard.app is App Store–only (macos masApps); macvm has no Apple ID.
  environment.systemPackages = [ pkgs.wireguard-tools ];

  # Lean Homebrew set (framework in modules/darwin/homebrew.nix).
  homebrew = {
    brews = [ ];
    casks = [
      "opera"
      "whatsapp"
      "capcut"
      "iina"
      "google-chrome"
    ];
    # Always empty: macvm has no Apple ID / App Store login — any masApps entry
    # fails brew bundle and aborts activation. Official WireGuard.app is macos-only.
    masApps = { };
  };

  # ---- Host Screengrab via Tart VirtioFS ------------------------------------
  # Path shape matches core.nix screengrabDir; host attaches share with
  # `macvm-tart-start` (--dir=Screengrab:…). Rotation stays macos-only.
  # StartInterval re-heals after boot race / remount; dangling symlinks cleared.
  launchd.user.agents.nix-screengrab-share = {
    serviceConfig = {
      Label = "org.nixos.nix-screengrab-share";
      ProgramArguments = [ (lib.getExe nixScreengrabShare) ];
      RunAtLoad = true;
      StartInterval = 30;
      StandardOutPath = "${home}/Library/Logs/nix-screengrab-share.log";
      StandardErrorPath = "${home}/Library/Logs/nix-screengrab-share.log";
    };
  };

  # ---- Clipboard sync with the macos host (packages/tart-guest-agent.nix) ---
  # `--run-agent` = `--run-vdagent` (clipboard) + `--run-rpc` (`tart exec` /
  # `tart ip --resolver=agent` from the host). Must be a per-user LaunchAgent,
  # not a LaunchDaemon — pasteboard access needs a live GUI session (root has
  # none), matching cirruslabs' own reference tart-guest-agent.plist. KeepAlive
  # respawns it if the process dies; RunAtLoad starts it at login.
  launchd.user.agents.tart-guest-agent = {
    serviceConfig = {
      Label = "org.cirruslabs.tart-guest-agent";
      ProgramArguments = [ (lib.getExe nixTartGuestAgent) ];
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "${home}/Library/Logs/tart-guest-agent.log";
      StandardErrorPath = "${home}/Library/Logs/tart-guest-agent.log";
    };
  };

  system.activationScripts.postActivation.text = lib.mkAfter ''
    # Same ensure as the user agent (root can create the symlink).
    ${lib.getExe nixScreengrabShare} || true
    /usr/sbin/chown -h ${loginName}:staff ${lib.escapeShellArg screengrabLocal} 2>/dev/null || true

    # Residual macos-only login openers (open-mail / Slack / …) leave launchd
    # "enabled" ghosts after host-scoping to macos — they once auto-launched
    # Mail at login so it stuck on the Dock while running. Boot out + disable.
    uid="$(/usr/bin/id -u ${loginName} 2>/dev/null || true)"
    if [ -n "$uid" ]; then
      for lab in org.nixos.open-mail org.nixos.open-messages org.nixos.open-slack \
                 org.nixos.open-maccy org.nixos.open-docker; do
        /bin/launchctl bootout "gui/$uid/$lab" 2>/dev/null || true
        /bin/launchctl disable "gui/$uid/$lab" 2>/dev/null || true
      done
    fi
  '';
}
