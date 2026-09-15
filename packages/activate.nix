# `activate` — one word for what nix-darwin makes you spell out.
#
# Since nix-darwin's 2025-01-30 root migration, `darwin-rebuild switch` as a
# normal user dies with "system activation must now be run as root" (exit 1) —
# and dies WITHOUT prompting. The guard is a bare `id -u` test followed by
# `exit 1`, so PAM is never reached and this fleet's Touch ID sudo
# (security.pam.services.sudo_local.touchIdAuth, modules/darwin/core.nix) never
# gets a chance to fire. Upstream self-elevation was removed in that same
# migration and never replaced: the script's only two `sudo` mentions are a
# comment and a step DOWN to $SUDO_USER.
#
# So this re-execs under sudo, turning that dead end into the Touch ID sheet.
# It is NOT a new privilege path — same sudo, same PAM stack, same boundary;
# upstream pushed the decision to the caller, and this makes it once,
# declaratively, instead of on every invocation.
#
# `-H` because nix warns when $HOME is not owned by root — the same reason
# packages/key-recovery.nix:452 spells its own escalation `sudo -H`.
#
# Deliberately generic: no repo path, no hostname, no `--flake`. A bare
# `darwin-rebuild switch` resolves the flake through /etc/nix-darwin and the
# attribute through `scutil --get LocalHostName`, so this works on any darwin
# host in the fleet. Extra arguments are forwarded, so `activate --flake .#macos`
# or `activate --show-trace` still work.
{
  writeShellApplication,
  coreutils,
  git,
}:
writeShellApplication {
  name = "activate";
  runtimeInputs = [
    coreutils
    git
  ];
  text = ''
    rebuild=/run/current-system/sw/bin/darwin-rebuild
    if [ ! -x "$rebuild" ]; then
      echo "activate: $rebuild is missing — this Mac has never been activated." >&2
      echo "activate: bootstrap it first with 'nix run .#macos' (see docs/mac-key-recovery-runbook.md)." >&2
      exit 1
    fi

    # Say WHAT is about to be activated before elevating. A bare rebuild finds
    # its flake through /etc/nix-darwin, so nothing on screen would otherwise
    # name the tree — and this worktree is shared by several agent sessions that
    # hop branches. Untracked files count as dirty on purpose: flakes ignore
    # them, so a "clean-looking" tree can still build something unexpected.
    if [ -e /etc/nix-darwin/flake.nix ]; then
      dir=$(dirname "$(readlink -f /etc/nix-darwin/flake.nix)")
      echo "activate: flake $dir"
      if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
        branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
        rev=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo '?')
        dirty=""
        [ -z "$(git -C "$dir" status --porcelain 2>/dev/null)" ] || dirty=" (DIRTY)"
        echo "activate: branch $branch @ $rev$dirty"
      fi
    fi

    if [ "$(id -u)" -eq 0 ]; then
      exec "$rebuild" switch "$@"
    fi
    exec /usr/bin/sudo -H "$rebuild" switch "$@"
  '';
}
