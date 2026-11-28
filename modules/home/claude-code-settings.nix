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
# So the floor stays at user scope and Nix re-asserts it: merge only your own keys
# into a file the app also writes (the pattern the retired claude-desktop.nix used).
#
# THE FILE-OWNERSHIP TEST this follows:
#   Does the tool also WRITE this file?  -> merge only your keys      <- THIS
#   Does the tool REJECT a symlink?      -> copy at activation        (grok)
#   Otherwise                            -> store symlink            (the default)
# settings.json answers YES to the first question and, until now, got the third.
# That mismatch is the whole defect, in one line.
#
# LOCAL AND UNBACKED, ON PURPOSE — the fourth member of ADR-004 phase 3's class
# (~/.aws/config, ~/.config/git/*.inc, allowed_signers), not an exception to it. If
# this file is lost, the OPERATOR's preferences go with it; the Nix baseline below
# does not, because the merge re-asserts it on the next activation. Where such
# hand-placed files live now: docs/new-mac-runbook.md § Hand-placed files.
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

  # Where the operator overlay is read from (see mergeOne). XDG, never a home literal.
  overlayPath = "${config.xdg.configHome}/nix-config/claude-settings.overlay.json";

  jaq = lib.getExe pkgs.jaq;
  # "Exactly one JSON object" — the same test the upstream merger applies to its
  # input (it refuses `{}{}`, which a plain `jq -e .` would accept).
  isOneObject = "${jaq} -se 'length == 1 and (.[0] | type == \"object\")'";

  # Every profile directory that gets the floor: ~/.claude, plus the work profile's
  # own directory when it is enabled (claude-profiles.nix). ONE rendered
  # nixSettings, N writable targets — each profile keeps its own UI edits.
  settingsDirs = [
    configDir
  ]
  ++ lib.optional config.local.claudeWorkProfile.enable config.local.claudeWorkProfile.configDir;

  # The merge itself, shared by the two activation entries below. Idempotent:
  # running it twice yields the same file.
  #
  # upstream option home-manager.programs.claude-code.mutableSettings exists → not used
  # (header). Its ENGINE is used instead: lib.hm.generators.mkImpureConfigMerger (pinned
  # home-manager modules/lib/generators.nix), called as a library function with a
  # three-operand jqOperation. It brings what the hand-rolled `install -m 600` + printf
  # write lacked: a temp candidate renamed into place (no EEXIST between two concurrent
  # activations, no half-written file), a conflict check, and DRY_RUN. Measured
  # 2026-11-28: 2x100 paired concurrent runs, 0 failures, 0 EEXIST — but also 0 conflict
  # messages, so the overlap window was probably never hit: no regression, not proof.
  # The EEXIST is gone by construction (rename, never unlink + create).
  #
  # The pre-checks below keep the three behaviours the merger does not have:
  #   1. MIGRATION — previous generations left a read-only store SYMLINK here; the
  #      merger refuses a store target, so replace any symlink with a real file once.
  #   2. CORRUPT FILE — the merger refuses to merge an unparseable file and FAILS the
  #      switch. A corrupt user file must not brick activation: back it up and start
  #      from an empty object. (Claude Code's own words for the managed equivalent are
  #      that an unparseable document means "none of its settings are in effect", so
  #      silently continuing on top of garbage would be the worse outcome.)
  #   3. FORCE 600 — the merger keeps an existing file's mode (`chmod --reference`) and
  #      applies `mode` only to a NEW file. This file holds the user-scope permissions
  #      floor, so it is forced to 600 first; the candidate then inherits 600.
  #
  # One NEW failure mode, accepted by the operator (2026-11-28): if Claude Code writes
  # the file DURING activation, the merger reports "changed during activation; keeping
  # the newer file" and the switch fails loudly. The old write silently clobbered it.
  mergeOne =
    dir:
    let
      merger = lib.hm.generators.mkImpureConfigMerger {
        inherit pkgs;
        format = "json";
        empty = "{}";
        mode = "600";
        path = "${dir}/settings.json";
        staticSettings = nixSettings;
        # RIGHT OPERAND WINS, recursively: the operator's keys survive, Nix's keys
        # are restored. `*` replaces ARRAYS wholesale rather than concatenating,
        # which is exactly what permissions.deny needs — the floor is reinstated
        # entire, not appended to whatever was there.
        #
        # The overlay sits in the MIDDLE on purpose: it beats the live file, so an
        # overlay value is re-asserted every rebuild — and Nix still wins over it, so
        # an overlay can never take back a `permissions.deny`. Like the live file,
        # a key DELETED from the overlay is not removed here; set it to `false`
        # instead. The cost of `*` replacing arrays: an overlay cannot ADD to an
        # array Nix owns (permissions) — hooks belong in a plugin's hooks.json instead.
        # The merger binds only $dynamic and $static, so the overlay rides in on the
        # environment ($ENV, validated below).
        jqOperation = ''
          ($ENV.CLAUDE_SETTINGS_OVERLAY // "{}" | fromjson) as $ov
          | if ($dynamic | type) == "object" and ($static | type) == "object" and ($ov | type) == "object"
            then $dynamic * $ov * $static
            else error("expected JSON objects") end
        '';
      };
    in
    ''
      settings="${dir}/settings.json"
      run mkdir -p "${dir}"

      # 1. MIGRATION (see above).
      if [ -L "$settings" ]; then
        run rm -f "$settings"
      fi

      # 2. CORRUPT FILE (see above). Removing it after the backup hands the merger
      #    an absent file, which it treats as `{}` and creates with mode 600.
      if [ -s "$settings" ] && ! ${isOneObject} "$settings" > /dev/null 2>&1; then
        run cp "$settings" "$settings.corrupt-$(date +%Y%m%d%H%M%S)"
        run rm -f "$settings"
        warnEcho "claude-code: $settings was not one JSON object — backed it up and reset the Nix floor onto {}."
      fi

      # 3. FORCE 600 (see above).
      if [ -f "$settings" ]; then
        run chmod 600 "$settings"
      fi

      # THE OPERATOR OVERLAY: an optional, hand-placed JSON object (none on `macos` today)
      # carrying per-person settings this public repo must not name. The repo ships the
      # shape, the content stays on the Mac (ADR-004).
      # Missing = no-op; not one JSON object = warned and ignored, never fatal.
      overlay="${overlayPath}"
      CLAUDE_SETTINGS_OVERLAY='{}'
      if [ -s "$overlay" ]; then
        if ${isOneObject} "$overlay" > /dev/null 2>&1; then
          CLAUDE_SETTINGS_OVERLAY=$(cat "$overlay")
        else
          warnEcho "claude-code: $overlay is not a JSON object — ignored."
        fi
      fi
      export CLAUDE_SETTINGS_OVERLAY

      ${merger}

      unset CLAUDE_SETTINGS_OVERLAY
    '';
  mergeScript = lib.concatMapStringsSep "\n" mergeOne settingsDirs;
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

  # AND AGAIN AFTER claudeCodePlugins, because its `claude plugin marketplace add`
  # may rewrite extraKnownMarketplaces.<name> without the Nix-declared keys. Measured
  # 2026-09-23 against the since-deleted remove + add teardown (it dropped `autoUpdate`
  # until a second switch); UNMEASURED for `add` alone. The first merge still has to run BEFORE the plugins
  # step, so the CLI starts from a file that already carries the floor.
  home.activation.claudeCodeSettingsReassert = lib.hm.dag.entryAfter [
    "claudeCodePlugins"
  ] mergeScript;
}
