# Security Policy

## Reporting a vulnerability

If you find a security issue in this repository, please report it privately rather than opening a public issue.

- Preferred: open a [GitHub private security advisory](https://github.com/kattakath/nix-config/security/advisories/new).
- Alternatively, email **8927166+ismailkattakath@users.noreply.github.com**.

Please include enough detail to reproduce the issue. I'll acknowledge the report and work with you on a fix and disclosure timeline.

## Secrets model

This is infrastructure configuration, so how secrets are handled matters. The design principle is that **nothing sensitive is ever stored in plaintext in Nix or git** — the Nix store is world-readable, so a literal in a `.nix` file is effectively public.

- **System / service credentials** (today: `nixpi`'s Cloudflare Tunnel connector token and `nixvm`'s GitHub Actions runner PAT) are committed **encrypted** with [sops-nix](https://github.com/Mic92/sops-nix) — recipients in `.sops.yaml` (each secret age-encrypted to the target host's SSH host key plus the operator's key), ciphertext in `secrets/<host>.yaml`. Each host decrypts at activation with its own host key into `/run/secrets/<name>` (root-only, mode 0400); the plaintext never touches git or the world-readable store. (agenix remains removed; sops-nix was adopted 2026-07-08. The `cloudflared-connector` module still defaults to an operator-placed `/etc/secrets/cloudflared-token` for hosts that don't opt into sops.)
- **Personal tokens** (GitHub, Hugging Face, Docker, etc.) never enter Nix or git. They live in the macOS login Keychain or are established via one-time CLI logins.
- **Binary cache (Cachix):** the public `ismailkattakath` cache is consumed **read-only** by every host and the devcontainer — consumers hold only the substituter URL and public key, never a token. The write credential exists solely as a GitHub Actions secret used by CI to push build outputs; it is never present in Nix, git, or on any consumer.

If you believe any of the above assumptions has been violated (a committed secret, an over-scoped credential, a token that reached a consumer), please report it via the channels above.
