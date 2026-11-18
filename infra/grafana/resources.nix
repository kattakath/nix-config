# Every live object of the Grafana Cloud stack, adopted by `import` blocks (stack.nix) and
# GENERATED, not hand-written: `tofu plan -generate-config-out` over the live stack, then a
# deterministic HCL -> Nix conversion (2026-11-03, ADR-012 step 2). A `builtins.toJSON` value is
# exactly what the provider stores (rule models, the dashboard, datasource settings).
#
# Edit it like any Nix file. The plan is the judge: any change here shows up as a diff
# against the live stack. Per-person values arrive as arguments (identity.nix) or as the
# `rollup_sheet_id` tofu variable, never as literals.
#
# One file per domain since 2026-11-18, merged here. helpers.nix holds the shared builders;
# a domain file returns `{ <resource type>.<name> = …; }`. Two objects span domains (the
# Fleet overview board and the fleet-health group): addon.nix exports list fragments and
# fleet.nix appends them, so their order is written once, not left to a merge.
{
  operatorEmail,
  gcpProjectId,
  addonGcpProjectId,
  publicSiteUrl,
}:
let
  h = import ./helpers.nix { inherit gcpProjectId publicSiteUrl; };
  addon = import ./addon.nix { inherit h addonGcpProjectId; };
  domains = {
    core = import ./core.nix { inherit h operatorEmail gcpProjectId; };
    fleet = import ./fleet.nix { inherit h addon; };
    career = import ./career.nix { inherit h; };
    maps = import ./maps.nix { inherit h gcpProjectId; };
    nixpi = import ./nixpi.nix { inherit h publicSiteUrl; };
  };
  # Two levels deep, and a resource address declared by two files THROWS: a plain `//`
  # would let one file silently drop another's resource.
  disjoint =
    type:
    builtins.zipAttrsWith (
      name: defs:
      if builtins.length defs == 1 then
        builtins.head defs
      else
        throw "infra/grafana: ${type}.${name} is declared by more than one domain file"
    );
in
builtins.zipAttrsWith disjoint (builtins.attrValues domains)
