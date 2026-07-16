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
  orgName,
  cachixUrl,
  cachixKey,
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

  # nix-ld contract: the library search path exposed to FOREIGN (non-Nix) glibc
  # binaries (the VS Code Server's node, prebuilt language servers, …) via
  # NIX_LD_LIBRARY_PATH / LD_LIBRARY_PATH in config.Env. Imported from the shared
  # list the repo's NixOS hosts already use (modules/nixos/core.nix) so image and
  # hosts never drift — and so the NEXT foreign binary that needs zlib/openssl/
  # libGL just works with no image change. This is the ONE place the set grows,
  # instead of a per-soname shim added after each breakage.
  nixLdLibraries = import ../modules/shared/nix-ld-libraries.nix pkgs;
  nixLdLibraryPath = lib.makeLibraryPath nixLdLibraries;

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
    socket=/nix/var/nix/daemon-socket/socket
    # LIVENESS, not mere presence: a crashed daemon leaves the socket INODE behind,
    # so the old `[ ! -S socket ]` file test saw a dead socket, skipped the restart,
    # and every client then got "Connection refused". Probe an actual store ping
    # (the same liveness check the CI smoke test uses); a stale inode fails it and
    # we reclaim it before rebinding.
    daemon_alive() {
      [ -S "$socket" ] && NIX_REMOTE=daemon ${pkgs.nix}/bin/nix store ping >/dev/null 2>&1
    }
    if ! daemon_alive; then
      rm -f "$socket"
      # CRITICAL: the image sets NIX_REMOTE=daemon for CLIENTS, but the daemon
      # itself must NOT inherit it — otherwise it opens a RemoteStore pointing at
      # its own socket and proxies to itself (binds the socket, then resets every
      # request → "Connection reset by peer"). Run the daemon with NIX_REMOTE
      # empty so it drives the LOCAL store directly.
      NIX_REMOTE= ${pkgs.nix}/bin/nix-daemon > /tmp/nix-daemon.log 2>&1 &
      # Bounded wait until it actually LISTENS (not merely until the file appears).
      for _ in $(seq 1 50); do daemon_alive && break; done
    fi
    exec "$@"
  '';
in
dockerTools.streamLayeredImage {
  name = "nix-config-devcontainer";
  tag = "latest";

  # binSh / usrBinEnv are upstream dockerTools helpers that symlink /bin/sh ->
  # bashInteractive and /usr/bin/env -> coreutils env (see the FHS contract in
  # fakeRootCommands), replacing hand-rolled `ln -sf`.
  contents = basePackages ++ [
    nss
    dockerTools.binSh
    dockerTools.usrBinEnv
  ];

  # Store-path -> layer fan-out, under dockerTools' 125-layer ceiling.
  maxLayers = 120;

  # Register the closure of `contents` in the image's Nix DB so `nix develop`
  # sees VALID store paths (no rebuild/redownload). Upstream mechanism, replacing
  # a manual `nix-store --load-db`; also resets registrationTime to
  # SOURCE_DATE_EPOCH for reproducibility.
  includeNixDB = true;

  # enableFakechroot lets fakeRootCommands see the merged rootfs (so store paths
  # and /bin/sh resolve) via fakechroot+proot — forbidden on Darwin, fine in CI.
  enableFakechroot = true;
  fakeRootCommands = ''
    set -eu

    # ==========================================================================
    # FHS compat contract for the FOREIGN VS Code Server
    # --------------------------------------------------------------------------
    # This distroless image has NO base distro — glibc, a shell, and coreutils
    # live only under /nix/store. The VS Code Server (and other prebuilt binaries)
    # are generic-glibc FOREIGN binaries that make hardcoded FHS assumptions.
    # Every such assumption is satisfied HERE, deliberately in one place, instead
    # of reactively one breakage at a time. There are exactly three kinds:
    #
    #   (1) ELF loader — the nix-ld contract. Foreign binaries hardcode the
    #       STANDARD loader path in PT_INTERP; without it the kernel refuses them
    #       (exit 127). We OWN /lib*/ld-linux-* on a distroless image (no system
    #       loader to protect), so we point it straight at nixpkgs glibc. The libs
    #       those binaries then need at runtime are exposed via NIX_LD_LIBRARY_PATH
    #       / LD_LIBRARY_PATH in config.Env — NOT via /lib symlinks or
    #       /etc/ld.so.cache, which the nixpkgs-patched loader ignores (SYSTEM_DIRS
    #       = the glibc store path; dont-use-system-ld-so-cache.patch).
    #   (2) Interpreter PATHS the kernel resolves BEFORE any ELF loader runs — a
    #       `#!/usr/bin/env sh` shebang and hardcoded `/bin/sh`. nix-ld cannot help
    #       here (this is path resolution, not dynamic loading); they must exist.
    #   (3) Distro identity — /etc/os-release, probed by the devcontainer runtime
    #       on every `devcontainer up`; ID=nixos also short-circuits the server's
    #       check-requirements.sh glibc-version probe.
    # ==========================================================================

    # (1) ELF loader: standard path -> nixpkgs glibc loader. Arch-derived name,
    #     mirrored across /lib <-> /lib64 for binaries that probe the sibling dir.
    mkdir -p lib lib64
    ln -sf ${pkgs.glibc}/lib/${loaderInfo.name} ${loaderInfo.libDir}/${loaderInfo.name}
    ${
      lib.optionalString (loaderInfo.libDir == "lib") ''
        ln -sf ${pkgs.glibc}/lib/${loaderInfo.name} lib64/${loaderInfo.name}
      ''
    }${
      lib.optionalString (loaderInfo.libDir == "lib64") ''
        ln -sf ${pkgs.glibc}/lib/${loaderInfo.name} lib/${loaderInfo.name}
      ''
    }

    # (2) Interpreter paths /bin/sh + /usr/bin/env come from dockerTools.binSh /
    #     dockerTools.usrBinEnv in `contents` (byte-identical symlinks to
    #     bashInteractive/bin/bash and coreutils/bin/env). /bin/sh is hardcoded by
    #     many tools + the entrypoint's exec target; the VS Code Server bootstrap
    #     scripts (check-requirements.sh and siblings) use `#!/usr/bin/env sh`, so
    #     without /usr/bin/env the kernel rejects the shebang (exit 126) and the
    #     server never installs.

    # (3) Distro identity — silences the devcontainer distro probe; ID=nixos also
    #     short-circuits the server's check-requirements.sh glibc-version check.
    mkdir -p etc usr/lib
    cat > etc/os-release <<'OSRELEASE'
    NAME="nix-config devcontainer"
    ID=nixos
    ID_LIKE=nixos
    PRETTY_NAME="nix-config devcontainer (distroless)"
    VERSION_ID="unstable"
    HOME_URL="https://github.com/${orgName}/nix-config"
    OSRELEASE
    ln -sf /etc/os-release usr/lib/os-release

    # --- runtime writable dirs -----------------------------------------------
    # writable HOME for vscode (gh config, ~/.claude, npm cache).
    mkdir -p home/${username}
    chown -R ${toString uid}:${toString gid} home/${username}

    # world-writable, sticky /tmp (nix-daemon.log lands here; nix build tmp).
    mkdir -p tmp
    chmod 1777 tmp

    # workspace bind-mount target.
    mkdir -p .${workdir}
    chown -R ${toString uid}:${toString gid} workspaces

    # --- runtime Nix state dirs ----------------------------------------------
    # The store DB itself is baked by `includeNixDB = true` above (registers the
    # closure of `contents`); it also creates db/ + gcroots/. We still pre-create
    # daemon-socket/, profiles/ and temproots/ (with the upstream --daemon
    # installer's perms) so the daemon never has to mkdir them at runtime over
    # baked-immutable /nix — which can crash the worker after the listen socket is
    # already visible. CRITICAL: do NOT bind-mount a volume over /nix in
    # devcontainer.json — it shadows this baked warm store.
    mkdir -p nix/var/nix/db nix/var/nix/profiles nix/var/nix/gcroots nix/var/nix/temproots \
             nix/var/nix/daemon-socket
    chmod 0755 nix/var/nix/daemon-socket

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
    extra-substituters = ${cachixUrl}
    extra-trusted-public-keys = ${cachixKey}
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
      # nix-ld env contract for FOREIGN (non-Nix) glibc binaries (the VS Code
      # Server's node, prebuilt language servers): the /lib*/ld-linux-*.so.*
      # symlink (fakeRootCommands) lets the kernel EXEC them; these vars let the
      # loader FIND their shared libs. Baking the broad SHARED library set — the
      # same one the NixOS hosts use (modules/shared/nix-ld-libraries.nix) — means
      # the next foreign binary needing zlib/openssl/libGL runs with no image
      # change, ending the per-soname whack-a-mole. LD_LIBRARY_PATH mirrors
      # NIX_LD_LIBRARY_PATH because we symlink the standard loader straight to
      # nixpkgs glibc (distroless: no system loader to protect), so the REAL loader
      # — not a nix-ld shim binary — reads LD_LIBRARY_PATH. These are the same
      # store paths the co-installed Nix binaries already resolve via their own
      # RUNPATH (ABI-identical), so the global shadow is benign; the CI smoke test
      # (nix store ping / nix build) confirms it.
      "NIX_LD=${pkgs.stdenv.cc.bintools.dynamicLinker}"
      "NIX_LD_LIBRARY_PATH=${nixLdLibraryPath}"
      "LD_LIBRARY_PATH=${nixLdLibraryPath}"
    ];
  };
}
