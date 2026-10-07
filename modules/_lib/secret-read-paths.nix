# The secret PATHS no agent may read, as DATA — one copy, two renderers.
#
# WHY DATA AND NOT RULES. Two enforcement layers need these paths in two
# incompatible spellings, and until 2026-10-07 only one layer existed:
#
#   Claude Code `permissions.deny`  ->  "Read(~/.aws/sso/cache/**)"
#     (the claude-guardrails.nix home module) — a glob in Claude's own syntax,
#     where a leading `//` means absolute and `~/` means home-relative.
#   a macOS Seatbelt profile        ->  (deny file-read* (subpath "<home>/.aws/sso/cache"))
#     (the plugin-mcp.nix home module, desktop-commander's fence) — SBPL,
#     absolute paths only, no `~` and no globs.
#
# One string cannot be both, so one layer had to be derived from the other.
# Deriving the Seatbelt list by MATCHING the `Read(...)` strings was rejected for
# the reason claude-guardrails.nix already records about its managed-settings
# twin: a match-based derivation yields `[ ]` the moment a rule is reworded, and
# `[ ]` is a well-formed, completely EMPTY floor that nothing reports. Going the
# other way — data to strings — cannot fail that way: there is no pattern to
# miss. Both consumers additionally ASSERT this list is non-empty, so the silent
# vacuum that file warns about is mechanically impossible here rather than merely
# unlikely.
#
# WHAT BELONGS HERE: only paths whose CONTENT is a decrypted secret. NOT a
# command shape (`agenix -d`, `secret reveal`, `security find-generic-password
# -w`) — those are Bash-text rules with no path to render, and they stay as
# literals in claude-guardrails.nix. The per-path rationale lives there too; this
# file holds the coordinates, not the argument.
#
# NOT auto-imported — `modules/_lib/` is excluded from import-tree by convention
# (see ./nix-ld-libraries.nix for why that exclusion is a pinned-input
# convention). Consumers `import` it explicitly.
{
  # Absolute paths. Rendered `Read(//<p>/**)` for Claude (its absolute spelling
  # doubles the leading slash) and `(subpath "<p>")` for Seatbelt.
  #
  # ALL FOUR AGENIX SPELLINGS, because `/run` is a SYMLINK on darwin: measured
  # 2026-10-07, `/run -> private/var/run` and `/run/agenix -> /run/agenix.d/1`.
  # The two layers disagree about symlinks, which is why both forms are needed:
  #   Seatbelt resolves them. Measured the same day with a decoy symlink: a deny
  #     naming EITHER the link path or the resolved target blocks a read through
  #     the link, so for the fence either form alone would have sufficed.
  #   Claude's `Read()` glob does NOT resolve them — it matches the path text the
  #     tool call carries. So the single `Read(//run/agenix/**)` that stood here
  #     before never covered a read spelled `/private/var/run/agenix.d/1/…`.
  #     Rendering all four CLOSES that hole rather than restating one rule.
  absolute = [
    "/run/agenix"
    "/run/agenix.d"
    "/private/var/run/agenix"
    "/private/var/run/agenix.d"
  ];

  # Paths under $HOME, written WITHOUT a leading slash. Rendered `Read(~/<p>/**)`
  # for Claude and `(subpath "${homeDirectory}/<p>")` for Seatbelt — a package may
  # not read Home Manager's config, so the fence is handed the home directory
  # rather than reaching for it (see ../../packages/keychain-mcp.nix).
  underHome = [
    ".local/state/nix-config-cf-tunnel"
    ".local/state/nix-config-mcp-public"
    ".aws/sso/cache"
  ];
}
