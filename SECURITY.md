# Security Policy

## Reporting a vulnerability

If you find a security issue in this repository, please report it privately rather than opening a public issue.

- Preferred: open a [GitHub private security advisory](https://github.com/ismailkattakath/nix-config/security/advisories/new).
- Alternatively, email **8927166+ismailkattakath@users.noreply.github.com**.

Please include enough detail to reproduce the issue. I'll acknowledge the report and work with you on a fix and disclosure timeline.

## Secrets model

This is infrastructure configuration, so how secrets are handled matters. The design principle is that **nothing sensitive is ever stored in plaintext in Nix or git** — the Nix store is world-readable, so a literal in a `.nix` file is effectively public.

- **System / service credentials** (e.g. the Cloudflare tunnel credential) are encrypted with [agenix](https://github.com/ryantm/agenix), scoped to a specific host's SSH host key, and decrypted only at activation on that host.
- **Personal tokens** (GitHub, Hugging Face, Docker, etc.) never enter Nix or git. They live in the macOS login Keychain or are established via one-time CLI logins.
- **Binary cache (Cachix):** the public `ismailkattakath` cache is consumed **read-only** by every host and the devcontainer — consumers hold only the substituter URL and public key, never a token. The write credential exists solely as a GitHub Actions secret used by CI to push build outputs; it is never present in Nix, git, or on any consumer.

If you believe any of the above assumptions has been violated (a committed secret, an over-scoped credential, a token that reached a consumer), please report it via the channels above.
