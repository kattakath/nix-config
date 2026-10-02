# OPERATOR-ONLY — not part of the reusable engine; the template mkForce-disables or omits this.
# Übersicht — the one declared desktop widget: a single HTML file, rendered
# full-screen behind every window with no chrome, re-read every five minutes.
#
# The app is a Homebrew cask (hosts/macos.nix) because Übersicht is a
# signed .app with no nixpkgs/home-manager packaging; Nix owns only the widget.
# Übersicht watches its widgets directory (chokidar) and hot-loads any `*.jsx`
# it finds — including a Home Manager symlink into the store — so materialising
# the file IS the install; there is no registration step and no launchd unit.
#
# upstream-first: grepped home-manager/modules and nix-darwin/modules for
# `ubersicht`/`übersicht` (2026-09-15, both pinned inputs) — no option exists in
# either, so this is a plain `home.file` entry, not a hand-rolled activation shim.
#
# Rendering: the file goes into an `<iframe srcDoc>` rather than
# `dangerouslySetInnerHTML`. A full HTML document (its own `<head>`, `<style>`,
# scripts) renders as a document inside an iframe; innerHTML would strip
# `<html>`/`<head>`/`<body>` and leak the file's CSS into Übersicht's page.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.ubersicht;
  # Übersicht's own default; changeable in the app's preferences, in which case
  # the option below must follow it.
  widgetsDir = "Library/Application Support/Übersicht/widgets";
in
{
  options.local.ubersicht = {
    htmlWidget = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "$HOME/.local/share/ubersicht/next-right-thing.html";
      description = ''
        Runtime path of the ONE HTML file to render as a full-screen Übersicht
        widget. A shell string, not a Nix path: it is interpolated into the
        widget's `command` (run by Übersicht via `/bin/sh`), so `$HOME` expands
        and the file is read live at every refresh — never copied into the store.
        `null` places no widget.

        Keep it OUT of `~/Desktop`, `~/Documents` and `~/Downloads`. Übersicht is
        unsandboxed and shells out via `/bin/sh`, which TCC denies in those three
        directories, so the widget renders an EPERM instead of the file.
      '';
    };

    refreshMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = "How often Übersicht re-reads the file.";
    };

    widgetsDir = lib.mkOption {
      type = lib.types.str;
      default = widgetsDir;
      description = ''
        `$HOME`-relative widgets directory. Only change it if Übersicht's own
        "Widgets folder" preference was moved off its default.
      '';
    };
  };

  config = lib.mkIf (cfg.htmlWidget != null && pkgs.stdenv.hostPlatform.isDarwin) {
    home.file."${cfg.widgetsDir}/html-fullscreen.jsx".text = ''
      // Managed by nix-config (modules/shared/ubersicht.nix) — edits are overwritten.
      // Double-quoted so `$HOME` still expands and a path with spaces survives.
      export const command = "cat \"${cfg.htmlWidget}\"";

      export const refreshFrequency = ${toString (cfg.refreshMinutes * 60 * 1000)};

      // Fill the whole screen; Übersicht draws behind every window and the
      // desktop icons, so this is a live wallpaper, not a floating panel.
      export const className = `
        position: fixed;
        top: 0;
        left: 0;
        width: 100vw;
        height: 100vh;
        margin: 0;
        padding: 0;
        overflow: hidden;
        background: transparent;
      `;

      export const render = ({ output, error }) => {
        if (error) {
          return <pre style={{ color: "#f66", padding: 16 }}>{String(error)}</pre>;
        }
        return (
          <iframe
            title="html-fullscreen"
            srcDoc={output}
            sandbox="allow-scripts allow-same-origin"
            style={{
              border: 0,
              margin: 0,
              padding: 0,
              width: "100%",
              height: "100%",
              display: "block",
              background: "transparent",
            }}
          />
        );
      };
    '';
  };
}
