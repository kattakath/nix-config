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
# bootstrap.sh spells its own first-activation escalation `sudo -H` too.
#
# upstream-first (.claude/rules/upstream-first.md): grepped the pinned nix-darwin
# modules/ for sudo|elevate|rebuild|activate — NO option restores self-elevation.
# The only sudo-adjacent surface is `security.sudo.extraConfig`, which would take
# the opposite route (a NOPASSWD rule REMOVES the prompt rather than raising it).
#
# But the rule's grep has a blind spot, and this hit it: `nh` (nix-helper, 4.4.2,
# already on PATH here) has `--elevation-strategy`, so the community DOES own this
# and a modules/ grep could never see it — nh is a package, not an option. The
# reason we still do not use it is measured, not ignorance: modules/shared/home.nix
# deliberately sets NO `programs.nh.darwinFlake` pointer because nh's progress
# ticker repaints ~15x/s with no off switch (NH_NOM=0 and NO_COLOR=1 both measured
# to change nothing), which is worse than plain darwin-rebuild under a pipe and
# unreadable in Claude Code's append-only viewport. That rejects nh's OUTPUT, not
# its elevation — so if the ticker is ever fixable, this wrapper is the thing to
# retire, keeping only the three diagnostics below that nh has no equivalent for.
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
    # `--dry-run` is a BUILD flag, not a rehearsal. darwin-rebuild files it under
    # extraBuildFlags (darwin-rebuild:59) and then runs `nix-env -p … --set` and
    # `$systemConfig/activate` for `switch` UNCONDITIONALLY — so the profile
    # advances, activation is attempted against a path the dry build never
    # realised, and /run/current-system is left behind. That is the same drift
    # the check below reports, arrived at from the other direction. Measured
    # here 2026-09-15: two `--dry-run` invocations advanced the profile two
    # generations without ever repointing /run/current-system.
    for arg in "$@"; do
      if [ "$arg" = "--dry-run" ]; then
        echo "activate: --dry-run does NOT rehearse a switch — darwin-rebuild applies it to the" >&2
        echo "activate:   BUILD only, then sets the profile and activates anyway." >&2
        echo "activate:   To rehearse, build without activating:  darwin-rebuild build" >&2
        exit 2
      fi
    done

    rebuild=/run/current-system/sw/bin/darwin-rebuild
    if [ ! -x "$rebuild" ]; then
      echo "activate: $rebuild is missing — this Mac has never been activated." >&2
      echo "activate: bootstrap it first with 'nix run .#macos' (see docs/new-mac-runbook.md)." >&2
      exit 1
    fi

    # P7 — /run/current-system is NOT authoritative, and this script trusts it
    # for $rebuild above. A per-user home-manager activation that fails (an
    # account with no GUI session: "Bootstrap failed: 125") aborts `activate`
    # under `set -e` ~80 lines before its closing
    # `ln -sfn … /run/current-system`, so the system PROFILE advances while that
    # symlink — and the current-system GC root, and PATH — stay on the old
    # generation. It sat four generations behind before anyone noticed, and only
    # because four pointers were compared by hand. Mechanise the comparison.
    #
    # WARN, never block: a stale pointer is precisely the state someone runs
    # `activate` to repair, and this run is what fixes it.
    profile=$(readlink -f /nix/var/nix/profiles/system 2>/dev/null || true)
    running=$(readlink -f /run/current-system 2>/dev/null || true)
    if [ -n "$profile" ] && [ -n "$running" ] && [ "$profile" != "$running" ]; then
      echo "activate: WARNING — /run/current-system has drifted from the system profile." >&2
      echo "activate:   profile : $profile" >&2
      echo "activate:   running : $running" >&2
      echo "activate:   A previous activation aborted before repointing it (usually a" >&2
      echo "activate:   per-user launchd agent failing for an account that has never" >&2
      echo "activate:   logged in). PATH resolves through the RUNNING one. Continuing;" >&2
      echo "activate:   a successful switch repoints it." >&2
    fi

    # Say WHAT is about to be activated before elevating. A bare rebuild finds
    # its flake through /etc/nix-darwin, so nothing on screen would otherwise
    # name the tree — and this worktree is shared by several agent sessions that
    # hop branches. Untracked files count as dirty on purpose: flakes ignore
    # them, so a "clean-looking" tree can still build something unexpected.
    # P5 — a DANGLING /etc/nix-darwin/flake.nix is the quiet failure: `ln -s`
    # never checks its target, so activation happily plants a broken link (a
    # moved or renamed clone), `-e` is then false, and darwin-rebuild silently
    # ignores it and falls through to the legacy `<darwin>` path with an error
    # that names none of this. `activate` is the one place positioned to say so,
    # because it already resolves the link. An activation-time assertion would be
    # wrong: the path legitimately does not exist during the first activation
    # that creates it.
    if [ -L /etc/nix-darwin/flake.nix ] && [ ! -e /etc/nix-darwin/flake.nix ]; then
      echo "activate: WARNING — /etc/nix-darwin/flake.nix is DANGLING." >&2
      echo "activate:   points at: $(readlink -f /etc/nix-darwin/flake.nix 2>/dev/null || readlink /etc/nix-darwin/flake.nix)" >&2
      echo "activate:   Nothing is there, so a bare \`darwin-rebuild switch\` will ignore it" >&2
      echo "activate:   and fail against the legacy <darwin> path. The clone probably moved:" >&2
      echo "activate:   fix the environment.etc target in modules/parts/hosts.nix, then" >&2
      echo "activate:   re-activate once WITH --flake to repair the link." >&2
    fi

    if [ -e /etc/nix-darwin/flake.nix ]; then
      dir=$(dirname "$(readlink -f /etc/nix-darwin/flake.nix)")
      # Name the ATTRIBUTE too, not just the tree. A bare rebuild resolves it from
      # `scutil --get LocalHostName`, which macOS can change at RUNTIME on an mDNS
      # collision (two hosts claiming one .local name) — nix-darwin re-forces the
      # declared name every activation, so it self-heals, but in the window
      # between, the bare form fails with `attribute 'darwinConfigurations.<other>'
      # missing` and nothing on screen explains why. Printing it costs nothing and
      # makes that failure legible. NOT verified here: this fleet has one Mac, so
      # there is nothing to collide with.
      echo "activate: flake $dir#$(/usr/sbin/scutil --get LocalHostName)"
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
