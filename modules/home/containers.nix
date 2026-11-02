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
#   services.colima.profiles.<name>.isService       :121   one launchd agent per profile (`launchd.agents`)
#   services.colima.profiles.<name>.isActive        :130   `colima start --activate=true`
#   services.colima.profiles.<name>.setDockerHost   :143   exports DOCKER_HOST=unix://$COLIMA_HOME/<p>/docker.sock (`dockerHostProfile`)
#   services.colima.profiles.<name>.settings               rendered to $COLIMA_HOME/<p>/colima.yaml (`yamlFormat.generate`)
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
# modules/ for `docker|colima|podman|virtualisation` — no container-runtime option), so a system-
# level answer does not exist; the home-manager one is the whole surface.
#
# WHAT IS GENUINELY CUSTOM HERE: the `local.containers.enable` switch, the
# profile's `settings` values, and the docker client package. No script, no wrapper.
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
# THE DOCKER CLI IS NIXPKGS' `docker-client` (off brew since 2026-11-02), and it
# already carries buildx and compose: the pinned nixpkgs
# `pkgs/applications/virtualization/docker/default.nix` builds the client with
# `buildxSupport ? true` / `composeSupport ? true` and wraps `docker` with
# `--prefix DOCKER_CLI_PLUGIN_DIRS` pointing at both plugins' `libexec/docker/
# cli-plugins` (its `cli-system-plugin-dir-from-env` patch). So `docker-buildx`
# and `docker-compose` need no install of their own and no ~/.docker/cli-plugins
# links — the forced out-of-store links this module carried for the brew client
# went with it. The SAME package is colima's `dockerPackage`, so the agent's
# `docker context use` and the shell's `docker` are one binary. Nothing in this
# repo consumes the socket: tart-vms is Apple Virtualization, gitlab-runner is
# the Tart custom executor, local-rag is native postgres, and the devcontainer
# image is a CI/Codespaces artifact (brew's `devcontainer` CLI only calls
# `docker` on PATH).
#
# NOT `programs.docker-cli` (pinned home-manager `modules/programs/docker-cli.nix`):
# it installs no package, and it links `config.json` READ-ONLY from the store,
# while colima's `--activate` writes `currentContext` into that file and
# `docker login` writes `auths` — both would fail. The client config stays mutable.
#
# COST: one VM per LOGGED-IN account, started at login (`RunAtLoad`), holding
# `cpu`/`memory` below while it runs. Tune `memory` (GiB) here; `disk` is a
# sparse image and can only ever be INCREASED after creation.
#
# The option defaults OFF and is enabled per account, because a second account's
# agents cannot be bootstrapped before its first login (`gui/<uid>` does not
# exist until then, and bootstrapping into it aborts activation).
#
# Docker Desktop's one-time teardown recipe (done on `macos`) left this header 2026-11-02; git history keeps it.
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
  # One docker for the shell AND the colima agent — see the header.
  dockerClient = pkgs.docker-client;
in
{
  options.local.containers = {
    enable = lib.mkEnableOption ''
      the per-user Colima container runtime (`services.colima`) with the
      `docker` CLI pointed at this user's own socket via DOCKER_HOST
    '';
  };

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isDarwin) {
    home.packages = [ dockerClient ];

    services.colima = {
      enable = true;
      dockerPackage = dockerClient;
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
          # Home-manager's module default is an EXPLICIT `mounts = []`, which colima
          # treats as "share nothing" rather than falling back to its own CLI default
          # of auto-mounting `~`. Without this, every wp-env bind mount under $HOME
          # resolves to an empty root-owned dir inside the guest (a client's
          # local WordPress clone hit this 2026-09-24/28: "elementor plugin could not
          # be found" because wp-content/plugins was never actually shared).
          mounts = [
            {
              location = "~";
              writable = true;
            }
          ];
          # Sized for the 36 GiB / 12-core (6P+6E) M3 Pro, 2026-09-21: cpu = the
          # P-core count (idle vCPUs are free); memory is a hard budget, not a soft
          # cap — vz commits pages lazily, and Lima attaches a virtio balloon device but
          # never inflates it (zero `TargetVirtualMachineMemorySize` calls in
          # lima-vm/lima, checked 2026-09-21), so the guest page cache grows into it
          # and only a VM restart hands it back. 12 GiB (~33%) leaves ~24 GiB
          # for native Ollama models + GUI. The 4/4 before was Lima's builtin floor.
          cpu = 6;
          memory = 12;
          disk = 100;
        };
      };
    };
  };
}
