# `page-lab-pick` — the two-way element picker, as a fleet CLI.
#
# WHY A PACKAGE AT ALL. The picker is a plugin script, and a plugin script is normally
# just run with `node`. This wrapper exists for one reason: Node 20 on this fleet has NO
# global `WebSocket` (F-NODE-NO-WS in the plugin's references/facts.md), so the raw-CDP
# client must either re-exec itself with `--experimental-websocket` or run on Node 22+.
# Pinning `nodejs_22` here removes the flag from the fleet path entirely — the script keeps
# its own feature-detect for anyone running it outside Nix, but on this Mac it never fires.
#
# It is NOT the only way to run the picker; `node plugins/page-lab/scripts/pick-element.mjs`
# still works. This is the reproducible entry point, so a session that reaches for the CLI
# gets a known Node rather than whatever is on PATH.
#
# Deliberately NOT a launchd agent and NOT wired to run automatically: arming a picker
# swallows the next click on every armed tab (F-ARMED-SWALLOWS), so it is always an explicit
# act with a visible start and a guaranteed disarm.
{
  lib,
  writeShellApplication,
  nodejs_22,
}:

writeShellApplication {
  name = "page-lab-pick";

  runtimeInputs = [ nodejs_22 ];

  # The script lives in the plugin tree, not here, so there is exactly one copy: the same
  # file the plugin ships to Claude Code is the file this CLI executes. A `cp` into the
  # store would fork them and let the two drift.
  text = ''
    exec node ${../plugins/page-lab/scripts/pick-element.mjs} "$@"
  '';

  meta = {
    description = "Arm Chrome's element picker over CDP and emit a validated pick envelope";
    longDescription = ''
      Arms `Overlay.setInspectMode` on every open page target, waits for the operator to
      click one element, then resolves that node and prints a `page-lab/pick@1` envelope
      on stdout. Always disarms — on success, on timeout, on signal, and via a detached
      watchdog if the process dies outright.

      Requires a browser already listening for CDP, which on this fleet means
      `nix-chromium-debug` (the browser is a Homebrew cask, so a launch flag can never be
      declarative here — F-CASK-NOFLAG).
    '';
    platforms = lib.platforms.all;
    mainProgram = "page-lab-pick";
  };
}
