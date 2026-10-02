# THE FOUR LAUNCHD SOURCES ON A DARWIN HOST — enumerated ONCE.
#
# A darwin host composes launchd units from four independent option surfaces, two
# layers and two launchd domains:
#
#   home-manager   launchd.agents        -> ~/Library/LaunchAgents   gui/<uid>
#   nix-darwin     launchd.user.agents   -> ~/Library/LaunchAgents   gui/<uid>
#   nix-darwin     launchd.agents        -> /Library/LaunchAgents    gui/<uid>
#   nix-darwin     launchd.daemons       -> /Library/LaunchDaemons   system
#
# WHY A FILE AND NOT A LIST IN EACH CONSUMER. Three modules walk this surface and
# each one fails SILENTLY on a dropped source — no build goes red, the unit simply
# stops being covered:
#
#   checks.<system>.launchd-log-rotation  a log that reaches no rotator grows
#                                         unbounded (modules/parts/checks.nix)
#   launchd-reconcile.nix                 a unit outside its domain is never
#                                         re-bootstrapped (./launchd-reconcile.nix)
#
# A list typed twice is two lists; the drift between them is invisible precisely
# because the failure mode of BOTH consumers is doing nothing. nix-darwin's
# `launchd.agents` is the one that proves it: it is a DIFFERENT option from
# `launchd.user.agents` (pinned nix-darwin modules/launchd/default.nix:139 vs
# :171, rendered to environment.launchAgents and environment.userLaunchAgents
# respectively), nothing in this tree declares one today, and a consumer that
# walked only three sources would stay green on the first unit declared there.
#
# `key` IS NOT COSMETIC. The two layers store the raw plist under different attrs
# — home-manager under `config`, nix-darwin under `serviceConfig` — so a consumer
# that hardcodes one reads `{ }` from the other and reports a clean sweep over
# half the fleet's units.
#
# `selfHeals` AND `domain` RECORD WHICH MECHANISM COVERS WHICH SOURCE, which is
# the whole reason ./launchd-reconcile.nix is daemon-only rather than four-way:
#
#   selfHeals  home-manager's activation PROBES with `launchctl print` and falls
#              through to bootout+install+bootstrap when a plist is unchanged but
#              the agent is not loaded (pinned home-manager
#              modules/launchd/default.nix:326-331 and :445-452). nix-darwin's
#              activation is diff-gated in BOTH its lanes — modules/system/launchd.nix
#              wraps the system body at :19 and the user body at :37 in
#              `if ! diff <old> <new>` — so an unchanged plist means the
#              unload/copy/load body never runs at all.
#   domain     launchd-reconcile.nix runs as root, from `postActivation` AND from
#              `activate-system`'s boot script. At boot there is no logged-in user,
#              so `gui/<uid>` DOES NOT EXIST — its boot half cannot reach a gui
#              agent even in principle, and its probe/verbs (`launchctl print
#              system/<label>`, `bootstrap system <plist>`) are system-domain. The
#              gui lanes need `launchctl asuser <uid> sudo --user=<user>` (the shape
#              upstream's own userLaunchdActivation uses), i.e. a second mechanism,
#              not a wider filter.
#
# So a `selfHeals = false; domain = "gui"` source is covered by NEITHER — and as
# of 2026-10-02 NOTHING composed on `macos` sits there. It was FIVE. metube and
# yt-dlp-web-ui moved 2026-09-22; `open-maccy` and the two trash sweeps followed
# into modules/home/macos-user-agents.nix; then the two `tart-vms` CI runner
# lanes (`gitlab-runner`, `tart-runner-<instance>`) finished the row. Labels were
# pinned every time, so each unit kept its Background Task Management approval.
#
# THE TWO CI LANES WERE NOT THE HARD CASE THEY LOOKED LIKE, and this is the part
# worth recording: the obstacle was assumed to be that the `tart-vms` capsule has
# no home-manager lane, so a migration would have to add one. It does not have to.
# A nix-darwin module can declare straight into
# `home-manager.users.<primaryUser>.launchd.agents` — ./logging.nix:337 already
# did exactly that for its own user tick — and for these two that is the only
# correct shape, because their plists derive from nix-darwin options
# (`local.tart.runnerStateDir` defaults off `config.system.primaryUserHome`,
# `environment.systemPackages`, the state-dir mkdir). A second home-manager-class
# capsule module would have had to re-derive each plist through an internal
# option, and a consumer importing only the darwin half would have lost every
# runner SILENTLY. Lane, not layer: what self-heals is the OPTION SURFACE a unit
# lands on, never which file writes it.
#
# `checks.<system>.launchd-selfheal-lane` gates the LANE'S EMPTINESS as its first
# leg, not just the five Labels — every per-unit leg names a unit, which is how
# five of them accumulated here unnoticed. A new unit declared on this row now
# fails the build.
#
# The last `launchd.user.agents` text left in the tree is in
# modules/features/tart-vms/darwin.nix (`local.tart.vms.*`), and it reaches no
# host: that module lost its only consumer when `macvm` was removed 2026-09-05,
# and modules/parts/compose.nix inherits only the two runner lanes from the
# capsule — so `local.tart.vms` is not even a declared option on `macos`. It is
# the subject of docs/macvm-readd-runbook.md and moves with that re-add.
#
# Do not "fix" a future unit here by widening ./launchd-reconcile.nix. Both
# bullets above say why it cannot work: nix-darwin's own activation is diff-gated
# in BOTH lanes, so it will not re-load an unchanged plist, and the reconciler's
# boot half runs before any login, where `gui/<uid>` does not exist at all.
# Widening the filter hand-rolls a second re-bootstrap for a lane the fleet has
# already emptied.
#
# NOT A MODULE. hosts/macos.nix imports modules/darwin/*.nix by explicit path
# (flake.nix's import-tree only matches modules/parts/* and
# modules/features/*/flake-module.nix), so a plain function here is never
# auto-imported as a nix-darwin module.
#
# `config` IS THE DARWIN SYSTEM CONFIG of the host being described — the module's
# own `config` from inside modules/darwin/, or
# `config.flake.darwinConfigurations.<host>.config` from the engine.
{
  config,
  loginName,
}:
[
  {
    name = "home-manager launchd.agents";
    units = config.home-manager.users.${loginName}.launchd.agents or { };
    key = "config";
    domain = "gui";
    selfHeals = true;
  }
  {
    name = "nix-darwin launchd.user.agents";
    units = config.launchd.user.agents or { };
    key = "serviceConfig";
    domain = "gui";
    selfHeals = false;
  }
  {
    name = "nix-darwin launchd.agents";
    units = config.launchd.agents or { };
    key = "serviceConfig";
    domain = "gui";
    selfHeals = false;
  }
  {
    name = "nix-darwin launchd.daemons";
    units = config.launchd.daemons or { };
    key = "serviceConfig";
    domain = "system";
    selfHeals = false;
  }
]
