# Nix-FULL devcontainer image for nix-config — the deliberate inverse of a
# nix-free application image. This repo's devcontainer exists to RUN Nix
# (`nix flake check`, `darwin-rebuild`, `nixos-rebuild`), so the baked payload
# IS a working single-user Nix plus the DB-registered devShell closure: inside
# the container, `nix develop` realizes nothing (no build, no download).
#
# Built by CI (.github/workflows/build-devcontainer.yml), pushed multi-arch to
# GHCR, and referenced verbatim by .devcontainer/devcontainer.json. Replaces the
# old four-Features stack (nix / node / claude-code / github-cli) with one image.
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

  # Real `vscode` user (uid/gid 1000) so runtime identity probes resolve. fakeNss
  # yields a READ-ONLY /etc/passwd — hence updateRemoteUserUID:false in the JSON.
  nss = pkgs.fakeNss.override {
    extraPasswdLines = [
      "${username}:x:${toString uid}:${toString gid}:${username}:/home/${username}:${pkgs.bashInteractive}/bin/bash"
    ];
    extraGroupLines = [
      "${username}:x:${toString gid}:"
    ];
  };
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

    # /bin/sh — the devcontainer keepalive runs `/bin/sh -c "while sleep ..."`
    # and many tools hardcode it.
    mkdir -p bin
    ln -sf ${pkgs.bashInteractive}/bin/bash bin/sh

    # writable HOME for vscode (nix profile, gh config, ~/.claude, npm cache).
    mkdir -p home/${username}
    chown -R ${toString uid}:${toString gid} home/${username}

    # world-writable, sticky /tmp.
    mkdir -p tmp
    chmod 1777 tmp

    # workspace bind-mount target.
    mkdir -p .${workdir}
    chown -R ${toString uid}:${toString gid} workspaces

    # --- make Nix actually work: register the baked closure in the store DB ----
    # Without --load-db the /nix/store paths are PRESENT but INVALID, so
    # `nix develop` would try to rebuild/redownload everything. This mirrors
    # dockerTools.buildImageWithNixDb, done here for a layered image.
    #
    # CRITICAL: do NOT bind-mount a volume over /nix in devcontainer.json — it
    # would shadow this baked store and empty the warm cache. The container's
    # own overlay makes /nix/store writable for new builds.
    mkdir -p nix/var/nix/db nix/var/nix/profiles nix/var/nix/gcroots nix/var/nix/temproots
    export NIX_STATE_DIR=/nix/var/nix
    export NIX_REMOTE=
    ${pkgs.nix}/bin/nix-store --load-db < ${closure}/registration

    # The container runs as uid ${toString uid} (vscode) but the baked store is
    # root-owned, so single-user nix can't create /nix/store/.links or new paths
    # ("Permission denied"). Widen the MUTABLE dir nodes only — baked store PATHS
    # stay root-owned/read-only, so the layer stays small. Use chmod 1777 on the
    # store dir (world-writable + sticky) so it works regardless of how the layer
    # records dir OWNERSHIP; chown /nix/var (db/profiles/gcroots — small).
    chown ${toString uid}:${toString gid} nix nix/store || true
    chmod 1777 nix/store
    chown -R ${toString uid}:${toString gid} nix/var

    # --- baked nix.conf: flakes on + the public Cachix substituter (read only) -
    # Key is a verification key (also in modules/shared/nix-cache.nix); read is
    # public, so NO auth token on the consumer.
    mkdir -p etc/nix
    cat > etc/nix/nix.conf <<'NIXCONF'
    experimental-features = nix-command flakes
    extra-substituters = https://ismailkattakath.cachix.org
    extra-trusted-public-keys = ismailkattakath.cachix.org-1:7BbEvLpASY7aNUZfpzRMWir1zjU3nqmllBTl8p7gr2I=
    NIXCONF
  '';

  config = {
    User = "${toString uid}:${toString gid}";
    WorkingDir = workdir;
    Env = [
      "PATH=${lib.makeBinPath contents}:/usr/local/bin:/usr/bin:/bin"
      "HOME=/home/${username}"
      "USER=${username}"
      # Single-user nix (no daemon inside the container).
      "NIX_REMOTE="
      "NIXPKGS_ALLOW_UNFREE=1"
      # TLS trust for every https client baked in.
      "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      "GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      "LANG=C.UTF-8"
      "DEVCONTAINER=true"
    ];
    # No blocking Cmd/Entrypoint — the VS Code dev container runtime injects its
    # own keepalive and execs the server. A blocking CMD would fight that.
  };
}
