# The secret PATHS no agent may read, as DATA — one copy, rendered by each importer.
#
# WHY DATA AND NOT RULES. Each consumer renders its own spelling: Claude Code
# `permissions.deny` globs (claude-guardrails.nix) and grok's sandbox deny list
# (modules/home/default.nix). Data → strings cannot yield an empty floor on a
# reword the way a match-based derivation can; an EMPTY list is still caught by
# claude-guardrails.nix's assertion and the Bash guard hook's "Rule 1f DISARMED".
#
# WHAT BELONGS HERE: only paths whose CONTENT is a decrypted (or never-encrypted)
# secret. NOT a command shape (`agenix -d`, `secret reveal`, `security
# find-generic-password -w`) — those are Bash-text rules with no path to render, and they stay as
# literals in claude-guardrails.nix. The per-path rationale lives there too; this
# file holds the coordinates, not the argument.
#
# NOT auto-imported — `modules/_lib/` is excluded from import-tree by convention
# (see ./nix-ld-libraries.nix for why that exclusion is a pinned-input
# convention). Consumers `import` it explicitly.
{
  # Absolute paths. Rendered `Read(//<p>/**)` for Claude (its absolute spelling
  # doubles the leading slash).
  #
  # ALL FOUR AGENIX SPELLINGS, because `/run` is a SYMLINK on darwin: measured
  # 2026-10-07, `/run -> private/var/run` and `/run/agenix -> /run/agenix.d/1`.
  # Claude's `Read()` glob does NOT resolve symlinks — it matches the path text the
  # tool call carries — so `Read(//run/agenix/**)` alone never covered a read spelled
  # `/private/var/run/agenix.d/1/…`. Rendering all four closes that hole.
  absolute = [
    "/run/agenix"
    "/run/agenix.d"
    "/private/var/run/agenix"
    "/private/var/run/agenix.d"
  ];

  # Paths under $HOME, written WITHOUT a leading slash. Rendered `Read(~/<p>/**)`
  # for Claude.
  underHome = [
    # The tunnel stack's tofu state. A LITERAL, not ./terranix-stacks.nix's stateDirName:
    # the Bash guard hook parses this file's strings as text (loadSecretPaths).
    ".local/state/nix-config-cf-tunnel"
    ".local/state/nix-config-mcp-public"
    ".aws/sso/cache"
    # page-lab's dedicated browser profiles: session cookies under a mock keychain,
    # so effectively plaintext. Why, and why the managed tier omits it: claude-guardrails.nix.
    ".local/state/page-lab"
  ];

  # ── The WIDER credential inventory — grok's sandbox only ──────────────────
  # These hold credentials but are also read by tools the fleet needs (gh reads
  # ~/.config/gh, evaluation reads **/*.age, this fleet documents ~/.aws/config), so
  # they are NOT Claude Read denies. grok's sandbox has no file-level granularity, so
  # it denies the whole set. `~/.ssh/id_ed25519` is the
  # agenix OPERATOR identity (secrets/secrets.nix) — the reason this tier exists.

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
}
