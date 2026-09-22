{
  config,
  pkgs,
  lib,
  ...
}:
# Make Claude Code's USER-scope settings.json LAYERED: a Nix-owned floor that is
# re-asserted every rebuild, over a real file the app and the operator can write.
#
# THE DEFECT, and it is UPSTREAM's design rather than a local mistake. The pinned
# home-manager's `programs.claude-code` renders settings.json with
# `install -Dm444` into the store and symlinks it (modules/programs/claude-code/
# default.nix:295-316). Mode 444, in /nix/store: the app cannot persist anything
# the UI writes, and a rebuild reverts it. Reading options.nix in full — enable,
# finalPackage, enableMcpIntegration, configDir, settings, context, plugins,
# marketplaces, skills, lspServers, mcpServers — there is NO mutability option,
# so upstream-first comes back EMPTY and this module is warranted.
#
# The operator hits this as: they cannot change the Bedrock model.
# claude-bedrock-gate.nix:48-50 already records the chicken-and-egg — the agent
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
# RESIDUAL EXPOSURE, stated rather than hidden. Between rebuilds the file is
# writable, so a session could edit the workflow-narrowing denies. Two things
# bound it: the SECRET-VALUE subset is additionally in the root-owned managed file
# and cannot be retracted by any lower scope, and every rebuild restores the full
# user floor. What is traded is "immutable between rebuilds" for "the operator can
# change their model without a rebuild" — which is what was asked for.
let
  inherit (config.programs.claude-code) configDir;

  # Nix's OWN keys, rendered from the very option every other module already
  # writes to (claude-guardrails.nix, claude-plugins.nix, claude-otel.nix,
  # claude-bedrock-gate.nix). Intercepting the RENDERING rather than the option
  # means no module has to change and checks.nix:567 keeps reading the same path.
  nixSettings = (pkgs.formats.json { }).generate "claude-code-nix-settings.json" (
    config.programs.claude-code.settings
    // {
      "$schema" = "https://json.schemastore.org/claude-code-settings.json";
    }
  );
in
# isDarwin only, matching claude-brain.nix and claude-guardrails.nix:
# programs.claude-code is darwin-only in this fleet (home.nix).
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
      ''
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

        # RIGHT OPERAND WINS, recursively: the operator's keys survive, Nix's keys
        # are restored. jq's `*` replaces ARRAYS wholesale rather than concatenating,
        # which is exactly what permissions.deny needs — the floor is reinstated
        # entire, not appended to whatever was there.
        merged=$(printf '%s' "$base" | ${pkgs.jq}/bin/jq -s --slurpfile nix ${nixSettings} '.[0] * $nix[0]')
        run install -m 600 /dev/null "$settings"
        printf '%s\n' "$merged" > "$settings"
      '';
}
