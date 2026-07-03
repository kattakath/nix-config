# Nix-FULL devcontainer image for nix-config — the deliberate inverse of a
# nix-free application image. This repo's devcontainer exists to RUN Nix
# (`nix flake check`, `darwin-rebuild`, `nixos-rebuild`), so the baked payload
# IS a working Nix plus the DB-registered devShell closure: inside the
# container, `nix develop` realizes nothing (no build, no download).
#
# STORE ACCESS MODEL — Nix's MULTI-USER model (not single-user):
#   `streamLayeredImage` bakes /nix/store IMMUTABLY root-owned (it rebuilds the
#   store dir from the store-path layers and discards any chown/chmod of it).
#   That is the PRECONDITION of Nix multi-user, not a bug: the container starts
#   a root `nix-daemon` (via the entrypoint) and unprivileged `vscode` reaches
#   it over the socket (`NIX_REMOTE=daemon`), so the daemon does all privileged
#   store writes. Mirrors the first-party devcontainers/features/nix path — no
#   chown hacks, no sudo.
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

  basePackages = devPackages ++ extraTools;

  # Foreign (non-Nix) glibc binaries — e.g. the VS Code Server's bundled generic
  # `node` — hardcode the STANDARD ELF interpreter path in their PT_INTERP; the
  # kernel refuses them (exit 127) when it is absent, and this distroless image
  # has glibc only under /nix/store. So the standard loader path must be
  # populated. The image is multi-arch, so the loader FILENAME is derived from
  # the target platform, never hardcoded: ld-linux-aarch64.so.1 (canonically in
  # /lib) on aarch64, ld-linux-x86-64.so.2 (in /lib64) on x86_64.
  hostPlat = pkgs.stdenv.hostPlatform;
  loaderInfo =
    if hostPlat.isAarch64 then
      {
        name = "ld-linux-aarch64.so.1";
        libDir = "lib";
      }
    else if hostPlat.isx86_64 then
      {
        name = "ld-linux-x86-64.so.2";
        libDir = "lib64";
      }
    else
      throw "devcontainer-image: unsupported host platform ${hostPlat.system} — add its glibc loader name/dir";

  # gcc runtime libs (libstdc++.so.6, libgcc_s.so.1) the VS Code Server node needs
  # once the loader resolves. Put on LD_LIBRARY_PATH in config.Env (below) — the
  # only mechanism the store-isolated nixpkgs loader honors; scoped to this one
  # narrow dir so it doesn't perturb the co-installed Nix binaries.
  gccLib = pkgs.stdenv.cc.cc.lib;

  # Everything that must be a VALID store path so `nix develop` skips build +
  # download; its `registration` is loaded into the image's Nix DB below.
  closure = pkgs.closureInfo { rootPaths = basePackages; };

  # Real `vscode` user only. fakeNss yields a READ-ONLY /etc/passwd — hence
  # updateRemoteUserUID:false in the JSON. No nixbld build users: with an empty
  # build-users-group (below) the daemon builds as its own uid (root).
  nss = pkgs.fakeNss.override {
    extraPasswdLines = [
      "${username}:x:${toString uid}:${toString gid}:${username}:/home/${username}:${pkgs.bashInteractive}/bin/bash"
    ];
    extraGroupLines = [
      "${username}:x:${toString gid}:"
    ];
  };

  # Container entrypoint: start the root nix-daemon (idempotent) then exec the
  # command. Plain backgrounded process, no systemd — the standard container
  # pattern, mirroring devcontainers/features/nix's nix-entrypoint.sh.
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

  contents = basePackages ++ [ nss ];

  # Store-path -> layer fan-out, under dockerTools' 125-layer ceiling.
  maxLayers = 120;

  # enableFakechroot lets fakeRootCommands see the merged rootfs (so store paths
  # and /bin/sh resolve) via fakechroot+proot — forbidden on Darwin, fine in CI.
  enableFakechroot = true;
  fakeRootCommands = ''
    set -eu

    # /bin/sh — many tools (and the entrypoint's exec target) hardcode it.
    mkdir -p bin
    ln -sf ${pkgs.bashInteractive}/bin/bash bin/sh

    # /usr/bin/env — the VS Code Server bootstrap scripts (check-requirements.sh
    # and its siblings) start with `#!/usr/bin/env sh`; on this distroless Nix
    # image /usr/bin/env is absent, so the kernel rejects the shebang with
    # "/usr/bin/env: bad interpreter: No such file or directory" (exit 126) and
    # the server never installs — `devcontainer up` / Remote-Containers attach
    # then aborts. env resolves the real interpreter (sh/bash/node) via the
    # container PATH, which already carries the store bins plus /bin.
    mkdir -p usr/bin
    ln -sf ${pkgs.coreutils}/bin/env usr/bin/env

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
    # Without --load-db the /nix/store paths are PRESENT but INVALID and the
    # daemon rebuilds/redownloads everything. Mirrors buildImageWithNixDb.
    # CRITICAL: do NOT bind-mount a volume over /nix in devcontainer.json — it
    # shadows this baked warm store. Pre-create daemon-socket/ with the upstream
    # --daemon installer's perms rather than letting the daemon mkdir it at
    # runtime over baked-immutable /nix (which can crash the worker after the
    # listen socket is already visible).
    mkdir -p nix/var/nix/db nix/var/nix/profiles nix/var/nix/gcroots nix/var/nix/temproots \
             nix/var/nix/daemon-socket
    chmod 0755 nix/var/nix/daemon-socket
    export NIX_STATE_DIR=/nix/var/nix
    export NIX_REMOTE=
    ${pkgs.nix}/bin/nix-store --load-db < ${closure}/registration

    # --- baked nix.conf: multi-user daemon + flakes + public Cachix (read) ----
    # sandbox=false: the build sandbox doesn't work nested in a container.
    # build-users-group= (EMPTY): with NIX_REMOTE=daemon and an empty group,
    # builds run as the daemon's own uid (root), removing the whole nixbld
    # failure class — sound for a daemon serving TRUSTED clients (trusted-users).
    # trusted-users lets vscode add substituters / import paths interactively.
    # The Cachix key is public-read (verification key, mirrored in
    # modules/shared/nix-cache.nix) — no token baked in.
    mkdir -p etc/nix
    cat > etc/nix/nix.conf <<'NIXCONF'
    experimental-features = nix-command flakes
    build-users-group =
    sandbox = false
    trusted-users = root vscode
    extra-substituters = https://ismailkattakath.cachix.org
    extra-trusted-public-keys = ismailkattakath.cachix.org-1:7BbEvLpASY7aNUZfpzRMWir1zjU3nqmllBTl8p7gr2I=
    NIXCONF

    # --- make FOREIGN (non-Nix) glibc binaries runnable ----------------------
    # The VS Code Server's generic-glibc `node` has its PT_INTERP set to the
    # standard loader path (/lib/ld-linux-aarch64.so.1 or
    # /lib64/ld-linux-x86-64.so.2), which a distroless Nix image lacks — so the
    # server exits 127 and never starts. Symlink the standard loader path to
    # nixpkgs glibc's loader so the kernel can exec these binaries.
    mkdir -p lib lib64
    ln -sf ${pkgs.glibc}/lib/${loaderInfo.name} ${loaderInfo.libDir}/${loaderInfo.name}
    # Also mirror into the sibling dir (/lib <-> /lib64) for binaries that probe it.
    ${
      lib.optionalString (loaderInfo.libDir == "lib") ''
        ln -sf ${pkgs.glibc}/lib/${loaderInfo.name} lib64/${loaderInfo.name}
      ''
    }${
      lib.optionalString (loaderInfo.libDir == "lib64") ''
        ln -sf ${pkgs.glibc}/lib/${loaderInfo.name} lib/${loaderInfo.name}
      ''
    }

    # NOTE: libstdc++.so.6 / libgcc_s.so.1 for the foreign binary are resolved by
    # LD_LIBRARY_PATH in config.Env (below), NOT here. Two alternatives were
    # PROVEN not to work with the nixpkgs-patched loader:
    #   * /etc/ld.so.cache — nixpkgs' dont-use-system-ld-so-cache.patch repoints
    #     the loader's cache into the glibc store path, so /etc/ld.so.cache is
    #     never consulted;
    #   * symlinking libs into /lib,/lib64 — the loader's default search dirs
    #     (SYSTEM_DIRS) are the glibc STORE path (prefix=$out), not FHS /lib.
    # Both left "libstdc++.so.6: cannot open shared object file". LD_LIBRARY_PATH
    # is the mechanism the store-isolated loader honors.

    # --- minimal /etc/os-release --------------------------------------------
    # Silences the devcontainer runtime's distro probe, which otherwise logs a
    # failure on every `devcontainer up`.
    cat > etc/os-release <<'OSRELEASE'
    NAME="nix-config devcontainer"
    ID=nixos
    ID_LIKE=nixos
    PRETTY_NAME="nix-config devcontainer (distroless)"
    VERSION_ID="unstable"
    HOME_URL="https://github.com/ismailkattakath/nix-config"
    OSRELEASE
    mkdir -p usr/lib
    ln -sf /etc/os-release usr/lib/os-release
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
      # /bin holds the /bin/sh symlink (created in fakeRootCommands); the FHS
      # /usr/local/bin:/usr/bin dirs are never created in this distroless Nix
      # image, so they were dead PATH entries and are omitted.
      "PATH=${lib.makeBinPath basePackages}:/bin"
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
      # Make libstdc++.so.6 / libgcc_s.so.1 resolvable to FOREIGN (non-Nix)
      # glibc binaries (the VS Code Server's `node`), which otherwise die with
      # "libstdc++.so.6: cannot open shared object file" once the loader symlink
      # lets them exec (see fakeRootCommands for why this is the only mechanism).
      # Scoped to the one narrow gcc-lib dir so the shadow surface is just
      # libstdc++/libgcc_s — safe for the co-installed Nix binaries, since those
      # sonames are the SAME gcc's ABI-identical store libs and every other lib
      # they need has a distinct soname absent from this dir.
      "LD_LIBRARY_PATH=${lib.makeLibraryPath [ gccLib ]}"
    ];
  };
}
