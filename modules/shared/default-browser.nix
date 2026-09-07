# The macOS default browser, claimed declaratively.
#
# This is a fleet-level concern, not a Chromium one — the handler is a property of
# LaunchServices, and any installed browser can hold it. It lived in
# `modules/shared/chromium.nix` while Chromium was the answer; it moved here when it
# stopped being (Opera Air is the default, Chromium is the debugging browser whose
# profile `services.mcpGateway.chromeDevtools.userDataDir` points at).
#
# `defaultbrowser` takes the SHORT name (`operaair`, `chromium`, `safari`, `opera`),
# NOT the bundle id — `com.operasoftware.OperaAir` is rejected as "not available as an
# HTTP handler". Run the CLI with NO ARGUMENTS for a read-only list of the handlers it
# recognises, with the current default starred; that doubles as this option's doctor.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.defaultBrowser;
in
{
  options.local.defaultBrowser = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "operaair";
    description = ''
      Short `defaultbrowser` handler name to claim `http`/`https` (and so
      `public.html`) for in LaunchServices, making it the macOS default browser.
      `null` claims nothing and leaves whatever the Mac already has.

      **Idempotent, and that is the tool's own doing, not ours:** `defaultbrowser`
      reads the current handler first and early-returns with "<name> is already set
      as the default HTTP handler", never touching LaunchServices. So a settled Mac
      is a true no-op and there is nothing to re-confirm on a routine `activate`.
      That matters because of the next point.

      **Expect one consent dialog, once, on the activation that actually changes the
      handler.** It is not avoidable and not a bug: `defaultbrowser` calls Launch
      Services' `LSSetDefaultHandlerForURLScheme`, whose SDK-declared replacement,
      `-[NSWorkspace setDefaultApplicationAtURL:toOpenURLsWithScheme:completionHandler:]`,
      is documented in `AppKit/NSWorkspace.h` as: *"Some URL schemes require user
      consent before you can change their handlers. If a change requires user
      consent, the system will ask the user asynchronously"*. The browser schemes are
      exactly those, for every tool and every API.

      The legacy API is safe to keep using: the macOS 26 SDK still declares it
      `API_TO_BE_DEPRECATED`, i.e. soft-deprecated with no removal version. `duti` is
      the obvious alternative and is passed over — it takes bundle ids but has no
      idempotence guard, so it would re-ask every activation.
    '';
  };

  config = lib.mkIf (cfg != null && pkgs.stdenv.hostPlatform.isDarwin) {
    # The CLI doubles as this setting's read-only doctor (no args → the handler list,
    # current default starred), so it is worth a PATH entry.
    home.packages = [ pkgs.defaultbrowser ];

    # Not a launchd unit — a plain activation step, so launchd-naming.md's
    # `nix-<kebab>` arg0 rule does not apply (nothing lands in BTM).
    #
    # Tolerates its own failure on purpose: browsers here are Homebrew casks, and
    # nothing orders brew's activation before Home Manager's, so on a first-ever
    # rebuild the .app may not be registered with LaunchServices yet. Warn and move
    # on; the next activation picks it up. Never fail a rebuild over which browser
    # opens a link.
    home.activation.defaultBrowser = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD ${lib.getExe pkgs.defaultbrowser} ${lib.escapeShellArg cfg} \
        || /usr/bin/printf '%s\n' "warning: could not make ${cfg} the default browser (cask not registered yet?) — retried next activation"
    '';
  };
}
