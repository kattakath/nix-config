# `claude-work` — Claude Code as the WORK account, alongside
# plain `claude` as the personal one (Max), at the SAME time, in different projects.
#
# WHY A PER-PROCESS TOKEN. Claude Code keeps ONE login per config dir: the Keychain item
# `Claude Code-credentials` (an isolated CLAUDE_CONFIG_DIR gets its own
# `Claude Code-credentials-<hash>`). `/login` swaps that one item, so every running
# session flips account at once. CLAUDE_CODE_OAUTH_TOKEN in the environment outranks the
# stored login for that process only — measured 2026-10-26 on 2.1.296: `claude auth
# status` with the variable set reports `authMethod: oauth_token` and the SAME
# configDirectory/projectsDirectory (~/.claude). So history, memory, settings and plugins
# stay shared; only the billing identity differs.
#
# REJECTED: a second CLAUDE_CONFIG_DIR (full OAuth, but sharing history/memory means a
# symlink farm two live sessions write through); nixpkgs `cc-switch`/`cc-switch-cli`
# (they rewrite the GLOBAL config — the same one-account-at-a-time limit as `/login`,
# and they fight the Nix-managed settings.json).
#
# THE TOKEN comes from `claude setup-token`, approved in the browser AS the work account
# (~1 year; inference-scoped, so claude.ai connectors may not load in these sessions).
# Plant it without argv or history, under the <tool>:<host>:<kind> convention:
#   pbpaste | secret set --env CLAUDE_CODE_OAUTH_TOKEN claude:work:oauth
{ writeShellApplication }:
writeShellApplication {
  name = "claude-work";
  text = ''
    token="$(/usr/bin/security find-generic-password -a "$(id -un)" -s claude:work:oauth -w 2>/dev/null || true)"
    if [ -z "$token" ]; then
      echo "claude-work: no login-Keychain secret for service claude:work:oauth." >&2
      echo "  1. run: claude setup-token  (approve in the browser as the WORK account)" >&2
      echo "  2. copy the token, then: pbpaste | secret set --env CLAUDE_CODE_OAUTH_TOKEN claude:work:oauth" >&2
      exit 1
    fi
    export CLAUDE_CODE_OAUTH_TOKEN="$token"
    exec claude "$@"
  '';
}
