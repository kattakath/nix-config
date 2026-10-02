# `services.postgresql` vs the local-rag capsule — the upstream-first record

**Verdict: REFUTED. The daemon stays hand-rolled.** nix-darwin's
`services.postgresql` exists, was read in full, and does not fit — not on taste, on
four properties that each regress **silently**: a green build, a running cluster, and
either a consumer reading zero rows or an agent macOS never restarts.

This file is the artifact [`.claude/rules/upstream-first.md`](../.claude/rules/upstream-first.md)
demands: what was grepped, the option surface found, which half was adopted, which half
stayed custom and the quoted upstream limitation that forced it, the alternatives rejected,
and the condition under which this decision should be revisited.

**It records a refusal, which is the easier thing to lose.** `modules/features/local-rag/pgvector-local.nix`
hand-rolls ~90 lines of Postgres daemon + bootstrap. To a reader who has not opened the
pinned input, "just use `services.postgresql`" is the obvious conventionality fix, and the
module carried no citation saying otherwise until this landed. The cost of re-litigating it
is not the reading — it is that the swap *appears to work*.

## What was grepped, and where

```bash
src=$(nix eval --raw --impure --expr \
  'builtins.toString (builtins.getFlake "'"$PWD"'").inputs.nix-darwin.outPath')
# → /nix/store/8ggr67sci43hlp8ba6rhjrdhhj5490am-source   (the rev in flake.lock)

grep -rn "postgres" "$src/modules/"
# → modules/services/postgresql/default.nix   (370 lines, read in full)
```

Measured on the real host, not inferred — `services.postgresql` is genuinely reachable
from this fleet's darwin module set:

```
darwinConfigurations.macos.config.services ? postgresql   →  true
```

So this is **not** "no option exists". The option exists, is loadable, and was rejected on
fit. Every line citation below is `modules/services/postgresql/default.nix:<line>` in that
store path unless another file is named.

## The option surface

| Option | Default | Verdict here |
|---|---|---|
| `enable` (:43) | `false` | — |
| `package` (:45) | `postgresql_14` via `stateVersion` (:313) | capsule needs 16 — settable |
| `port` (:53) | `5432` | capsule uses `5433` — settable |
| `dataDir` (:67) | `/var/lib/postgresql/<psqlSchema>` (:316) | **blocker 5** (destructive) |
| `authentication` (:79) | `mkAfter` block (:318-324) | `mkAfter` ✅ but see **blocker 4** |
| `identMap` (:96) | `""` | unused |
| `initdbArgs` (:108) | `[]` | would carry `--auth=peer`, but not `-U` |
| `initialScript` (:118) | `null` | **blocker 3 — declared, inert** |
| `ensureDatabases` (:126) | `[]` | **blocker 3 — declared, inert** |
| `ensureUsers` (:141) | `[]` | **blocker 3 — declared, inert** |
| `enableTCPIP` (:200) | `false` → `listen_addresses = "localhost"` (:303) | fine |
| `logLinePrefix` (:210) | `"[%p] "` | fine |
| `extraPlugins` (:221) | `[]` → `package.withPackages` (:10-12) | **ADOPTED in spirit** |
| `settings` (:231) | renders `postgresql.conf` (:21) | fine |
| `recoveryConfig` (:257) | `null` | unused |
| `superUser` (:265) | `"postgres"`, `internal` + `readOnly` | **blocker 2** |

Rendered unit: `launchd.user.agents.postgresql` (:335), `KeepAlive` + `RunAtLoad`
(:361-362), `PGDATA` via `EnvironmentVariables` (:363-365).

## The five blockers

### 1. It renders into the launchd lane the fleet is emptying

Upstream emits **`launchd.user.agents.postgresql`** (:335). `modules/darwin/launchd-sources.nix`
enumerates what that means:

| Source | Domain | `selfHeals` |
|---|---|---|
| home-manager `launchd.agents` ← **capsule today** | `gui` | **`true`** |
| nix-darwin `launchd.user.agents` ← **upstream renders here** | `gui` | `false` |
| nix-darwin `launchd.agents` | `gui` | `false` |
| nix-darwin `launchd.daemons` | `system` | `false`, but **reconciled** |

`selfHeals = true` is home-manager's activation probing with `launchctl print` and falling
through to bootout+install+bootstrap when a plist is unchanged but the agent is not loaded.
nix-darwin's activation is diff-gated in both its lanes, so an unchanged plist means the
load body never runs. And `launchd-reconcile.nix` is system-domain and root-only — at boot
there is no logged-in user, so `gui/<uid>` does not exist and it cannot reach a gui agent
even in principle.

A `selfHeals = false; domain = "gui"` unit is therefore covered by **neither** mechanism.
That file also records the fleet's standing remedy and its direction of travel:

> The fleet's standing remedy for that is MIGRATION to the home-manager lane, where upstream
> already owns the probe (metube and yt-dlp-web-ui moved 2026-09-22 for exactly this […]).
> Do not "fix" it by widening the reconciler.

Adopting `services.postgresql` walks a **live database** the opposite way down that path,
ten days after two services were moved off it. Measured on the host: `launchd.user.agents`
holds exactly five units today (two log rotators, two CI runner agents and a clipboard
helper), matching `launchd-sources.nix`'s own count — and Postgres is correctly not among
them.

### 2. arg0 would become `/bin/sh`

Upstream uses the `script` option, and nix-darwin renders that to
(`modules/launchd/default.nix:88-93`):

```nix
serviceConfig.ProgramArguments = mkIf (config.command != "") [
  "/bin/sh"
  "-c"
  "/bin/wait4path /nix/store && exec ${config.command}"
];
```

arg0 is Apple's shell. That is two failures at once:

- [`.claude/rules/launchd-naming.md`](../.claude/rules/launchd-naming.md) — macOS Background
  Task Manager lists a unit by arg0's basename, so this appears as `sh`.
- the **measured TCC failure** `modules/shared/launchd-launcher.nix` exists to prevent:
  "A /nix/store arg0 can read ~/Downloads; `/bin/sh` is refused with EPERM".

The capsule gets the correct arg0 for free: `launchd-launcher.nix` defaults
`launcher.name = "nix-${name}"`, and home-manager renders the plist's
`ProgramArguments = [ "${launcher}/bin/${launcherName}" ]`
(pinned home-manager `modules/launchd/default.nix:138-158`). Measured on the host:
`launcher.name = "nix-postgres-pgvector"`.

That launcher types **`options.launchd.agents`** — home-manager's attr. It cannot reach
nix-darwin's `launchd.user.agents`: the wrap is not merely absent in that lane, it is
unreachable from it.

**`ast-grep` cannot catch this one.** `ast-grep/rules/launchd-bare-interpreter-arg0.yml` is
scoped to this repo's own files; the offending `"/bin/sh"` literal lives in the pinned input.
A regression here would be invisible to every existing gate — which is why it is now pinned
by a capsule check instead.

### 3. The bootstrap has no upstream home — the options exist and do nothing

`initialScript` (:118), `ensureDatabases` (:126) and `ensureUsers` (:141) are fully declared,
with types, descriptions and examples. They are also **inert**, and upstream says so in its
own words (:283-295):

```nix
    # FIXME: implement. I didn't implement these because they require some
    # sort of postStart facility, which launchd does not provide.
    #
    # one could perhaps trigger another agent by the existing agent, but
    # I couldn't find how to do that.
    warnings = if cfg.initialScript != null
      || cfg.ensureDatabases != []
      || cfg.ensureUsers != []
      then [''
        Currently nix-darwin does not support postgresql initialScript,
        ensureDatabases, or ensureUsers
      '']
      else [];
```

This is **worse than absence**, and it is the single most important line in this document. A
reader grepping for an option name finds three hits and concludes the bootstrap is upstream's
problem. Setting them changes nothing and emits a warning that a `switch` scrolls past.

So the capsule's bootstrap — the scoped role, the database, `CREATE EXTENSION vector` /
`http`, the `embed()` function, the HNSW index, the per-entry extra databases — stays custom
**whatever happens to the daemon half**. That is what makes the "partial adoption" shape
unattractive rather than merely smaller: it buys nothing and pays blockers 1, 2, 4 and 5.

### 4. The no-secret model would invert

`superUser` is `internal` + `readOnly` (:265-274):

```nix
      superUser = mkOption {
        type = types.str;
        default = "postgres";
        internal = true;
        readOnly = true;
```

and upstream runs `initdb -U ${cfg.superUser}` (:345). The capsule runs
`initdb -D "$DATADIR" -U "$OSUSER" --auth=peer`, because its entire password-free design
rests on **peer auth, where the OS user name must equal the role name**: the macOS login
user *is* the cluster superuser over the unix socket, which is how the bootstrap performs
admin work with no credential in existence. Upstream pins the superuser to `postgres` with no
way to change it, so that identity match breaks and every bootstrap `psql` loses its admin
path.

On `authentication` — **it is `mkAfter`** (:318), so repo-side rules would prepend cleanly,
which is the right thing for `pg_hba.conf`'s first-match-wins ordering. That is a genuine
point in upstream's favour. The problem is the tail it appends (:321-324):

```
        local all all              peer
        host  all all 127.0.0.1/32 md5
        host  all all ::1/128      md5
```

`all all` over TCP — **every** database for **every** role, password-authenticated. The
capsule emits exactly one database/role pair per line and nothing else, by rewriting the
whole file. Suppressing upstream's tail needs `lib.mkForce`, which discards the `mkAfter`
behaviour that made the option attractive in the first place. There is no configuration of
this option that keeps both properties.

### 5. `dataDir` moves, and the live cluster goes dark

`dataDir` defaults to `/var/lib/postgresql/${psqlSchema}` (:316) — a root-owned path — while
the capsule's is `$HOME/.local/share/postgres-pgvector` (measured on the host:
`/Users/ismail/.local/share/postgres-pgvector`). Upstream's agent then does (:340-350):

```nix
          if ! test -e ${cfg.dataDir}/PG_VERSION; then
            # Cleanup the data directory.
            ${pkgs.coreutils}/bin/rm -f ${cfg.dataDir}/*.conf
            # Initialise the database.
            ${postgresql}/bin/initdb -U ${cfg.superUser} ${concatStringsSep " " cfg.initdbArgs}
```

A `dataDir` change therefore **initdb's a fresh, empty cluster**. The old bytes are not
deleted, but from every consumer's point of view the database is gone: the retrieval corpus
and any consumer's local dev database read as empty, with a green build and a healthy-looking
server. This repo's local RAG holds client material, so "looks empty" is the worst available
failure shape.

`dataDir` is settable, so this is the one blocker that is *avoidable* — but only by someone
who knew to avoid it. It is pinned by a check now rather than left to care.

## What was adopted, and what stayed custom

| Half | Owner | Evidence |
|---|---|---|
| Postgres **daemon** (launchd unit, supervision, pg_hba, initdb) | **custom** — stays | blockers 1-5 |
| **Bootstrap** (role, db, extensions, `embed()`, index, extra dbs) | **custom** — forced | blocker 3, quoted |
| **Extension build** (pgvector + pgsql-http) | **upstream mechanism** | `postgresql_16.withPackages`, the same call `extraPlugins` makes at :10-12 |
| **Ollama coordinates** (embed host/port) | **upstream option** | home-manager `services.ollama.host`/`.port` |

So the capsule is already a *partial* reuse; the half that could move is the half that was
already upstream's. **pgvector itself was never at risk** — it does not arrive through
`services.postgresql` at all. It comes from `pkgs.postgresql_16.withPackages (ps: [ ps.pgvector ps.pgsql-http ])`,
which is unchanged by this decision. Verified three ways: the package expression is untouched,
the `local-rag-module` check still asserts the agent and the `databaseUri` seam, and
`local-rag-extra-dbs` still asserts `CREATE EXTENSION IF NOT EXISTS vector` reaches the
generated wrapper.

## Alternatives rejected

| Alternative | Why it lost |
|---|---|
| **Full adoption** of `services.postgresql` | Blocker 3 — the bootstrap is unimplementable upstream, so the custom half survives anyway while blockers 1, 2, 4 and 5 are all paid. |
| **Partial adoption**: upstream daemon + custom bootstrap *(the shape this investigation set out to land)* | Same blockers 1, 2, 4, 5 for zero lines saved. The bootstrap would also need a second launchd unit ordered before the daemon, which is the `postStart` facility upstream's own FIXME says launchd does not provide. |
| **Adopt, pinning `dataDir` + `package` + `port` and `mkForce`-ing `authentication`** | Retires blockers 4-partial and 5, leaves 1, 2 and 3 untouched — and `mkForce` discards the only property (`mkAfter`) that favoured the option. |
| **Move the capsule to nix-darwin `launchd.daemons`** and hand-roll there | Gains the reconciler, loses home-manager's self-heal probe and the whole `local.rag.*` home-manager option surface, including the `databaseUri` seam. A system daemon would also run the cluster as root, inverting blocker 4 rather than solving it. |
| **Keep custom, write nothing down** *(the status quo before this)* | The failure this document is for. The module carried no citation, so the next reader re-derives it or, worse, "fixes" it. |

## What is proven, and what is not

| Claim | Status |
|---|---|
| `services.postgresql` exists and is reachable on `macos` | **measured** (`config.services ? postgresql` → `true`) |
| `authentication` is `mkAfter` | **quoted**, :318 |
| `initialScript` / `ensureDatabases` / `ensureUsers` are declared but inert | **quoted**, :118-198 declaration + :283-295 warning |
| Upstream renders `launchd.user.agents`, arg0 `/bin/sh` | **quoted**, :335 + `modules/launchd/default.nix:88-93` |
| That lane self-heals under neither mechanism | **cited** to `modules/darwin/launchd-sources.nix` (which cites the pinned sources `file:line`) |
| The capsule's arg0 is `nix-postgres-pgvector` | **measured** on the host |
| `dataDir` default differs and triggers `initdb` | **quoted**, :316 + :340-350 |
| **Not tested:** that adoption actually loses the live cluster at runtime | **deliberately not run.** Proving blocker 5 empirically means pointing a fresh `initdb` at a live RAG store. The code path is quoted instead. |
| **Not tested:** whether macOS in practice drops this agent often enough for `selfHeals` to matter | **unmeasured.** Blocker 1 rests on the mechanism's absence, not on an observed restart failure. This is the **weakest assumption** here; a count of `launchctl print` misses across the five gui units would settle it. |

## Mechanised, not just written down

`modules/features/local-rag/checks/module-evaluations.nix` →
`checks.<system>.local-rag-upstream-seam` pins the four properties the swap would move: the
home-manager lane, a store-path arg0, `initdb … --auth=peer` with the login user, no `md5`
rule anywhere, and `dataDir` under `$HOME`. Each assertion was falsified before landing —
an injected `md5` rule, a `/var/lib/postgresql/16` `dataDir`, and a dropped `--auth=peer`
each turned the check red with its own message.

Darwin-only, like the rest of the capsule's checks, since the services are launchd agents.

## Retire this decision when

nix-darwin grows the `postStart` facility its own FIXME asks for (:283) **and** renders
Postgres into a lane that either self-heals or is reconciled. Either one alone is
insufficient: the facility without the lane still fails blockers 1 and 2, and the lane
without the facility still fails blocker 3.

Until then the citation lives in
`modules/features/local-rag/pgvector-local.nix`'s header, where the next reader tempted by
the one-line fix will actually hit it.
