{ pkgs, lib, ... }:
# "Brain Signals" — the fleet's Claude Code ANSWER-SHAPE kit: a BLUF-first,
# layered, scannable output style, a companion calibration rule, the
# `/explain`-family explainer skills, the `cartographer` read-only architecture
# subagent, and `/task` (goal-locked execution).
#
# WHY THIS IS PUBLIC. It is an accessibility calibration, not a secret: the same
# ADHD/dyslexia answer-shape requirement is already spelled out in this repo's
# own global context (claude/CLAUDE.md § "Answer shape"), and the diagrams rule
# there is the prose twin of the output style's § Diagrams. Keeping the style
# itself private meant the two halves could drift with nothing to catch it, and
# meant a forker got the rule with no mechanism to satisfy it. Moved out of the
# private nix-personal layer 2026-09-12; nix-personal now contributes nothing
# here.
#
# EVERY CONTENT CLASS BELOW IS EXTENDABLE, DELIBERATELY. `outputStyles`,
# `agents`, `commands`, `rules` are `attrsOf (either lines path)` and `skills`
# is `either (attrsOf …) path` — all of them merge PER KEY across modules, so a
# private layer (or a fork) ADDS its own entries and these survive untouched.
# Two rules keep that true:
#   - never route extra global prose through `context` (options.nix:134,
#     `either lines path`): modules/shared/home.nix already defines it as a
#     PATH, and a second path definition is a hard eval error, not a merge.
#     Extra global instructions arrive as another `rules.<name>` instead.
#   - never set `skills` to a bare path, and never use the `rulesDir`/`agentsDir`/
#     `commandsDir` forms: a path collapses `either` to mergeOneOption, and
#     upstream asserts rules XOR rulesDir (default.nix:247-259). Either one
#     destroys the seam for everyone downstream.
#
# Content lives in ../../claude/<class>/ (global agent context, next to
# CLAUDE.md) and ../../skills/<name>/ (global skills, next to rag/
# android-phone). Those are SOURCE PATH LITERALS, resolved relative to THIS
# file — repo-relative is correct and required; a $HOME path is impossible here.
#
# Top-level `lib.mkIf isDarwin`, matching ./claude-bedrock-gate.nix: upstream's
# own `config = lib.mkIf cfg.enable` (default.nix:227) already emits nothing on
# the NixOS hosts, and home.nix:938 keeps `programs.claude-code` darwin-only, so
# this gate is belt-and-braces that also keeps nixpi/nixvm byte-identical.
lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
  programs.claude-code = {
    outputStyles.brain-signals = ../../claude/output-styles/brain-signals.md;
    agents.cartographer = ../../claude/agents/cartographer.md;
    rules.brain-signals-context = ../../claude/rules/brain-signals-context.md;
    # /task — goal-locked execution protocol: bounded scout, an approved
    # contract (goal / runnable done-when / out-of-scope), a FROZEN TodoWrite
    # list worked one item at a time, and a parking lot for everything found
    # off-plan. Exists because the drift is bidirectional: mid-task discoveries
    # pull Claude off the ask, and "oh also…" pulls the operator off it. Routes
    # to the resources already on this fleet (Explore/cartographer/Plan agents,
    # systematic-debugging, gh-cli, claude-api, run, activation, diagram skills,
    # /code-review, /simplify, /security-review) instead of reinventing them.
    commands.task = ../../claude/commands/task.md;

    # The `/explain` family. Declared here rather than in home.nix's big global
    # skills block because these seven are ONE kit with the output style above —
    # they encode the same answer shape at command granularity. `skills` is a
    # single option, so these merge with that block; the names were checked free.
    #
    # RAW PATHS, not `"${…}"` strings — unlike home.nix's entries, which are
    # strings because they interpolate a flake INPUT's store path. Upstream
    # branches on that (lib.nix:95-116): a real path to a directory becomes a
    # plain recursive `home.file` entry, while a path-LIKE string is routed
    # through an extra `runCommandLocal` symlink farm. Same result, one fewer
    # derivation, and it is the form upstream's own examples use.
    skills = {
      explain = ../../skills/explain;
      compare = ../../skills/compare;
      map = ../../skills/map;
      zoom = ../../skills/zoom;
      why = ../../skills/why;
      tldr = ../../skills/tldr;
      diagram = ../../skills/diagram;
    };

    settings = {
      # Declarative style selection — settings.json is a store symlink by design
      # on this fleet; /config edits don't persist, Nix is the write path.
      # "Brain Signals" (the frontmatter name, not the filename) validated live
      # against Claude Code 2.1.212 before being baked here.
      #
      # mkDefault on BOTH: these two are the only OVERRIDABLE knobs in this
      # module (a scalar can be replaced, never extended), so a private layer or
      # a forker who wants a different style keeps the kit installed and just
      # assigns over them — no mkForce needed.
      outputStyle = lib.mkDefault "Brain Signals";
      alwaysThinkingEnabled = lib.mkDefault true;
      # skillListingBudgetFraction = 0.02;  # uncomment if /context shows the
      #   skill listing truncating descriptions (60+ skills share the 1% default)
    };
  };
}
