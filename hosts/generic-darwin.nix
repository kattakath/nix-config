# A darwin host that carries NOTHING personal — the one `templates/` points at.
#
# WHY THIS EXISTS. `mkDarwin` resolves its host profile from a string
# (`hosts/<hostname>.nix`), and `templates/default` used to pass
# `hostname = "macos"`. That handed every downstream consumer the OPERATOR'S host:
# measured 2026-09-15, `mkDarwin { hostname = "macos"; }` evaluated for an
# unrelated caller to the operator's own account and `users.knownUsers` — user
# accounts created on a stranger's Mac — plus both self-hosted CI runner lanes
# and 34 Homebrew casks.
#
# That is the exact failure `templates/` exists to prevent: the composition API is
# there so people CONSUME this engine instead of forking it, and a seam that drags
# 929 lines of one person's machine is a seam people will fork around.
#
# WHAT IT DELIBERATELY DOES NOT DO. No hostName, no casks, no accounts, no
# runners, no `local.*` feature flags. A consumer's own `extraModules` is where
# their machine gets described — that file is theirs, this one is the engine's.
#
# NOTE ON hostName. Left unset on purpose. nix-darwin defaults it, and the
# consumer should set it in their own host module: it is what
# `scutil --set LocalHostName` imposes, and therefore what a bare
# `darwin-rebuild switch` later reads back to pick the flake attribute. Setting a
# name here would rename every consumer's Mac to the same thing.
{ loginName, ... }:
{
  # The one thing genuinely required of a darwin host rather than chosen by it:
  # `modules/darwin/core.nix` is the system layer every Mac needs (stateVersion,
  # primaryUser, /etc, launchd, GUI PATH). The engine deliberately does NOT put it
  # in mkDarwin's base list — `hosts/macos.nix:30` imports it too — so a host
  # profile is the thing that opts a Mac into the system layer at all.
  imports = [ ../modules/darwin/core.nix ];

  # The account the identity names. core.nix reads `users.users.${loginName}.home`
  # (home-manager's homeDirectory comes from it on darwin), so without this block a
  # consumer's eval died with "home.homeDirectory … null" — hosts/macos.nix declares
  # the same block for the fleet, and `checks.template-consumer` used to add it by
  # hand, which is why the gap was invisible until the template itself was
  # evaluated (ADR-004 §9.9, 2026-09-20). Same shape as the fleet host: the literal
  # `/Users/<name>` is the one place a home path is REQUIRED (the ast-grep rule
  # exempts `users.users.*.home` for exactly this).
  users.users.${loginName} = {
    name = loginName;
    home = "/Users/${loginName}";
  };

  # Most real configs need this the moment they add a cask or a font; enabling it
  # here saves every consumer the same first-run failure. Flip it off in your own
  # module if you want a strictly free closure.
  nixpkgs.config.allowUnfree = true;
}
