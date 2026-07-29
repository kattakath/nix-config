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
in
{
  imports = [ ../modules/darwin/core.nix ];

  nixpkgs.config.allowUnfree = true;

  # Stable identity for host-gated modules (no macos login openers / RAG stack).
  networking.hostName = "macvm";

  # Dock bottom on the VM (core.nix uses right on the real Mac).
  system.defaults.dock.orientation = lib.mkForce "bottom";

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
    spice_ver="${spiceVdagentVersion}"
    spice_pkg="${spiceVdagentPkg}"
    spice_id="com.redhat.spice.vdagent"
    cur="$(/usr/sbin/pkgutil --pkg-info "$spice_id" 2>/dev/null | /usr/bin/awk '/^version:/{print $2}')"
    if [ "$cur" != "$spice_ver" ]; then
      echo "macvm: installing UTM guest tools (spice-vdagent $spice_ver; was ''${cur:-none})" >&2
      /usr/sbin/installer -pkg "$spice_pkg" -target / || \
        echo "macvm: WARNING — spice-vdagent installer failed" >&2
    fi
    # Daemon (system) + agent (gui user). Vendor plists use spice-vdagent basenames
    # (fine for BTM — not bare sh). First-ever run may need a one-time Privacy
    # prompt to allow spice-vdagent / spice-vdagentd (Gatekeeper).
    if [ -f /Library/LaunchDaemons/com.redhat.spice.vdagentd.plist ]; then
      if ! /bin/launchctl print system/com.redhat.spice.vdagentd >/dev/null 2>&1; then
        echo "macvm: loading com.redhat.spice.vdagentd" >&2
        /bin/launchctl bootstrap system /Library/LaunchDaemons/com.redhat.spice.vdagentd.plist 2>/dev/null \
          || /bin/launchctl load -w /Library/LaunchDaemons/com.redhat.spice.vdagentd.plist 2>/dev/null \
          || true
      fi
    fi
    if [ -f /Library/LaunchAgents/com.redhat.spice.vdagent.plist ]; then
      uid="$(/usr/bin/id -u ${userName} 2>/dev/null || true)"
      if [ -n "''${uid:-}" ] && ! /bin/launchctl print "gui/$uid/com.redhat.spice.vdagent" >/dev/null 2>&1; then
        echo "macvm: loading com.redhat.spice.vdagent (gui/$uid)" >&2
        /bin/launchctl asuser "$uid" /bin/launchctl bootstrap "gui/$uid" \
          /Library/LaunchAgents/com.redhat.spice.vdagent.plist 2>/dev/null \
          || /bin/launchctl asuser "$uid" /bin/launchctl load -w \
            /Library/LaunchAgents/com.redhat.spice.vdagent.plist 2>/dev/null \
          || true
      fi
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
}
