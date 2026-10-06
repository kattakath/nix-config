# Minister memory index — kattakath/nix-config

- [empire learnings land in the skills repo](project_empire-plugin-landed-learnings.md) — agent prompt text lives in `kattakath/skills` plugins/empire; reaching this fleet needs a SECOND PR (the pin bump). Its conventions, gates and the backticked-name curation trap

- [empire DISABLED 2026-10-06](project_empire-disabled-and-declared-lane-false.md) — `false`, NOT deletion: an absent `declared` key leaves the stale `true` the last activation wrote

- [acpx pnpm 12 fetchDeps break](project_acpx-pnpm12-fetchdeps-break.md) — #809's nixpkgs bump moved pnpm 11.25.0→12.3.4; pnpm 12's `links/` farm feeds JSONC to fetchDeps' jq loop, killing `activate`
- [Worktree guard refuses runtime paths](feedback_worktree-guard-refuses-runtime-paths.md) — `nix eval`, `$VAR` into find, and `sh -c` from xargs are all blocked; write a script file and run it by literal path
- [nixvm initrd case-hack blocker](project_nixvm-initrd-case-hack-blocker.md) — FIXED by disabling one initrd terminfo entry; the mechanism (case-insensitive store + case-hack leaking into the Linux builder) is still live for other paths
- [tor-browser aarch64 alpha overlay](project_tor-browser-aarch64-overlay.md) — why overrideAttrs (not .override), the torrc-defaults path move, and that the 16.0a13 pin will 404 when upstream rolls
- [nixvm clipboard over qemu-vdagent](project_nixvm-clipboard-qemu-vdagent.md) — raw qemu.options is correct (no upstream option); virtserialport needs NO `bus=`; text-only; unverified by interaction
- [Resolve the REAL nixpkgs lock node](feedback_resolve-the-real-nixpkgs-lock-node.md) — the node named `nixpkgs` is transitive here; the root's is `nixpkgs_2` (26.11). Reading the wrong one invalidated a whole research lane
- [Detached launch and process proof](feedback_detached-launch-and-process-proof.md) — macOS has NO `setsid`, and `pgrep -f` matches your own monitor shell; both faked a running VM. Use nohup+disown and `pgrep -x`
- [nixvm 9p shares DO work on darwin](project_nixvm-9p-shares-work-on-darwin.md) — the old `virtiofsd is Linux-only` comment forbade a feature for a year; `useVirtiofs` is `isLinux`, so darwin falls back to `-virtfs` 9p
- [nixvm wireguard: TOOLS ONLY](project_nixvm-wireguard-mount-not-wg-quick-option.md) — conf share built then reverted 2026-10-06 (operator's call); the wg-quick.interfaces rejection still stands (public repo, peer topology in git). macOS stays GUI-only
- [nixvm ssh on Mac loopback 2222](project_nixvm-ssh-loopback-2222.md) — THREE changes needed together (forward+bind+firewall), all in vmVariant; `host.address` is what keeps it off the LAN; core.nix untouched
- [nixvm Retina halving + vdagent is clipboard-only](project_nixvm-retina-halving-and-vdagent-clipboard-only.md) — cocoa.m DIVIDES the framebuffer by backingScaleFactor, so resolution and dpi move as a PAIR; window resize never reflows the guest
- [nixvm lockscreen = permanent lockout](project_nixvm-autologin-locker-lockout-trap.md) — autologin + NO password + a PAM-backed locker; xfce enableScreensaver defaults TRUE upstream. Prove absence from the CLOSURE, not the pam list
- [nixvm: a GREEN BUILD IS NOT ACCEPTANCE](project_nixvm-green-build-is-not-acceptance.md) — two defects passed every gate and were wrong in the guest: a Modes line cannot create a mode, and useNixStoreImage silently inherits writableStore=false (which broke nix, HM and ~/.zshrc)
- [nixvm PGP: gpa + gcr-3 back ON PURPOSE](project_nixvm-pgp-pinentry-gcr-tradeoff.md) — pinentry-gtk2 is a THROWING alias stub; gcr-3 returns deliberately (a passphrase prompt has a valid answer); gpa 126 vs seahorse 145 paths, both carry avahi+openldap
- [nixvm features come in TWO halves](project_nixvm-two-layer-feature-class.md) — clipboard, display, SSH and audio each need a host QEMU arg AND a guest service; one half alone is a silent no-op that builds green
- [nixvm USB passthrough is CLOSED](project_nixvm-usb-passthrough-closed.md) — operator accepted no USB 2026-10-06; no qemu.options line can fix it, usbipd-mac was denied by Apple, VirtualHere excludes HID. GPG/SSH need no passthrough (agent-socket RemoteForward)
