# Where the brag-doc redaction GATE lives (engine/ + its client denylist).
#
# Public/private split: the two SKILLS are public and vendored here
# (skills/brag, skills/brags-review). The gate they call is not — `config/scope.json`
# IS the client denylist, so publishing it publishes exactly what it exists to
# scrub. It lives in the private nix-personal flake (`brags/`), which fills this
# option from `extraHomeModules`. Absorbed there from the archived
# github.com/kattakath/brags, 2026-09-12.
#
# The empty default is load-bearing, not a placeholder: unfilled ⇒ BRAG_ENGINE_DIR
# is never set ⇒ brags-review's `${BRAG_ENGINE_DIR:?}` aborts and the skill refuses
# to run. That is the correct public-only behaviour — a draft is never posted
# ungated. Fail-closed, matching redact.py's own posture.
#
# ✅ upstream-first: grepped the PINNED home-manager for the concept before writing
# this. `home.sessionVariables` (modules/home-environment.nix:289) is the only
# relevant surface, and upstream's OWN idiom for "omit a variable entirely" is
# `lib.optionalAttrs (v != null) { ${n} = v; }` at :645-661 — null is NOT filtered
# downstream (`lib.shell.exportAll` at modules/lib/shell.nix:77 exports every attr),
# so the key must be dropped before it reaches the option. There is no upstream
# option modelling "private sibling directory for a vendored skill"; that is fleet
# composition, which `lib.mkDarwin { extraHomeModules }` already exists for. The
# shape here is git-allowed-signers.nix's, reused verbatim.
#
# Unlike git-allowed-signers.nix this module ALSO carries config — legal because it
# uses the explicit `config = { … }` form. That file's warning is about BARE config
# attrs alongside a top-level `options` attr, which is what HM rejects.
#
# The value must be a $HOME-relative CHECKOUT path — never a store path
# ("${./brags}") and never a literal /Users/<name>. The store is world-readable and
# Cachix-pushed, and nothing writes into the engine dir at runtime (writes go to
# $BRAG_DATA_DIR), so store-residency would buy nothing and leak the denylist.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.kattakath.brag.engineDir = lib.mkOption {
    type = lib.types.str;
    default = "";
    example = "$HOME/Developer/gitlab.com/ismailkattakath/nix-personal/brags";
    description = ''
      Directory holding brags-review's fail-closed redaction gate (`engine/redact.py`
      and its sibling `config/scope.json`), exported as BRAG_ENGINE_DIR on darwin.
      Empty (the public default) leaves the variable unset, so the skill fails closed.
      Filled by the private nix-personal layer.
    '';
  };

  # Darwin-gated to match home.nix's own sessionVariables block: the brag pipeline
  # is a Mac-only workflow, and gating here keeps nixpi/nixvm byte-identical.
  config.home.sessionVariables = lib.mkIf (
    pkgs.stdenv.hostPlatform.isDarwin && config.kattakath.brag.engineDir != ""
  ) { BRAG_ENGINE_DIR = config.kattakath.brag.engineDir; };
}
