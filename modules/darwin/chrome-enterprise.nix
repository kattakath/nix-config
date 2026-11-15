# Chrome Enterprise Core: enroll this Mac's Chrome as a MANAGED BROWSER (darwin only).
#
# WHAT IT BUYS. Mandatory, cloud-delivered Chrome policy on a Mac with no MDM. A policy
# that must be mandatory otherwise needs an MDM-installed `/Library/Managed Preferences`
# plist, and this fleet has none (docs/macos-settings-surface.md § Browser policies).
# Enrollment gives the machine a browser record in the Google Admin console, in the
# organizational unit the token belongs to; policies set on that unit then reach EVERY
# Chrome profile on the Mac, whatever account a profile is signed in to.
#
# THE MECHANISM IS ONE FILE. Chrome reads an enrollment token from
# `/Library/Google/Chrome/CloudManagementEnrollmentToken` (bare token, whitespace trimmed)
# on launch — the documented no-MDM route, and the only one: Chromium's
# `browser_dm_token_storage_mac.mm` guards the preference route behind
# `CFPreferencesAppValueIsForced`, so a `defaults write` is ignored. On first launch Chrome
# trades the token for a device token under
# `~/Library/Application Support/Google/Chrome Cloud Enrollment/` and uses that from then on.
#
# WHY agenix AND NOT A PLAIN FILE. The token is not a login, but whoever holds it can enroll
# a browser into the tenant, and the store is world-readable. agenix's own
# `age.secrets.<name>.path` links the decrypted file to an arbitrary path, so no activation
# script of ours is involved (upstream-first: grepped nix-darwin, home-manager and agenix
# `modules/` for `CloudManagementEnrollment`, `enrollment token` and `Library/Google/Chrome`
# — no option exists; agenix `modules/age.nix`'s `path` is the reused piece).
#
# WHAT IS NOT DECLARED HERE. The policies are the `gws-chrome` terranix stack
# (infra/google-workspace/chrome.nix), set on the token's organizational unit; the unit, the
# token and the admin role stay in the Admin console (docs/workspace-runbook.md § 8).
# `CloudManagementEnrollmentOptions = Mandatory` is deliberately
# NOT written: with it, a failed FIRST enrollment blocks Chrome from launching at all, and
# the decrypted token is absent until `activate-agenix` has run after a boot.
#
# TURNING IT OFF does not unenroll. Disabling removes the token link only; the browser
# stays enrolled through its device token until it is deleted in the console. After a
# console-side delete Chrome writes an invalid-token marker and will NOT re-enroll until the
# `Chrome Cloud Enrollment` directory above is removed by hand.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.chromeEnterprise;
in
{
  options.local.chromeEnterprise.enable = lib.mkEnableOption ''
    Chrome Enterprise Core browser enrollment: the agenix-held enrollment token linked
    to the path Chrome reads on a Mac with no MDM
  '';

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isDarwin) {
    # Owned by the login user because Chrome reads it as that user, not as root.
    age.secrets."chrome-enrollment-token" = {
      file = ../../secrets/chrome-enrollment-token.age;
      path = "/Library/Google/Chrome/CloudManagementEnrollmentToken";
      owner = config.system.primaryUser;
      mode = "0400";
    };
  };
}
