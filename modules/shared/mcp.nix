# Private, localhost-only MCP gateway for Claude Code — TEMPORARILY DISABLED.
#
# The original implementation (#142) registered a home-manager launchd USER (GUI)
# agent — `org.nix-community.home.mcp-gateway` in the `gui/<uid>` domain — for the
# flake's `userName` (`ismail`, uid 502). But this Mac's active GUI login is
# `aloshy` (uid 501), so the `gui/502` domain does not exist at activation time
# and `darwin-rebuild switch` aborts with:
#
#   Failed to stop agent 'gui/502/org.nix-community.home.mcp-gateway':
#   Boot-out failed: 125: Domain does not support specified action
#
# A home-manager GUI agent fundamentally needs its user to have an active login
# session, which `ismail` does not. Until the gateway is redesigned to fit the
# two-account setup (e.g. a nix-darwin *system* daemon, or gated to the active
# GUI user), this module is a NO-OP so activation succeeds. Claude Code continues
# to work with its own MCP configuration; nothing here is load-bearing.
_: { }
