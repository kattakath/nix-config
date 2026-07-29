# macvm — UTM aarch64-darwin guest (sandbox analogue of nixvm).
#
# Persona: `aloshy` (mkDarwin `identity` override in flake.nix). The guest login
# account MUST be that user. Activate *inside* the VM:
#   sudo nix run github:kattakath/nix-config#macvm
#   sudo darwin-rebuild switch --flake .#macvm
#
# Host-side UTM + SSH: docs/macvm-utm-runbook.md (`nix run .#macvm-utm-*`).
# Optional Grok CLI (once, not Homebrew): curl -fsSL https://x.ai/cli/install.sh | bash
{
  userName,
  lib,
  pkgs,
  ...
}:
let
  # Operator ed25519 public key — sole network login credential (same as nixpi/nixvm).
  operatorSshKey = import ../secrets/operator-key.nix;

  # UTM macOS guest tools (spice-vdagent) — clipboard sharing host↔guest when
  # both are macOS 15+ and Virtualization → Clipboard Sharing is on in UTM.
  # Official pkg from utmapp/vd_agent (same bits as “Install Guest Tools” CD).
  # Bump version + hash together when UTM ships a new release.
  spiceVdagentVersion = "0.22.1";
  spiceVdagentPkg = pkgs.fetchurl {
    url = "https://github.com/utmapp/vd_agent/releases/download/spice-vdagent-${spiceVdagentVersion}-macOS/spice-vdagent-${spiceVdagentVersion}.pkg";
    hash = "sha256-x1iz/0PpqSCnhZH1NRTZl/r8r3prjYZOVVuB/d7eSAk=";
  };

  # Single ensure script for launchd + activation (path shape = core.nix screengrabDir).
  screengrabShare = "/Volumes/My Shared Files/Screengrab";
  screengrabLocal = "/Users/${userName}/Pictures/Screengrab";
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
    log "waiting for $shared (host: macvm-utm-share-screengrab + restart guest if needed)"
    exit 0
  '';
in
{
  imports = [ ../modules/darwin/core.nix ];

  nixpkgs.config.allowUnfree = true;

  # Stable identity for host-gated modules (no macos login openers / RAG stack).
  networking.hostName = "macvm";

  # Dock: bottom (core.nix uses right). core.nix also sets static-only = true
  # (running apps only) — force off so pinned apps stay when not running.
  system.defaults.dock = {
    orientation = lib.mkForce "bottom";
    static-only = lib.mkForce false;
    persistent-apps = [
      "/System/Applications/Utilities/Terminal.app"
      "/Applications/WhatsApp.app"
      "/Applications/Opera.app"
    ];
  };

  # ---- SSH: host → guest over UTM Shared (bridge100 ≈ 192.168.64.0/24) --------
  # One path: Apple's sshd via services.openssh (Remote Login). Keys-only;
  # authorized_keys + host keys from nix-darwin. Host entrypoint:
  # `nix run .#macvm-utm-ssh`.
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
  #
  # Same block also ensures UTM guest tools (spice-vdagent) are installed and
  # loaded — replaces the one-shot “Install Guest Tools” CD flow.
  system.activationScripts.launchd.text = lib.mkAfter ''
    if ! /bin/launchctl print system/com.openssh.sshd >/dev/null 2>&1; then
      echo "macvm: loading com.openssh.sshd" >&2
      /bin/launchctl enable system/com.openssh.sshd 2>/dev/null || true
      /bin/launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null \
        || /bin/launchctl load -w /System/Library/LaunchDaemons/ssh.plist 2>/dev/null \
        || echo "macvm: WARNING — could not load com.openssh.sshd" >&2
    fi

    # ---- UTM Guest Tools (spice-vdagent ${spiceVdagentVersion}) --------------
    # Clipboard host↔guest (macOS 15+ both sides; UTM Virtualization.ClipboardSharing).
    # Replaces the one-shot “Install Guest Tools” CD. Vendor plists use spice-*
    # basenames (fine for BTM). First install may need a one-time Gatekeeper allow.
    spice_ver="${spiceVdagentVersion}"
    spice_pkg="${spiceVdagentPkg}"
    spice_id="com.redhat.spice.vdagent"
    cur="$(/usr/sbin/pkgutil --pkg-info "$spice_id" 2>/dev/null | /usr/bin/awk '/^version:/{print $2}')"
    if [ "$cur" != "$spice_ver" ]; then
      echo "macvm: installing UTM guest tools (spice-vdagent $spice_ver; was ''${cur:-none})" >&2
      /usr/sbin/installer -pkg "$spice_pkg" -target / || \
        echo "macvm: WARNING — spice-vdagent installer failed" >&2
    else
      echo "macvm: spice-vdagent $spice_ver already installed" >&2
    fi

    ensure_job() {
      # usage: ensure_job <domain/label> <plist>
      local target="$1" plist="$2"
      if [ ! -f "$plist" ]; then
        echo "macvm: WARNING — missing $plist" >&2
        return 1
      fi
      if /bin/launchctl print "$target" >/dev/null 2>&1; then
        # Already loaded; kickstart only if not running (state not "running").
        if ! /bin/launchctl print "$target" 2>/dev/null | /usr/bin/grep -q 'state = running'; then
          echo "macvm: kickstart $target" >&2
          /bin/launchctl kickstart -k "$target" 2>/dev/null || true
        fi
        return 0
      fi
      echo "macvm: bootstrap $target" >&2
      /bin/launchctl bootstrap "''${target%/*}" "$plist" 2>/dev/null \
        || /bin/launchctl load -w "$plist" 2>/dev/null \
        || true
    }

    ensure_job system/com.redhat.spice.vdagentd /Library/LaunchDaemons/com.redhat.spice.vdagentd.plist
    uid="$(/usr/bin/id -u ${userName} 2>/dev/null || true)"
    if [ -n "''${uid:-}" ]; then
      ensure_job "gui/$uid/com.redhat.spice.vdagent" /Library/LaunchAgents/com.redhat.spice.vdagent.plist
    fi

    if [ -c /dev/tty.com.redhat.spice.0 ]; then
      echo "macvm: spice virtio channel present" >&2
    else
      echo "macvm: WARNING — /dev/tty.com.redhat.spice.0 missing (enable Clipboard Sharing in UTM; reboot guest)" >&2
    fi
    if /bin/launchctl print system/com.redhat.spice.vdagentd 2>/dev/null | /usr/bin/grep -q 'state = running'; then
      echo "macvm: spice-vdagentd running" >&2
    else
      echo "macvm: WARNING — spice-vdagentd not running" >&2
    fi
  '';

  # core.nix enables Application Firewall + stealth on the real Mac; that blocks
  # host→guest SSH on the UTM Shared bridge. Sandbox: leave the wall open.
  networking.applicationFirewall = {
    enable = lib.mkForce false;
    enableStealthMode = lib.mkForce false;
  };

  users.users.${userName} = {
    name = userName;
    home = "/Users/${userName}";
    openssh.authorizedKeys.keys = [ operatorSshKey ];
  };

  # Passwordless sudo for the guest admin: host agents activate via
  # `nix run .#macvm-utm-ssh -- sudo nix run …#macvm` (no interactive TTY).
  # Acceptable on this sandbox — keys-only SSH on UTM Shared, not the real Mac.
  security.sudo.extraConfig = ''
    ${userName} ALL=(ALL) NOPASSWD: ALL
  '';

  # ---- Per-host home-manager (sandbox trims) ---------------------------------
  home-manager.users.${userName} = {
    # MCP gateway (~14 servers) is macos-only weight; disable agent + client wiring.
    services.mcpGateway.enable = false;
    # Stock wallpaper + Terminal so the VM is visually distinct from macos.
    local.desktopAesthetics.enable = false;
  };

  # Red accent = fullscreen-safe tell (wallpaper/Dock may be hidden).
  system.defaults.CustomUserPreferences.NSGlobalDomain = {
    AppleAccentColor = 0; # red
    AppleHighlightColor = "1.000000 0.733333 0.721569 Red";
  };

  # Lean Homebrew set (framework in modules/darwin/homebrew.nix).
  homebrew = {
    brews = [ ];
    casks = [
      "opera"
      "whatsapp"
      "capcut"
      "iina"
    ];
    masApps = { };
  };

  # ---- Host Screengrab via UTM VirtioFS --------------------------------------
  # Path shape matches core.nix screengrabDir; host registers share with
  # `nix run .#macvm-utm-share-screengrab`. Rotation stays macos-only.
  # StartInterval re-heals after boot race / remount; dangling symlinks cleared.
  launchd.user.agents.nix-screengrab-share = {
    serviceConfig = {
      Label = "org.nixos.nix-screengrab-share";
      ProgramArguments = [ (lib.getExe nixScreengrabShare) ];
      RunAtLoad = true;
      StartInterval = 30;
      StandardOutPath = "/Users/${userName}/Library/Logs/nix-screengrab-share.log";
      StandardErrorPath = "/Users/${userName}/Library/Logs/nix-screengrab-share.log";
    };
  };

  system.activationScripts.postActivation.text = lib.mkAfter ''
    # Same ensure as the user agent (root can create the symlink).
    ${lib.getExe nixScreengrabShare} || true
    /usr/sbin/chown -h ${userName}:staff ${lib.escapeShellArg screengrabLocal} 2>/dev/null || true

    # Residual macos-only login openers (open-mail / Slack / …) leave launchd
    # "enabled" ghosts after host-scoping to macos — they once auto-launched
    # Mail at login so it stuck on the Dock while running. Boot out + disable.
    uid="$(/usr/bin/id -u ${userName} 2>/dev/null || true)"
    if [ -n "$uid" ]; then
      for lab in org.nixos.open-mail org.nixos.open-messages org.nixos.open-slack \
                 org.nixos.open-maccy org.nixos.open-docker; do
        /bin/launchctl bootout "gui/$uid/$lab" 2>/dev/null || true
        /bin/launchctl disable "gui/$uid/$lab" 2>/dev/null || true
      done
    fi
  '';
}
