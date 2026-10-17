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
# reason we still do not use it is measured, not ignorance: modules/home/default.nix
# deliberately sets NO `programs.nh.darwinFlake` pointer because nh's progress
# ticker repaints ~15x/s with no off switch (NH_NOM=0 and NO_COLOR=1 both measured
# to change nothing), which is worse than plain darwin-rebuild under a pipe and
# unreadable in Claude Code's append-only viewport. That rejects nh's OUTPUT, not
# its elevation — so if the ticker is ever fixable, this wrapper is the thing to
# retire, keeping only the three diagnostics below that nh has no equivalent for.
#
# Deliberately generic: no repo path and no hostname baked in. Both halves of
# the flake reference are read at RUNTIME from where a bare `darwin-rebuild
# switch` reads them — the tree from /etc/nix-darwin/flake.nix, the attribute
# from scutil — with ONE substitution: `HostName`, not `LocalHostName` (why: the
# comment above `attr=` below). So this works on any darwin host in the fleet.
# Extra arguments are forwarded, and an explicit `--flake` or `--no-flake` wins:
# it is passed through untouched, so `activate --flake .#macos` still works.
#
# upstream-first, for passing `#attr` ourselves: grepped the pinned nix-darwin
# pkgs/nix-tools/darwin-rebuild.sh — the attribute comes ONLY from `#attr` or
# `scutil --get LocalHostName` (:165-171); no HostName path, env var or option.
# On the tool axis `nh darwin switch -H <host>` does own this, and is rejected
# for the same measured ticker reason as above.
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
    explicitFlake=""
    for arg in "$@"; do
      case "$arg" in
        --dry-run)
          echo "activate: --dry-run does NOT rehearse a switch — darwin-rebuild applies it to the" >&2
          echo "activate:   BUILD only, then sets the profile and activates anyway." >&2
          echo "activate:   To rehearse, build without activating:  darwin-rebuild build" >&2
          exit 2
          ;;
        # darwin-rebuild.sh:84-89 parses only these two-token spellings (no
        # `--flake=`), so a literal match is the whole detection.
        --flake | --no-flake) explicitFlake=1 ;;
      esac
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

    flakeArgs=()
    if [ -e /etc/nix-darwin/flake.nix ]; then
      dir=$(dirname "$(readlink -f /etc/nix-darwin/flake.nix)")
      # The ATTRIBUTE comes from HostName, not LocalHostName — measured, not
      # assumed. macOS rewrites LocalHostName at RUNTIME when another responder
      # answers for the same `.local` name (`macos` -> `macos-2`), and a bare
      # darwin-rebuild then dies with "does not provide attribute
      # 'darwinConfigurations.macos-2'". It does NOT self-heal while the clash is
      # live: nix-darwin re-runs `scutil --set LocalHostName` on EVERY activation
      # (pinned modules/networking/default.nix:195-197, not diff-gated), and
      # mDNSResponder re-probes, hits the clash and renames it back ~0.9 s later —
      # 11 of 11 set->rename cycles in the system log, 2026-10-16/17. HostName and
      # ComputerName stayed `macos` throughout: mDNSResponder only ever rewrites
      # LocalHostName. The rival that time was THIS Mac's own KDE Connect,
      # announcing `macos.local` with a stale IP — a clash needs no second Mac.
      # LocalHostName (darwin-rebuild's own default) is the fallback only when
      # HostName is unset, as on a consumer of hosts/generic-darwin.nix that
      # declares no networking.hostName.
      attr=$(/usr/sbin/scutil --get HostName 2>/dev/null) || attr=$(/usr/sbin/scutil --get LocalHostName)
      if [ -n "$explicitFlake" ]; then
        echo "activate: flake from your --flake/--no-flake, passed through as given"
      else
        flakeArgs=(--flake "$dir#$attr")
        echo "activate: flake $dir#$attr"
      fi
      # Machine state, not the path chosen, so it prints for an explicit
      # `--flake` too: one without `#attr` still falls to darwin-rebuild's own
      # LocalHostName default and still dies on the clash.
      localName=$(/usr/sbin/scutil --get LocalHostName 2>/dev/null || true)
      if [ "$localName" != "$attr" ]; then
        echo "activate:   LocalHostName is '$localName', not '$attr' — macOS renames it on a" >&2
        echo "activate:   .local (mDNS) name clash. darwin-rebuild's own default (bare, or a" >&2
        echo "activate:   --flake with no #attr) would look for darwinConfigurations.$localName." >&2
      fi
      if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
        branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
        rev=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo '?')
        dirty=""
        [ -z "$(git -C "$dir" status --porcelain 2>/dev/null)" ] || dirty=" (DIRTY)"
        echo "activate: branch $branch @ $rev$dirty"
      fi
    fi

    if [ "$(id -u)" -eq 0 ]; then
      exec "$rebuild" switch "''${flakeArgs[@]}" "$@"
    fi
    exec /usr/bin/sudo -H "$rebuild" switch "''${flakeArgs[@]}" "$@"
  '';
}
