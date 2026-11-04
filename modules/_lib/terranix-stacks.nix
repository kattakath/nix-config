# The terranix stacks and their per-user state directories, as DATA — one list, read by:
#   modules/parts/terranix.nix        every wrapper's `state_dir` (stateDir refuses a stack
#                                     missing here, so a new stack cannot skip this list)
#   modules/home/claude-guardrails.nix  the `permissions.ask` Read rules over those dirs
#
# cf-tunnel's dir is a DENY, spelled as a literal in ./secret-read-paths.nix (a hook parses
# that file as text); the guardrails skip any dir already on that list, so no path sits in
# both tiers.
#
# Before this file the guardrails list was hand-kept, and the grafana and github stacks
# shipped without an entry (hygiene NH-C-fact-twice, 2026-11-04).
#
# NOT auto-imported — `modules/_lib/` is excluded from import-tree by convention
# (see ./nix-ld-libraries.nix). Consumers `import` it explicitly.
let
  names = [
    "cf-tunnel"
    "cf-access-org"
    "cf-zones"
    "gcp-foundation"
    "gcp-budget"
    "hc-checks"
    "grafana"
    "github"
  ];
in
{
  inherit names;

  # The directory name under $XDG_STATE_HOME (default ~/.local/state).
  stateDirName =
    stack:
    if builtins.elem stack names then
      "nix-config-${stack}"
    else
      throw "modules/_lib/terranix-stacks.nix: unknown stack '${stack}'. Add it to `names`, which the Claude Code guardrails read.";

  # The terranix-drift agent's own state dir (summary.json lives there). Not a stack; it
  # sits in the same nix-config-* family, so its one spelling lives beside theirs.
  driftStateDirName = "nix-config-terranix-drift";
}
