# Security Policy

## Reporting a vulnerability

If you find a security issue in this repository, please report it privately rather than opening a public issue.

- Preferred: open a [GitHub private security advisory](https://github.com/kattakath/nix-config/security/advisories/new).
- Alternatively, email **8927166+ismailkattakath@users.noreply.github.com**.

Please include enough detail to reproduce the issue. I'll acknowledge the report and work with you on a fix and disclosure timeline.

## Secrets model

This is infrastructure configuration, so how secrets are handled matters. The design principle is that **nothing sensitive is ever stored in plaintext in Nix or git** — the Nix store is world-readable, so a literal in a `.nix` file is effectively public.

- **System / service credentials** (today: `nixpi`'s Cloudflare Tunnel connector token and the `macos` + `nixvm` GitHub Actions runner PATs) are committed **encrypted** with [agenix](https://github.com/ryantm/agenix) — recipients declared in `secrets/secrets.nix` (each `.age` secret encrypted directly to the target host's SSH host key plus the operator's key; pure age/SSH, no `ssh-to-age`), ciphertext in `secrets/<name>.age`. Each host decrypts at activation with its own `/etc/ssh/ssh_host_ed25519_key` into `/run/agenix/<name>` (root-only, mode 0400); the plaintext never touches git or the world-readable store. (agenix replaced sops-nix on 2026-07-08. The `cloudflared-connector` module still defaults to an operator-placed `/etc/secrets/cloudflared-token` for hosts that don't opt into agenix, but `nixpi` overrides it to the agenix path.)
- **Personal tokens** (GitHub, Hugging Face, Docker, etc.) never enter Nix or git. They live in the macOS login Keychain or are established via one-time CLI logins.
- **Binary cache (Cachix):** the public `kattakath` cache is consumed **read-only** by every host and the devcontainer — consumers hold only the substituter URL and public key, never a token. The write credential exists solely as a GitHub Actions secret used by CI to push build outputs; it is never present in Nix, git, or on any consumer.

If you believe any of the above assumptions has been violated (a committed secret, an over-scoped credential, a token that reached a consumer), please report it via the channels above.
