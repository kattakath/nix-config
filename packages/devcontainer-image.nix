# Nix-FULL devcontainer image for nix-config — the deliberate inverse of a
# nix-free application image. This repo's devcontainer exists to RUN Nix
# (`nix flake check`, `darwin-rebuild`, `nixos-rebuild`), so the baked payload
# IS a working Nix plus the DB-registered devShell closure: inside the
# container, `nix develop` realizes nothing (no build, no download).
#
# STORE ACCESS MODEL — Nix's official MULTI-USER model (not single-user):
#   `dockerTools.streamLayeredImage` bakes /nix/store IMMUTABLY root-owned (it
#   reconstructs the store dir from the store-path layers and discards any
#   chown/chmod of it — verified). A root-owned store is not a bug: it is the
#   PRECONDITION of Nix multi-user. So the container starts a root `nix-daemon`
#   (via the entrypoint) and unprivileged `vscode` reaches it over the socket
#   (`NIX_REMOTE=daemon`) — the daemon performs all privileged store writes.
#   This is both Nix's documented multi-user model AND the exact non-root path
#   the first-party devcontainers/features/nix uses. No chown hacks, no sudo.
#
# Built by CI (.github/workflows/build-devcontainer.yml), pushed multi-arch to
# GHCR, referenced verbatim by .devcontainer/devcontainer.json (remoteUser
# vscode + overrideCommand:false so the daemon entrypoint runs). Replaces the
# old four-Features stack (nix / node / claude-code / github-cli).
#
#   nix build .#packages.<linux>.devcontainerImage   # ./result = stream script
#   ./result | docker load                           # local smoke test
#   ./result | gzip --fast | skopeo copy docker-archive:/dev/stdin docker://...  # CI push
#
# `devPackages` is the SHARED dev toolchain list from flake.nix (devPackagesFor),
# the same list the `nix develop` devShell uses — so image and shell never drift.
{
  pkgs,
  lib,
  devPackages,
}:

let
  inherit (pkgs) dockerTools;

  username = "vscode";
  uid = 1000;
  gid = 1000;
  workdir = "/workspaces/nix-config";

  # Pieces the removed devcontainer Features provided, plus base userland. `nix`
  # is the whole point; `nodejs` is required because Claude Code's JS hooks run
  # bare `node` under /bin/sh; `claude-code` is UNFREE (image is built with the
  # allowUnfree pkgs from flake.nix's pkgsUnfreeFor).
  extraTools = with pkgs; [
    nix
    nodejs_22
    claude-code
    gh
    bashInteractive
    coreutils
    gnugrep
    gnused
    gawk
    findutils
    which
    cacert # CA bundle for every https client (nix substituters, gh, git)
    gnutar
    gzip
    xz
    openssh
  ];

  contents = devPackages ++ extraTools;

  # Everything that must be a VALID store path so `nix develop` skips build +
  # download. `registration` below is loaded into the image's Nix DB.
  closure = pkgs.closureInfo { rootPaths = contents; };

  # Real `vscode` user only. fakeNss yields a READ-ONLY /etc/passwd — hence
  # updateRemoteUserUID:false in the JSON. No nixbld build users: with an empty
  # build-users-group (below) the daemon runs builds as its own uid (root), so
  # the whole nixbld group/user machinery is unused and dropped.
  nss = pkgs.fakeNss.override {
    extraPasswdLines = [
      "${username}:x:${toString uid}:${toString gid}:${username}:/home/${username}:${pkgs.bashInteractive}/bin/bash"
    ];
    extraGroupLines = [
      "${username}:x:${toString gid}:"
    ];
  };

  # Container entrypoint: start the root nix-daemon (idempotent) then hand off to
  # the command. Runs as root (config.User = root); the daemon is a plain
  # backgrounded process (no systemd) — the standard container pattern, mirroring
  # devcontainers/features/nix's nix-entrypoint.sh.
  entrypoint = pkgs.writeShellScript "nix-daemon-entrypoint" ''
    if [ ! -S /nix/var/nix/daemon-socket/socket ]; then
      # CRITICAL: the image sets NIX_REMOTE=daemon for CLIENTS, but the daemon
      # itself must NOT inherit it — otherwise it opens a RemoteStore pointing at
      # its own socket and proxies to itself (binds the socket, then resets every
      # request → "Connection reset by peer"). Run the daemon with NIX_REMOTE
      # empty so it drives the LOCAL store directly.
      NIX_REMOTE= ${pkgs.nix}/bin/nix-daemon > /tmp/nix-daemon.log 2>&1 &
    fi
    exec "$@"
  '';
in
dockerTools.streamLayeredImage {
  name = "nix-config-devcontainer";
  tag = "latest";

  contents = contents ++ [ nss ];

  # Good store-path -> layer fan-out; cache-friendly across rebuilds. Cap 125.
  maxLayers = 120;

  # enableFakechroot lets fakeRootCommands see the merged rootfs (so store paths
  # and /bin/sh resolve) via fakechroot+proot — forbidden on Darwin, fine in CI.
  enableFakechroot = true;
  fakeRootCommands = ''
    set -eu

    # /bin/sh — many tools (and the entrypoint's exec target) hardcode it.
    mkdir -p bin
    ln -sf ${pkgs.bashInteractive}/bin/bash bin/sh

    # writable HOME for vscode (gh config, ~/.claude, npm cache).
    mkdir -p home/${username}
    chown -R ${toString uid}:${toString gid} home/${username}

    # world-writable, sticky /tmp (nix-daemon.log lands here; nix build tmp).
    mkdir -p tmp
    chmod 1777 tmp

    # workspace bind-mount target.
    mkdir -p .${workdir}
    chown -R ${toString uid}:${toString gid} workspaces

    # --- register the baked closure in the store DB --------------------------
    # Without --load-db the /nix/store paths are PRESENT but INVALID, so the
    # daemon would try to rebuild/redownload everything. The daemon (root) reads
    # this same root-owned db. Mirrors dockerTools.buildImageWithNixDb.
    #
    # /nix/store stays root-owned (immutable in this image type — and correct for
    # multi-user: only the root daemon writes it). CRITICAL: do NOT bind-mount a
    # volume over /nix in devcontainer.json — it would shadow this baked warm
    # store. The container overlay makes the store writable for the root daemon.
    # Pre-create daemon-socket/ with the perms the upstream --daemon installer
    # sets — rather than relying on the daemon to mkdir it at runtime over the
    # baked-immutable /nix (a runtime-permission variable that can crash the
    # worker after the listen socket is already visible).
    mkdir -p nix/var/nix/db nix/var/nix/profiles nix/var/nix/gcroots nix/var/nix/temproots \
             nix/var/nix/daemon-socket
    chmod 0755 nix/var/nix/daemon-socket
    export NIX_STATE_DIR=/nix/var/nix
    export NIX_REMOTE=
    ${pkgs.nix}/bin/nix-store --load-db < ${closure}/registration

    # --- baked nix.conf: multi-user daemon + flakes + public Cachix (read) ----
    # sandbox=false: the build sandbox doesn't work nested in a container.
    # build-users-group= (EMPTY): documented behavior — with NIX_REMOTE=daemon
    # and an empty group, builds run as the daemon's own uid (root); no
    # setuid-to-nixbld step. This is the sound, documented choice for a daemon
    # serving TRUSTED clients (trusted-users below) and removes the whole nixbld
    # failure class (matches the single-user-in-container posture that works).
    # trusted-users: let vscode add substituters / import paths interactively.
    # Cachix key is a verification key (also in modules/shared/nix-cache.nix).
    mkdir -p etc/nix
    cat > etc/nix/nix.conf <<'NIXCONF'
    experimental-features = nix-command flakes
    build-users-group =
    sandbox = false
    trusted-users = root vscode
    extra-substituters = https://ismailkattakath.cachix.org
    extra-trusted-public-keys = ismailkattakath.cachix.org-1:7BbEvLpASY7aNUZfpzRMWir1zjU3nqmllBTl8p7gr2I=
    NIXCONF
  '';

  config = {
    # Container/entrypoint runs as ROOT so the nix-daemon starts privileged.
    # VS Code drops to the non-root `vscode` remoteUser for terminals/processes,
    # which reach the daemon over the socket (NIX_REMOTE=daemon below).
    User = "0:0";
    WorkingDir = workdir;

    # Entrypoint starts the daemon, then execs Cmd. Requires overrideCommand:false
    # in devcontainer.json so VS Code respects this entrypoint; Cmd = a keepalive
    # so the container stays up for `docker exec` sessions.
    Entrypoint = [ "${entrypoint}" ];
    Cmd = [
      "${pkgs.coreutils}/bin/sleep"
      "infinity"
    ];

    Env = [
      "PATH=${lib.makeBinPath contents}:/usr/local/bin:/usr/bin:/bin"
      "HOME=/home/${username}"
      "USER=${username}"
      # Multi-user: clients talk to the root daemon over the socket.
      "NIX_REMOTE=daemon"
      "NIXPKGS_ALLOW_UNFREE=1"
      # TLS trust for every https client baked in.
      "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      "GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      "LANG=C.UTF-8"
      "DEVCONTAINER=true"
    ];
  };
}
