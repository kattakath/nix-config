# Reports — and on request prunes — the Claude Code runtime state a rebuild never
# touches.
#
# WHY THIS CANNOT BE A FLAKE CHECK OR AN ACTIVATION STEP, which is the same reason
# launchd-doctor exists: every byte here is a property of the RUNNING machine, written
# by Claude Code at runtime, and nothing in a generation describes it. `nix flake
# check` cannot see it and activation must not delete it — `ast-grep` already forbids
# activation touching state it does not own, and silently removing an operator's
# transcripts on a rebuild is exactly the class of surprise that rule exists to stop.
#
# So this is an operator-invoked tool, DRY RUN BY DEFAULT. `--prune` is the opt-in.
#
# WHAT IT CLEANS, and why each is safe:
#   (a) orphaned plugin version directories. Claude Code installs a plugin at
#       cache/<marketplace>/<plugin>/<version>/ and leaves every previous version in
#       place on update. installed_plugins.json names the ONE version in use, so
#       anything else under that plugin is unreferenced. Measured 2026-10-01: 286
#       orphaned version dirs inside 266 MB of cache — a versionless marketplace
#       means a new directory per MERGE, so this grows with upstream activity rather
#       than with anything the operator does.
#   (b) `*.clone` scratch directories. Mid-update working copies; a leftover means an
#       update was interrupted. Never referenced once the update completes.
#
# WHAT IT DELIBERATELY DOES NOT TOUCH:
#   - the CURRENT version of every installed plugin, read from
#     installed_plugins.json rather than guessed from mtime. A heuristic that picked
#     "newest" would delete the live copy the moment an update was rolled back.
#   - `~/.claude/plugins/data/` — per-plugin runtime data. Some belongs to plugins no
#     longer installed, which LOOKS like garbage and is not: reinstalling a plugin is
#     routine, and its data surviving is the reason a reinstall is not a reset.
#   - transcripts and telemetry under ~/.claude. Large (~5 GB) but they are the
#     record, and deleting them is a judgement about what history is worth keeping —
#     not something a GC tool should decide. Reported, never pruned.
#   - ANY path under a `snapshots/` directory. Deliberately excluded by name:
#     ~/.local/state/claude-otel/snapshots/ holds deduped event extracts kept
#     OUTSIDE the collector's 50 MB x 5 rotation precisely so they survive it.
#     Sweeping them would destroy the only durable copy while the rotation keeps
#     doing its job.
{
  writeShellApplication,
  coreutils,
  findutils,
  jq,
  gnugrep,
}:
writeShellApplication {
  name = "claude-state-gc";
  runtimeInputs = [
    coreutils
    findutils
    jq
    gnugrep
  ];
  text = ''
    prune=0
    case "''${1:-}" in
      --prune) prune=1 ;;
      "" | --dry-run) ;;
      *)
        echo "usage: claude-state-gc [--dry-run | --prune]" >&2
        exit 2
        ;;
    esac

    root="$HOME/.claude/plugins"
    manifest="$root/installed_plugins.json"
    cache="$root/cache"

    if [ ! -r "$manifest" ]; then
      echo "claude-state-gc: no $manifest — nothing to do."
      exit 0
    fi

    # The ONE version per plugin that is actually installed. Read from the manifest,
    # never inferred: `installPath`'s basename is the version directory in use.
    keep=$(jq -r '.plugins | to_entries[]
                  | .key as $id
                  | ($id | split("@")) as $p
                  | .value[0].installPath
                  | select(. != null)
                  | sub(".*/cache/"; "")' "$manifest" 2>/dev/null || true)

    total=0
    count=0
    echo "== orphaned plugin version directories =="
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      rel=''${dir#"$cache"/}
      # snapshots/ is never a candidate, wherever it appears.
      case "$rel" in */snapshots/* | snapshots/*) continue ;; esac
      if printf '%s\n' "$keep" | grep -qxF "$rel"; then continue; fi
      sz=$(du -sk "$dir" 2>/dev/null | cut -f1 || echo 0)
      total=$((total + sz))
      count=$((count + 1))
      if [ "$prune" -eq 1 ]; then
        rm -rf -- "$dir"
        echo "  pruned  $rel"
      else
        echo "  orphan  $rel"
      fi
    done <<EOF
    $(find "$cache" -mindepth 3 -maxdepth 3 -type d 2>/dev/null | sort)
    EOF

    echo "== interrupted-update scratch clones =="
    clones=0
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      clones=$((clones + 1))
      if [ "$prune" -eq 1 ]; then
        rm -rf -- "$c"
        echo "  pruned  ''${c#"$root"/}"
      else
        echo "  leftover  ''${c#"$root"/}"
      fi
    done <<EOF
    $(find "$root" -maxdepth 4 -type d -name '*.clone' 2>/dev/null | sort)
    EOF

    echo
    echo "orphaned version dirs: $count  (~$((total / 1024)) MiB)"
    echo "scratch clones:        $clones"

    # REPORTED, NEVER PRUNED. Deleting the record is the operator's call, not a GC
    # tool's — and the figure is the point: it is what makes that call informed.
    if [ -d "$HOME/.claude/projects" ]; then
      echo "transcripts (~/.claude/projects): $(du -sh "$HOME/.claude/projects" 2>/dev/null | cut -f1) — NOT pruned, reported only"
    fi

    if [ "$prune" -eq 0 ] && { [ "$count" -gt 0 ] || [ "$clones" -gt 0 ]; }; then
      echo
      echo "dry run. re-run with --prune to delete the above."
    fi
  '';
}
