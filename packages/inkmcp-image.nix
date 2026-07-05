# inkmcp container image — a Linux-ONLY OCI artifact that runs the Inkscape MCP
# server (inkmcp) headless, driving a real Inkscape over D-Bus.
#
# WHY THIS EXISTS / WHY LINUX-ONLY:
#   inkmcp is an Inkscape MCP server in two halves: (a) an MCP server (main.py,
#   fastmcp over STDIO) that drives Inkscape by shelling out to `gdbus`, and
#   (b) an Inkscape EFFECT EXTENSION (org.khema.inkscape.mcp) that performs the
#   actual SVG ops inside a running Inkscape. The server activates the effect via
#   GTK GApplication's org.gtk.Actions D-Bus interface. On LINUX this executes
#   the extension; on macOS the same call is a silent no-op and SEGFAULTS with no
#   document open. So a Linux container is the only working home — and because
#   this image uses `dockerTools.streamLayeredImage` with `enableFakechroot`
#   (forbidden on Darwin), it is gated to `linuxSystems` in flake.nix and never
#   evaluated on the darwin triples.
#
# HARD RUNTIME REQUIREMENTS baked into the entrypoint (each learned by hitting the
# failure): a live D-Bus SESSION bus shared by Inkscape AND the server; Inkscape
# launched with that bus + a virtual DISPLAY (Xvfb) AND a real .svg document
# already open (empty doc crashes); the extension tree COPIED into a writable
# $HOME/.config/inkscape/extensions (the Nix store is read-only) BEFORE Inkscape
# starts so the action registers; `gdbus` on PATH; poll ListNames until
# org.inkscape.Inkscape appears; only then exec `python main.py` (stdio).
#
# The server's python env carries fastmcp (+lxml); it does NOT carry inkex — the
# extension side runs under Inkscape's OWN bundled python. No runtime venv/pip
# (upstream run_inkscape_mcp.sh is replaced by a baked env; the sandbox has no
# network).
#
#   nix build .#packages.<linux>.inkmcpImage   # ./result = stream script
#   ./result | docker load                     # local smoke test
#   docker run -i --rm inkmcp:latest           # MCP client speaks over stdio (-i required)
{
  pkgs,
  lib,
}:

let
  inherit (pkgs) dockerTools;

  username = "root";
  uid = 0;
  gid = 0;
  home = "/root";
  workdir = "/root";

  # Server-side python: fastmcp (>=2.0.0; nixpkgs has 3.x) + lxml. NOT inkex —
  # the extension half runs under Inkscape's bundled python, not this one.
  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.fastmcp
    ps.lxml
  ]);

  # inkmcp source: GitHub release v1.0.0 asset `inkmcp-extension.zip`. fetchurl
  # (NOT fetchzip) because the SRI is over the .zip FILE, not the unpacked tree.
  # Zip layout: top-level inkscape_mcp.py + inkscape_mcp.inx, plus the inkmcp/
  # package dir (main.py, inkscape_mcp_server.py, inkmcpops/, __init__.py, ...).
  inkmcpSrc = pkgs.stdenvNoCC.mkDerivation {
    pname = "inkmcp-src";
    version = "1.0.0";
    src = pkgs.fetchurl {
      url = "https://github.com/Shriinivas/inkmcp/releases/download/v1.0.0/inkmcp-extension.zip";
      hash = "sha256-TvnBZHTSuhdcdDQMtlM6G/Amz3z177cc/k5dVSFwPGM=";
    };
    nativeBuildInputs = [ pkgs.unzip ];
    # The release zip has THREE top-level entries: inkscape_mcp.py and
    # inkscape_mcp.inx (the Inkscape effect-extension registration) plus the
    # inkmcp/ package dir. Nix's default unpackPhase picks the lone inkmcp/
    # SUBDIR as sourceRoot and silently DROPS the two top-level files — so we
    # disable it and unzip straight into $out, preserving the exact layout
    # Inkscape's extensions dir expects (top-level .py/.inx + inkmcp/).
    dontUnpack = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cd "$out"
      unzip -q "$src"
      runHook postInstall
    '';
  };

  # Runtime PATH for the entrypoint: python env, inkscape, gdbus (glib.bin),
  # dbus-launch/dbus-daemon (dbus), Xvfb (xorg.xvfb), plus a coreutils/bash
  # userland. fontconfig/dejavu_fonts/dconf satisfy Inkscape's headless GTK
  # needs. cacert for TLS completeness.
  runtimePackages = with pkgs; [
    pythonEnv
    inkscape
    glib.bin # gdbus
    dbus # dbus-launch + dbus-daemon
    xvfb # Xvfb
    bashInteractive
    coreutils
    gnugrep
    gnused
    findutils
    which
    fontconfig
    dejavu_fonts
    dconf
    cacert
  ];

  # Read-only /etc/passwd + /etc/group via fakeNss (root user only). Appended to
  # contents so dbus/Inkscape can resolve the uid.
  nss = pkgs.fakeNss.override {
    extraPasswdLines = [
      "${username}:x:${toString uid}:${toString gid}:${username}:${home}:${pkgs.bashInteractive}/bin/bash"
    ];
    extraGroupLines = [
      "${username}:x:${toString gid}:"
    ];
  };

  # Entrypoint — the exact boot sequence the runtime requirements dictate.
  entrypoint = pkgs.writeShellScript "inkmcp-entrypoint" ''
    set -euo pipefail

    # 1. Writable HOME + XDG_RUNTIME_DIR + TMPDIR (store is read-only). TMPDIR
    #    must be shared by server (mcp_params.json) and the Inkscape-side
    #    extension — both default to /tmp when TMPDIR is unset, so we pin it.
    export HOME=${home}
    export XDG_RUNTIME_DIR=/tmp/xdg-runtime
    export TMPDIR=/tmp
    mkdir -p "$HOME/.config/inkscape/extensions" "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"

    # 2. Copy the store-baked extension tree into the writable user extensions
    #    dir and make the scripts executable. Inkscape scans this dir for effect
    #    extensions; the org.khema.inkscape.mcp action registers from here.
    cp -r ${inkmcpSrc}/. "$HOME/.config/inkscape/extensions/"
    chmod -R u+w "$HOME/.config/inkscape/extensions"
    find "$HOME/.config/inkscape/extensions" -name '*.py' -o -name '*.sh' \
      | while IFS= read -r f; do chmod +x "$f"; done

    # 3. A D-Bus machine-id MUST exist before any bus/GDBus use. This is not a
    #    NixOS host, so neither /etc/machine-id nor /var/lib/dbus/machine-id is
    #    present — and GLib (_g_dbus_get_machine_id) and libdbus both REFUSE to
    #    auto-generate one, failing with "Invalid machine ID". Without it, both
    #    dbus-launch and Inkscape's GApplication (GDBus) registration break, so
    #    the whole image would be non-functional. Create it (writable container
    #    layer) and point the legacy path at it.
    dbus-uuidgen --ensure=/etc/machine-id
    mkdir -p /var/lib/dbus
    ln -sf /etc/machine-id /var/lib/dbus/machine-id

    # 4. Start a D-Bus SESSION bus at a known address; export it so BOTH Inkscape
    #    and the server share the SAME bus (required for name registration +
    #    calls). We DON'T use `dbus-launch` (nixpkgs patches it to a NixOS-only
    #    /run/current-system daemon path) NOR `dbus-daemon --session` (whose
    #    nixpkgs session.conf resolves to no usable <listen> in a non-NixOS
    #    container: "Configuration file needs one or more <listen> elements").
    #    Instead we hand dbus-daemon a minimal, self-contained config with an
    #    explicit <listen> at our address and a permissive session policy.
    cat > /tmp/inkmcp-dbus-session.conf <<DBUSCONF
    <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
    <busconfig>
      <type>session</type>
      <listen>unix:path=$XDG_RUNTIME_DIR/bus</listen>
      <policy context="default">
        <allow send_destination="*" eavesdrop="true"/>
        <allow eavesdrop="true"/>
        <allow own="*"/>
      </policy>
    </busconfig>
    DBUSCONF
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    dbus-daemon --config-file=/tmp/inkmcp-dbus-session.conf --nofork --nopidfile &
    for _ in $(seq 1 50); do
      [ -S "$XDG_RUNTIME_DIR/bus" ] && break
      sleep 0.1
    done
    [ -S "$XDG_RUNTIME_DIR/bus" ] || { echo "inkmcp: D-Bus session bus failed to start" >&2; exit 1; }

    # 5. Virtual framebuffer + DISPLAY (Inkscape is a GUI app even headless).
    Xvfb :99 -screen 0 1024x768x24 >/tmp/xvfb.log 2>&1 &
    export DISPLAY=:99
    for _ in $(seq 1 50); do
      [ -e /tmp/.X11-unix/X99 ] && break
      sleep 0.1
    done

    # 6. A REAL document must be open before any command (empty doc crashes with
    #    an emergency save). Write a blank canvas and launch Inkscape with it, on
    #    the shared bus + display, in the background.
    doc=/tmp/inkmcp-canvas.svg
    cat > "$doc" <<'SVG'
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="768"
         viewBox="0 0 1024 768"></svg>
    SVG
    inkscape "$doc" >/tmp/inkscape.log 2>&1 &

    # 7. Poll until Inkscape's GApplication has claimed its bus name — only then
    #    is it ready to service effect activations.
    ready=0
    for _ in $(seq 1 100); do
      if gdbus call --session \
          --dest org.freedesktop.DBus \
          --object-path /org/freedesktop/DBus \
          --method org.freedesktop.DBus.ListNames 2>/dev/null \
          | grep -q org.inkscape.Inkscape; then
        ready=1
        break
      fi
      sleep 0.2
    done
    [ "$ready" = 1 ] || { echo "inkmcp: Inkscape never registered on the session bus" >&2; exit 1; }

    # 8. Exec the MCP server (stdio transport). exec so signals + stdio forward
    #    to the server as PID 1's payload; run with `docker run -i`.
    cd "$HOME/.config/inkscape/extensions/inkmcp"
    exec ${pythonEnv}/bin/python main.py
  '';
in
dockerTools.streamLayeredImage {
  name = "inkmcp";
  tag = "latest";

  contents = runtimePackages ++ [ nss ];

  # Store-path -> layer fan-out, under dockerTools' 125-layer ceiling.
  maxLayers = 120;

  # enableFakechroot lets fakeRootCommands see the merged rootfs (store paths +
  # /bin/sh) via fakechroot+proot — forbidden on Darwin, which is precisely why
  # this derivation is Linux-gated in flake.nix.
  enableFakechroot = true;
  fakeRootCommands = ''
    set -eu

    # /bin/sh + /usr/bin/env: many tools (and dbus-launch/Xvfb wrappers) hardcode
    # these interpreter paths. Relative paths — fakeRootCommands runs at rootfs /.
    mkdir -p bin usr/bin
    ln -sf ${pkgs.bashInteractive}/bin/bash bin/sh
    ln -sf ${pkgs.coreutils}/bin/env usr/bin/env

    # Writable HOME for the root user (extension copy, fontconfig cache, configs).
    mkdir -p root
    chown -R ${toString uid}:${toString gid} root

    # World-writable sticky /tmp (Xvfb socket, dbus, mcp_params.json, canvas svg).
    mkdir -p tmp
    chmod 1777 tmp

    # Xvfb needs /tmp/.X11-unix to exist and be writable for its listening socket.
    mkdir -p tmp/.X11-unix
    chmod 1777 tmp/.X11-unix
  '';

  config = {
    User = "${toString uid}:${toString gid}";
    WorkingDir = workdir;
    Entrypoint = [ "${entrypoint}" ];
    # No keepalive Cmd: the entrypoint execs the long-lived stdio server itself.
    Env = [
      "PATH=${lib.makeBinPath runtimePackages}:/bin"
      "HOME=${home}"
      "USER=${username}"
      "LANG=C.UTF-8"
      "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      "GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      # GLib/GTK schema + fontconfig discovery for headless Inkscape.
      "FONTCONFIG_FILE=${pkgs.fontconfig.out}/etc/fonts/fonts.conf"
      "GSETTINGS_SCHEMA_DIR=${pkgs.glib.out}/share/glib-2.0/schemas"
      "XDG_DATA_DIRS=${pkgs.dejavu_fonts}/share:${pkgs.glib.out}/share"
    ];
  };
}
