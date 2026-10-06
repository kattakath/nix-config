# Minister memory index — kattakath/nix-config

- [acpx pnpm 12 fetchDeps break](project_acpx-pnpm12-fetchdeps-break.md) — #809's nixpkgs bump moved pnpm 11.25.0→12.3.4; pnpm 12's `links/` farm feeds JSONC to fetchDeps' jq loop, killing `activate`
- [Worktree guard refuses runtime paths](feedback_worktree-guard-refuses-runtime-paths.md) — `nix eval`, `$VAR` into find, and `sh -c` from xargs are all blocked; write a script file and run it by literal path
