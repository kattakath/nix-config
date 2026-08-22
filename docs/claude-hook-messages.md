# Reading Claude Code hook messages in this repo

The hooks in [`.claude/settings.json`](../.claude/settings.json) surface messages that the
Claude Code harness labels with error-adjacent words even when nothing is broken. This is
the decoder: **scan the first keywords of the message, not the harness label.**

| You see | It actually is | Action |
|---|---|---|
| *(silence at turn end)* | Stop-gate ran and approved — configs evaluate clean. The normal case. | None |
| `✔︎ stop-gate: …passed…` / `⚠︎ stop-gate: …syntax only…` | Approve, with provenance (host check ran / degraded advisory). | None (⚠︎: rely on CI for full eval) |
| `✘ stop-gate BLOCKED — <category>: …` | **Not a malfunction.** The gate refusing to end the turn: git purity, a `.nix` syntax error, or `nix flake check` failing. Addressed to the agent, which must fix the repo before stopping. | Let the agent fix; it self-resolves |
| `superhook: inner <event> hook crashed (exit N) — safe-approving…` | The hook script itself broke; superhook **fails open** so the session is never wedged. Incident logged. | `/superhook-review` later |
| `superhook: <event> hook blocked Nx with an identical reason and was overridden…` | Loop-breaker: the gate kept failing identically (likely a gate bug, not a config bug). Logged. | `/superhook-review` |
| `PreToolUse:Write hook error: [<the whole rubric>…]: DENY: <reason>` | **The misleading one.** Usually a *policy decision*, not an error: the prompt-based secret/target judge declining a write. The harness renders prompt hooks as `[prompt text]: verdict`, so the hook's own ~40-line rubric is echoed before the verdict. **Only the text after the final `]:` matters.** | Read that final reason; if it looks wrong, `/pretooluse-review` |

## Why the labels mislead

- The harness prefixes every non-approve hook outcome with "error", including deliberate
  DENY/block decisions.
- `type: "prompt"` hooks (the Write|Edit gate) cannot be wrapped by `superhook.js`, and
  their full prompt is echoed in the rendering — the verdict hides at the end. Shortening
  the rubric would trade judge accuracy for cosmetics; not worth it.
- Command hooks under `superhook.js` always self-identify (`superhook:` / `stop-gate`),
  fail open on crashes, and break identical-reason loops after 3 hits — a hook problem is
  therefore loud but never session-fatal.

## Triage entry points

- `/superhook-review` — crash/loop incidents from the supervised command hooks.
- `/pretooluse-review` — the attempt/outcome log for Bash and Write|Edit gates
  (`.claude/hooks/pretooluse.log`), including prompt-hook denials, which have no other log.
