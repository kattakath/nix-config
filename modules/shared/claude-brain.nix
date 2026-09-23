{ pkgs, lib, ... }:
# "Brain Signals" — the fleet's Claude Code ANSWER-SHAPE kit, SELECTED here and
# SHIPPED elsewhere. The kit itself (output style, the /explain family, the
# `cartographer` subagent, `/task`) is the `brain-signals` plugin in
# github:kattakath/skills, enabled in modules/shared/home.nix like any other
# plugin, so it updates from that repo with no pin bump here. It moved there
# 2026-09-23: it is content, and this repo declares shape.
#
# WHAT STAYS, and why each has no plugin form:
#   - the calibration RULE (claude/rules/brain-signals-context.md): plugins carry
#     skills, agents, commands, hooks and output styles, but not rules or
#     CLAUDE.md context (plugins-reference: "A CLAUDE.md file at the plugin root
#     is not loaded as project context").
#   - the style SELECTION: a scalar setting, which is configuration, not content.
#
# EXTENDABLE, DELIBERATELY. `rules` is `attrsOf (either lines path)` and merges
# per key, so a private layer ADDS its own rule and this one survives. Never
# route extra global prose through `context` (options.nix:134): modules/shared/
# home.nix already defines it as a PATH, and a second path definition is a hard
# eval error, not a merge.
lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
  programs.claude-code = {
    rules.brain-signals-context = ../../claude/rules/brain-signals-context.md;

    settings = {
      # A plugin output style is NAMESPACED "<plugin>:<name>" — measured
      # 2026-09-23: with the style shipped by a plugin, a bare "Brain Signals"
      # silently applied nothing and "brain-signals:Brain Signals" applied it.
      #
      # mkDefault on BOTH: these two are the only OVERRIDABLE knobs in this
      # module (a scalar can be replaced, never extended), so a private layer or
      # a forker who wants a different style keeps the kit installed and just
      # assigns over them — no mkForce needed.
      outputStyle = lib.mkDefault "brain-signals:Brain Signals";
      alwaysThinkingEnabled = lib.mkDefault true;
      # skillListingBudgetFraction = 0.02;  # uncomment if /context shows the
      #   skill listing truncating descriptions (60+ skills share the 1% default)
    };
  };
}
