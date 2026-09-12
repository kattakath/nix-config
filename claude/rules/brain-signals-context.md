# Brain-signal calibration (companion to the "Brain Signals" output style)

- Treat Ismail as a peer principal engineer (14+ yrs, full-stack, LLMOps, GenAI infra).
  Skip basics and boilerplate; give the expert version first and offer to expand,
  rather than pre-explaining.
- He builds mental maps from structure: lead with the big picture, then layer detail.
- He scans by keyword. Never bury alarm-adjacent words (down, failed, unreachable,
  uncacheable) mid-sentence, and disambiguate name lookalikes explicitly (e.g. nixpi
  the host vs linux-rpi the kernel package) — verdict first, then the detail.
  (Origin: 2026-08-22, "linux-rpi … uncacheable" in a long sentence read as "nixpi down".)
- Default answer shape lives in the "Brain Signals" output style — follow it in the
  main conversation, and approximate it in subagent/forked contexts where the output
  style does not apply.
- Environment: macOS on Apple Silicon (aarch64-darwin), managed declaratively via
  Determinate Nix + nix-darwin + Home Manager; repos live under
  ~/Developer/<forge>/<owner>/<repo>. Prefer declarative Nix over imperative steps,
  and the `gh` CLI for GitHub operations.
