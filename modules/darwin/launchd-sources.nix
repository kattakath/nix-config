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
# So a `selfHeals = false; domain = "gui"` source is covered by NEITHER — true
# today of the TWO remaining `launchd.user.agents` units, both in the `tart-vms`
# capsule (`gitlab-runner`, `tart-runner-dontsell-vm`), which has no
# home-manager lane and whose `runnerStateDir` default reads nix-darwin's
# `config.system.primaryUserHome`. It was FIVE until 2026-10-02. The fleet's
# standing remedy is MIGRATION to the home-manager lane, where upstream already
# owns the probe (metube and yt-dlp-web-ui moved 2026-09-22 for exactly this;
# `open-maccy` and the two trash sweeps followed on 2026-10-02 into
# modules/home/macos-user-agents.nix, Labels pinned so BTM state survived, gated
# by `checks.<system>.launchd-selfheal-lane`; logging.nix's user tick was
# declared there rather than in `launchd.user.agents` for the same reason, and
# its header says so). Do not "fix" it by widening the reconciler: that
# hand-rolls a second re-bootstrap for a lane the fleet is emptying.
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
