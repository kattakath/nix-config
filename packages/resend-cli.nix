# `resend` — the official Resend CLI (github.com/resend/resend-cli, npm `resend-cli`),
# for sending/managing email (Resend account: DontSell.ai's dontsell-ai/app project) from
# the terminal. Not yet packaged in nixpkgs (checked 2026-08-21: `nix search nixpkgs
# resend-cli` -> no hits, only the unrelated python `resend` SDK), so this is an `npx`
# runtime-fetch wrapper — same convention as the other unpackaged npm CLIs here
# (mcp-wordpress via wpMcp, telegram-mcp), pinned to a fixed version for reproducibility.
#
# AUTH: the CLI's own documented priority is `--api-key` flag > `RESEND_API_KEY` env var >
# saved `resend login` credentials (resend.com/docs/cli). This wrapper injects
# RESEND_API_KEY from the login Keychain at RUN TIME (never in argv/git/store — same
# pattern as obs-fb-setup's FB_PERSISTENT_STREAM_KEY / apifyMcp's APIFY_TOKEN in mcp.nix),
# so every invocation is non-interactively authenticated with no browser OAuth step and no
# on-disk credential file. The same secret is already used by dontsell-ai/app's Resend
# integration (Vercel env `RESEND_API_KEY`, sourced from this same Keychain entry).
# Resilient by design (warns, does not abort) so a missing secret can't break other Keychain-
# dependent activation steps: `resend` itself will simply fail auth until one is set.
# The Keychain SERVICE is `resend.com:api` (the <tool>:<host>:<kind> convention), and the
# lookup below is by service — so `secret set RESEND_API_KEY <key>` would store it under
# the service `RESEND_API_KEY` and this wrapper would never find it. Bind the env name
# explicitly instead, and pipe the value so it never reaches argv or shell history:
#   pbpaste | secret set --env RESEND_API_KEY resend.com:api   # Resend dashboard -> API Keys
{
  writeShellApplication,
  nodejs,
}:
writeShellApplication {
  name = "resend";
  runtimeInputs = [ nodejs ];
  text = ''
    key="$(/usr/bin/security find-generic-password -a "$(id -un)" -s resend.com:api -w 2>/dev/null || true)"
    if [ -z "$key" ]; then
      echo "resend: no login-Keychain secret for service resend.com:api — auth will fail until set (pbpaste | secret set --env RESEND_API_KEY resend.com:api)." >&2
    fi
    export RESEND_API_KEY="$key"
    exec npx -y resend-cli@2.14.0 "$@"
  '';
}
