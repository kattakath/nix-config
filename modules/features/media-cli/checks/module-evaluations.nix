# THE OPTION LAYER OF THE CAPSULE BOUNDARY (ADR-002 §2) — the three evaluation
# checks the satellite declared inline in its own `flake.nix`, carried over with
# their bodies and their comments intact.
#
# They are in a file rather than in ./flake-module.nix for the reason every
# absorbed capsule found: the satellite's flake.nix was allowed to be long
# because it was the whole repo, and a capsule's entry file is not. `module`,
# `home-manager` and `packageGraph` arrive as ARGUMENTS because a capsule leaf
# may not reach up with `../` (ast-grep/rules/capsule-must-not-reach-out.yml);
# ./flake-module.nix passes each one down.
{
  pkgs,
  home-manager,
  module,
  packageGraph,
}:
let
  mkHm =
    extra:
    home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      # `extra` is its OWN module, never `base // extra`: `//` is a
      # SHALLOW merge, so `{ programs.mediaCli.ollamaHost = …; }`
      # replaces the whole `programs` attrset and takes
      # `programs.mediaCli.enable = true` with it — the module then
      # defines no agents at all and the assertion below dies on a
      # missing attribute instead of testing anything. The module
      # system merges module lists deeply; that is its job.
      modules = [
        module
        {
          home.username = "tester";
          home.homeDirectory = "/Users/tester";
          home.stateVersion = "24.05";
          programs.mediaCli.enable = true;
        }
        extra
      ];
    };
  hm = mkHm { };
  workerArg0 = c: builtins.head c.config.launchd.agents.media-queue.config.ProgramArguments;

  # The kill-switch fixtures. Two configurations that differ by exactly one
  # thing — whether this module is in the list at all — and `enable` set in
  # neither. Separate from `mkHm` because that helper hard-codes
  # `enable = true`, which is right for every other check here and exactly
  # wrong for this one.
  fixture = {
    home.username = "tester";
    home.homeDirectory = "/Users/tester";
    home.stateVersion = "24.05";
  };
  mkOff =
    modules:
    home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = modules ++ [ fixture ];
    };
  hmOff = mkOff [ module ];
  hmBare = mkOff [ ];
  bool = b: if b then "yes" else "no";
  # `home.packages` is NOT empty in a bare home-manager configuration — it
  # carries whatever upstream's own modules put there — so "empty" is the wrong
  # assertion and measured as such: it failed on the first run of this check.
  # The right one is DIFFERENCE against the same configuration without this
  # module, which is the only spelling that says "this module contributed
  # nothing" rather than "home-manager contributed nothing".
  pkgNames =
    c: builtins.concatStringsSep " " (builtins.map (p: p.name or "?") c.config.home.packages);
in
{
  # The module's whole job is the wiring, so assert the wiring:
  # both launchd agents exist, the worker watches all three priority
  # tiers, and the agent's arg0 is a /nix/store `nix-*` path. That
  # last one is not cosmetic — an adhoc-signed /nix/store arg0 is
  # what lets the worker READ the TCC-protected folders it exists to
  # work on; a bare interpreter there silently reads nothing.
  module-evaluates =
    let
      agents = hm.config.launchd.agents;
      worker = agents.media-queue.config;
      arg0 = builtins.head worker.ProgramArguments;
    in
    pkgs.runCommand "media-cli-module-eval" { } ''
      test "${toString (builtins.length worker.QueueDirectories)}" = 3
      test "${toString worker.RunAtLoad}" = "1"
      test "${worker.ProcessType}" = "Background"
      test "${toString agents.media-queue-power.config.StartInterval}" = "20"
      case "${builtins.baseNameOf arg0}" in nix-*) ;; *) echo "arg0 must be nix-*: ${arg0}" >&2; exit 1 ;; esac
      case "${arg0}" in /nix/store/*) ;; *) echo "arg0 must be a store path: ${arg0}" >&2; exit 1 ;; esac
      echo ok > "$out"
    '';

  # REGRESSION GUARD for a bug this repo actually shipped: an
  # `ollamaHost` that reached the interactive CLI and NOT the launchd
  # worker, because its only delivery was `home.sessionVariables` and
  # a launchd agent inherits no shell profile. Ollama is a SOFT
  # dependency, so the worker did not fail — it wrote labels with no
  # caption and said "no ollama at ...". Silent, and invisible while
  # the option's default happened to equal the tool's own fallback.
  #
  # Asserted as INEQUALITY rather than by grepping a closure: if the
  # host does not reach the worker, the two agents are byte-identical
  # and their arg0 is the same store path. That is exactly the old
  # behaviour, and it is a pure evaluation — no closure walk, no
  # sandbox question about whether a runtime reference is present.
  host-reaches-worker =
    let
      a = workerArg0 (mkHm {
        programs.mediaCli.ollamaHost = "127.0.0.1:11434";
      });
      b = workerArg0 (mkHm {
        programs.mediaCli.ollamaHost = "sentinel.invalid:65000";
      });
    in
    pkgs.runCommand "media-cli-host-reaches-worker" { } ''
      test "${a}" != "${b}" || {
        echo "programs.mediaCli.ollamaHost does not reach the launchd worker" >&2
        echo "both hosts produced arg0: ${a}" >&2
        exit 1
      }
      echo ok > "$out"
    '';

  # THE KILL-SWITCH GATE (ADR-002 §2 anatomy). This module is imported
  # UNCONDITIONALLY by modules/shared/home.nix — the profile every host in the
  # fleet runs, `nixpi` and `nixvm` included — and only then gated to the real
  # Mac by `programs.mediaCli.enable = isMacosHost`. So "off" is the state two
  # of three hosts are in, and anything this module leaks while off lands on
  # them: a launchd agent on a Linux box, an `OLLAMA_HOST` in a server's
  # environment, an activation step that copies Finder Services onto NixOS.
  #
  # Asserted as ATTRIBUTE ABSENCE, not as an empty value. `config.launchd.agents
  # ? media-queue` being false is the only spelling that distinguishes "the
  # module defined nothing" from "the module defined a disabled agent", and the
  # second is the regression worth catching — home-manager renders a disabled
  # agent's plist attrset just the same. `home.packages` is the one that cannot
  # be done that way (it is a LIST, and upstream puts things in it); see
  # `pkgNames` above for the difference-based spelling it uses instead.
  inert =
    let
      c = hmOff.config;
    in
    pkgs.runCommand "media-cli-inert" { } ''
      fail() { echo "media-cli-inert: $*" >&2; exit 1; }
      test "${bool (c.launchd.agents ? media-queue)}" = no \
        || fail "launchd.agents.media-queue exists with programs.mediaCli.enable unset"
      test "${bool (c.launchd.agents ? media-queue-power)}" = no \
        || fail "launchd.agents.media-queue-power exists with programs.mediaCli.enable unset"
      test "${bool (c.home.sessionVariables ? OLLAMA_HOST)}" = no \
        || fail "home.sessionVariables.OLLAMA_HOST is set with programs.mediaCli.enable unset"
      test "${bool (c.home.activation ? mediaCliQuickActions)}" = no \
        || fail "the ~/Library/Services activation runs with programs.mediaCli.enable unset"
      test "${pkgNames hmOff}" = "${pkgNames hmBare}" \
        || fail "home.packages differs from a config without this module: [${pkgNames hmOff}] vs [${pkgNames hmBare}]"
      echo ok > "$out"
    '';

  # The other half: prove the value is actually BAKED, not merely
  # that something in the closure moved. Greps the generated script
  # for a host no resolver will ever answer.
  host-is-baked =
    let
      describe =
        (import packageGraph {
          inherit pkgs;
          defaultHost = "http://sentinel.invalid:65000";
        }).media-describe;
    in
    pkgs.runCommand "media-cli-host-is-baked" { } ''
      grep -q 'sentinel\.invalid:65000' ${describe}/bin/media-describe || {
        echo "defaultHost is not baked into media-describe" >&2
        exit 1
      }
      echo ok > "$out"
    '';
}
