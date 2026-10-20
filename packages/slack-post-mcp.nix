# ONE generic Slack posting launcher: `nix-mcp-slack <workspace>.slack.com`.
#
# WHAT IT DOES. Reads the operator's user token (xoxp) for the workspace named in argv
# from the login Keychain (service `mcp:<host>:xoxp`, the repo's `scope:host:field`
# shape that `secret ls` indexes), then execs korotovsky/slack-mcp-server
# (./slack-mcp-server.nix — why that server, and not the hosted one, is in its header).
#
# WHY THE WORKSPACE IS AN ARGUMENT, NOT A NIX VALUE. Which workspaces the operator is in
# is client identity, and this repo is public. The PRIVATE plugin that wants a workspace
# names it in its own `.mcp.json` (`"command": "nix-mcp-slack", "args": ["<host>"]`), so
# this repo ships the mechanism and no workspace name at all.
#
# UPSTREAM FIRST, both checked:
#   * packages/keychain-mcp.nix (this repo's factory) bakes each Keychain service name
#     in at BUILD time and execs a fixed argv — there is no runtime-selected service, so
#     it cannot serve a host chosen in argv. Own file, on the same precedent as
#     ./gmail-mcp.nix, whose key is likewise chosen per account.
#   * `envchain` already does "Keychain -> env, then exec", but stores items under its
#     own `envchain-<namespace>` service names, which the `secret` index and the GCP
#     backend (local.keychainSecrets) cannot see. Not used; revisit if keychain-secrets
#     ever adopts envchain.
#
# CACHES: left at upstream's default ON PURPOSE. v1.3.0 reads SLACK_MCP_USERS_CACHE /
# SLACK_MCP_CHANNELS_CACHE and, when unset, keys both files by the token's TEAM ID
# (pkg/provider/api.go, newWithXOXP: `getCachePathWithTeamID(teamID, …)`), so two
# workspaces cannot share a cache file. Overriding them per host would only re-derive
# what upstream already isolates.
{
  lib,
  writeShellApplication,
  callPackage,
}:
{
  # Passed in rather than read from Home Manager: a package may not reach into that, and
  # a hardcoded home literal is what ast-grep/rules/no-hardcoded-home-paths.yml rejects.
  homeDirectory,
}:
let
  server = callPackage ./slack-mcp-server.nix { };
in
# `set -u` only, as in keychain-mcp.nix: a missing Keychain item must WARN and still
# start, so the failure is visible in the client instead of looking like a dead server.
writeShellApplication {
  name = "nix-mcp-slack";
  bashOptions = [ "nounset" ];
  excludeShellChecks = [ "SC2155" ];
  text = ''
    host="''${1:-}"
    # The host becomes part of a Keychain service name, so it is validated, not trusted.
    # 64 = EX_USAGE.
    if ! [[ "$host" =~ ^[a-z0-9-]+\.slack\.com$ ]]; then
      echo "usage: nix-mcp-slack <workspace>.slack.com" >&2
      exit 64
    fi

    service="mcp:$host:xoxp"
    export SLACK_MCP_XOXP_TOKEN="$(/usr/bin/security find-generic-password -a "$(id -un)" -s "$service" -w 2>/dev/null || true)"
    if [ -z "$SLACK_MCP_XOXP_TOKEN" ]; then
      echo "nix-mcp-slack: no user token in the login Keychain (service $service)." >&2
      echo "  Set it with: secret set $service <xoxp-token>" >&2
      echo "  Tools will fail until it exists; this launcher still starts so the failure is visible to the client." >&2
    fi

    # Posting on: the reason this server exists (no `Sent using Claude` footer).
    export SLACK_MCP_ADD_MESSAGE_TOOL=true
    # Pinned: a plugin-spawned process and a launchd one do not agree on HOME, and the
    # server keeps its caches under it.
    export HOME=${lib.escapeShellArg homeDirectory}

    exec ${lib.getExe server} --transport stdio
  '';
}
