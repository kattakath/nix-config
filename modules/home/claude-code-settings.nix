{
  config,
  pkgs,
  lib,
  ...
}:
# Make Claude Code's USER-scope settings.json LAYERED: a Nix-owned floor that is
# re-asserted every rebuild, over a real file the app and the operator can write.
#
# THE DEFECT, and it is UPSTREAM's default rather than a local mistake. The pinned
# home-manager's `programs.claude-code` renders settings.json with
# `install -Dm444` into the store and symlinks it (the `!cfg.mutableSettings`
# branch of home-manager/modules/programs/claude-code/default.nix). Mode 444, in
# /nix/store: the app cannot persist anything the UI writes, and a rebuild reverts it.
#
# upstream option home-manager.programs.claude-code.mutableSettings EXISTS at the
# current pin (options.nix) — it merges the declared settings into a writable
# file via lib.hm.generators.mkImpureConfigMerger, Nix winning. It is NOT used,
# because it covers two operands where this module needs three: it has no slot
# for the operator overlay (the merger takes exactly two inputs), no ordering
# against `claudeCodePlugins` (the 2026-09-23 autoUpdate loss), and it FAILS
# activation on a corrupt file where this module backs it up and resets to {}.
# Retire this module when upstream takes extra merge inputs, or the overlay moves.
#
# The operator hits this as: they cannot change the Bedrock model.
# claude-bedrock-gate.nix already records the chicken-and-egg — the agent
# needed to diagnose it is the one that just lost its model, and settings.json is
# read-only under /nix so it cannot be hand-repaired.
#
# WHY A MERGE AND NOT `mkOutOfStoreSymlink`. Out-of-store would hand the operator
# the WHOLE file, floor included. That is only safe if the user layer holds
# nothing that must be protected, and it does:
#   · There is exactly ONE user-scope settings file. claude-code 2.1.260's own
#     source identifiers are userSettings / projectSettings / localSettings /
#     managedSettings / policySettings / flagSettings, and `settings.local.json`
#     is PROJECT scope (its strings name `.claude/settings.local.json`, workspace
#     trust, per-project MCP choices). So the floor and the model picker cannot be
#     split across two user-scope files — there is no second file.
#   · The floor cannot move up to managed either. modules/darwin/
#     claude-managed-settings.nix § SCOPE RULE admits only "never print a secret
#     value" / "never sign work as an AI" and explicitly not rules that "merely
#     narrow a workflow", which most of the user floor does; and its § COVERAGE
#     LIMIT records that managed settings do NOT reach an Anthropic-hosted cloud
#     session, which is why "the user- and project-scope layers stay put rather
#     than being replaced by this one".
# So the floor stays at user scope and Nix re-asserts it. This is the
# claude-desktop.nix pattern — merge only your own keys into a file the app also
# writes — applied to the one other Claude file with the same ownership shape.
#
# THE FILE-OWNERSHIP TEST this follows (same one claude-desktop.nix answers):
#   Does the tool also WRITE this file?  -> merge only your keys      <- THIS
#   Does the tool REJECT a symlink?      -> copy at activation        (grok)
#   Otherwise                            -> store symlink            (the default)
# settings.json answers YES to the first question and, until now, got the third.
# That mismatch is the whole defect, in one line.
#
# LOCAL AND UNBACKED, ON PURPOSE — the fourth member of ADR-004 phase 3's class
# (~/.aws/config, ~/.config/git/*.inc, allowed_signers), not an exception to it. If
# this file is lost, the OPERATOR's preferences go with it; the Nix baseline below
# does not, because the merge re-asserts it on the next activation. THE TRIGGER, so
# this is not re-litigated every time someone notices it is unbacked: when a SECOND
# piece of operator content genuinely needs restoring after machine loss, create ONE
# private operator-content repo for all of them at once — not one repo for the first
# file that raises the question. Reasoning and the nix-config disqualifier:
# docs/secrets-recovery-and-identity-adr.md § 9.7.
#
# RESIDUAL EXPOSURE, stated rather than hidden. Between rebuilds the file is
# writable, so a session could edit the workflow-narrowing denies. Two things
# bound it: the SECRET-VALUE subset is additionally in the root-owned managed file
# and cannot be retracted by any lower scope, and every rebuild restores the full
# user floor. What is traded is "immutable between rebuilds" for "the operator can
# change their model without a rebuild" — which is what was asked for.
let
  inherit (config.programs.claude-code) configDir;

  # Nix's OWN keys, rendered from the very option every other module already
  # writes to. Intercepting the RENDERING rather than the option
  # means no module has to change and checks.nix's `userDeny` keeps reading the same path.
  nixSettings = (pkgs.formats.json { }).generate "claude-code-nix-settings.json" (
    config.programs.claude-code.settings
    // {
      "$schema" = "https://json.schemastore.org/claude-code-settings.json";
    }
  );

  # Where the operator overlay is read from (see mergeScript). XDG, never a home
  # literal; `emptyJson` stands in when it is absent so the jq call has one shape.
  overlayPath = "${config.xdg.configHome}/nix-config/claude-settings.overlay.json";
  emptyJson = pkgs.writeText "claude-settings-overlay-empty.json" "{}";

  # The merge itself, shared by the two activation entries below. Idempotent:
  # running it twice yields the same file.
  mergeScript = ''
    settings="${configDir}/settings.json"
    run mkdir -p "${configDir}"

    # MIGRATION: previous generations left a read-only store SYMLINK here.
    # Replace it with a real file once; thereafter this is a no-op.
    if [ -L "$settings" ]; then
      run rm -f "$settings"
    fi

    # A corrupt user file must not brick activation — back it up and start from
    # an empty object rather than failing the whole switch. Claude Code's own
    # words for the managed equivalent are that an unparseable document means
    # "none of its settings are in effect", so silently continuing on top of
    # garbage would be the worse outcome.
    base="{}"
    if [ -s "$settings" ]; then
      if ${pkgs.jq}/bin/jq -e . "$settings" > /dev/null 2>&1; then
        base=$(cat "$settings")
      else
        run cp "$settings" "$settings.corrupt-$(date +%Y%m%d%H%M%S)"
        warnEcho "claude-code: $settings was not valid JSON — backed it up and reset the Nix floor onto {}."
      fi
    fi

    # THE OPERATOR OVERLAY: an optional, hand-placed JSON object (none on `macos` since
    # 2026-11-01, when the operator's private repo was deleted) carrying what this
    # public repo must not name — private marketplaces and the plugin ids they
    # enable. The repo ships the shape, the content stays on the Mac: ADR-004's
    # rule, and the "one private operator-content repo" its § 9.7 trigger names.
    # Missing = no-op; not a JSON object = warned and ignored, never fatal.
    overlay="${overlayPath}"
    ov=${emptyJson}
    if [ -s "$overlay" ]; then
      if ${pkgs.jq}/bin/jq -e 'type == "object"' "$overlay" > /dev/null 2>&1; then
        ov="$overlay"
      else
        warnEcho "claude-code: $overlay is not a JSON object — ignored."
      fi
    fi

    # RIGHT OPERAND WINS, recursively: the operator's keys survive, Nix's keys
    # are restored. jq's `*` replaces ARRAYS wholesale rather than concatenating,
    # which is exactly what permissions.deny needs — the floor is reinstated
    # entire, not appended to whatever was there.
    #
    # The overlay sits in the MIDDLE on purpose: it beats the live file, so an
    # overlay value is re-asserted every rebuild — and Nix still wins over it, so
    # an overlay can never take back a `permissions.deny`. Like the live file,
    # a key DELETED from the overlay is not removed here; set it to `false`
    # instead. The cost of `*` replacing arrays: an overlay cannot ADD to an
    # array Nix owns (hooks, permissions) — private hooks belong in the private
    # plugins' hooks.json instead.
    merged=$(printf '%s' "$base" | ${pkgs.jq}/bin/jq -s --slurpfile ov "$ov" --slurpfile nix ${nixSettings} '.[0] * $ov[0] * $nix[0]')
    # THE ONE LINE TWO CONCURRENT ACTIVATIONS CAN COLLIDE ON, and the error it
    # produces names the symptom rather than the cause — which cost two
    # escalations and a withdrawn rewrite spec on 2026-10-02.
    #
    # `install` UNLINKS the target then creates it. Two `activate` runs overlapping
    # on this path interleave as: A unlinks, B unlinks, A creates, B creates and
    # gets EEXIST. That surfaces as
    #   install: cannot create regular file '~/.claude/settings.json': File exists
    # and it reads exactly like Home Manager having lost ownership of the file. It
    # is not. The plain file is DELIBERATE (`home.file…enable = mkForce false`
    # below), the merge above already handles both a legacy symlink and a
    # pre-existing plain file, and `claudeCodeSettingsReassert` already re-runs
    # after the plugin CLI rewrites it.
    #
    # SO: if you see that error, check for a second activation before changing
    # anything here. The line is correct; `install -m 600 /dev/null` is what makes
    # the mode right BEFORE any content is written, which matters because this file
    # holds the user-scope permissions floor. Do not "fix" it into a chmod-after
    # write — that would open a window where the deny list is world-readable.
    run install -m 600 /dev/null "$settings"
    printf '%s\n' "$merged" > "$settings"
  '';
in
# isDarwin only, matching claude-brain.nix and claude-guardrails.nix:
# programs.claude-code is darwin-only in this fleet (default.nix).
lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
  # Stop upstream linking its read-only store copy. `enable` is home-manager's own
  # per-file switch (modules/lib/file-type.nix:38) — not a deletion hack. The key
  # is the ABSOLUTE path because configDir is absolute and upstream keys it that
  # way; verified against the built config, not assumed.
  home.file."${configDir}/settings.json".enable = lib.mkForce false;

  # BETWEEN linkGeneration and claudeCodePlugins: after the former so configDir
  # exists, before the latter because claude-plugins.nix reads and rewrites this
  # same file. `entryBetween before after` (home-manager modules/lib/dag.nix:123).
  home.activation.claudeCodeSettingsMerge =
    lib.hm.dag.entryBetween [ "claudeCodePlugins" ] [ "linkGeneration" ]
      mergeScript;

  # AND AGAIN AFTER claudeCodePlugins, because that step's CLI calls write this
  # file too. `claude plugin marketplace remove` + `add` (the re-registration a
  # marketplace SOURCE change triggers) rewrites extraKnownMarketplaces.<name>
  # without the Nix-declared `autoUpdate`. Measured 2026-09-23: the first switch
  # after moving `kattakath` from a store path to git left autoUpdate absent
  # until a second switch. The first merge still has to run BEFORE the plugins
  # step, so the CLI starts from a file that already carries the floor.
  home.activation.claudeCodeSettingsReassert = lib.hm.dag.entryAfter [
    "claudeCodePlugins"
  ] mergeScript;
}
