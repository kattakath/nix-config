# `nix-mcp-mcpfinder` — the mcpfinder MCP server (cross-registry MCP-server DISCOVERY:
# the Official MCP Registry + Glama + Smithery) launched under a Node that can actually
# run it.
#
# WHY A WRAPPER EXISTS AT ALL, which is the only interesting thing about this file.
# The server is a plain npm package, so the obvious declaration is a bare `npx -y
# @mcpfinder/server@1.1.0` in the owning plugin's `.mcp.json` and no Nix at all. That was
# tried (kattakath/skills#43) and reverted (#44). Re-measured 2026-10-02, unchanged:
#
#   $ npx -y @mcpfinder/server@1.1.0
#   Error [ERR_UNKNOWN_BUILTIN_MODULE]: No such built-in module: node:sqlite
#   Node.js v20.20.2
#
# `node:sqlite` landed in Node 22.5. The fleet's default Node is 20.x (fnm), so the Node a
# plugin's bare `npx` resolves to can never satisfy this package; under this flake's
# `pkgs.nodejs` (24.20.0) the same spec starts and lists its four tools. `runtimeInputs`
# puts that Node in front of `npx`, which is the entire job — same shape as
# ./resend-cli.nix, which wraps a different unpackaged npm CLI for a different reason.
#
# REJECTED ALTERNATIVES, so this is not re-litigated:
#   * raise the fleet default Node to 24 — a fleet-wide bump to move one server, against
#     the 20.x default ADR-007 settled (acpx pins its own Node for the same reason).
#   * a plugin-side `fnm exec --using=22` wrapper — needs that Node installed in fnm on
#     every machine, reintroducing exactly the machine-bound coupling the plugin lane
#     exists to remove. #44 rejected it and nothing has changed.
#   * drop the `@1.1.0` pin for a release that bundles its own sqlite — the pin is a
#     SECURITY control: a later release could reintroduce `add_mcp_server_config`, which
#     writes client config files imperatively, the one thing this repo's declaration-only
#     adoption model exists to prevent. Trading that away to fix a Node error is backwards.
#
# NOT PINNED AS A STORE PATH INSIDE THE PACKAGE NAME: `npx` fetches `@mcpfinder/server`
# at spawn from npm, as the gateway did before it. A nixpkgs build would be better, but
# nixpkgs does not package it (checked 2026-10-02) — so this is the same runtime-fetch
# trade the other npm-only wrappers here make, with the version pinned so the fetch is
# reproducible.
#
# NO STATE DIRECTORY NEEDED: measured 2026-10-02 from an empty cwd, a search call creates
# no file in the working directory and none under $HOME — its sqlite cache never touches
# the filesystem, so there is nothing to redirect to XDG.
{
  writeShellApplication,
  nodejs,
}:
writeShellApplication {
  name = "nix-mcp-mcpfinder";
  runtimeInputs = [ nodejs ];
  text = ''
    exec npx -y @mcpfinder/server@1.1.0 "$@"
  '';
}
