# ONE generic stdio-MCP launcher: read the credentials at LAUNCH, then exec the server.
#
# WHAT IT IS. The extracted form of `modules/shared/mcp.nix`'s `mkGeneratedStdio` — the
# function the purged gateway used to build nine of its servers. Nothing here is new
# mechanism; the invocations, the pins and the Keychain service names were read out of
# that file (origin/main's `catalogArgOverrides` + `requiredEnvToPasswordCommand`), not
# re-derived from an upstream README.
#
# WHY A GENERIC FACTORY RATHER THAN ONE FILE PER SERVER. The servers
# modules/home/plugin-mcp.nix builds through it need exactly the same shape: export N
# variables, exec a pinned interpreter.
# These do not write anything, so another copy of "export then exec" per server would be the
# "second copy is a bug with a delayed fuse" the repo motto names. The old gateway had
# already proven one function covers them; this is that function, lifted.
#
# WHY IT CANNOT LIVE IN THE PLUGIN. A Claude Code plugin's `.mcp.json` can set `env`, but
# only to literal values or `${VAR}` passthroughs — it cannot run
# `/usr/bin/security find-generic-password`. So nix-config seeds the plugin's `launcher`
# setting with a BINARY name and this builds that binary. Secret NAMES (Keychain service ids) are fine in Nix; a secret VALUE would
# land in the world-readable store, which is why the read happens at launch instead.
#
# NO FILE IS WRITTEN, so there is no `umask 077` here. Credentials reach the
# server through its ENVIRONMENT, never through argv (visible in `ps`) and never through
# a file. Saying so explicitly is cheaper than someone later "adding the missing umask"
# and wondering what it protects.
#
# The interpreter is baked as an absolute store path AND prepended to PATH. Both halves
# are needed, which is not obvious: MEASURED 2026-10-02, baking the absolute
# `…/nodejs-24/bin/npx` alone is NOT enough. `npx` runs under its own store-path shebang
# fine, but it then execs the DOWNLOADED package's bin, whose shebang is
# `#!/usr/bin/env node` — so the server resolves node from the CALLER's PATH. In this
# session that was fnm's node 20 and `@apify/actors-mcp-server` refused to start:
#   Error: Apify MCP server requires Node.js 22 or later (you have v20.20.2).
# The purged gateway never hit this because it ran under launchd with `pkgs.nodejs` on the
# agent's PATH; a plugin-spawned launcher has no such PATH control, so it sets its own.
{
  lib,
  writeShellApplication,
  nodejs,
  uv,
}:
{
  # Server id. Becomes the binary name `nix-mcp-<name>` — the value nix-config seeds
  # into the plugin's `launcher` setting.
  name,
  # "npx" or "uvx" — the two the catalog's stdio entries use. Resolved to a store path
  # here, mirroring the purged gateway's `resolveCatalogCommand`.
  interpreter,
  # Full argument vector for that interpreter, INCLUDING this fleet's version/interpreter
  # pins. Pins are not cosmetic: an unpinned `uvx postgres-mcp` was measured to break two
  # different ways (see modules/home/plugin-mcp.nix for the per-server detail).
  args,
  # ENV_VAR_NAME -> login-Keychain SERVICE id. Read with `-a $(id -un)`, the account every
  # `secret set` registers under. A missing entry warns and still starts, so the failure
  # is visible in the client rather than looking like a crashed server.
  keychainEnv ? { },
  # ENV_VAR_NAME -> literal value, for a non-secret coordinate the server needs (postgres'
  # loopback-trust connection URI). Deliberately separate from keychainEnv so a reader can
  # see at a glance which values are secret and which are not.
  plainEnv ? { },
  # Passed in rather than read from Home Manager config: a package may not reach into that,
  # and a hardcoded /Users/<name> in a .nix VALUE is what
  # ast-grep/rules/nix-hardcoded-home-path.yml rejects.
  homeDirectory,
}:
let
  runtime =
    if interpreter == "npx" then
      nodejs
    else if interpreter == "uvx" then
      uv
    else
      throw "packages/keychain-mcp.nix: unknown interpreter '${interpreter}' for ${name} (only npx/uvx are resolved; anything else needs its own launcher)";
  command = lib.getExe' runtime interpreter;
in
# writeShellApplication rather than writeShellScriptBin, for the build-time shellcheck these
# credential launchers had no gate for. `bashOptions` keeps EXACTLY the `set -u` they always
# ran under, not the default errexit + pipefail: a missing Keychain entry must WARN and still
# start (keychainEnv above), so nothing here may abort the launch. SC2155 ("declare and
# assign separately") is excluded because masking each read's status is the design — the
# `|| true` discards it, and the `[ -z ]` test that follows is the real check.
writeShellApplication {
  name = "nix-mcp-${name}";
  bashOptions = [ "nounset" ];
  excludeShellChecks = [ "SC2155" ];
  text = ''
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (var: service: ''
        export ${var}="$(/usr/bin/security find-generic-password -a "$(id -un)" -s ${lib.escapeShellArg service} -w 2>/dev/null || true)"
        if [ -z "${"$" + var}" ]; then
          echo "nix-mcp-${name}: ${var} is not in the login Keychain (service ${service})." >&2
          echo "  Set it with: secret set ${service} <value>" >&2
          echo "  Tools will fail until it exists; this launcher still starts so the failure is visible to the client." >&2
        fi
      '') keychainEnv
    )}

    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (var: value: "export ${var}=${lib.escapeShellArg value}") plainEnv
    )}

    # Pinned: a plugin-spawned process and a launchd one do not agree on HOME, and both
    # npx and uvx keep their package caches under it.
    export HOME=${lib.escapeShellArg homeDirectory}

    # PREPENDED, not replaced: the downloaded server's own `#!/usr/bin/env node` shebang
    # resolves here instead of in the caller's fnm shim (see the header's measurement).
    # Prepend rather than overwrite so a server that shells out to something ordinary still
    # finds it.
    export PATH=${lib.escapeShellArg "${runtime}/bin"}:"$PATH"

    exec ${command} ${lib.concatMapStringsSep " " lib.escapeShellArg args}
  '';
}
