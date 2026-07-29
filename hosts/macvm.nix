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
  ...
}:
let
  # Operator ed25519 public key — sole network login credential (same as nixpi/nixvm).
  operatorSshKey = import ../secrets/operator-key.nix;
in
{
  imports = [ ../modules/darwin/core.nix ];

  nixpkgs.config.allowUnfree = true;

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
  system.activationScripts.launchd.text = lib.mkAfter ''
    if ! /bin/launchctl print system/com.openssh.sshd >/dev/null 2>&1; then
      echo "macvm: loading com.openssh.sshd" >&2
      /bin/launchctl enable system/com.openssh.sshd 2>/dev/null || true
      /bin/launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null \
        || /bin/launchctl load -w /System/Library/LaunchDaemons/ssh.plist 2>/dev/null \
        || echo "macvm: WARNING — could not load com.openssh.sshd" >&2
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
