# Publishing hyperframes-selfhost (mother → public)

Canonical public product: **https://github.com/ismailkattakath/hyperframes-selfhost**

## Model

```
nix-config (mother)
  packages/hyperframes-selfhost/*     # install, compose, image, docs seed
  infra/hyperframes/stack.nix         # Terranix forges terraform/config.tf.json
           │
           │  nix run .#hf-export -- /tmp/hf
           ▼
ismailkattakath/hyperframes-selfhost  # PRs, Actions, community docs
  .env.example                        # yes
  .env                                # never
  terraform/config.tf.json            # generated only
  install.sh                          # primary non-Nix path
```

- **You (upstream):** change TF only via nix-config Terranix; export overwrites public `terraform/`.
- **Forks:** no Nix required; may edit TF; not your problem.

## One-shot publish / update

```bash
# From nix-config checkout (after changes merged or on a PR branch)
nix run .#hf-export -- /tmp/hyperframes-selfhost

# First time only:
#   gh repo create ismailkattakath/hyperframes-selfhost --public --description "…"

cd /tmp/hyperframes-selfhost
# If updating existing clone:
#   git clone git@github.com:ismailkattakath/hyperframes-selfhost.git
#   rsync -a --delete --exclude .git /tmp/hyperframes-selfhost/ ./hyperframes-selfhost/

git init   # first time
git add -A
git status   # confirm NO .env
git commit -m "export: sync from kattakath/nix-config"
git branch -M main
git remote add origin git@github.com:ismailkattakath/hyperframes-selfhost.git  # first time
git push -u origin main
```

Or open a PR against the public repo instead of pushing main.

## Checklist before community noise

- [ ] Cold install green on a clean machine (or Docker Desktop linux)
- [ ] `.env.example` complete; `.env` absent from git
- [ ] `terraform/config.tf.json` present; no `terraform/main.tf`
- [ ] Public CI green (compose config + JSON parse)
- [ ] README states: not HeyGen cloud MCP; manual Tailscale + Google secrets
