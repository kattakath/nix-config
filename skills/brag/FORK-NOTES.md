# Fork notes — `/brag` skill

Vendored (not `curl | bash`-installed) from **[kammradt/brag-skill](https://github.com/kammradt/brag-skill)**
(MIT, © Vinicius Kammradt — see `README.md`) so it installs **declaratively** via
`programs.claude-code.skills` (`modules/shared/home.nix`, darwin-gated), the same
reproducible path as the other global skills — no imperative `install.sh`.

## The only change from upstream

Upstream writes its data (`config.json`, `impact.md`, `developer-value.md`) into the
**skill's own directory** (`$SKILL_DIR`, resolved via `readlink`). Under Home Manager that
directory is **Nix-managed** — its files are `/nix/store` symlinks and the dir is rewritten
on every `darwin-rebuild switch` (linkGeneration / orphan-link cleanup). Writing user data
into it is wrong: it isn't version-controlled or backed up, and it collides with the
generation the module owns. (The dir happens to be writable — the read-only bit is the
*files*, not the dir — so it wouldn't hard-fail, which is exactly why the correct home
matters: data belongs in the private repo, not scattered into a managed skill dir.)

So every data path was redirected from `$SKILL_DIR` to **`$BRAG_DATA_DIR`**, which the skill
now *requires* (errors if unset — no hardcoded path baked into the skill prose):

```bash
BRAG_DATA_DIR="${BRAG_DATA_DIR:?set once in nix-config home.nix home.sessionVariables}"
```

`$BRAG_DATA_DIR` is defined in **ONE place** — `modules/shared/home.nix`
(`home.sessionVariables.BRAG_DATA_DIR`, `$HOME`-relative) — and points at
**`~/Developer/local/brags`**, a git repo with **no remote**: `impact.md` /
`developer-value.md` / `config.json` are versioned locally and never pushed anywhere. Change
the location there, in one place; nothing else hardcodes it.

Do not confuse it with `$BRAG_ENGINE_DIR`, which the *other* skill (`brags-review`) uses for
the fail-closed redaction gate. That one is private — it holds a client denylist — and comes
from the nix-personal layer via `kattakath.brag.engineDir`
(`modules/shared/brag-engine.nix`). `/brag` itself never touches it.

Nothing else was modified — the mining logic, modes, templates, and `reference/` are upstream verbatim.

## Where it sits in the rebuilt brags pipeline

`/brag` is the **mine → ledger** stage (replaces the old bespoke `engine/*.py`). Downstream,
the private repo still owns the two custom, novel stages the research found no reuse for:
the fail-closed **redaction gate** and the human-gated **LinkedIn curate** loop.
See project memory `brag-docs-reusable-tools` / `prefer-off-the-shelf`.
