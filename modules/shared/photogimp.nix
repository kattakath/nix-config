# PhotoGIMP — the Photoshop-like layout/shortcut patch for GIMP (darwin only).
#
# WHAT THIS IS
# PhotoGIMP (github.com/Diolinux/PhotoGIMP, GPL-3.0) is NOT a fork or a separate
# binary: it is a bundle of replacement files for GIMP's USER PROFILE directory —
# `shortcutsrc` (Adobe's documented shortcuts), `toolrc` + `sessionrc` (Photoshop
# tool order and panel layout), `gimprc`, `contextrc`, `theme.css`, `tool-options/`,
# `plug-in-settings/`, `filters/`, and a splash. GIMP itself comes from the `gimp`
# Homebrew cask (modules/darwin/homebrew.nix); this module only patches its config.
#
# WHY AN ACTIVATION COPY AND NOT `home.file`
# These files are MUTABLE — GIMP rewrites `sessionrc`, `gimprc`, and `contextrc`
# when it exits. `home.file` would place read-only /nix/store SYMLINKS; GIMP's
# write-then-rename would replace the symlink with a real file, and the next
# `darwin-rebuild switch` would abort on the collision (the classic
# home-manager-vs-app-owned-config fight). So we COPY the payload in and hand
# ownership to GIMP.
#
# SEEDING SEMANTICS: the stamp file records the payload's store path. The copy
# runs when the stamp is missing (fresh Mac) or stale (the pinned release below
# was bumped) — never otherwise, so in-app tweaks and window layout survive every
# rebuild. Bumping `version`/`hash` deliberately re-seeds and overwrites them.
#
# PROFILE DIRECTORY: GIMP keys its profile on the MAJOR.MINOR version
# (~/Library/Application Support/GIMP/<gimpSeries>). The upstream zip ships a
# `3.0/` root, but the patch is compatible across the 3.x series — we strip that
# root and re-target the series actually installed. A GIMP 3.4 upgrade means
# bumping `gimpSeries` here (an unpatched fresh profile is the failure mode, not
# a broken one).
#
# KNOWN MACOS CAVEAT: PhotoGIMP's shortcuts follow Adobe's WINDOWS documentation,
# i.e. Ctrl-based, whereas GIMP on macOS conventionally maps to Cmd. Expect some
# shortcuts to land on Ctrl; rebind individually in Edit ▸ Keyboard Shortcuts.
{ pkgs, lib, ... }:
let
  # The GIMP profile series on this Mac — `gimp --version` reports 3.2.x, so the
  # profile lives in ~/Library/Application Support/GIMP/3.2.
  gimpSeries = "3.2";

  profileDir = "$HOME/Library/Application Support/GIMP/${gimpSeries}";

  # The generic (non-Linux) payload: config files only, no .desktop/icons. Its
  # single `3.0/` root is stripped by fetchzip's default stripRoot, so the
  # derivation IS the profile contents.
  photogimp = pkgs.fetchzip {
    name = "photogimp-3.1";
    url = "https://github.com/Diolinux/PhotoGIMP/releases/download/3.1/PhotoGIMP.zip";
    hash = "sha256-wCn7ShhJfK6Xs7Cc56cQ7El+SUN6s0cjpvA71gQDbhc=";
  };
in
{
  home.activation = lib.mkIf pkgs.stdenv.isDarwin {
    # Seed the GIMP profile with the PhotoGIMP config. rsync (not cp -R) so a
    # partial/interrupted copy converges, and `--chmod=u+w` because everything
    # copied out of the store arrives read-only (444/555) — GIMP must be able to
    # rewrite sessionrc/gimprc on exit.
    photogimpProfile = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      photogimpStamp="${profileDir}/.photogimp-source"
      if [ "$(cat "$photogimpStamp" 2>/dev/null || true)" != "${photogimp}" ]; then
        $DRY_RUN_CMD /bin/mkdir -p "${profileDir}"
        $DRY_RUN_CMD ${pkgs.rsync}/bin/rsync -a --chmod=u+w \
          "${photogimp}/" "${profileDir}/"
        echo "${photogimp}" | $DRY_RUN_CMD ${pkgs.coreutils}/bin/tee "$photogimpStamp" >/dev/null
      fi
    '';
  };
}
