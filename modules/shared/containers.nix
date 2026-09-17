# The per-user container runtime (darwin only): Colima, declared through
# home-manager's own `services.colima`, replacing the Docker Desktop cask.
#
# WHY Docker Desktop had to go — it is a per-user GUI monolith with a MACHINE-WIDE
# privileged helper bound to ONE username. Measured on `macos`, 2026-09-16:
#
#   /Library/LaunchDaemons/com.docker.socket.plist
#     ProgramArguments = [ /Library/PrivilegedHelperTools/com.docker.socket "ismail" ]
#   /var/run/docker.sock -> $HOME_OF_THAT_ONE_USER/.docker/run/docker.sock  (srwxr-xr-x)
#
# The helper hardcodes the account that first launched the app, and the system
# socket is a symlink INTO that account's home. Any other account on the machine
# therefore gets EACCES on every `docker` call — and were it to launch the app
# itself, the helper would re-bind to it and break the first account instead. One
# runtime per machine, owned by whoever clicked first, is not a runtime a
# declarative config can own.
#
# WHAT OFF-THE-SHELF OPTION THIS USES (upstream-first, pinned home-manager
# `modules/services/colima.nix`):
#
#   services.colima.enable                          :17
#   services.colima.profiles.<name>.isService       :121   one launchd agent per profile (:264-308)
#   services.colima.profiles.<name>.isActive        :130   `colima start --activate=true`
#   services.colima.profiles.<name>.setDockerHost   :143   exports DOCKER_HOST=unix://$COLIMA_HOME/<p>/docker.sock (:257-259)
#   services.colima.profiles.<name>.settings        :160   rendered to $COLIMA_HOME/<p>/colima.yaml (:243-249)
#   services.colima.colimaHomeDir                   :19    default `.colima` for stateVersion < 26.05, also sets $COLIMA_HOME
#
# Everything is per-user by construction: the agent is a `launchd.agents` entry
# in the user's own gui domain, `$COLIMA_HOME` is under the user's home, and the
# docker socket lives there too. Two accounts → two VMs → no shared helper, no
# shared socket, nothing to be "bound" to one name. The agent's arg0 is
# `nix-colima-default`, because `./launchd-launcher.nix` renames every
# home-manager agent (.claude/rules/launchd-naming.md) — nothing to do here.
#
# `nix-darwin` has NO `virtualisation.*` namespace (grepped the pinned input's
# modules/ for `docker|colima|podman|virtualisation` — zero hits), so a system-
# level answer does not exist; the home-manager one is the whole surface.
#
# WHAT IS GENUINELY CUSTOM HERE: nothing but the `local.containers.enable`
# switch and the profile's `settings` values. No script, no wrapper, no path.
#
# WHY `setDockerHost` and the three profile flags are spelled out even though the
# option has a default: the module's default profile is only used when NOTHING
# defines `profiles`, and its `setDockerHost` default is
# `versionAtLeast home.stateVersion "26.05"` (:74) — this fleet is on 24.05, so
# without the explicit `true` the `docker` CLI would still look for the Docker
# Desktop socket. `isActive` also has colima run `docker context use colima`,
# so the CLI works with or without the DOCKER_HOST export (the env var wins and
# docker prints a one-line notice saying so — expected, not a conflict).
#
# WHY `runtime` is in `settings` and must never be dropped: colima decides
# whether a colima.yaml is "empty" by `Runtime == ""` (colima 0.10.3
# `config/config.go:143`, checked at `cmd/start.go:474`). A partial YAML without
# `runtime` is treated as NO config and every other key in it is silently
# ignored. The other keys are colima's own (`embedded/defaults/colima.yaml`,
# also `colima template`): `vmType` (:162, default qemu) and `mountType` (:195,
# "virtiofs (for vz), sshfs (for qemu)"). `vz` is Apple's Virtualization
# framework — the same one the tart-vms capsule already runs on — so no qemu
# binary is needed and virtiofs mounts are the native, fast path. `arch`,
# `vmType`, `mountType` and `runtime` are FIXED after the VM is first created
# (`cmd/start.go` setFixedConfigs); changing them later means `colima delete`.
#
# THE DOCKER CLI STAYS ON BREW. `docker`, `docker-buildx` and `docker-compose`
# in hosts/macos.nix are the CLIENT (plugins under /opt/homebrew/lib/docker/
# cli-plugins); the module only adds nixpkgs' `docker` to the AGENT's PATH so
# colima can run `docker context use` (:283-293). Nothing in this repo consumes
# the socket: tart-vms is Apple Virtualization, gitlab-runner is the Tart custom
# executor, local-rag is native postgres, and the devcontainer image is a
# CI/Codespaces artifact.
#
# COST: one VM per LOGGED-IN account, started at login (`RunAtLoad`), holding
# `cpu`/`memory` below while it runs. Tune `memory` (GiB) here; `disk` is a
# sparse image and can only ever be INCREASED after creation.
#
# The option defaults OFF and is enabled per account, because a second account's
# agents cannot be bootstrapped before its first login (`gui/<uid>` does not
# exist until then, and bootstrapping into it aborts activation).
#
# MIGRATION — the first `activate` after this lands removes the cask through
# `brew bundle --cleanup` (onActivation.cleanup = "uninstall"). The cask
# uninstall does NOT remove the privileged helper, its two LaunchDaemons or
# the per-user Desktop leftovers. Manual, one time, NOT run by this module:
#
#   # machine-wide (root): the helper that was bound to one username
#   sudo launchctl bootout system/com.docker.socket
#   sudo launchctl bootout system/com.docker.vmnetd
#   sudo rm -f /Library/LaunchDaemons/com.docker.socket.plist \
#              /Library/LaunchDaemons/com.docker.vmnetd.plist \
#              /Library/PrivilegedHelperTools/com.docker.socket \
#              /Library/PrivilegedHelperTools/com.docker.vmnetd \
#              /var/run/docker.sock
#
#   # per user: Desktop's config.json state (mutable — `docker login` writes it,
#   # so it is deliberately NOT managed by programs.docker-cli here)
#   #   currentContext "desktop-linux"  → colima's --activate switches it itself
#   #   credsStore "desktop"            → docker-credential-desktop is gone; drop the
#   #                                     key or set "osxkeychain" (brew docker-credential-helper)
#   #   ~/.docker/cli-plugins/docker-{compose,buildx} → dangling links into Docker.app;
#   #                                     re-point at the brew formulae:
#   ln -sfn /opt/homebrew/lib/docker/cli-plugins/docker-compose "$HOME/.docker/cli-plugins/docker-compose"
#   ln -sfn /opt/homebrew/lib/docker/cli-plugins/docker-buildx  "$HOME/.docker/cli-plugins/docker-buildx"
#
# First start downloads the ~200 MB Ubuntu guest image into $COLIMA_HOME; the
# agent logs to $XDG_STATE_HOME/colima/default.log (module default, :155).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.containers;
in
{
  options.local.containers = {
    enable = lib.mkEnableOption ''
      the per-user Colima container runtime (`services.colima`) with the
      `docker` CLI pointed at this user's own socket via DOCKER_HOST
    '';
  };

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isDarwin) {
    services.colima = {
      enable = true;
      profiles.default = {
        isService = true;
        isActive = true;
        setDockerHost = true;
        settings = {
          # Load-bearing — see the header: an absent `runtime` makes colima treat
          # the whole file as empty.
          runtime = "docker";
          arch = "host";
          vmType = "vz";
          mountType = "virtiofs";
          cpu = 4;
          memory = 4;
          disk = 100;
        };
      };
    };
  };
}
