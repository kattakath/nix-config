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

  # ── The WIDER credential inventory, and the per-layer divergence ──────────
  #
  # WHY A SECOND TIER EXISTS. The lists above are denied at EVERY layer, because
  # nothing legitimate reads them. These are different: they hold credentials, but
  # some of them are also read by tools the fleet needs working. So each layer
  # takes the subset it can AFFORD, and the point of putting them here is that the
  # divergence is then visible in one file instead of being two lists that
  # silently disagree.
  #
  # THEY SILENTLY DISAGREED, which is why this tier was added (2026-10-07). A
  # /hygiene audit found `grok`'s sandbox.toml denying ~/.ssh while the
  # desktop-commander Seatbelt fence left it READABLE — and `~/.ssh/id_ed25519` is
  # the agenix OPERATOR identity (secrets/secrets.nix), the key
  # `cloudflared-token.age` is encrypted to ALONE. Two mechanisms, one fact, no
  # shared source, and the newer one was the weaker.
  #
  # EVERY ROW BELOW IS PRICED. Measured 2026-10-07 against the built profile, each
  # rejection isolated against a control rather than assumed:
  #
  #   rule                     fence?  why
  #   ~/.ssh/id_* (not .pub)   YES     free — SSH git ls-remote and `gh auth
  #                                    status` both still work, because ssh reads
  #                                    the key from the agent, not the file
  #   ~/.docker                YES     free
  #   **/*.pem, **/.env        YES     free
  #   **/*.age                 NO      BREAKS `nix flake check` — evaluation reads
  #                                    the ciphertexts. Isolated: dropping only
  #                                    this rule makes the check pass again, and
  #                                    the base fence passes too. Accepted,
  #                                    because the KEY deny above already makes a
  #                                    ciphertext useless on its own.
  #   ~/.config/gh             NO      BREAKS `gh auth status`
  #   ~/.aws (whole)           NO      blocks ~/.aws/config, which this fleet
  #                                    documents reading; `.aws/sso/cache` is
  #                                    already denied at every layer above
  #
  # grok's sandbox has no file-level granularity, so it denies whole directories.
  # That is why it gets the wide list and Seatbelt gets the priced subset.

  # Home-relative credential DIRECTORIES. grok denies all of these outright.
  agentCredentialDirs = [
    ".ssh"
    ".aws"
    ".docker"
    ".config/gh"
  ];

  # Basename patterns at any depth. grok renders them `**/<glob>`.
  agentCredentialGlobs = [
    "*.pem"
    "*.age"
    ".env"
  ];

  # The Seatbelt subset, per the priced table above. Deliberately NOT derived by
  # filtering the two lists above — a filter would go empty on a reword, the same
  # objection claude-guardrails.nix records. These are stated, and each omission
  # has its reason in the table.
  fence = {
    # Whole directories the fence can deny for free.
    denyDirs = [ ".docker" ];
    # Private key MATERIAL inside ~/.ssh. The public half is re-allowed by the
    # renderer (last-match-wins), since `id_[^/]*` matches `id_x.pub` too.
    privateKeyDir = ".ssh";
    # Basename patterns the fence can afford — `*.age` is absent ON PURPOSE.
    denyGlobs = [
      "*.pem"
      ".env"
    ];
  };
}
