# Minister memory index — kattakath/nix-config

- [acpx pnpm 12 fetchDeps break](project_acpx-pnpm12-fetchdeps-break.md) — #809's nixpkgs bump moved pnpm 11.25.0→12.3.4; pnpm 12's `links/` farm feeds JSONC to fetchDeps' jq loop, killing `activate`
- [Worktree guard refuses runtime paths](feedback_worktree-guard-refuses-runtime-paths.md) — `nix eval`, `$VAR` into find, and `sh -c` from xargs are all blocked; write a script file and run it by literal path
- [nixvm initrd case-hack blocker](project_nixvm-initrd-case-hack-blocker.md) — FIXED by disabling one initrd terminfo entry; the mechanism (case-insensitive store + case-hack leaking into the Linux builder) is still live for other paths
- [tor-browser aarch64 alpha overlay](project_tor-browser-aarch64-overlay.md) — why overrideAttrs (not .override), the torrc-defaults path move, and that the 16.0a13 pin will 404 when upstream rolls
- [nixvm clipboard over qemu-vdagent](project_nixvm-clipboard-qemu-vdagent.md) — raw qemu.options is correct (no upstream option); virtserialport needs NO `bus=`; text-only; unverified by interaction
- [Resolve the REAL nixpkgs lock node](feedback_resolve-the-real-nixpkgs-lock-node.md) — the node named `nixpkgs` is transitive here; the root's is `nixpkgs_2` (26.11). Reading the wrong one invalidated a whole research lane
- [Detached launch and process proof](feedback_detached-launch-and-process-proof.md) — macOS has NO `setsid`, and `pgrep -f` matches your own monitor shell; both faked a running VM. Use nohup+disown and `pgrep -x`
- [nixvm 9p shares DO work on darwin](project_nixvm-9p-shares-work-on-darwin.md) — the old `virtiofsd is Linux-only` comment forbade a feature for a year; `useVirtiofs` is `isLinux`, so darwin falls back to `-virtfs` 9p
- [nixvm wireguard: TOOLS ONLY](project_nixvm-wireguard-mount-not-wg-quick-option.md) — conf share built then reverted 2026-10-06 (operator's call); the wg-quick.interfaces rejection still stands (public repo, peer topology in git). macOS stays GUI-only
