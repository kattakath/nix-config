# ONE per-account Gmail MCP launcher.
#
# HONEST STATE OF THE DUPLICATION, 2026-10-01: `modules/shared/mcp.nix` still contains an
# inline `mkGmailMcp` with the same logic. It is INERT — that module's gateway is disabled
# (`local.mcpGateway.enable = false`), so nothing builds it — and it goes when the gateway
# code is deleted, which must wait until the Cloudflare side has been destroyed through
# terranix. Until then this file is the LIVE copy and that one is dead weight. Saying so
# is better than claiming a single source of truth that does not yet exist.
#
# WHY A PACKAGE RATHER THAN AN INLINE `let` IN A MODULE. It has two consumers now: the
# `local.gmailMcp` module that puts these on PATH for the PLUGIN lane, and (until it is
# deleted) `modules/shared/mcp.nix`'s gateway. Inlining it in either would make the other
# a copy — and a second copy of credential-handling code is the exact shape the repo
# motto calls "a bug with a delayed fuse". Extracted 2026-10-01 when the gateway was
# purged and the plugin lane needed the same launcher.
#
# WHAT IT DOES, and why none of it can live in the plugin instead:
#   * reads GMAIL_OAUTH_CLIENT_ID / GMAIL_OAUTH_CLIENT_SECRET from the login Keychain at
#     LAUNCH, so no secret is ever in the Nix store (world-readable), in argv, or in the
#     plugin repo. A Claude Code plugin's `.mcp.json` can set `env`, but only to literal
#     values or passthroughs — it cannot run a Keychain read, which is why the plugin
#     declares this wrapper by NAME and the wrapper does the credential work.
#   * materialises `~/.gmail-mcp/gcp-oauth.keys.json` in the exact shape Google's own
#     downloaded client secret has, because @artymclabin/gmail-mcp reads a FILE PATH and
#     has no env-var form for the client id/secret.
#   * gives each account its OWN credentials file and its OWN `--tool-prefix`, because
#     the upstream server keys its token cache by file path and its tools by prefix —
#     without both, four accounts collapse into one and overwrite each other's tokens.
#
# `npx` is baked as an absolute store path, so the launcher is immune to whatever Node
# the calling session has on PATH. That matters here: the plugin lane gets fnm's Node,
# which is a different version from the fleet default, and a launcher that resolved `npx`
# at runtime would behave differently depending on who spawned it.
{
  lib,
  writeShellScriptBin,
  nodejs,
}:
{
  # The real Google/Workspace address. The sanitised alias is derived, never passed in,
  # so the caller cannot desynchronise the tool prefix from the credentials filename.
  email,
  # Passed in rather than read from a module: a package may not reach into Home Manager
  # config, and a hardcoded /Users/<name> in a .nix VALUE is what
  # ast-grep/rules/no-hardcoded-home-paths.yml exists to reject.
  homeDirectory,
}:
let
  # `--tool-prefix` cannot contain "@" or "." — the upstream server rejects it — so the
  # address is sanitised once here and reused for the prefix, the credentials filename
  # and the binary name. One derivation, so they cannot drift apart.
  alias = lib.toLower (
    lib.replaceStrings
      [
        "@"
        "."
        "+"
      ]
      [
        "_"
        "_"
        "_"
      ]
      email
  );
  npx = lib.getExe' nodejs "npx";
in
writeShellScriptBin "nix-mcp-gmail-${alias}" ''
  set -u

  # 077 BEFORE the file exists, not chmod after. The previous inline version wrote the
  # oauth keys and THEN chmod'd them, which leaves a window where a file containing the
  # OAuth client secret is readable by anyone on the box. Narrow, but free to close.
  umask 077

  dir="${homeDirectory}/.gmail-mcp"
  mkdir -p "$dir"

  client_id="$(/usr/bin/security find-generic-password -a "$(id -un)" -s GMAIL_OAUTH_CLIENT_ID -w 2>/dev/null || true)"
  client_secret="$(/usr/bin/security find-generic-password -a "$(id -un)" -s GMAIL_OAUTH_CLIENT_SECRET -w 2>/dev/null || true)"
  if [ -z "$client_id" ] || [ -z "$client_secret" ]; then
    echo "nix-mcp-gmail-${alias}: GMAIL_OAUTH_CLIENT_ID / GMAIL_OAUTH_CLIENT_SECRET are not in the login Keychain." >&2
    echo "  Set them with: secret set GMAIL_OAUTH_CLIENT_ID   (and _SECRET)" >&2
    echo "  Tools will fail until both exist; this launcher still starts so the failure is visible to the client." >&2
  fi

  # printf, not a heredoc: a heredoc inside a Nix indented string has to be de-indented
  # to column 0 or the terminator never matches, which makes the whole block fragile to
  # reformatting. printf also quotes the substitutions properly.
  oauth_keys="$dir/gcp-oauth.keys.json"
  printf '{"installed":{"client_id":"%s","client_secret":"%s","redirect_uris":["http://localhost"]}}\n' \
    "$client_id" "$client_secret" > "$oauth_keys"

  export GMAIL_OAUTH_PATH="$oauth_keys"
  export GMAIL_CREDENTIALS_PATH="$dir/credentials-${alias}.json"
  # The server writes its token cache relative to HOME; launchd and a plugin-spawned
  # process do not agree on HOME, so it is pinned.
  export HOME="${homeDirectory}"

  # FIRST RUN NEEDS A BROWSER, once per account:
  #   GMAIL_OAUTH_PATH=$oauth_keys GMAIL_CREDENTIALS_PATH=$GMAIL_CREDENTIALS_PATH \
  #     ${npx} -y @artymclabin/gmail-mcp auth
  exec ${npx} -y @artymclabin/gmail-mcp --tool-prefix=${alias}_
''
