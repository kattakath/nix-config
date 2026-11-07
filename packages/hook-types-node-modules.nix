# The `node_modules` tree `.claude/hooks/*.js` type-check against — ONE definition,
# read by `checks.<system>.hook-types` (the CI gate) AND by `link-hook-types` (the
# editor's view), so the TypeScript LSP and CI resolve the identical store path.
# `$out` IS the node_modules directory (no `$out/node_modules`), so it can be the target
# of a GC-rooted out-link.
#
# Pins, and why each:
#   SDK 0.3.300  its package.json `claudeCodeVersion` is 2.1.300, the `claude-code`
#                nixpkgs ships at this pin: the types describe the CLI the fleet
#                actually runs. Bump it WITH the claude-code bump.
#   @types/node  24.19.2 — the node 24 line nixpkgs' `nodejs` is on.
# Both tarballs are fixed-output fetches whose hash IS the registry's own
# `dist.integrity` (sha512 SRI), so the pin is checkable with `npm view`.
#
# No peer dependencies: sdk.d.ts imports zod, @anthropic-ai/sdk and
# @modelcontextprotocol/sdk, none of which the hooks touch; the tsconfig's
# `skipLibCheck` silences their unresolved imports.
#
# Why not nixpkgs' `importNpmLock.buildNodeModules` (the documented node_modules-for-a-
# devShell builder): it reads a package.json + package-lock.json, which would be a second
# copy of the two pins below, and npm would lock the SDK's peer dependencies this tree
# deliberately leaves out.
{
  lib,
  runCommand,
  fetchurl,
}:
let
  npmTarball =
    name: version: hash:
    fetchurl {
      url = "https://registry.npmjs.org/${name}/-/${baseNameOf name}-${version}.tgz";
      inherit hash;
    };
  agentSdk =
    npmTarball "@anthropic-ai/claude-agent-sdk" "0.3.300"
      "sha512-3NGPEUj+VTMQAQ0vaUUQtrce6rNb9a4XhY8QKIOLUp9mDkdbwrrjjD9oMKcDpcLhFKqZdTc02RBUo55GrbY9CA==";
  typesNode =
    npmTarball "@types/node" "24.19.2"
      "sha512-93d49wCWJkCyN87MxLpNN6KXPCwFw7bVUg79mGUV1OS40JGWwVCr8n61DXCSqz7CV6/VfPkb7xec7uP2M+QHWQ==";
in
runCommand "hook-types-node-modules"
  {
    meta = {
      description = "node_modules (claude-agent-sdk + @types/node) that .claude/hooks/*.js type-check against";
      platforms = lib.platforms.all;
    };
  }
  ''
    mkdir -p $out/@anthropic-ai/claude-agent-sdk $out/@types/node
    # --strip-components: each tarball has ONE top directory, and @types/node's is
    # literally `node v24.19` (with a space), not npm's usual `package`.
    tar -xzf ${agentSdk} --strip-components=1 -C $out/@anthropic-ai/claude-agent-sdk
    tar -xzf ${typesNode} --strip-components=1 -C $out/@types/node
  ''
