# Minister memory index — kattakath/nix-config

- [acpx pnpm 12 fetchDeps break](project_acpx-pnpm12-fetchdeps-break.md) — #809's nixpkgs bump moved pnpm 11.25.0→12.3.4; pnpm 12's `links/` farm feeds JSONC to fetchDeps' jq loop, killing `activate`
- [Worktree guard refuses runtime paths](feedback_worktree-guard-refuses-runtime-paths.md) — `nix eval`, `$VAR` into find, and `sh -c` from xargs are all blocked; write a script file and run it by literal path
- [nixvm initrd case-hack blocker](project_nixvm-initrd-case-hack-blocker.md) — nixvm's toplevel/VM will NOT build on this Mac: case-hack names leak into the Linux builder, terminfo/l/linux missing. Pre-existing; verify via vmVariant.system.path instead
- [tor-browser aarch64 alpha overlay](project_tor-browser-aarch64-overlay.md) — why overrideAttrs (not .override), the torrc-defaults path move, and that the 16.0a13 pin will 404 when upstream rolls
- [nixvm clipboard over qemu-vdagent](project_nixvm-clipboard-qemu-vdagent.md) — raw qemu.options is correct (no upstream option); virtserialport needs NO `bus=`; text-only; unverified by interaction
- [Resolve the REAL nixpkgs lock node](feedback_resolve-the-real-nixpkgs-lock-node.md) — the node named `nixpkgs` is transitive here; the root's is `nixpkgs_2` (26.11). Reading the wrong one invalidated a whole research lane
