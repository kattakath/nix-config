# `superhook` + `superhook-digest` — the hook supervisor, as fleet CLIs.
#
# WHY PACKAGES AND NOT A PLUGIN HOOK. superhook is a WRAPPER: `.claude/settings.json`
# names it in FRONT of the hook it supervises (`superhook Stop -- node …/stop-gate.js`).
# A plugin's own `hooks/hooks.json` can only ADD a hook that runs alongside the others —
# it cannot wrap one — so the plugin form cannot deliver this, and the plugin ships the
# scripts and the `/superhook-review` command instead.
#
# AND WHY NOT A PATH IN settings.json. That file is checked in, so it can hold neither a
# `/nix/store` path (machine- and generation-specific, and it would go stale on every
# content bump) nor `''${CLAUDE_PLUGIN_ROOT}` (defined only inside a plugin's own hook
# context, never in project settings). A bare command name on PATH is the one spelling
# that is stable in git, survives a re-pin, and needs no interpolation. Hook commands run
# through a shell with the user's environment — the SessionStart hook in the same file
# already relies on that, resolving `nix` and `git` by PATH lookup.
#
# The scripts come from the PINNED `kattakath-claude-plugins` input, not from this repo,
# so the copy Claude Code is offered and the copy this fleet executes are the same bytes.
{
  lib,
  writeShellApplication,
  nodejs,
  # The superhook plugin tree inside the pinned marketplace input. No default: a missing
  # pin must be an eval error, never a silently absent supervisor.
  superhookSrc,
}:

let
  mk =
    {
      name,
      script,
      description,
    }:
    writeShellApplication {
      inherit name;
      runtimeInputs = [ nodejs ];
      text = ''
        exec node ${superhookSrc}/scripts/${script} "$@"
      '';
      meta = {
        inherit description;
        platforms = lib.platforms.all;
        mainProgram = name;
      };
    };
in
{
  superhook = mk {
    name = "superhook";
    script = "superhook.js";
    description = "Supervise a command-type Claude Code hook: crash safety plus a loop breaker";
  };

  superhook-digest = mk {
    name = "superhook-digest";
    script = "superhook-digest.js";
    description = "Summarise superhook.log incidents since the last review";
  };
}
